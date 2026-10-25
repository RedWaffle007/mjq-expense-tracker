#!/usr/bin/env node
// Destructive release-cleanup utility. It does nothing without the exact
// confirmation flag, and never prints service-account contents.
import { readFile } from 'node:fs/promises';
import { cert, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore, FieldValue } from 'firebase-admin/firestore';

const args = Object.fromEntries(process.argv.slice(2).map((value, index, all) =>
  value.startsWith('--') ? [value.slice(2), all[index + 1]?.startsWith('--') ? true : all[index + 1]] : null).filter(Boolean));
if (args.confirm !== 'DELETE-TEST-DATA' || typeof args.key !== 'string' ||
    typeof args.email !== 'string' || typeof args.name !== 'string') {
  console.error('Usage: node scripts/prepare-release.mjs --confirm DELETE-TEST-DATA --key /path/key.json --email real-ceo@example.com --name "CEO Name"');
  process.exit(2);
}
const serviceAccount = JSON.parse(await readFile(args.key, 'utf8'));
const app = initializeApp({ credential: cert(serviceAccount), projectId: serviceAccount.project_id });
const db = getFirestore(app);
const auth = getAuth(app);

async function deleteCollection(name) {
  while (true) {
    const snapshot = await db.collection(name).limit(200).get();
    if (snapshot.empty) return;
    for (const doc of snapshot.docs) {
      if (name === 'entries') {
        const history = await doc.ref.collection('history').get();
        for (const child of history.docs) await child.ref.delete();
      }
      await doc.ref.delete();
    }
  }
}

for (const name of ['activity', 'entries', 'sites', 'inviteLinks', 'invites', 'users']) {
  await deleteCollection(name);
}
let pageToken;
do {
  const page = await auth.listUsers(1000, pageToken);
  if (page.users.length) await auth.deleteUsers(page.users.map((user) => user.uid));
  pageToken = page.pageToken;
} while (pageToken);

const email = args.email.trim().toLowerCase();
await db.doc(`invites/${email}`).set({
  name: args.name.trim(), email, phone: '', role: 'ceo', inviteToken: '',
  invitedBy: 'bootstrap', createdAt: FieldValue.serverTimestamp(),
  claimed: false, claimedBy: null,
});
await db.doc('config/app').set({ lastExportAt: null }, { merge: true });
console.log(`Release cleanup complete. CEO invite created for ${email}.`);
