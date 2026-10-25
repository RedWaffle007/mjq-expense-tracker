// POST /invites/create — CEO only. Body: { email, phone, name, role }.
// Re-inviting an unclaimed email updates the invite; a claimed one is refused.

import { isRole, requireCeo } from '../access';
import { PreconditionFailedError, type Db } from '../google/firestore';
import { HttpError, ok, stringField, type RouteResult } from '../http';
import type { VerifiedToken } from '../verify-id-token';

const EMAIL_RE = /^[^\s@/]+@[^\s@/]+\.[^\s@/]+$/;

function normalizePhone(value: string): string {
  let phone = value.replace(/[\s()-]/g, '');
  if (/^\d{10}$/.test(phone)) phone = `+91${phone}`;
  if (phone.startsWith('00')) phone = `+${phone.slice(2)}`;
  if (!/^\+[1-9]\d{7,14}$/.test(phone)) throw new HttpError(400, 'invalid-phone');
  return phone;
}

export async function createInvite(
  caller: VerifiedToken,
  body: Record<string, unknown>,
  deps: { db: Db; inviteBaseUrl?: string },
): Promise<RouteResult> {
  const { db } = deps;
  await requireCeo(db, caller.uid);

  const email = stringField(body, 'email', { max: 254 }).toLowerCase();
  if (!EMAIL_RE.test(email)) throw new HttpError(400, 'invalid-email');
  const name = stringField(body, 'name', { max: 80 });
  const phone = normalizePhone(stringField(body, 'phone', { max: 30 }));
  const role = body.role;
  if (!isRole(role)) throw new HttpError(400, 'invalid-role');

  const existing = await db.getDoc(`invites/${email}`);
  if (existing?.data.claimed === true) throw new HttpError(409, 'already-registered');

  const inviteToken = crypto.randomUUID().replaceAll('-', '');
  try {
    await db.commit([
      {
        path: `invites/${email}`,
        data: {
          name, email, phone, role, invitedBy: caller.uid, inviteToken,
          claimed: false, claimedBy: null,
        },
        serverTimestamps: ['createdAt'],
        precondition: existing ? { updateTime: existing.updateTime } : { exists: false },
      },
      {
        path: `inviteLinks/${inviteToken}`,
        data: { email },
        serverTimestamps: ['createdAt'],
        precondition: { exists: false },
      },
    ]);
  } catch (e) {
    if (e instanceof PreconditionFailedError) throw new HttpError(409, 'retry');
    throw e;
  }
  const base = deps.inviteBaseUrl ?? 'https://mjq-worker.timeapp.workers.dev';
  return ok({ email, phone, inviteUrl: `${base}/join/${inviteToken}` });
}
