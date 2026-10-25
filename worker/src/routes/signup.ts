// POST /signup/complete — first sign-in of an invited Google account.
//
// The email comes ONLY from the verified ID token, never from the request body,
// so nobody can claim someone else's invite.

import { isRole } from '../access';
import { PreconditionFailedError, type Db } from '../google/firestore';
import type { IdentityAdmin } from '../google/identity-toolkit';
import { HttpError, ok, type RouteResult } from '../http';
import type { VerifiedToken } from '../verify-id-token';

export async function completeSignup(
  caller: VerifiedToken,
  deps: { db: Db; idp: IdentityAdmin },
): Promise<RouteResult> {
  const { db, idp } = deps;
  const { uid } = caller;

  if (caller.signInProvider !== 'google.com') throw new HttpError(403, 'google-sign-in-required');
  if (!caller.email || !caller.emailVerified) throw new HttpError(403, 'email-not-verified');

  // Already signed up: never reactivate here (only the CEO can), but repair the
  // claims in case a previous attempt failed after creating the doc.
  const existing = await db.getDoc(`users/${uid}`);
  if (existing) {
    const { role, active, name } = existing.data;
    if (active !== true || !isRole(role)) throw new HttpError(403, 'deactivated');
    await idp.updateAccount(uid, { customClaims: { role, active: true } });
    return ok({ role, name });
  }

  const email = caller.email;
  const invite = await db.getDoc(`invites/${email}`);
  if (!invite) throw new HttpError(403, 'not-invited');
  const { role, name, claimed, claimedBy } = invite.data;
  if (!isRole(role) || typeof name !== 'string') throw new HttpError(500, 'bad-invite');
  if (claimed === true && claimedBy !== uid) throw new HttpError(403, 'invite-already-used');

  try {
    await db.commit([
      {
        path: `users/${uid}`,
        data: { name, email, role, active: true, fcmTokens: [] },
        serverTimestamps: ['createdAt'],
        precondition: { exists: false },
      },
      {
        path: `invites/${email}`,
        data: { claimed: true, claimedBy: uid },
        mask: ['claimed', 'claimedBy'],
        precondition: { updateTime: invite.updateTime },
      },
    ]);
  } catch (e) {
    // Another request (a double tap) won the race; the app simply retries.
    if (e instanceof PreconditionFailedError) throw new HttpError(409, 'retry');
    throw e;
  }

  await idp.updateAccount(uid, { customClaims: { role, active: true } });
  return ok({ role, name });
}
