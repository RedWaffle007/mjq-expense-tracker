// Cloudflare Worker entry point (plan.md Section 6). A thin shell: check the
// method, cap the body, verify the Firebase ID token, build the Google
// transports, and hand off to a route. Fails closed: any unexpected error is a
// 500 and nothing half-done is reported as success.

import { enforcesAppCheck, isEmulator, type Env } from './env';
import { getAccessToken, type ServiceAccount } from './google/access-token';
import { makeFirestoreDb, type Db } from './google/firestore';
import { makeFcm, type Fcm } from './google/fcm';
import { makeIdentityAdmin, type IdentityAdmin } from './google/identity-toolkit';
import { HttpError, json, type RouteResult } from './http';
import { createInvite } from './routes/invites';
import { completeSignup } from './routes/signup';
import { setUserActive } from './routes/users';
import { photoViewUrls, signPhotoUpload, type CloudinaryConfig } from './routes/photos';
import { notifyActivity, sweepActivities } from './routes/notify';
import { IdTokenError, verifyFirebaseIdToken, type VerifiedToken } from './verify-id-token';
import { AppCheckError, verifyAppCheckToken } from './verify-app-check';

const MAX_BODY_BYTES = 4096;

export interface Deps {
  db: Db;
  idp: IdentityAdmin;
  inviteBaseUrl?: string;
  cloudinary?: CloudinaryConfig;
  verifyCloudinary?: () => Promise<boolean>;
  fcm?: Fcm;
}

type Route = (
  caller: VerifiedToken,
  body: Record<string, unknown>,
  deps: Deps,
) => Promise<RouteResult>;

const ROUTES: Record<string, Route> = {
  '/signup/complete': (caller, _body, deps) => completeSignup(caller, deps),
  '/invites/create': createInvite,
  '/users/set-active': setUserActive,
  '/photos/sign-upload': signPhotoUpload,
  '/photos/view-urls': photoViewUrls,
  '/notify': notifyActivity,
};

const ANDROID_PACKAGE = 'com.mjq.expensetracker';
const DEBUG_SHA256 = '1E:22:4B:C3:AF:38:AD:0B:C7:53:30:4D:30:30:12:0A:35:37:AF:6B:BB:3C:21:9B:27:36:84:03:47:09:7E:E8';

function assetLinks(): Response {
  return new Response(JSON.stringify([{
    relation: ['delegate_permission/common.handle_all_urls'],
    target: {
      namespace: 'android_app',
      package_name: ANDROID_PACKAGE,
      sha256_cert_fingerprints: [DEBUG_SHA256],
    },
  }]), { headers: { 'Content-Type': 'application/json; charset=utf-8' } });
}

