import { beforeEach, describe, expect, it } from 'vitest';

import type { Env } from '../src/env';
import { handleRequest, type Runtime } from '../src/index';
import { uploadSignature } from '../src/routes/photos';
import { AppCheckError } from '../src/verify-app-check';
import { IdTokenError, type VerifiedToken } from '../src/verify-id-token';
import { FakeDb, FakeIdp, token } from './fakes';

const env: Env = {
  PROJECT_ID: 'demo-mjq',
  APK_DOWNLOAD_URL: 'https://downloads.test/mjq-expense-tracker.apk',
};

let db: FakeDb;
let idp: FakeIdp;
let sentMessages: { token: string; data: Record<string, string> }[];
let invalidTokens: Set<string>;
// The "ID token" in these tests is a key into this map; verification itself is
// covered in verify-id-token.test.ts.
let tokens: Map<string, VerifiedToken>;

const runtime: Runtime = {
  async verify(t) {
    const v = tokens.get(t);
    if (!v) throw new IdTokenError('bad token');
    return v;
  },
  async makeDeps() {
    return {
      db,
      idp,
      fcm: {
        async send(message) {
          sentMessages.push({ token: message.token, data: message.data });
          return invalidTokens.has(message.token) ? 'invalid' as const : 'sent' as const;
        },
      },
      cloudinary: { cloudName: 'mjq-test', apiKey: '123456', apiSecret: 'test-secret' },
    };
  },
};

async function call(path: string, bearer: string | null, body: unknown = {}, method = 'POST') {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (bearer) headers.Authorization = `Bearer ${bearer}`;
  const resp = await handleRequest(
    new Request(`https://worker.test${path}`, {
      method,
      headers,
      body: method === 'POST' ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined,
    }),
    env,
    runtime,
  );
  return { status: resp.status, body: (await resp.json()) as Record<string, unknown> };
}

function seedUser(uid: string, role: 'ceo' | 'manager', active = true) {
  db.seed(`users/${uid}`, { name: uid, email: `${uid}@example.com`, role, active, fcmTokens: [] });
}

beforeEach(() => {
  db = new FakeDb();
  idp = new FakeIdp();
  sentMessages = [];
  invalidTokens = new Set();
  tokens = new Map([
    ['ceo', token('ceo')],
    ['mgr', token('mgr')],
    ['new', token('new', { email: 'new.person@gmail.com' })],
  ]);
  seedUser('ceo', 'ceo');
  seedUser('mgr', 'manager');
});

describe('/notify', () => {
  beforeEach(() => {
    db.seed('users/ceo', { name: 'Boss', role: 'ceo', active: true, fcmTokens: ['ceo-token'] });
    db.seed('users/mgr', { name: 'Manager', role: 'manager', active: true, fcmTokens: ['mgr-token', 'dead-token'] });
    db.seed('users/third', { name: 'Third', role: 'manager', active: true, fcmTokens: ['third-token'] });
    db.seed('activity/activity01', {
      actorId: 'mgr', entryId: 'entry-1', summary: 'Manager added cement',
      photoOnly: false, notifiedAt: null, createdAt: '2026-09-27T00:00:00.000Z',
    });
  });

  it('sends to every active user except the actor and is idempotent', async () => {
    const first = await call('/notify', 'mgr', { activityId: 'activity01' });
    expect(first.status).toBe(200);
    expect(sentMessages.map((message) => message.token)).toEqual(['ceo-token', 'third-token']);
    expect(db.data('activity/activity01')?.notifiedAt).toBe('SERVER_TIME');
    const second = await call('/notify', 'mgr', { activityId: 'activity01' });
    expect(second.body).toMatchObject({ sent: 0, alreadyNotified: true });
    expect(sentMessages).toHaveLength(2);
  });

  it('removes invalid tokens and rejects a caller who did not create the activity', async () => {
    invalidTokens.add('dead-token');
    db.seed('activity/activity02', {
      actorId: 'ceo', entryId: 'entry-2', summary: 'Boss edited steel',
      photoOnly: false, notifiedAt: null, createdAt: '2026-09-27T00:00:00.000Z',
    });
    expect((await call('/notify', 'mgr', { activityId: 'activity02' })).status).toBe(403);
    const result = await call('/notify', 'ceo', { activityId: 'activity02' });
    expect(result.body.invalidTokensRemoved).toBe(1);
    expect(db.data('users/mgr')?.fcmTokens).toEqual(['mgr-token']);
  });

  it('logs photo-only activity without sending a push', async () => {
    db.seed('activity/activity03', {
      actorId: 'mgr', entryId: 'entry-3', summary: 'Added photo',
      photoOnly: true, notifiedAt: null, createdAt: '2026-09-27T00:00:00.000Z',
    });
    const result = await call('/notify', 'mgr', { activityId: 'activity03' });
    expect(result.body).toMatchObject({ sent: 0, skippedPhotoOnly: true });
    expect(sentMessages).toHaveLength(0);
  });
});

