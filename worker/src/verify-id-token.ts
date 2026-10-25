// Verifies a Firebase Auth ID token inside the Worker, using Google's published
// JWK set (JWK format imports straight into WebCrypto, no X.509 parsing).
//
// Checks: RS256 with a known kid, valid signature, aud/iss for THIS project,
// not expired, issued in the past, non-empty subject.
//
// Emulator mode: Auth-emulator tokens are unsigned (alg "none"). They are
// accepted ONLY when the caller passes `emulator: true`, which the Worker sets
// from the EMULATOR var that exists only in local .dev.vars.

import { base64UrlToBytes, base64UrlToJson } from './util';

const JWK_URL =
  'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';

const SKEW_SECONDS = 60;

export interface VerifiedToken {
  uid: string;
  email: string | null;
  emailVerified: boolean;
  signInProvider: string | null;
  claims: Record<string, unknown>;
}

export class IdTokenError extends Error {}

interface JwtHeader {
  alg?: string;
  kid?: string;
}

interface JwtPayload {
  aud?: string;
  iss?: string;
  sub?: string;
  exp?: number;
  iat?: number;
  email?: string;
  email_verified?: boolean;
  firebase?: { sign_in_provider?: string };
  [key: string]: unknown;
}

// Per-isolate cache of imported public keys, keyed by kid, expiring per the
// endpoint's Cache-Control max-age. Keeps each request within the CPU limit.
let jwkCache: { keys: Map<string, CryptoKey>; expEpochMs: number } | null = null;

/** Test hook: forget cached keys. */
export function resetJwkCacheForTests(): void {
  jwkCache = null;
}

export async function verifyFirebaseIdToken(
  token: string,
  projectId: string,
  options: { emulator?: boolean } = {},
): Promise<VerifiedToken> {
  const parts = typeof token === 'string' ? token.split('.') : [];
  if (parts.length !== 3) throw new IdTokenError('malformed token');
  const [headerB64, payloadB64, sigB64] = parts as [string, string, string];

  let header: JwtHeader;
  let payload: JwtPayload;
  try {
    header = base64UrlToJson<JwtHeader>(headerB64);
    payload = base64UrlToJson<JwtPayload>(payloadB64);
  } catch {
    throw new IdTokenError('undecodable token');
  }

  if (options.emulator && header.alg === 'none') {
    // Unsigned emulator token: skip the signature, keep every other check.
  } else {
    if (header.alg !== 'RS256' || !header.kid) {
      throw new IdTokenError('unexpected token header');
    }
    const key = await getPublicKey(header.kid);
    if (!key) throw new IdTokenError('unknown signing key');
    const ok = await crypto.subtle.verify(
      'RSASSA-PKCS1-v1_5',
      key,
      base64UrlToBytes(sigB64),
      new TextEncoder().encode(`${headerB64}.${payloadB64}`),
    );
    if (!ok) throw new IdTokenError('bad signature');
  }

  const now = Math.floor(Date.now() / 1000);
  if (payload.aud !== projectId) throw new IdTokenError('wrong audience');
  if (payload.iss !== `https://securetoken.google.com/${projectId}`) {
    throw new IdTokenError('wrong issuer');
  }
  if (typeof payload.exp !== 'number' || payload.exp < now - SKEW_SECONDS) {
    throw new IdTokenError('token expired');
  }
  if (typeof payload.iat !== 'number' || payload.iat > now + SKEW_SECONDS) {
    throw new IdTokenError('token issued in the future');
  }
  if (!payload.sub || typeof payload.sub !== 'string') {
    throw new IdTokenError('missing subject');
  }

  return {
    uid: payload.sub,
    email: typeof payload.email === 'string' ? payload.email.toLowerCase() : null,
    emailVerified: payload.email_verified === true,
    signInProvider: payload.firebase?.sign_in_provider ?? null,
    claims: payload,
  };
}

async function getPublicKey(kid: string): Promise<CryptoKey | undefined> {
  const now = Date.now();
  if (!jwkCache || jwkCache.expEpochMs < now) {
    const resp = await fetch(JWK_URL);
    if (!resp.ok) throw new IdTokenError('could not fetch signing keys');
    const { keys } = (await resp.json()) as { keys: (JsonWebKey & { kid: string })[] };
    const imported = new Map<string, CryptoKey>();
    for (const jwk of keys) {
      const cryptoKey = await crypto.subtle.importKey(
        'jwk',
        jwk,
        { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
        false,
        ['verify'],
      );
      imported.set(jwk.kid, cryptoKey);
    }
    jwkCache = { keys: imported, expEpochMs: now + maxAgeMs(resp) };
  }
  return jwkCache.keys.get(kid);
}

function maxAgeMs(resp: Response): number {
  const m = (resp.headers.get('cache-control') ?? '').match(/max-age=(\d+)/);
  return m ? parseInt(m[1]!, 10) * 1000 : 3_600_000;
}