async function inviteLanding(path: string, deps: Deps, apkDownloadUrl?: string): Promise<Response> {
  const token = path.slice('/join/'.length);
  if (!/^[a-f0-9]{32}$/.test(token)) return new Response('Not found', { status: 404 });
  const link = await deps.db.getDoc(`inviteLinks/${token}`);
  const email = link?.data.email;
  const invite = typeof email === 'string' ? await deps.db.getDoc(`invites/${email}`) : null;
  const valid = invite?.data.inviteToken === token && invite.data.claimed !== true;
  if (!valid) return new Response('This invitation is no longer active.', { status: 410 });

  const install = apkDownloadUrl
    ? `<a href="${apkDownloadUrl}">Download the Android app</a><p class="help">Android may ask you to allow installation from your browser. After installing, open the app and sign in with the invited Google account.</p>`
    : '<p class="help">Ask the CEO for the current app installation file, then open this invitation again.</p>';
  const html = `<!doctype html><html lang="en"><meta name="viewport" content="width=device-width,initial-scale=1"><title>MJQ invitation</title><style>body{font:16px system-ui;margin:0;background:#f7f7f7;color:#202124}.card{max-width:440px;margin:12vh auto;padding:32px;background:white;border-radius:16px;box-shadow:0 4px 24px #0002}a{display:inline-block;margin-top:16px;padding:12px 18px;border-radius:24px;background:#176b52;color:white;text-decoration:none}.help{color:#5f6368;font-size:14px;line-height:1.5}</style><main class="card"><h1>You're invited</h1><p>Install MJQ Builders &amp; Developers, then sign in with the Google account that was invited.</p>${install}</main></html>`;
  return new Response(html, { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
}

/** Seams for tests: token verification and the Google transports. */
export interface Runtime {
  verify(token: string, env: Env): Promise<VerifiedToken>;
  verifyAppCheck?(token: string, env: Env): Promise<void>;
  makeDeps(env: Env): Promise<Deps>;
}

export const defaultRuntime: Runtime = {
  verify: (token, env) =>
    verifyFirebaseIdToken(token, env.PROJECT_ID, { emulator: isEmulator(env) }),
  verifyAppCheck: (token, env) => {
    if (isEmulator(env)) return Promise.resolve();
    if (!env.PROJECT_NUMBER || !env.ANDROID_APP_ID) throw new AppCheckError('configuration');
    return verifyAppCheckToken(token, env.PROJECT_NUMBER, env.ANDROID_APP_ID);
  },

  async makeDeps(env) {
    if (isEmulator(env)) {
      const base = { projectId: env.PROJECT_ID, accessToken: 'owner' };
      return {
        db: makeFirestoreDb({ ...base, emulatorHost: env.FIRESTORE_EMULATOR_HOST }),
        idp: makeIdentityAdmin({ ...base, emulatorHost: env.AUTH_EMULATOR_HOST }),
      };
    }
    let serviceAccount: ServiceAccount;
    try {
      serviceAccount = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT ?? '') as ServiceAccount;
    } catch {
      throw new HttpError(500, 'server-misconfigured');
    }
    const accessToken = await getAccessToken(serviceAccount);
    const base = { projectId: env.PROJECT_ID, accessToken };
    // A pasted secret can carry a trailing newline, which breaks every signature.
    const cloudinarySecret = env.CLOUDINARY_API_SECRET?.trim();
    return {
      db: makeFirestoreDb(base),
      idp: makeIdentityAdmin(base),
      fcm: makeFcm(env.PROJECT_ID, accessToken),
      cloudinary: env.CLOUDINARY_CLOUD_NAME && env.CLOUDINARY_API_KEY && cloudinarySecret
        ? {
            cloudName: env.CLOUDINARY_CLOUD_NAME,
            apiKey: env.CLOUDINARY_API_KEY,
            apiSecret: cloudinarySecret,
          }
        : undefined,
      verifyCloudinary: env.CLOUDINARY_CLOUD_NAME && env.CLOUDINARY_API_KEY && cloudinarySecret
        ? async () => {
            const credentials = btoa(`${env.CLOUDINARY_API_KEY}:${cloudinarySecret}`);
            const response = await fetch(
              `https://api.cloudinary.com/v1_1/${encodeURIComponent(env.CLOUDINARY_CLOUD_NAME!)}/ping`,
              { headers: { Authorization: `Basic ${credentials}` } },
            );
            return response.ok;
          }
        : undefined,
    };
  },
};

export async function handleRequest(
  request: Request,
  env: Env,
  runtime: Runtime = defaultRuntime,
): Promise<Response> {
  const url = new URL(request.url);
  if (request.method === 'GET' && url.pathname === '/.well-known/assetlinks.json') {
    return assetLinks();
  }
  if (request.method === 'GET' && url.pathname.startsWith('/join/')) {
    try {
      const deps = await runtime.makeDeps(env);
      return await inviteLanding(url.pathname, deps, env.APK_DOWNLOAD_URL);
    } catch (e) {
      console.error('invite landing failed', String(e));
      return new Response('Temporarily unavailable', { status: 503 });
    }
  }
  if (request.method !== 'POST') {
    return json({ error: 'method-not-allowed' }, 405, { Allow: 'POST' });
  }
  const route = ROUTES[url.pathname];
  if (!route) return json({ error: 'not-found' }, 404);

  const declared = Number(request.headers.get('content-length') ?? '0');
  if (declared > MAX_BODY_BYTES) return json({ error: 'body-too-large' }, 413);
  const raw = await request.text();
  if (raw.length > MAX_BODY_BYTES) return json({ error: 'body-too-large' }, 413);

  let body: Record<string, unknown>;
  try {
    const parsed: unknown = raw ? JSON.parse(raw) : {};
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      throw new Error('not an object');
    }
    body = parsed as Record<string, unknown>;
  } catch {
    return json({ error: 'invalid-json' }, 400);
  }

  const authz = request.headers.get('authorization') ?? '';
  const idToken = authz.startsWith('Bearer ') ? authz.slice(7).trim() : '';
  let caller: VerifiedToken;
  try {
    if (!idToken) throw new IdTokenError('missing token');
    caller = await runtime.verify(idToken, env);
  } catch (e) {
    if (e instanceof IdTokenError) return json({ error: 'unauthorized' }, 401);
    console.error('token verification failed', String(e));
    return json({ error: 'internal' }, 500);
  }

  if (!isEmulator(env) && runtime.verifyAppCheck) {
    try {
      const appCheck = request.headers.get('x-firebase-appcheck') ?? '';
      if (!appCheck) throw new AppCheckError('missing');
      await runtime.verifyAppCheck(appCheck, env);
    } catch (e) {
      if (!enforcesAppCheck(env)) {
        // Monitor mode: log until Play Integrity and the debug token are set up.
        console.warn('app check not verified', url.pathname, String(e));
      } else if (e instanceof AppCheckError) {
        return json({ error: 'invalid-app-check' }, 401);
      } else {
        return json({ error: 'internal' }, 500);
      }
    }
  }

  try {
    const deps = await runtime.makeDeps(env);
    deps.inviteBaseUrl = env.PUBLIC_BASE_URL ?? url.origin;
    const result = await route(caller, body, deps);
    return json(result.body, result.status);
  } catch (e) {
    if (e instanceof HttpError) return json({ error: e.code }, e.status);
    console.error('route failed', url.pathname, String(e));
    return json({ error: 'internal' }, 500);
  }
}

export default {
  fetch: (request: Request, env: Env) => handleRequest(request, env),
  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    const deps = await defaultRuntime.makeDeps(env);
    await sweepActivities(deps);
  },
};
