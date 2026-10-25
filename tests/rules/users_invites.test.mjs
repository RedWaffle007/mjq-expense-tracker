// Security-rules tests for users/ and invites/ (plan.md Section 7, Milestone 1).
//
// Every denial is paired with the legitimate operation it must not break, so a
// rules file that denied everything would fail half of this suite.
//
// Run: npm test   (starts the Firestore emulator via firebase-tools)

import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  serverTimestamp,
  setDoc,
  updateDoc,
} from 'firebase/firestore';

const CEO = 'uid_ceo';
const MANAGER = 'uid_manager';
const DEACTIVATED = 'uid_deactivated';
const STRANGER = 'uid_stranger'; // signed in with Google, never invited

const MANAGER_EMAIL = 'manager@example.com';

let testEnv;

// Claims exactly as the Worker sets them at signup.
const claims = {
  [CEO]: { role: 'ceo', active: true, email: 'ceo@example.com' },
  [MANAGER]: { role: 'manager', active: true, email: MANAGER_EMAIL },
  // Deactivated in users/ but still holding an old token that says active.
  [DEACTIVATED]: { role: 'manager', active: true, email: 'gone@example.com' },
  [STRANGER]: { email: 'stranger@example.com' },
};

function db(uid) {
  return testEnv.authenticatedContext(uid, claims[uid]).firestore();
}

function userDoc(name, email, role, active) {
  return { name, email, role, active, fcmTokens: [], createdAt: new Date() };
}

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-mjq',
    firestore: {
      rules: readFileSync(
        new URL('../../firebase/firestore.rules', import.meta.url),
        'utf8',
      ),
    },
  });
});

after(async () => {
  await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const admin = ctx.firestore();
    await setDoc(doc(admin, 'users', CEO), userDoc('CEO', 'ceo@example.com', 'ceo', true));
    await setDoc(doc(admin, 'users', MANAGER), userDoc('Ravi', MANAGER_EMAIL, 'manager', true));
    await setDoc(doc(admin, 'users', DEACTIVATED), userDoc('Gone', 'gone@example.com', 'manager', false));
    await setDoc(doc(admin, 'invites', MANAGER_EMAIL), {
      name: 'Ravi',
      email: MANAGER_EMAIL,
      role: 'manager',
      invitedBy: CEO,
      createdAt: new Date(),
      claimed: true,
      claimedBy: MANAGER,
    });
  });
});

describe('users', () => {
  it('active users can read any user', async () => {
    await assertSucceeds(getDoc(doc(db(MANAGER), 'users', CEO)));
    await assertSucceeds(getDocs(collection(db(CEO), 'users')));
  });

  it('an uninvited signed-in user cannot read or list users', async () => {
    await assertFails(getDoc(doc(db(STRANGER), 'users', CEO)));
    await assertFails(getDocs(collection(db(STRANGER), 'users')));
  });

  it('an unauthenticated client cannot read users', async () => {
    const anon = testEnv.unauthenticatedContext().firestore();
    await assertFails(getDoc(doc(anon, 'users', CEO)));
  });

  it('a deactivated user with a still-valid active token is blocked from others', async () => {
    await assertFails(getDoc(doc(db(DEACTIVATED), 'users', CEO)));
    await assertFails(getDocs(collection(db(DEACTIVATED), 'users')));
  });

  it('a deactivated user can still read their OWN doc (to see they were deactivated)', async () => {
    await assertSucceeds(getDoc(doc(db(DEACTIVATED), 'users', DEACTIVATED)));
  });

  it('a stranger can read their own (missing) doc, which lets the app detect "not signed up"', async () => {
    await assertSucceeds(getDoc(doc(db(STRANGER), 'users', STRANGER)));
  });

  it('a user can update only their own fcmTokens', async () => {
    await assertSucceeds(
      updateDoc(doc(db(MANAGER), 'users', MANAGER), { fcmTokens: ['token-a'] }),
    );
  });

  it('a user cannot promote themselves or reactivate themselves', async () => {
    await assertFails(updateDoc(doc(db(MANAGER), 'users', MANAGER), { role: 'ceo' }));
    await assertFails(updateDoc(doc(db(MANAGER), 'users', MANAGER), { active: false }));
    await assertFails(
      updateDoc(doc(db(DEACTIVATED), 'users', DEACTIVATED), { active: true }),
    );
  });

  it('a deactivated user cannot even update their own fcmTokens', async () => {
    await assertFails(
      updateDoc(doc(db(DEACTIVATED), 'users', DEACTIVATED), { fcmTokens: ['t'] }),
    );
  });

  it("a user cannot touch someone else's doc, even the CEO", async () => {
    await assertFails(updateDoc(doc(db(MANAGER), 'users', CEO), { fcmTokens: [] }));
    await assertFails(updateDoc(doc(db(CEO), 'users', MANAGER), { active: false }));
  });

  it('fcmTokens must be a short list', async () => {
    await assertFails(
      updateDoc(doc(db(MANAGER), 'users', MANAGER), { fcmTokens: 'not-a-list' }),
    );
    const tooMany = Array.from({ length: 11 }, (_, i) => `t${i}`);
    await assertFails(updateDoc(doc(db(MANAGER), 'users', MANAGER), { fcmTokens: tooMany }));
  });

  it('nobody can create users docs from the app (signup goes through the Worker)', async () => {
    await assertFails(
      setDoc(doc(db(STRANGER), 'users', STRANGER),
        userDoc('Me', 'stranger@example.com', 'ceo', true)),
    );
    await assertFails(
      setDoc(doc(db(CEO), 'users', 'uid_new'),
        userDoc('New', 'new@example.com', 'manager', true)),
    );
  });

  it('nobody can delete users docs from the app', async () => {
    await assertFails(deleteDoc(doc(db(CEO), 'users', MANAGER)));
    await assertFails(deleteDoc(doc(db(MANAGER), 'users', MANAGER)));
  });

  it('a manager whose token lacks the active claim is blocked even if the doc is active', async () => {
    const noClaim = testEnv
      .authenticatedContext(MANAGER, { role: 'manager', email: MANAGER_EMAIL })
      .firestore();
    await assertFails(getDoc(doc(noClaim, 'users', CEO)));
  });
});

