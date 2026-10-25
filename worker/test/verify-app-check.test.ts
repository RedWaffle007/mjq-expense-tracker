import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { bytesToBase64Url, jsonToBase64Url } from '../src/util';
import { AppCheckError, resetAppCheckKeyCacheForTests, verifyAppCheckToken } from '../src/verify-app-check';

const PROJECT = '71897827045';
const APP = `1:${PROJECT}:android:test`;
const KID = 'app-check-test-key';
let keys: CryptoKeyPair;
let publicJwk: JsonWebKey;

beforeAll(async () => {
  keys = await crypto.subtle.generateKey({
    name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256',
  }, true, ['sign', 'verify']) as CryptoKeyPair;
  publicJwk = (await crypto.subtle.exportKey('jwk', keys.publicKey)) as JsonWebKey;
});

beforeEach(() => {
  resetAppCheckKeyCacheForTests();
  vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
    keys: [{ ...publicJwk, kid: KID, alg: 'RS256' }],
  }), { headers: { 'cache-control': 'max-age=3600' } })));
});
afterEach(() => vi.unstubAllGlobals());

async function token(overrides: Record<string, unknown> = {}) {
  const now = Math.floor(Date.now() / 1000);
  const header = jsonToBase64Url({ alg: 'RS256', typ: 'JWT', kid: KID });
  const body = jsonToBase64Url({
    iss: `https://firebaseappcheck.googleapis.com/${PROJECT}`,
    aud: [`projects/${PROJECT}`], sub: APP, iat: now - 5, exp: now + 3600,
    ...overrides,
  });
  const input = `${header}.${body}`;
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', keys.privateKey, new TextEncoder().encode(input));
  return `${input}.${bytesToBase64Url(new Uint8Array(signature))}`;
}

describe('verifyAppCheckToken', () => {
  it('accepts a valid token for this Firebase app', async () => {
    await expect(verifyAppCheckToken(await token(), PROJECT, APP)).resolves.toBeUndefined();
  });
  it('rejects a wrong app, project audience, expired token, and malformed token', async () => {
    await expect(verifyAppCheckToken(await token({ sub: 'other-app' }), PROJECT, APP)).rejects.toBeInstanceOf(AppCheckError);
    await expect(verifyAppCheckToken(await token({ aud: ['projects/other'] }), PROJECT, APP)).rejects.toBeInstanceOf(AppCheckError);
    await expect(verifyAppCheckToken(await token({ exp: 1 }), PROJECT, APP)).rejects.toBeInstanceOf(AppCheckError);
    await expect(verifyAppCheckToken('bad', PROJECT, APP)).rejects.toBeInstanceOf(AppCheckError);
  });
});
