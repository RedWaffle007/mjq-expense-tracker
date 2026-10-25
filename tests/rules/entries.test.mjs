import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';

import { assertFails, assertSucceeds, initializeTestEnvironment } from '@firebase/rules-unit-testing';
import {
  Timestamp, deleteDoc, doc, getDoc, serverTimestamp, setDoc, updateDoc, writeBatch,
} from 'firebase/firestore';

const CEO = 'uid_ceo';
const MANAGER = 'uid_manager';
const SITE_A = 'site_a';
const SITE_B = 'site_b';
const DATE = Timestamp.fromDate(new Date('2026-09-20T00:00:00Z'));
const tracked = [
  'siteId', 'item', 'category', 'amount', 'quantity', 'unit', 'rate',
  'vendor', 'note', 'expenseDate', 'photos',
];

let testEnv;
const claims = {
  [CEO]: { role: 'ceo', active: true, email: 'ceo@example.com' },
  [MANAGER]: { role: 'manager', active: true, email: 'manager@example.com' },
};
const db = (uid) => testEnv.authenticatedContext(uid, claims[uid]).firestore();

function entry(uid, changeId = 'change_1') {
  return {
    siteId: SITE_A, item: 'Cement', category: 'material', amount: 1900000,
    quantity: 50, unit: 'bags', rate: 38000, vendor: 'Sai Traders', note: null,
    expenseDate: DATE, photos: [], pendingPhotoCount: 0, source: 'manual',
    createdBy: uid, createdAt: serverTimestamp(), updatedBy: uid,
    updatedAt: serverTimestamp(), isDeleted: false, deletedBy: null,
    deletedAt: null, lastChangeId: changeId, baseChangeId: null, conflict: null,
  };
}

function createChanges(data) {
  return Object.fromEntries(tracked.map((field) => [field, { before: null, after: data[field] }]));
}

function activity(entryId, siteId, uid, type, photoOnly = false) {
  return {
    type, photoOnly, entryId, siteId, actorId: uid,
    summary: `${uid} ${type}d Cement`, createdAt: serverTimestamp(), notifiedAt: null,
  };
}

async function createValid(uid = MANAGER, entryId = 'entry_1', changeId = 'change_1', overrides = {}) {
  const database = db(uid);
  const data = { ...entry(uid, changeId), ...overrides };
  const batch = writeBatch(database);
  batch.set(doc(database, 'entries', entryId), data);
  batch.set(doc(database, 'entries', entryId, 'history', changeId), {
    action: 'create', by: uid, at: serverTimestamp(), changes: createChanges(data),
    conflict: false, overwroteChangeId: null,
  });
  batch.set(doc(database, 'activity', changeId), activity(entryId, data.siteId, uid, 'create'));
  await batch.commit();
}

async function updateBatch({
  uid = MANAGER, entryId = 'entry_1', changeId, baseChangeId,
  fields, changes, action = 'update', conflict = false, overwroteChangeId = null,
  photoOnly = false,
}) {
  const database = db(uid);
  const current = (await getDoc(doc(database, 'entries', entryId))).data();
  const batch = writeBatch(database);
  batch.update(doc(database, 'entries', entryId), {
    ...fields, updatedBy: uid, updatedAt: serverTimestamp(), lastChangeId: changeId,
    baseChangeId,
    conflict: conflict ? { by: uid, at: serverTimestamp() } : null,
  });
  batch.set(doc(database, 'entries', entryId, 'history', changeId), {
    action, by: uid, at: serverTimestamp(), changes, conflict, overwroteChangeId,
  });
  batch.set(
    doc(database, 'activity', changeId),
    activity(entryId, fields.siteId ?? current.siteId, uid, action, photoOnly),
  );
  return batch.commit();
}

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-mjq',
    firestore: { rules: readFileSync(new URL('../../firebase/firestore.rules', import.meta.url), 'utf8') },
  });
});
after(async () => testEnv.cleanup());

