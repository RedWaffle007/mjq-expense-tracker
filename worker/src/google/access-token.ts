// Mints a short-lived Google OAuth2 access token from the service-account
// credential, entirely in the Worker (WebCrypto RS256). The private key lives
// only in the encrypted FIREBASE_SERVICE_ACCOUNT secret.
//
// Scopes: datastore (Firestore REST), firebase.messaging (FCM v1, Milestone 4),
// identitytoolkit (custom claims and account disable).

import { bytesToBase64Url, jsonToBase64Url, pemToBytes } from '../util';

const SCOPES = [
  'https://www.googleapis.com/auth/datastore',
  'https://www.googleapis.com/auth/firebase.messaging',
  'https://www.googleapis.com/auth/identitytoolkit',
].join(' ');

const TOKEN_URI = 'https://oauth2.googleapis.com/token';

export interface ServiceAccount {
  client_email: string;
  private_key: string;
}

// Per-isolate cache. Workers reuse isolates across requests, so we avoid
// re-signing (the expensive part) on every call. Refresh a minute early.
let cached: { token: string; expEpochMs: number } | null = null;

export async function getAccessToken(serviceAccount: ServiceAccount): Promise<string> {
  const now = Date.now();
  if (cached && cached.expEpochMs - 60_000 > now) return cached.token;

  const iat = Math.floor(now / 1000);
  const claims = {
    iss: serviceAccount.client_email,
    scope: SCOPES,
    aud: TOKEN_URI,
    iat,
    exp: iat + 3600,
  };
  const signingInput = `${jsonToBase64Url({ alg: 'RS256', typ: 'JWT' })}.${jsonToBase64Url(claims)}`;

  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToBytes(serviceAccount.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(signingInput),
  );
  const assertion = `${signingInput}.${bytesToBase64Url(new Uint8Array(sig))}`;

  const resp = await fetch(TOKEN_URI, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });
  if (!resp.ok) {
    throw new Error(`OAuth token exchange failed (${resp.status}): ${await resp.text()}`);
  }
  const json = (await resp.json()) as { access_token: string; expires_in?: number };
  cached = {
    token: json.access_token,
    expEpochMs: now + (json.expires_in ?? 3600) * 1000,
  };
  return cached.token;
}
