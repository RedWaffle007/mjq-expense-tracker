import { requireActiveUser } from '../access';
import type { Db } from '../google/firestore';
import { PreconditionFailedError } from '../google/firestore';
import type { Fcm } from '../google/fcm';
import { HttpError, type RouteResult } from '../http';
import type { VerifiedToken } from '../verify-id-token';

export const notificationChannelId = 'expense_activity';

export async function notifyActivity(
  caller: VerifiedToken,
  body: Record<string, unknown>,
  deps: { db: Db; fcm?: Fcm },
): Promise<RouteResult> {
  await requireActiveUser(deps.db, caller.uid);
  const activityId = typeof body.activityId === 'string' ? body.activityId : '';
  if (!/^[A-Za-z0-9_-]{8,64}$/.test(activityId)) throw new HttpError(400, 'invalid-activity-id');
  const activity = await deps.db.getDoc(`activity/${activityId}`);
  if (!activity) throw new HttpError(404, 'activity-not-found');
  if (activity.data.actorId !== caller.uid) throw new HttpError(403, 'forbidden');
  return deliverActivity(activityId, activity, deps);
}

export async function deliverActivity(
  activityId: string,
  activity: { data: Record<string, unknown>; updateTime: string },
  deps: { db: Db; fcm?: Fcm },
): Promise<RouteResult> {
  if (activity.data.notifiedAt != null) return { status: 200, body: { sent: 0, alreadyNotified: true } };
  // Chosen product policy: photo-only activity is visible in-app, but does not push.
  if (activity.data.photoOnly === true) {
    await markNotified(activityId, activity.updateTime, deps.db);
    return { status: 200, body: { sent: 0, skippedPhotoOnly: true } };
  }
  if (!deps.fcm) throw new HttpError(503, 'fcm-unavailable');
  const lease = activity.data.notificationLeaseAt;
  const leaseTime = typeof lease === 'string' ? Date.parse(lease) : Number.NaN;
  if (Number.isFinite(leaseTime) && Date.now() - leaseTime < 5 * 60_000) {
    return { status: 200, body: { sent: 0, alreadyInProgress: true } };
  }
  try {
    await deps.db.commit([{
      path: `activity/${activityId}`,
      data: { notificationLeaseAt: null }, mask: ['notificationLeaseAt'],
      serverTimestamps: ['notificationLeaseAt'], precondition: { updateTime: activity.updateTime },
    }]);
  } catch (error) {
    if (error instanceof PreconditionFailedError) {
      return { status: 200, body: { sent: 0, alreadyInProgress: true } };
    }
    throw error;
  }
  const claimed = await deps.db.getDoc(`activity/${activityId}`);
  if (!claimed) throw new HttpError(404, 'activity-not-found');
  const summary = await notificationSummary(activityId, activity.data, deps.db);
  const users = await deps.db.query('users', { where: [{ field: 'active', op: 'EQUAL', value: true }] });
  let sent = 0;
  let invalid = 0;
  for (const user of users) {
    if (user.id === activity.data.actorId) continue;
    const tokens = Array.isArray(user.data.fcmTokens)
      ? user.data.fcmTokens.filter((token): token is string => typeof token === 'string') : [];
    const keep: string[] = [];
    for (const token of tokens) {
      const result = await deps.fcm.send({
        token,
        notification: { title: 'Expense update', body: summary },
        data: { type: 'expense_activity', activityId, entryId: String(activity.data.entryId ?? '') },
        android: { priority: 'high', notification: { channel_id: notificationChannelId } },
      });
      if (result === 'sent') { sent += 1; keep.push(token); }
      else if (result === 'invalid') invalid += 1;
      else keep.push(token);
    }
    if (keep.length !== tokens.length) {
      await deps.db.commit([{ path: `users/${user.id}`, data: { fcmTokens: keep }, mask: ['fcmTokens'], precondition: { updateTime: user.updateTime } }]);
    }
  }
  // Even zero-token activities are complete: token refresh does not justify stale pushes.
  await markNotified(activityId, claimed.updateTime, deps.db);
  return { status: 200, body: { sent, invalidTokensRemoved: invalid } };
}

async function notificationSummary(activityId: string, activity: Record<string, unknown>, db: Db): Promise<string> {
  const entryId = String(activity.entryId ?? '');
  const [entry, history, actor] = await Promise.all([
    db.getDoc(`entries/${entryId}`),
    db.getDoc(`entries/${entryId}/history/${activityId}`),
    db.getDoc(`users/${String(activity.actorId ?? '')}`),
  ]);
  if (!entry) return String(activity.summary ?? 'An expense changed');
  const site = await db.getDoc(`sites/${String(activity.siteId ?? entry.data.siteId ?? '')}`);
  const who = String(actor?.data.name ?? 'Someone');
  const item = String(entry.data.item ?? 'expense');
  const siteName = String(site?.data.name ?? 'a site');
  const amount = formatPaise(entry.data.amount);
  const quantity = entry.data.quantity == null ? ''
    : ` (${String(entry.data.quantity)}${entry.data.unit ? ` ${String(entry.data.unit)}` : ''})`;
  if (activity.type === 'create') return `${who} added ${item}${quantity} · ${amount} · ${siteName}`;
  if (activity.type === 'delete') return `${who} deleted ${item} · ${amount} · ${siteName}`;
  const amountChange = history?.data.changes && typeof history.data.changes === 'object'
    ? (history.data.changes as Record<string, unknown>).amount : null;
  if (amountChange && typeof amountChange === 'object') {
    const values = amountChange as Record<string, unknown>;
    return `${who} edited ${item} at ${siteName}: Amount ${formatPaise(values.before)} → ${formatPaise(values.after)}`;
  }
  return `${who} edited ${item} · ${siteName}`;
}

function formatPaise(value: unknown): string {
  const rupees = typeof value === 'number' ? value / 100 : 0;
  const fixed = rupees.toFixed(2);
  const [whole, decimal] = fixed.split('.') as [string, string];
  const last = whole.slice(-3);
  const rest = whole.slice(0, -3).replace(/\B(?=(\d{2})+(?!\d))/g, ',');
  return `₹${rest ? `${rest},` : ''}${last}${decimal === '00' ? '' : `.${decimal}`}`;
}

async function markNotified(activityId: string, updateTime: string, db: Db): Promise<void> {
  try {
    await db.commit([{
      path: `activity/${activityId}`,
      data: { notifiedAt: null }, mask: ['notifiedAt'], serverTimestamps: ['notifiedAt'],
      precondition: { updateTime },
    }]);
  } catch (error) {
    if (!(error instanceof PreconditionFailedError)) throw error;
  }
}

export async function sweepActivities(deps: { db: Db; fcm?: Fcm }, now = new Date()): Promise<void> {
  const cutoff = new Date(now.getTime() - 60_000);
  const rows = await deps.db.query('activity', {
    where: [
      { field: 'notifiedAt', op: 'EQUAL', value: null },
      { field: 'createdAt', op: 'LESS_THAN_OR_EQUAL', value: cutoff },
    ],
    orderBy: { field: 'createdAt', direction: 'ASCENDING' }, limit: 10,
  });
  for (const row of rows) {
    try { await deliverActivity(row.id, row, deps); }
    catch (error) { console.error('activity sweep failed', row.id, String(error)); }
  }
}
