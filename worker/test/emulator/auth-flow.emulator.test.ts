// End-to-end check of the real REST transports against the Firebase emulators:
// Google sign-in (emulated) → signup → claims → invite → deactivate.
//
// Run: npm run test:emulator   (starts the Auth + Firestore emulators)

import { beforeAll, describe, expect, it } from 'vitest';

import type { Env } from '../../src/env';
import { handleRequest } from '../../src/index';

const PROJECT = 'demo-mjq';
const FS = process.env.FIRESTORE_EMULATOR_HOST;
const AUTH = process.env.FIREBASE_AUTH_EMULATOR_HOST;

const env: Env = {
  PROJECT_ID: PROJECT,
  EMULATOR: 'true',
  FIRESTORE_EMULATOR_HOST: FS,
  AUTH_EMULATOR_HOST: AUTH,
};

const docUrl = (path: string) =>
  `http://${FS}/v1/projects/${PROJECT}/databases/(default)/documents/${path}`;

async function signInWithGoogle(email: string, sub: string) {
  const resp = await fetch(
    `http://${AUTH}/identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=fake`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        requestUri: 'http://localhost',
        returnSecureToken: true,
        postBody: `id_token=${encodeURIComponent(
          JSON.stringify({ sub, email, email_verified: true }),
        )}&providerId=google.com`,
      }),
    },
  );
  const json = (await resp.json()) as { idToken: string; localId: string };
  return { idToken: json.idToken, uid: json.localId };
}

async function lookup(uid: string) {
  const resp = await fetch(
    `http://${AUTH}/identitytoolkit.googleapis.com/v1/projects/${PROJECT}/accounts:lookup`,
    {
      method: 'POST',
      headers: { Authorization: 'Bearer owner', 'Content-Type': 'application/json' },
      body: JSON.stringify({ localId: [uid] }),
    },
  );
  const json = (await resp.json()) as {
    users: { customAttributes?: string; disabled?: boolean; validSince?: string }[];
  };
  return json.users[0]!;
}

async function getFields(path: string) {
  const resp = await fetch(docUrl(path), { headers: { Authorization: 'Bearer owner' } });
  if (resp.status === 404) return null;
  return ((await resp.json()) as { fields: Record<string, Record<string, unknown>> }).fields;
}

async function call(path: string, idToken: string, body: unknown = {}) {
  const resp = await handleRequest(
    new Request(`https://worker.test${path}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${idToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }),
    env,
  );
  return { status: resp.status, body: (await resp.json()) as Record<string, unknown> };
}

describe.skipIf(!FS || !AUTH)('auth flow against the emulators', () => {
  let ceo: { idToken: string; uid: string };

  beforeAll(async () => {
    await fetch(`http://${FS}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, {
      method: 'DELETE',
    });
    await fetch(`http://${AUTH}/emulator/v1/projects/${PROJECT}/accounts`, { method: 'DELETE' });
    // What bootstrap-ceo.mjs does: an invite for the CEO's email.
    await fetch(docUrl('invites/ceo@gmail.com'), {
      method: 'PATCH',
      headers: { Authorization: 'Bearer owner', 'Content-Type': 'application/json' },
      body: JSON.stringify({
        fields: {
          name: { stringValue: 'The CEO' },
          email: { stringValue: 'ceo@gmail.com' },
          role: { stringValue: 'ceo' },
          invitedBy: { stringValue: 'bootstrap' },
          claimed: { booleanValue: false },
          claimedBy: { nullValue: null },
        },
      }),
    });
    ceo = await signInWithGoogle('CEO@gmail.com', 'google-ceo');
  });

  it('the CEO signs up through the bootstrap invite and gets claims', async () => {
    const r = await call('/signup/complete', ceo.idToken);
    expect(r).toEqual({ status: 200, body: { ok: true, role: 'ceo', name: 'The CEO' } });
    const user = await getFields(`users/${ceo.uid}`);
    expect(user?.role).toEqual({ stringValue: 'ceo' });
    expect(user?.active).toEqual({ booleanValue: true });
    expect(user?.createdAt).toHaveProperty('timestampValue');
    expect(JSON.parse((await lookup(ceo.uid)).customAttributes!)).toEqual({
      role: 'ceo',
      active: true,
    });
    const invite = await getFields('invites/ceo@gmail.com');
    expect(invite?.claimedBy).toEqual({ stringValue: ceo.uid });
  });

  it('an uninvited Google account is blocked', async () => {
    const stranger = await signInWithGoogle('stranger@gmail.com', 'google-stranger');
    const r = await call('/signup/complete', stranger.idToken);
    expect(r).toEqual({ status: 403, body: { error: 'not-invited' } });
    expect(await getFields(`users/${stranger.uid}`)).toBeNull();
  });

  it('the CEO invites a manager, who signs up; the CEO deactivates them', async () => {
    const inv = await call('/invites/create', ceo.idToken, {
      email: 'Manager@Gmail.com',
      phone: '+91 98765 43210',
      name: 'Ravi',
      role: 'manager',
    });
    expect(inv.status).toBe(200);

    const mgr = await signInWithGoogle('manager@gmail.com', 'google-mgr');
    const signup = await call('/signup/complete', mgr.idToken);
    expect(signup.body).toMatchObject({ role: 'manager', name: 'Ravi' });

    // A manager can't use CEO routes.
    const denied = await call('/invites/create', mgr.idToken, {
      email: 'x@gmail.com', name: 'X', role: 'manager',
    });
    expect(denied).toEqual({ status: 403, body: { error: 'ceo-only' } });

    const off = await call('/users/set-active', ceo.idToken, { uid: mgr.uid, active: false });
    expect(off.status).toBe(200);
    expect((await getFields(`users/${mgr.uid}`))?.active).toEqual({ booleanValue: false });
    const account = await lookup(mgr.uid);
    expect(account.disabled).toBe(true);
    expect(JSON.parse(account.customAttributes!)).toEqual({ role: 'manager', active: false });

    // Their old token no longer works for anything, including re-signup.
    expect((await call('/signup/complete', mgr.idToken)).body.error).toBe('deactivated');
  });
});