beforeEach(async () => {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const admin = ctx.firestore();
    await setDoc(doc(admin, 'users', CEO), {
      name: 'CEO', email: 'ceo@example.com', role: 'ceo', active: true, fcmTokens: [], createdAt: new Date(),
    });
    await setDoc(doc(admin, 'users', MANAGER), {
      name: 'Ravi', email: 'manager@example.com', role: 'manager', active: true, fcmTokens: [], createdAt: new Date(),
    });
    for (const id of [SITE_A, SITE_B]) {
      await setDoc(doc(admin, 'sites', id), {
        name: id, location: '', notes: '', status: 'active', createdBy: CEO, createdAt: new Date(),
      });
    }
  });
});

describe('entry batches', () => {
  it('accepts a complete create batch from a manager', async () => {
    await assertSucceeds(createValid());
  });

  it('accepts free-text, missing, and older numeric quantities', async () => {
    await assertSucceeds(createValid(MANAGER, 'text_qty', 'q_1', { quantity: '50 bags' }));
    await assertSucceeds(createValid(MANAGER, 'no_qty', 'q_2', { quantity: null }));
    await assertSucceeds(createValid(MANAGER, 'num_qty', 'q_3', { quantity: 50 }));
    await assertSucceeds(updateBatch({
      entryId: 'num_qty', changeId: 'q_4', baseChangeId: 'q_3', fields: { quantity: '1 load' },
      changes: { quantity: { before: 50, after: '1 load' } },
    }));
  });

  it('rejects empty, over-long, and non-text quantities', async () => {
    await assertFails(createValid(MANAGER, 'empty_qty', 'q_1', { quantity: '' }));
    await assertFails(createValid(MANAGER, 'long_qty', 'q_2', { quantity: 'x'.repeat(61) }));
    await assertFails(createValid(MANAGER, 'bool_qty', 'q_3', { quantity: true }));
    await createValid(MANAGER, 'edit_qty', 'q_4');
    await assertFails(updateBatch({
      entryId: 'edit_qty', changeId: 'q_5', baseChangeId: 'q_4', fields: { quantity: 'x'.repeat(61) },
      changes: { quantity: { before: 50, after: 'x'.repeat(61) } },
    }));
  });

  it('rejects create without matching history and activity', async () => {
    const data = entry(MANAGER);
    await assertFails(setDoc(doc(db(MANAGER), 'entries', 'entry_1'), data));
  });

  it('accepts a normal edit and records exact before/after values', async () => {
    await createValid();
    await assertSucceeds(updateBatch({
      changeId: 'change_2', baseChangeId: 'change_1', fields: { amount: 2000000 },
      changes: { amount: { before: 1900000, after: 2000000 } },
    }));
  });

  it('accepts a form edit that changes several fields at once, normal or conflicting', async () => {
    await createValid();
    const fields = { item: 'Cement OPC 53', quantity: '60 bags', rate: 40000, amount: 2400000 };
    const changes = {
      item: { before: 'Cement', after: 'Cement OPC 53' },
      quantity: { before: 50, after: '60 bags' },
      rate: { before: 38000, after: 40000 },
      amount: { before: 1900000, after: 2400000 },
    };
    await assertSucceeds(updateBatch({ changeId: 'change_2', baseChangeId: 'change_1', fields, changes }));
    await createValid(MANAGER, 'entry_2', 'other_1');
    await updateBatch({
      entryId: 'entry_2', changeId: 'other_2', baseChangeId: 'other_1', fields: { vendor: 'New Vendor' },
      changes: { vendor: { before: 'Sai Traders', after: 'New Vendor' } },
    });
    await assertSucceeds(updateBatch({
      entryId: 'entry_2', changeId: 'other_3', baseChangeId: 'other_1', fields, changes,
      conflict: true, overwroteChangeId: 'other_2',
    }));
  });

  it('rejects a wrong normal-edit before value', async () => {
    await createValid();
    await assertFails(updateBatch({
      changeId: 'change_2', baseChangeId: 'change_1', fields: { amount: 2000000 },
      changes: { amount: { before: 1, after: 2000000 } },
    }));
  });

  it('allows everyone to move an entry only when the site change is in history', async () => {
    await createValid();
    await assertSucceeds(updateBatch({
      changeId: 'change_2', baseChangeId: 'change_1', fields: { siteId: SITE_B },
      changes: { siteId: { before: SITE_A, after: SITE_B } },
    }));
  });

  it('accepts a correctly marked conflict and rejects incorrect conflict metadata', async () => {
    await createValid();
    await updateBatch({
      changeId: 'change_2', baseChangeId: 'change_1', fields: { vendor: 'New Vendor' },
      changes: { vendor: { before: 'Sai Traders', after: 'New Vendor' } },
    });
    await assertSucceeds(updateBatch({
      changeId: 'change_3', baseChangeId: 'change_1', fields: { amount: 2100000 },
      changes: { amount: { before: 1900000, after: 2100000 } },
      conflict: true, overwroteChangeId: 'change_2',
    }));

    await createValid(MANAGER, 'entry_2', 'other_1');
    await assertFails(updateBatch({
      entryId: 'entry_2', changeId: 'other_2', baseChangeId: 'stale', fields: { amount: 2100000 },
      changes: { amount: { before: 1900000, after: 2100000 } },
      conflict: true, overwroteChangeId: 'wrong',
    }));
  });

  it('soft-deletes with immutable history, but denies undelete and hard delete', async () => {
    await createValid();
    await assertSucceeds(updateBatch({
      changeId: 'change_2', baseChangeId: 'change_1', action: 'delete', changes: {},
      fields: { isDeleted: true, deletedBy: MANAGER, deletedAt: serverTimestamp() },
    }));
    await assertFails(updateDoc(doc(db(MANAGER), 'entries', 'entry_1'), { isDeleted: false }));
    await assertFails(deleteDoc(doc(db(CEO), 'entries', 'entry_1')));
  });

  it('denies invalid amounts and any later history/activity mutation', async () => {
    const data = entry(MANAGER);
    data.amount = 0;
    const database = db(MANAGER);
    const batch = writeBatch(database);
    batch.set(doc(database, 'entries', 'bad'), data);
    batch.set(doc(database, 'entries', 'bad', 'history', 'change_1'), {
      action: 'create', by: MANAGER, at: serverTimestamp(), changes: createChanges(data),
      conflict: false, overwroteChangeId: null,
    });
    batch.set(doc(database, 'activity', 'change_1'), activity('bad', SITE_A, MANAGER, 'create'));
    await assertFails(batch.commit());

    await createValid();
    await assertFails(updateDoc(doc(database, 'entries', 'entry_1', 'history', 'change_1'), { action: 'delete' }));
    await assertFails(updateDoc(doc(database, 'activity', 'change_1'), { notifiedAt: serverTimestamp() }));
  });

  it('accepts pending photos on create and an audited photo attachment', async () => {
    const database = db(MANAGER);
    const data = entry(MANAGER);
    data.pendingPhotoCount = 1;
    const batch = writeBatch(database);
    batch.set(doc(database, 'entries', 'photo_entry'), data);
    batch.set(doc(database, 'entries', 'photo_entry', 'history', 'change_1'), {
      action: 'create', by: MANAGER, at: serverTimestamp(), changes: createChanges(data),
      conflict: false, overwroteChangeId: null,
    });
    batch.set(doc(database, 'activity', 'change_1'), activity('photo_entry', SITE_A, MANAGER, 'create'));
    await assertSucceeds(batch.commit());

    const photo = {
      publicId: 'bills/site_a/photo_entry/123e4567-e89b-12d3-a456-426614174000',
      uploadedAt: DATE,
    };
    await assertSucceeds(updateBatch({
      entryId: 'photo_entry', changeId: 'change_2', baseChangeId: 'change_1',
      fields: { photos: [photo], pendingPhotoCount: 0 },
      changes: { photos: { before: [], after: [photo] } },
      photoOnly: true,
    }));
  });

  it('rejects unaudited or malformed photo attachment changes', async () => {
    await createValid();
    const malformed = { publicId: 'someone-elses-photo', uploadedAt: DATE };
    await assertFails(updateBatch({
      changeId: 'change_2', baseChangeId: 'change_1',
      fields: { photos: [malformed] },
      changes: { photos: { before: [], after: [malformed] } },
      photoOnly: true,
    }));
  });
});
