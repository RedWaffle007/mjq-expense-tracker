import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'expense_entry.dart';
import 'pending_totals.dart';
import 'quantity.dart';
import '../worker/worker_client.dart';

class EntryDraft {
  const EntryDraft({
    required this.siteId,
    required this.item,
    required this.category,
    required this.amount,
    required this.quantity,
    required this.unit,
    required this.rate,
    required this.vendor,
    required this.note,
    required this.expenseDate,
    this.source = 'manual',
  });

  final String siteId;
  final String item;
  final ExpenseCategory category;
  final int amount;
  final String? quantity;
  final String? unit;
  final int? rate;
  final String? vendor;
  final String? note;
  final DateTime expenseDate;
  final String source;

  Map<String, Object?> toFields() => {
    'siteId': siteId,
    'item': item.trim(),
    'category': category.name,
    'amount': amount,
    'quantity': _nullable(quantity),
    'unit': unit,
    'rate': rate,
    'vendor': _nullable(vendor),
    'note': _nullable(note),
    'expenseDate': Timestamp.fromDate(expenseDate),
  };

  static String? _nullable(String? value) {
    final text = value?.trim() ?? '';
    return text.isEmpty ? null : text;
  }
}

class SiteTotal {
  const SiteTotal({
    required this.amount,
    required this.count,
    this.asOf,
    this.isCached = false,
    this.includesUnsynced = false,
  });
  final int amount;
  final int count;
  final DateTime? asOf;

  /// The server total couldn't be fetched; this is the last known one.
  final bool isCached;

  /// Includes this phone's changes that haven't reached the server yet.
  final bool includesUnsynced;
}

class EntryRepository {
  EntryRepository(this._db, this._worker, this._pending);
  final FirebaseFirestore _db;
  final WorkerClient _worker;
  final PendingTotals _pending;
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();

  /// Clears unsynced-total records left by an earlier run once they sync.
  Future<void> settlePendingTotals() =>
      _pending.settleWhenSynced(_db.waitForPendingWrites);

