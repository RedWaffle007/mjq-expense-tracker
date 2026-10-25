import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import { jsonToBase64Url, bytesToBase64Url } from '../src/util';
import {
  IdTokenError,
  resetJwkCacheForTests,
  verifyFirebaseIdToken,
} from '../src/verify-id-token';

const PROJECT = 'demo-mjq';
const KID = 'test-kid';
let keys: CryptoKeyPair;
let publicJwk: JsonWebKey;

beforeAll(async () => {
  keys = (await crypto.subtle.generateKey(
    {
      name: 'RSASSA-PKCS1-v1_5',
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: 'SHA-256',
    },
    true,
    ['sign', 'verify'],
  )) as CryptoKeyPair;
  publicJwk = (await crypto.subtle.exportKey('jwk', keys.publicKey)) as JsonWebKey;
});

beforeEach(() => {
  resetJwkCacheForTests();
  vi.stubGlobal(
    'fetch',
    vi.fn(async () =>
      new Response(JSON.stringify({ keys: [{ ...publicJwk, kid: KID, alg: 'RS256' }] }), {
        headers: { 'cache-control': 'public, max-age=3600' },
      }),
    ),
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function payload(overrides: Record<string, unknown> = {}) {
  const now = Math.floor(Date.now() / 1000);
  return {
    iss: `https://securetoken.google.com/${PROJECT}`,
    aud: PROJECT,
    sub: 'uid_1',
    iat: now - 10,
    exp: now + 3600,
    email: 'Someone@Example.com',
    email_verified: true,
    firebase: { sign_in_provider: 'google.com' },
    ...overrides,
  };
}

async function sign(p: Record<string, unknown>, header: Record<string, unknown> = {}) {
  const input = `${jsonToBase64Url({ alg: 'RS256', kid: KID, ...header })}.${jsonToBase64Url(p)}`;
  const sig = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    keys.privateKey,
    new TextEncoder().encode(input),
  );
  return `${input}.${bytesToBase64Url(new Uint8Array(sig))}`;
}

function unsigned(p: Record<string, unknown>) {
  return `${jsonToBase64Url({ alg: 'none', typ: 'JWT' })}.${jsonToBase64Url(p)}.`;
}

describe('verifyFirebaseIdToken', () => {
  it('accepts a valid token and returns uid, lowercased email, and provider', async () => {
    const v = await verifyFirebaseIdToken(await sign(payload()), PROJECT);
    expect(v.uid).toBe('uid_1');
    expect(v.email).toBe('someone@example.com');
    expect(v.emailVerified).toBe(true);
    expect(v.signInProvider).toBe('google.com');
  });

  it('rejects a tampered payload', async () => {
    const good = await sign(payload());
    const [h, , s] = good.split('.');
    const forged = `${h}.${jsonToBase64Url(payload({ sub: 'uid_ceo' }))}.${s}`;
    await expect(verifyFirebaseIdToken(forged, PROJECT)).rejects.toBeInstanceOf(IdTokenError);
  });

  it('rejects another project, a wrong issuer, and an expired token', async () => {
    await expect(verifyFirebaseIdToken(await sign(payload({ aud: 'other' })), PROJECT))
      .rejects.toThrow('wrong audience');
    await expect(verifyFirebaseIdToken(await sign(payload({ iss: 'https://evil' })), PROJECT))
      .rejects.toThrow('wrong issuer');
    const past = Math.floor(Date.now() / 1000) - 7200;
    await expect(
      verifyFirebaseIdToken(await sign(payload({ iat: past - 3600, exp: past })), PROJECT),
    ).rejects.toThrow('token expired');
  });

  it('rejects an unknown key id and malformed input', async () => {
    await expect(verifyFirebaseIdToken(await sign(payload(), { kid: 'nope' }), PROJECT))
      .rejects.toThrow('unknown signing key');
    await expect(verifyFirebaseIdToken('not-a-jwt', PROJECT)).rejects.toThrow('malformed');
  });

  it('rejects unsigned (alg none) tokens outside emulator mode', async () => {
    await expect(verifyFirebaseIdToken(unsigned(payload()), PROJECT))
      .rejects.toThrow('unexpected token header');
  });

  it('accepts unsigned emulator tokens only in emulator mode, still checking claims', async () => {
    const v = await verifyFirebaseIdToken(unsigned(payload()), PROJECT, { emulator: true });
    expect(v.uid).toBe('uid_1');
    await expect(
      verifyFirebaseIdToken(unsigned(payload({ aud: 'other' })), PROJECT, { emulator: true }),
    ).rejects.toThrow('wrong audience');
  });
});
