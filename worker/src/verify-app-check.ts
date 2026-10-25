import { base64UrlToBytes, base64UrlToJson } from './util';

const JWK_URL = 'https://firebaseappcheck.googleapis.com/v1/jwks';
let cache: { keys: Map<string, CryptoKey>; expires: number } | null = null;

export function resetAppCheckKeyCacheForTests(): void { cache = null; }

export class AppCheckError extends Error {}

export async function verifyAppCheckToken(token: string, projectNumber: string, appId: string): Promise<void> {
  const parts = token.split('.');
  if (parts.length !== 3) throw new AppCheckError('malformed');
  const [head, body, signature] = parts as [string, string, string];
  const header = base64UrlToJson<{ alg?: string; typ?: string; kid?: string }>(head);
  const payload = base64UrlToJson<{ iss?: string; aud?: string[] | string; sub?: string; exp?: number; iat?: number }>(body);
  if (header.alg !== 'RS256' || header.typ !== 'JWT' || !header.kid) throw new AppCheckError('header');
  const key = await publicKey(header.kid);
  if (!key || !await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key,
      base64UrlToBytes(signature), new TextEncoder().encode(`${head}.${body}`))) {
    throw new AppCheckError('signature');
  }
  const now = Math.floor(Date.now() / 1000);
  const audience = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (payload.iss !== `https://firebaseappcheck.googleapis.com/${projectNumber}` ||
      !audience.includes(`projects/${projectNumber}`) || payload.sub !== appId ||
      typeof payload.exp !== 'number' || payload.exp <= now ||
      typeof payload.iat !== 'number' || payload.iat > now + 60) {
    throw new AppCheckError('claims');
  }
}

async function publicKey(kid: string): Promise<CryptoKey | undefined> {
  if (!cache || cache.expires < Date.now()) {
    const response = await fetch(JWK_URL);
    if (!response.ok) throw new AppCheckError('keys');
    const result = await response.json() as { keys: (JsonWebKey & { kid: string })[] };
    const keys = new Map<string, CryptoKey>();
    for (const jwk of result.keys) keys.set(jwk.kid, await crypto.subtle.importKey(
      'jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']));
    const maxAge = Number((response.headers.get('cache-control') ?? '').match(/max-age=(\d+)/)?.[1] ?? 3600);
    cache = { keys, expires: Date.now() + maxAge * 1000 };
  }
  return cache.keys.get(kid);
}
