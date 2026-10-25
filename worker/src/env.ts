// Worker bindings. Vars come from wrangler.toml, secrets from `wrangler secret put`,
// and local-only values from .dev.vars.

export interface Env {
  PROJECT_ID: string;
  PROJECT_NUMBER?: string;
  ANDROID_APP_ID?: string;
  /** Public Worker origin used in SMS invitation links. */
  PUBLIC_BASE_URL?: string;
  /** Direct, trusted APK distribution URL. Set once a release host is chosen. */
  APK_DOWNLOAD_URL?: string;
  /** Public Cloudinary identifiers. */
  CLOUDINARY_CLOUD_NAME?: string;
  CLOUDINARY_API_KEY?: string;
  /** Cloudinary signing secret. Never place this in wrangler.toml. */
  CLOUDINARY_API_SECRET?: string;
  /** Service-account JSON. Secret; absent in emulator mode. */
  FIREBASE_SERVICE_ACCOUNT?: string;
  /** "true" only in local development against the Firebase emulators. */
  EMULATOR?: string;
  FIRESTORE_EMULATOR_HOST?: string;
  AUTH_EMULATOR_HOST?: string;
  /**
   * "false" only while App Check is being set up: requests without a valid
   * token are logged and allowed. Anything else rejects them (fails closed).
   */
  APP_CHECK_ENFORCE?: string;
}

export function isEmulator(env: Env): boolean {
  return env.EMULATOR === 'true';
}

export function enforcesAppCheck(env: Env): boolean {
  return env.APP_CHECK_ENFORCE !== 'false';
}