  /// Emits whenever any user's entry change appears (its activity doc) or this
  /// phone's unsynced changes settle, so totals can be fetched again.
  Stream<void> totalsChanges() {
    final controller = StreamController<void>();
    final subscriptions = <StreamSubscription<void>>[];
    controller.onListen = () {
      subscriptions
        ..add(
          _db
              .collection('activity')
              .orderBy('createdAt', descending: true)
              .limit(1)
              .snapshots()
              .skip(1)
              .listen((_) => controller.add(null), onError: (_) {}),
        )
        ..add(_pending.changes.listen((_) => controller.add(null)));
    };
    controller.onCancel = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };
    return controller.stream;
  }

  Query<Map<String, dynamic>> _siteQuery(String siteId) => _db
      .collection('entries')
      .where('siteId', isEqualTo: siteId)
      .where('isDeleted', isEqualTo: false);

  Stream<List<ExpenseEntry>> watchForSite(String siteId) => _siteQuery(siteId)
      .orderBy('expenseDate', descending: true)
      .limit(50)
      .snapshots(includeMetadataChanges: true)
      .map(
        (snapshot) => snapshot.docs.map(ExpenseEntry.fromDoc).nonNulls.toList(),
      );

  Stream<ExpenseEntry?> watchOne(String id) => _db
      .collection('entries')
      .doc(id)
      .snapshots(includeMetadataChanges: true)
      .map(ExpenseEntry.fromDoc);

  Stream<List<EntryHistory>> watchHistory(String entryId) => _db
      .collection('entries')
      .doc(entryId)
      .collection('history')
      .orderBy('at', descending: true)
      .snapshots()
      .map(
        (snapshot) => snapshot.docs.map(EntryHistory.fromDoc).nonNulls.toList(),
      );

  /// Server aggregate (or the last known one when it can't be fetched) plus
  /// this phone's unsynced changes (plan.md Section 5, "Site totals").
  Future<SiteTotal> totalForSite(String siteId) async {
    final pending = await _pending.forSite(siteId);
    final includesUnsynced = pending.amount != 0 || pending.count != 0;
    try {
      final snapshot = await _siteQuery(
        siteId,
      ).aggregate(sum('amount'), count()).get();
      final amount = (snapshot.getSum('amount') ?? 0).round();
      final entries = snapshot.count ?? 0;
      final asOf = DateTime.now();
      await Future.wait([
        _preferences.setInt('site_total_${siteId}_amount', amount),
        _preferences.setInt('site_total_${siteId}_count', entries),
        _preferences.setInt(
          'site_total_${siteId}_at',
          asOf.millisecondsSinceEpoch,
        ),
      ]);
      return SiteTotal(
        amount: amount + pending.amount,
        count: entries + pending.count,
        asOf: asOf,
        includesUnsynced: includesUnsynced,
      );
    } on FirebaseException catch (error) {
      debugPrint(
        'Site total fell back to cache: ${error.code} ${error.message}',
      );
      final values = await Future.wait([
        _preferences.getInt('site_total_${siteId}_amount'),
        _preferences.getInt('site_total_${siteId}_count'),
        _preferences.getInt('site_total_${siteId}_at'),
      ]);
      return SiteTotal(
        amount: (values[0] ?? 0) + pending.amount,
        count: (values[1] ?? 0) + pending.count,
        asOf: values[2] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(values[2]!),
        isCached: true,
        includesUnsynced: includesUnsynced,
      );
    }
  }

  Future<Map<ExpenseCategory, int>> totalsByCategory(String siteId) async {
    final pending = {
      for (final category in ExpenseCategory.values)
        category: (await _pending.forSite(
          siteId,
          category: category.name,
        )).amount,
    };
    final totals = <ExpenseCategory, int>{};
    try {
      final snapshots = await Future.wait([
        for (final category in ExpenseCategory.values)
          _siteQuery(siteId)
              .where('category', isEqualTo: category.name)
              .aggregate(sum('amount'))
              .get(),
      ]);
      for (final (index, category) in ExpenseCategory.values.indexed) {
        final amount = (snapshots[index].getSum('amount') ?? 0).round();
        await _preferences.setInt(
          'site_total_${siteId}_${category.name}',
          amount,
        );
        totals[category] = amount + pending[category]!;
      }
    } on FirebaseException {
      for (final category in ExpenseCategory.values) {
        totals[category] =
            (await _preferences.getInt(
                  'site_total_${siteId}_${category.name}',
                ) ??
                0) +
            pending[category]!;
      }
    }
    return totals;
  }

  Future<String> create(
    EntryDraft draft, {
    required String uid,
    int pendingPhotoCount = 0,
    bool waitForServer = true,
  }) async {
    final entryRef = _db.collection('entries').doc();
    final changeId = _db.collection('activity').doc().id;
    final editableFields = draft.toFields();
    final fields = {...editableFields, 'photos': const <Object?>[]};
    final batch = _db.batch();
    batch.set(entryRef, {
      ...fields,
      'pendingPhotoCount': pendingPhotoCount,
      'source': draft.source,
      'createdBy': uid,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedBy': uid,
      'updatedAt': FieldValue.serverTimestamp(),
      'isDeleted': false,
      'deletedBy': null,
      'deletedAt': null,
      'lastChangeId': changeId,
      'baseChangeId': null,
      'conflict': null,
    });
    batch.set(entryRef.collection('history').doc(changeId), {
      'action': 'create',
      'by': uid,
      'at': FieldValue.serverTimestamp(),
      'changes': fields.map(
        (key, value) => MapEntry(key, {'before': null, 'after': value}),
      ),
      'conflict': false,
      'overwroteChangeId': null,
    });
    batch.set(
      _db.collection('activity').doc(changeId),
      _activity(
        type: 'create',
        entryId: entryRef.id,
        siteId: draft.siteId,
        uid: uid,
        summary: 'Added ${draft.item.trim()}',
      ),
    );
    await _commit(
      batch,
      changeId: changeId,
      deltas: totalDeltas(null, _countedDraft(draft)),
      waitForServer: waitForServer,
    );
    if (waitForServer) unawaited(_notify(changeId));
    return entryRef.id;
  }

  Future<String?> update(
    ExpenseEntry entry,
    EntryDraft draft, {
    required String uid,
    int pendingPhotoCount = 0,
    bool waitForServer = true,
  }) async {
    final after = draft.toFields();
    final before = entry.editableFields;
    final changes = <String, Object?>{};
    final updates = <String, Object?>{};
    for (final field in after.keys) {
      if (!_same(before[field], after[field])) {
        changes[field] = {'before': before[field], 'after': after[field]};
        updates[field] = after[field];
      }
    }
    if (pendingPhotoCount > 0) {
      updates['pendingPhotoCount'] =
          entry.pendingPhotoCount + pendingPhotoCount;
    }
    if (changes.isEmpty && updates.isEmpty) return null;
    return _change(
      entry: entry,
      uid: uid,
      action: 'update',
      changes: changes,
      updates: updates,
      siteId: draft.siteId,
      summary: changes.isEmpty
          ? (pendingPhotoCount == 1
                ? 'Queued a bill photo'
                : 'Queued $pendingPhotoCount bill photos')
          : 'Edited ${draft.item.trim()}',
      photoOnly: changes.isEmpty,
      deltas: totalDeltas(_counted(entry), _countedDraft(draft)),
      waitForServer: waitForServer,
    );
  }

  Future<void> softDelete(ExpenseEntry entry, {required String uid}) => _change(
    entry: entry,
    uid: uid,
    action: 'delete',
    changes: const {},
    updates: {
      'isDeleted': true,
      'deletedBy': uid,
      'deletedAt': FieldValue.serverTimestamp(),
    },
    siteId: entry.siteId,
    summary: 'Deleted ${entry.item}',
    deltas: totalDeltas(_counted(entry), null),
  );

  Future<void> attachUploadedPhoto({
    required String entryId,
    required String publicId,
    required String uid,
  }) async {
    final snapshot = await _db
        .collection('entries')
        .doc(entryId)
        .get(const GetOptions(source: Source.server));
    final entry = ExpenseEntry.fromDoc(snapshot);
    if (entry == null || entry.isDeleted) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'not-found',
        message: 'Expense no longer exists.',
      );
    }
    if (entry.photos.any((photo) => photo.publicId == publicId)) return;
    final uploadedAt = Timestamp.now();
    final after = [
      ...entry.photos.map(
        (photo) => {
          'publicId': photo.publicId,
          'uploadedAt': photo.uploadedAt == null
              ? null
              : Timestamp.fromDate(photo.uploadedAt!),
        },
      ),
      {'publicId': publicId, 'uploadedAt': uploadedAt},
    ];
    final before = entry.photos
        .map(
          (photo) => {
            'publicId': photo.publicId,
            'uploadedAt': photo.uploadedAt == null
                ? null
                : Timestamp.fromDate(photo.uploadedAt!),
          },
        )
        .toList(growable: false);
    await _change(
      entry: entry,
      uid: uid,
      action: 'update',
      changes: {
        'photos': {'before': before, 'after': after},
      },
      updates: {
        'photos': after,
        'pendingPhotoCount': entry.pendingPhotoCount > 0
            ? entry.pendingPhotoCount - 1
            : 0,
      },
      siteId: entry.siteId,
      summary: 'Added a bill photo to ${entry.item}',
      photoOnly: true,
    );
  }

  Future<String> _change({
    required ExpenseEntry entry,
    required String uid,
    required String action,
    required Map<String, Object?> changes,
    required Map<String, Object?> updates,
    required String siteId,
    required String summary,
    bool photoOnly = false,
    List<TotalDelta> deltas = const [],
    bool waitForServer = true,
  }) async {
    final changeId = _db.collection('activity').doc().id;
    final entryRef = _db.collection('entries').doc(entry.id);
    final batch = _db.batch();
    batch.update(entryRef, {
      ...updates,
      'updatedBy': uid,
      'updatedAt': FieldValue.serverTimestamp(),
      'lastChangeId': changeId,
      'baseChangeId': entry.lastChangeId,
      'conflict': null,
    });
    batch.set(entryRef.collection('history').doc(changeId), {
      'action': action,
      'by': uid,
      'at': FieldValue.serverTimestamp(),
      'changes': changes,
      'conflict': false,
      'overwroteChangeId': null,
    });
    batch.set(
      _db.collection('activity').doc(changeId),
      _activity(
        type: action,
        entryId: entry.id,
        siteId: siteId,
        uid: uid,
        summary: summary,
        photoOnly: photoOnly,
      ),
    );
    await _commit(
      batch,
      changeId: changeId,
      deltas: deltas,
      waitForServer: waitForServer,
    );
    if (waitForServer) unawaited(_notify(changeId));
    return changeId;
  }

  /// Commits [batch], counting [deltas] in totals until the server
  /// acknowledges or rejects it.
  Future<void> _commit(
    WriteBatch batch, {
    required String changeId,
    required List<TotalDelta> deltas,
    required bool waitForServer,
  }) async {
    await _pending.record(changeId, deltas);
    final future = batch.commit().whenComplete(
      () => _pending.settle([changeId]),
    );
    if (waitForServer) {
      await future;
    } else {
      unawaited(future.catchError((_) {}));
    }
  }

  CountedEntry _counted(ExpenseEntry entry) => (
    siteId: entry.siteId,
    category: entry.category.name,
    amount: entry.amount,
  );

  CountedEntry _countedDraft(EntryDraft draft) => (
    siteId: draft.siteId,
    category: draft.category.name,
    amount: draft.amount,
  );

  Future<void> waitForPendingWrites() => _db.waitForPendingWrites();

  Future<bool> replayOfflineEdit({
    required String entryId,
    required String localChangeId,
    required String baseChangeId,
    required Map<String, Object?> before,
    required Map<String, Object?> desired,
    required String uid,
  }) async {
    final snapshot = await _db
        .collection('entries')
        .doc(entryId)
        .get(const GetOptions(source: Source.server));
    final current = ExpenseEntry.fromDoc(snapshot);
    if (current == null) throw StateError('Expense is no longer available.');
    if (current.lastChangeId == localChangeId) return true;

    final updates = <String, Object?>{};
    final changes = <String, Object?>{};
    for (final field in desired.keys) {
      if (!_same(before[field], desired[field])) {
        updates[field] = desired[field];
        changes[field] = {'before': before[field], 'after': desired[field]};
      }
    }
    if (updates.isEmpty) return true;
    final changeId = _db.collection('activity').doc().id;
    final entryRef = _db.collection('entries').doc(entryId);
    final batch = _db.batch();
    batch.update(entryRef, {
      ...updates,
      'updatedBy': uid,
      'updatedAt': FieldValue.serverTimestamp(),
      'lastChangeId': changeId,
      'baseChangeId': baseChangeId,
      'conflict': {'by': uid, 'at': FieldValue.serverTimestamp()},
    });
    batch.set(entryRef.collection('history').doc(changeId), {
      'action': 'update',
      'by': uid,
      'at': FieldValue.serverTimestamp(),
      'changes': changes,
      'conflict': true,
      'overwroteChangeId': current.lastChangeId,
    });
    batch.set(
      _db.collection('activity').doc(changeId),
      _activity(
        type: 'update',
        entryId: entryId,
        siteId: (updates['siteId'] as String?) ?? current.siteId,
        uid: uid,
        summary: 'Synced offline edit to ${current.item}',
      ),
    );
    await batch.commit();
    unawaited(_notify(changeId));
    return true;
  }

  Future<void> _notify(String activityId) async {
    try {
      await _worker.post('/notify', {'activityId': activityId});
    } catch (_) {
      // The Worker's scheduled sweep is the durable fallback.
    }
  }

  Future<List<ExpenseEntry>> allForExport() async {
    final snapshot = await _db
        .collection('entries')
        .where('isDeleted', isEqualTo: false)
        .orderBy('expenseDate')
        .get(const GetOptions(source: Source.server));
    return snapshot.docs.map(ExpenseEntry.fromDoc).nonNulls.toList();
  }

  Map<String, Object?> _activity({
    required String type,
    required String entryId,
    required String siteId,
    required String uid,
    required String summary,
    bool photoOnly = false,
  }) => {
    'type': type,
    'photoOnly': photoOnly,
    'entryId': entryId,
    'siteId': siteId,
    'actorId': uid,
    'summary': summary,
    'createdAt': FieldValue.serverTimestamp(),
    'notifiedAt': null,
  };

  bool _same(Object? a, Object? b) {
    if (a is Timestamp && b is Timestamp) return a == b;
    // Quantities saved before they became text are numbers; unchanged text
    // keeps the stored number rather than recording a no-op edit.
    if (a is num && b is String) return quantityText(a) == b;
    return a == b;
  }
}