describe('shell', () => {
  it('is POST-only', async () => {
    const r = await call('/signup/complete', 'ceo', {}, 'GET');
    expect(r.status).toBe(405);
  });

  it('404s unknown paths', async () => {
    expect((await call('/nope', 'ceo')).status).toBe(404);
  });

  it('rejects missing and invalid tokens with 401', async () => {
    expect((await call('/signup/complete', null)).status).toBe(401);
    expect((await call('/signup/complete', 'forged')).status).toBe(401);
  });

  it('rejects unattested requests unless App Check is in monitor mode', async () => {
    const attesting: Runtime = {
      ...runtime,
      async verifyAppCheck() { throw new AppCheckError('invalid'); },
    };
    const request = () => new Request('https://worker.test/signup/complete', {
      method: 'POST', headers: { Authorization: 'Bearer mgr' }, body: '{}',
    });
    const enforced = await handleRequest(request(), env, attesting);
    expect(enforced.status).toBe(401);
    expect(await enforced.json()).toEqual({ error: 'invalid-app-check' });
    const monitored = await handleRequest(
      request(), { ...env, APP_CHECK_ENFORCE: 'false' }, attesting,
    );
    expect(monitored.status).toBe(200);
  });

  it('rejects oversized and non-object bodies', async () => {
    expect((await call('/invites/create', 'ceo', { name: 'x'.repeat(5000) })).status).toBe(413);
    expect((await call('/invites/create', 'ceo', '[1,2]')).status).toBe(400);
    expect((await call('/invites/create', 'ceo', '{oops')).status).toBe(400);
  });
});

describe('/signup/complete', () => {
  function invite(email: string, extra: Record<string, unknown> = {}) {
    db.seed(`invites/${email}`, {
      name: 'New Person', email, role: 'manager', invitedBy: 'ceo',
      claimed: false, claimedBy: null, ...extra,
    });
  }

  it('blocks an uninvited Google account', async () => {
    const r = await call('/signup/complete', 'new');
    expect(r).toEqual({ status: 403, body: { error: 'not-invited' } });
    expect(db.data('users/new')).toBeUndefined();
    expect(idp.calls).toHaveLength(0);
  });

  it('signs up an invited account: user doc, claims, invite claimed', async () => {
    invite('new.person@gmail.com');
    const r = await call('/signup/complete', 'new');
    expect(r).toEqual({ status: 200, body: { ok: true, role: 'manager', name: 'New Person' } });
    expect(db.data('users/new')).toMatchObject({
      name: 'New Person', email: 'new.person@gmail.com', role: 'manager',
      active: true, fcmTokens: [], createdAt: 'SERVER_TIME',
    });
    expect(db.data('invites/new.person@gmail.com')).toMatchObject({ claimed: true, claimedBy: 'new' });
    expect(idp.last('new')).toEqual({ customClaims: { role: 'manager', active: true } });
  });

  it('ignores an email in the request body (uses the verified token only)', async () => {
    invite('victim@gmail.com', { role: 'ceo' });
    const r = await call('/signup/complete', 'new', { email: 'victim@gmail.com' });
    expect(r.status).toBe(403);
    expect(db.data('invites/victim@gmail.com')).toMatchObject({ claimed: false });
  });

  it('requires a verified email and Google sign-in', async () => {
    invite('new.person@gmail.com');
    tokens.set('unverified', token('new', { email: 'new.person@gmail.com', emailVerified: false }));
    tokens.set('password', token('new', { email: 'new.person@gmail.com', signInProvider: 'password' }));
    expect((await call('/signup/complete', 'unverified')).body.error).toBe('email-not-verified');
    expect((await call('/signup/complete', 'password')).body.error).toBe('google-sign-in-required');
  });

  it('refuses an invite already claimed by a different account', async () => {
    invite('new.person@gmail.com', { claimed: true, claimedBy: 'someone-else' });
    expect((await call('/signup/complete', 'new')).body.error).toBe('invite-already-used');
  });

  it('never reactivates a deactivated user', async () => {
    seedUser('new', 'manager', false);
    invite('new.person@gmail.com', { claimed: true, claimedBy: 'new' });
    const r = await call('/signup/complete', 'new');
    expect(r).toEqual({ status: 403, body: { error: 'deactivated' } });
    expect(db.data('users/new')).toMatchObject({ active: false });
    expect(idp.calls).toHaveLength(0);
  });

  it('repairs claims for an existing active user (retry after a partial failure)', async () => {
    const r = await call('/signup/complete', 'mgr');
    expect(r.status).toBe(200);
    expect(idp.last('mgr')).toEqual({ customClaims: { role: 'manager', active: true } });
  });
});

