#!/usr/bin/env node
// One-off: create the invite for the first CEO (plan.md Section 6). The CEO then
// signs in with Google and signs up through the normal /signup/complete flow.
//
// Usage:
//   node scripts/bootstrap-ceo.mjs --key /path/to/service-account.json \
//        --email ceo@gmail.com --name "Full Name"
//
// Against the emulator instead (no key needed):
//   FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 node scripts/bootstrap-ceo.mjs \
//        --project demo-mjq --email ceo@gmail.com --name "Full Name"

import { readFileSync } from 'node:fs';
import { parseArgs } from 'node:util';

import { cert, initializeApp } from 'firebase-admin/app';
import { FieldValue, getFirestore } from 'firebase-admin/firestore';

const { values } = parseArgs({
  options: {
    key: { type: 'string' },
    project: { type: 'string' },
    email: { type: 'string' },
    name: { type: 'string' },
  },
});

const email = values.email?.trim().toLowerCase();
const name = values.name?.trim();
if (!email || !/^[^\s@/]+@[^\s@/]+\.[^\s@/]+$/.test(email) || !name) {
  console.error('Usage: bootstrap-ceo.mjs --key <service-account.json> --email <email> --name <name>');
  process.exit(1);
}

const emulator = !!process.env.FIRESTORE_EMULATOR_HOST;
if (!emulator && !values.key) {
  console.error('--key is required unless FIRESTORE_EMULATOR_HOST is set.');
  process.exit(1);
}

const app = emulator
  ? initializeApp({ projectId: values.project ?? 'demo-mjq' })
  : initializeApp({ credential: cert(JSON.parse(readFileSync(values.key, 'utf8'))) });
const db = getFirestore(app);

const ref = db.doc(`invites/${email}`);
await db.runTransaction(async (tx) => {
  const snap = await tx.get(ref);
  if (snap.exists && snap.get('claimed') === true) {
    throw new Error(`${email} has already signed up; nothing to do.`);
  }
  tx.set(ref, {
    name,
    email,
    role: 'ceo',
    invitedBy: 'bootstrap',
    createdAt: FieldValue.serverTimestamp(),
    claimed: false,
    claimedBy: null,
  });
});

console.log(
  `CEO invite ready for ${email} on project ${app.options.projectId ?? '(from key)'}. ` +
    'Sign in with that Google account in the app.',
);
