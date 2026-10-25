// Caller authorization. The users doc is the source of truth (not the token's
// custom claims), so a deactivation takes effect on the very next request.

import type { Db } from './google/firestore';
import { HttpError } from './http';

export type Role = 'ceo' | 'manager';

export interface UserDoc {
  name: string;
  email: string;
  role: Role;
  active: boolean;
}

export function isRole(v: unknown): v is Role {
  return v === 'ceo' || v === 'manager';
}

export async function requireActiveUser(db: Db, uid: string): Promise<UserDoc> {
  const snap = await db.getDoc(`users/${uid}`);
  if (!snap || snap.data.active !== true || !isRole(snap.data.role)) {
    throw new HttpError(403, 'not-active');
  }
  return snap.data as unknown as UserDoc;
}

export async function requireCeo(db: Db, uid: string): Promise<UserDoc> {
  const user = await requireActiveUser(db, uid);
  if (user.role !== 'ceo') throw new HttpError(403, 'ceo-only');
  return user;
}