describe('/invites/create', () => {
  const body = {
    email: '  Ravi.Manager@Example.com ', phone: '98765 43210', name: ' Ravi ', role: 'manager',
  };

  it('lets the CEO invite by email and phone (normalized)', async () => {
    const r = await call('/invites/create', 'ceo', body);
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({
      ok: true, email: 'ravi.manager@example.com', phone: '+919876543210',
    });
    expect(r.body.inviteUrl).toMatch(/^https:\/\/worker\.test\/join\/[a-f0-9]{32}$/);
    expect(db.data('invites/ravi.manager@example.com')).toMatchObject({
      name: 'Ravi', email: 'ravi.manager@example.com', phone: '+919876543210', role: 'manager',
      invitedBy: 'ceo', claimed: false, claimedBy: null, createdAt: 'SERVER_TIME',
    });
    const token = (r.body.inviteUrl as string).split('/').at(-1)!;
    expect(db.data(`inviteLinks/${token}`)).toMatchObject({
      email: 'ravi.manager@example.com', createdAt: 'SERVER_TIME',
    });
  });

  it('blocks managers and deactivated CEOs', async () => {
    expect((await call('/invites/create', 'mgr', body)).body.error).toBe('ceo-only');
    seedUser('ceo', 'ceo', false);
    expect((await call('/invites/create', 'ceo', body)).body.error).toBe('not-active');
  });

  it('validates email, name, and role', async () => {
    expect((await call('/invites/create', 'ceo', { ...body, email: 'nope' })).body.error).toBe('invalid-email');
    expect((await call('/invites/create', 'ceo', { ...body, email: 'a/b@x.com' })).body.error).toBe('invalid-email');
    expect((await call('/invites/create', 'ceo', { ...body, name: '' })).body.error).toBe('invalid-name');
    expect((await call('/invites/create', 'ceo', { ...body, phone: '123' })).body.error).toBe('invalid-phone');
    expect((await call('/invites/create', 'ceo', { ...body, role: 'admin' })).body.error).toBe('invalid-role');
  });

  it('updates an unclaimed invite but refuses a claimed one', async () => {
    await call('/invites/create', 'ceo', body);
    const again = await call('/invites/create', 'ceo', { ...body, name: 'Ravi K' });
    expect(again.status).toBe(200);
    expect(db.data('invites/ravi.manager@example.com')).toMatchObject({ name: 'Ravi K' });

    db.seed('invites/taken@gmail.com', { email: 'taken@gmail.com', claimed: true, claimedBy: 'x' });
    const r = await call('/invites/create', 'ceo', { ...body, email: 'taken@gmail.com' });
    expect(r).toEqual({ status: 409, body: { error: 'already-registered' } });
  });

  it('serves only the current unclaimed opaque invitation link', async () => {
    const created = await call('/invites/create', 'ceo', body);
    const inviteUrl = created.body.inviteUrl as string;
    const active = await handleRequest(new Request(inviteUrl), env, runtime);
    expect(active.status).toBe(200);
    expect(active.headers.get('content-type')).toContain('text/html');
    expect(await active.text()).toContain('Download the Android app');

    const token = inviteUrl.split('/').at(-1)!;
    db.seed('invites/ravi.manager@example.com', {
      ...db.data('invites/ravi.manager@example.com'), claimed: true, claimedBy: 'new',
    });
    const used = await handleRequest(
      new Request(`https://worker.test/join/${token}`), env, runtime,
    );
    expect(used.status).toBe(410);
    expect((await handleRequest(
      new Request('https://worker.test/join/not-a-token'), env, runtime,
    )).status).toBe(404);
  });
});