describe('invites', () => {
  it('the CEO can read and list invites', async () => {
    await assertSucceeds(getDoc(doc(db(CEO), 'invites', MANAGER_EMAIL)));
    await assertSucceeds(getDocs(collection(db(CEO), 'invites')));
  });

  it('a manager cannot read invites', async () => {
    await assertFails(getDoc(doc(db(MANAGER), 'invites', MANAGER_EMAIL)));
    await assertFails(getDocs(collection(db(MANAGER), 'invites')));
  });

  it('an uninvited user cannot read their would-be invite', async () => {
    await assertFails(getDoc(doc(db(STRANGER), 'invites', 'stranger@example.com')));
  });

  it('a manager with a forged role claim is still not the CEO', async () => {
    const forged = testEnv
      .authenticatedContext(MANAGER, { role: 'ceo', active: true, email: MANAGER_EMAIL })
      .firestore();
    await assertFails(getDoc(doc(forged, 'invites', MANAGER_EMAIL)));
  });

  it('nobody can write invites from the app, not even the CEO', async () => {
    const invite = {
      name: 'X', email: 'x@example.com', role: 'manager',
      invitedBy: CEO, createdAt: new Date(), claimed: false, claimedBy: null,
    };
    await assertFails(setDoc(doc(db(CEO), 'invites', 'x@example.com'), invite));
    await assertFails(setDoc(doc(db(STRANGER), 'invites', 'stranger@example.com'), invite));
    await assertFails(deleteDoc(doc(db(CEO), 'invites', MANAGER_EMAIL)));
  });
});

describe('SMS invite links', () => {
  it('invite-link records are inaccessible to every app client', async () => {
    const token = '0123456789abcdef0123456789abcdef';
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'inviteLinks', token), {
        email: MANAGER_EMAIL,
        createdAt: new Date(),
      });
    });
    await assertFails(getDoc(doc(db(CEO), 'inviteLinks', token)));
    await assertFails(getDoc(doc(db(MANAGER), 'inviteLinks', token)));
    await assertFails(setDoc(doc(db(CEO), 'inviteLinks', 'another'), {
      email: 'x@example.com',
    }));
  });
});

describe('sites', () => {
  const site = {
    name: 'Site One',
    location: 'Hyderabad',
    notes: '',
    status: 'active',
    createdBy: CEO,
    createdAt: serverTimestamp(),
  };

  it('the CEO can create a valid active site and active users can read it', async () => {
    await assertSucceeds(setDoc(doc(db(CEO), 'sites', 'site_1'), site));
    await assertSucceeds(getDoc(doc(db(MANAGER), 'sites', 'site_1')));
  });

  it('a manager cannot create or edit sites', async () => {
    await assertFails(setDoc(doc(db(MANAGER), 'sites', 'site_1'), {
      ...site,
      createdBy: MANAGER,
    }));
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'sites', 'site_1'), {
        ...site,
        createdAt: new Date(),
      });
    });
    await assertFails(updateDoc(doc(db(MANAGER), 'sites', 'site_1'), { name: 'Changed' }));
  });

  it('the CEO can edit and archive a site without changing its creator', async () => {
    await assertSucceeds(setDoc(doc(db(CEO), 'sites', 'site_1'), site));
    await assertSucceeds(updateDoc(doc(db(CEO), 'sites', 'site_1'), {
      name: 'Site One Updated',
      status: 'archived',
    }));
    await assertFails(updateDoc(doc(db(CEO), 'sites', 'site_1'), { createdBy: MANAGER }));
  });

  it('rejects malformed sites and hard deletion', async () => {
    await assertFails(setDoc(doc(db(CEO), 'sites', 'archived_new'), {
      ...site,
      status: 'archived',
    }));
    await assertFails(setDoc(doc(db(CEO), 'sites', 'extra_field'), {
      ...site,
      unexpected: true,
    }));
    await assertFails(setDoc(doc(db(CEO), 'sites', 'blank_name'), {
      ...site,
      name: '',
    }));
    await assertSucceeds(setDoc(doc(db(CEO), 'sites', 'site_1'), site));
    await assertFails(deleteDoc(doc(db(CEO), 'sites', 'site_1')));
  });
});

describe('everything else', () => {
  it('unknown collections are denied until their milestone adds rules', async () => {
    await assertFails(getDoc(doc(db(CEO), 'unknown', 'doc_1')));
    await assertFails(setDoc(doc(db(CEO), 'unknown', 'doc_1'), { item: 'x' }));
  });
});
