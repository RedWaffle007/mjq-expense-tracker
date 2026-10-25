import { requireActiveUser } from '../access';
import { HttpError, type RouteResult } from '../http';
import type { VerifiedToken } from '../verify-id-token';
import type { Deps } from '../index';

const ID = /^[A-Za-z0-9_-]{1,150}$/;
const PUBLIC_ID = /^bills\/[A-Za-z0-9_-]{1,150}\/[A-Za-z0-9_-]{1,150}\/[a-f0-9-]{36}$/;
const MAX_VIEW_URLS = 40;

export interface CloudinaryConfig {
  cloudName: string;
  apiKey: string;
  apiSecret: string;
}

function config(deps: Deps): CloudinaryConfig {
  const value = deps.cloudinary;
  if (!value?.cloudName || !value.apiKey || !value.apiSecret) {
    throw new HttpError(503, 'photos-not-configured');
  }
  return value;
}

// Cloudinary's default signature algorithm, used by its own SDKs. Short
// (8-character) delivery URL signatures are SHA-1; SHA-256 is only for the
// 32-character long form.
async function sha1(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest('SHA-1', bytes));
}

export async function uploadSignature(
  params: Record<string, string | number>,
  secret: string,
): Promise<string> {
  const serialized = Object.entries(params)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([key, value]) => `${key}=${value}`)
    .join('&');
  const digest = await sha1(new TextEncoder().encode(serialized + secret));
  return [...digest].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

export async function signedDeliveryUrl(
  cloudName: string,
  publicId: string,
  secret: string,
): Promise<string> {
  const assetPath = `${publicId}.jpg`;
  const digest = await sha1(new TextEncoder().encode(assetPath + secret));
  const base64 = btoa(String.fromCharCode(...digest))
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replace(/=+$/, '');
  const encodedPath = publicId.split('/').map(encodeURIComponent).join('/');
  return `https://res.cloudinary.com/${encodeURIComponent(cloudName)}/image/authenticated/s--${base64.slice(0, 8)}--/${encodedPath}.jpg`;
}

export async function signPhotoUpload(
  caller: VerifiedToken,
  body: Record<string, unknown>,
  deps: Deps,
): Promise<RouteResult> {
  await requireActiveUser(deps.db, caller.uid);
  const siteId = body.siteId;
  const entryId = body.entryId;
  if (typeof siteId !== 'string' || !ID.test(siteId)) throw new HttpError(400, 'invalid-site-id');
  if (typeof entryId !== 'string' || !ID.test(entryId)) throw new HttpError(400, 'invalid-entry-id');

  const entry = await deps.db.getDoc(`entries/${entryId}`);
  if (!entry || entry.data.siteId !== siteId || entry.data.isDeleted === true) {
    throw new HttpError(404, 'entry-not-found');
  }

  const cloudinary = config(deps);
  if (deps.verifyCloudinary && !await deps.verifyCloudinary()) {
    throw new HttpError(503, 'cloudinary-credentials-invalid');
  }
  const timestamp = Math.floor(Date.now() / 1000);
  const publicId = `bills/${siteId}/${entryId}/${crypto.randomUUID()}`;
  const params = { format: 'jpg', public_id: publicId, timestamp, type: 'authenticated' };
  const signature = await uploadSignature(params, cloudinary.apiSecret);
  return {
    status: 200,
    body: {
      uploadUrl: `https://api.cloudinary.com/v1_1/${encodeURIComponent(cloudinary.cloudName)}/image/upload`,
      apiKey: cloudinary.apiKey,
      timestamp,
      publicId,
      format: 'jpg',
      type: 'authenticated',
      signature,
    },
  };
}

export async function photoViewUrls(
  caller: VerifiedToken,
  body: Record<string, unknown>,
  deps: Deps,
): Promise<RouteResult> {
  await requireActiveUser(deps.db, caller.uid);
  const publicIds = body.publicIds;
  const variant = body.variant;
  if (!Array.isArray(publicIds) || publicIds.length > MAX_VIEW_URLS
      || publicIds.some((value) => typeof value !== 'string' || !PUBLIC_ID.test(value))
      || (variant !== 'thumb' && variant !== 'full')) {
    throw new HttpError(400, 'invalid-public-ids');
  }
  const cloudinary = config(deps);
  const urls: Record<string, string> = {};
  for (const publicId of publicIds as string[]) {
    urls[publicId] = await signedDeliveryUrl(
      cloudinary.cloudName,
      publicId,
      cloudinary.apiSecret,
    );
  }
  return { status: 200, body: { urls } };
}
