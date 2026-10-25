// POST /users/set-active — CEO only. Body: { uid, active }.
//
// The users doc flips first: the security rules and the Worker both check it,
// so access ends on the next request. Then the claims are updated, and on
// deactivation the account is disabled and its sessions revoked so it can't
// sign in again or refresh its token.

import { isRole, requireCeo } from '../access';
import { PreconditionFailedError, type Db } from '../google/firestore';
import type { IdentityAdmin } from '../google/identity-toolkit';
import { HttpError, ok, stringField, type RouteResult } from '../http';
import type { VerifiedToken } from '../verify-id-token';

export async function setUserActive(
  caller: VerifiedToken,
  body: Record<string, unknown>,
  deps: { db: Db; idp: IdentityAdmin },
): Promise<RouteResult> {
  const { db, idp } = deps;
  await requireCeo(db, caller.uid);

  const uid = stringField(body, 'uid', { max: 128 });
  if (uid.includes('/')) throw new HttpError(400, 'invalid-uid');
  const active = body.active;
  if (typeof active !== 'boolean') throw new HttpError(400, 'invalid-active');
  if (uid === caller.uid) throw new HttpError(400, 'cannot-change-self');

  const target = await db.getDoc(`users/${uid}`);
  if (!target) throw new HttpError(404, 'user-not-found');
  const role = target.data.role;
  if (!isRole(role)) throw new HttpError(500, 'bad-user');

  try {
    await db.commit([
      {
        path: `users/${uid}`,
        data: { active },
        mask: ['active'],
        precondition: { updateTime: target.updateTime },
      },
    ]);
  } catch (e) {
    if (e instanceof PreconditionFailedError) throw new HttpError(409, 'retry');
    throw e;
  }

  await idp.updateAccount(uid, {
    customClaims: { role, active },
    disabled: !active,
    revokeSessions: !active,
  });
  return ok({ uid, active });
}
