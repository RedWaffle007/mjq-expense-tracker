// In-memory stand-ins for the Google transports, with the same precondition
// semantics as Firestore's commit (atomic: all writes apply or none do).

import { PreconditionFailedError, type Db, type DocWrite } from '../src/google/firestore';
import type { AccountUpdate, IdentityAdmin } from '../src/google/identity-toolkit';
import type { VerifiedToken } from '../src/verify-id-token';

export class FakeDb implements Db {
  docs = new Map<string, { data: Record<string, unknown>; updateTime: string }>();
  private clock = 0;

  seed(path: string, data: Record<string, unknown>): void {
    this.docs.set(path, { data: { ...data }, updateTime: this.tick() });
  }

  data(path: string): Record<string, unknown> | undefined {
    return this.docs.get(path)?.data;
  }

  async getDoc(path: string) {
    const d = this.docs.get(path);
    return d ? { data: { ...d.data }, updateTime: d.updateTime } : null;
  }

  async query(collection: string, options: Parameters<Db['query']>[1] = {}) {
    let rows = [...this.docs.entries()]
      .filter(([path]) => path.startsWith(`${collection}/`) && path.split('/').length === 2)
      .map(([path, value]) => ({ id: path.split('/')[1]!, data: { ...value.data }, updateTime: value.updateTime }));
    for (const condition of options?.where ?? []) {
      rows = rows.filter((row) => condition.op === 'EQUAL'
        ? row.data[condition.field] === condition.value
        : String(row.data[condition.field]) <= String(condition.value));
    }
    if (options?.orderBy) {
      const { field, direction } = options.orderBy;
      rows.sort((a, b) => String(a.data[field]).localeCompare(String(b.data[field])) *
        (direction === 'DESCENDING' ? -1 : 1));
    }
    return rows.slice(0, options?.limit ?? rows.length);
  }

  async commit(writes: DocWrite[]): Promise<void> {
    for (const w of writes) {
      const cur = this.docs.get(w.path);
      const p = w.precondition;
      if (p && 'exists' in p && p.exists !== !!cur) throw new PreconditionFailedError(w.path);
      if (p && 'updateTime' in p && cur?.updateTime !== p.updateTime) {
        throw new PreconditionFailedError(w.path);
      }
    }
    for (const w of writes) {
      const cur = this.docs.get(w.path);
      const base = w.mask ? { ...(cur?.data ?? {}) } : {};
      const fields = w.mask
        ? Object.fromEntries(w.mask.map((k) => [k, w.data[k]]))
        : w.data;
      const next: Record<string, unknown> = { ...base, ...fields };
      for (const f of w.serverTimestamps ?? []) next[f] = 'SERVER_TIME';
      this.docs.set(w.path, { data: next, updateTime: this.tick() });
    }
  }

  private tick(): string {
    return `t${++this.clock}`;
  }
}

export class FakeIdp implements IdentityAdmin {
  calls: { uid: string; update: AccountUpdate }[] = [];
  async updateAccount(uid: string, update: AccountUpdate): Promise<void> {
    this.calls.push({ uid, update });
  }
  last(uid: string): AccountUpdate | undefined {
    return [...this.calls].reverse().find((c) => c.uid === uid)?.update;
  }
}

export function token(uid: string, overrides: Partial<VerifiedToken> = {}): VerifiedToken {
  return {
    uid,
    email: `${uid}@example.com`,
    emailVerified: true,
    signInProvider: 'google.com',
    claims: {},
    ...overrides,
  };
}
