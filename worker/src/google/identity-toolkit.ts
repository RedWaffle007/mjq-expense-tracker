// Firebase Auth account admin over the Identity Toolkit REST API
// (projects.accounts.update): custom claims, disabling accounts, and revoking
// sessions. The Admin SDK can't run in a Worker; this is the same call it makes.

export interface AccountUpdate {
  /** Replaces all custom claims. */
  customClaims?: Record<string, unknown>;
  disabled?: boolean;
  /** Revoke every session issued before now. */
  revokeSessions?: boolean;
}

export interface IdentityAdmin {
  updateAccount(uid: string, update: AccountUpdate): Promise<void>;
}

export function makeIdentityAdmin(opts: {
  projectId: string;
  accessToken: string;
  emulatorHost?: string;
}): IdentityAdmin {
  const root = opts.emulatorHost
    ? `http://${opts.emulatorHost}/identitytoolkit.googleapis.com/v1`
    : 'https://identitytoolkit.googleapis.com/v1';
  const url = `${root}/projects/${opts.projectId}/accounts:update`;
  const bearer = opts.emulatorHost ? 'owner' : opts.accessToken;

  return {
    async updateAccount(uid, update) {
      const body: Record<string, unknown> = { localId: uid };
      if (update.customClaims) body.customAttributes = JSON.stringify(update.customClaims);
      if (update.disabled !== undefined) body.disableUser = update.disabled;
      if (update.revokeSessions) body.validSince = String(Math.floor(Date.now() / 1000));

      const resp = await fetch(url, {
        method: 'POST',
        headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!resp.ok) {
        throw new Error(`Identity Toolkit accounts:update → ${resp.status}: ${await resp.text()}`);
      }
    },
  };
}
