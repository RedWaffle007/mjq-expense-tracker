# MJQ Builders & Developers — Expense Tracker

The full specification is in [plan.md](plan.md). Everything runs on free tiers
(Firebase Spark, Cloudflare Workers Free, Cloudinary Free). Voice entry is
parked; see plan.md Section 13 to restore it.

| Folder | What |
|---|---|
| `app/` | Flutter app (Android first) |
| `worker/` | Cloudflare Worker (TypeScript): auth, invites, photos, push, App Check |
| `firebase/` | Firestore rules, indexes, emulator config |
| `tests/rules/` | Firestore security-rules tests (emulator) |

## Everyday commands

```bash
# App (real project)
cd app && flutter run

# Worker unit tests / integration tests against the emulators / deploy
cd worker && npm test
cd worker && npm run test:emulator
cd worker && npm run deploy

# Security-rules tests
cd tests/rules && npm test

# Deploy rules and indexes
cd firebase && firebase deploy --only firestore:rules,firestore:indexes
```

## Local development against the emulators

```bash
cd firebase && firebase emulators:start --only auth,firestore  # terminal 1 (data stays local)
cd worker && cp .dev.vars.example .dev.vars && npm run dev       # terminal 2
cd app && flutter run --dart-define=USE_EMULATORS=true           # Android emulator
# Create the CEO invite in the emulator (automated tests use the offline demo-mjq project instead):
cd worker && FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 \
  node scripts/bootstrap-ceo.mjs --project mjq-builders-developers --email you@gmail.com --name "Your Name"
```

## One-time setup

- Firebase project `mjq-builders-developers` on Spark, Firestore in asia-south1, Google sign-in enabled.
- Debug SHA-1/SHA-256 registered on the Android app (release keys must be added before release).
- Worker secret: `npx wrangler secret put FIREBASE_SERVICE_ACCOUNT < /path/to/key.json`
- First CEO: `node worker/scripts/bootstrap-ceo.mjs --key /path/to/key.json --email <ceo> --name "<name>"`
- Worker App Check runs in monitor mode (`APP_CHECK_ENFORCE = "false"` in
  `worker/wrangler.toml`) until Firebase App Check/Play Integrity and the
  development debug token are registered; then remove that line and deploy.
- Before a production release, create the stable release key, register its
  SHA-1/SHA-256 fingerprints, and follow the release checklist in
  [plan.md](plan.md) (Milestone 6), including the guarded cleanup/re-bootstrap
  script `worker/scripts/prepare-release.mjs`.

Never commit service-account keys or `.dev.vars`.