describe('/users/set-active', () => {
  it('blocks managers', async () => {
    const r = await call('/users/set-active', 'mgr', { uid: 'ceo', active: false });
    expect(r.body.error).toBe('ceo-only');
    expect(db.data('users/ceo')).toMatchObject({ active: true });
  });

  it('refuses to let the CEO change themselves', async () => {
    const r = await call('/users/set-active', 'ceo', { uid: 'ceo', active: false });
    expect(r.body.error).toBe('cannot-change-self');
  });

  it('deactivation flips the doc, drops the claim, disables and revokes', async () => {
    const r = await call('/users/set-active', 'ceo', { uid: 'mgr', active: false });
    expect(r.status).toBe(200);
    expect(db.data('users/mgr')).toMatchObject({ active: false, role: 'manager' });
    expect(idp.last('mgr')).toEqual({
      customClaims: { role: 'manager', active: false },
      disabled: true,
      revokeSessions: true,
    });
  });

  it('a deactivated user is locked out of the Worker immediately', async () => {
    await call('/users/set-active', 'ceo', { uid: 'mgr', active: false });
    seedUser('mgr', 'ceo', false); // even if they had been CEO
    expect((await call('/invites/create', 'mgr', { email: 'a@b.co', name: 'A', role: 'manager' })).body.error)
      .toBe('not-active');
  });

  it('reactivation restores the claim and re-enables the account', async () => {
    seedUser('mgr', 'manager', false);
    await call('/users/set-active', 'ceo', { uid: 'mgr', active: true });
    expect(db.data('users/mgr')).toMatchObject({ active: true });
    expect(idp.last('mgr')).toEqual({
      customClaims: { role: 'manager', active: true },
      disabled: false,
      revokeSessions: false,
    });
  });

  it('validates the body and 404s unknown users', async () => {
    expect((await call('/users/set-active', 'ceo', { uid: 'mgr', active: 'no' })).body.error).toBe('invalid-active');
    expect((await call('/users/set-active', 'ceo', { uid: 'a/b', active: false })).body.error).toBe('invalid-uid');
    expect((await call('/users/set-active', 'ceo', { uid: 'ghost', active: false })).status).toBe(404);
  });
});

describe('photo signing', () => {
  beforeEach(() => {
    db.seed('entries/entry_1', { siteId: 'site_a', isDeleted: false });
  });

  it('issues a tightly scoped authenticated upload signature to active users', async () => {
    const r = await call('/photos/sign-upload', 'mgr', { siteId: 'site_a', entryId: 'entry_1' });
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({
      uploadUrl: 'https://api.cloudinary.com/v1_1/mjq-test/image/upload',
      apiKey: '123456', format: 'jpg', type: 'authenticated',
    });
    expect(r.body.publicId).toMatch(/^bills\/site_a\/entry_1\/[a-f0-9-]{36}$/);
    expect(r.body.signature).toMatch(/^[a-f0-9]{40}$/);
  });

  it('matches the example signature in Cloudinary\'s documentation', async () => {
    expect(await uploadSignature({
      timestamp: 1315060510,
      public_id: 'sample_image',
      eager: 'w_400,h_300,c_pad|w_260,h_200,c_crop',
    }, 'abcd')).toBe('bfd09f95f331f558cbd1320e67aa8d488770583e');
  });

  it('requires a matching live entry and an active app user', async () => {
    expect((await call('/photos/sign-upload', 'mgr', {
      siteId: 'site_b', entryId: 'entry_1',
    })).body.error).toBe('entry-not-found');
    seedUser('mgr', 'manager', false);
    expect((await call('/photos/sign-upload', 'mgr', {
      siteId: 'site_a', entryId: 'entry_1',
    })).body.error).toBe('not-active');
  });

  it('returns signed authenticated view URLs and caps each request', async () => {
    const publicId = 'bills/site_a/entry_1/123e4567-e89b-12d3-a456-426614174000';
    const r = await call('/photos/view-urls', 'mgr', { publicIds: [publicId], variant: 'full' });
    expect(r.status).toBe(200);
    expect((r.body.urls as Record<string, string>)[publicId]).toMatch(
      /^https:\/\/res\.cloudinary\.com\/mjq-test\/image\/authenticated\/s--[A-Za-z0-9_-]{8}--\/bills\/site_a\/entry_1\/[a-f0-9-]{36}\.jpg$/,
    );
    expect((await call('/photos/view-urls', 'mgr', {
      publicIds: Array.from({ length: 41 }, () => publicId), variant: 'full',
    })).body.error).toBe('invalid-public-ids');
    expect((await call('/photos/view-urls', 'mgr', {
      publicIds: ['other/secret'], variant: 'full',
    })).status).toBe(400);
  });
});
