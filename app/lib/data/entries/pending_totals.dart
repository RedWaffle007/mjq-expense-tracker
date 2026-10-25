import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One site/category amount change from an entry write.
class TotalDelta {
  const TotalDelta({
    required this.siteId,
    required this.category,
    required this.amount,
    required this.count,
  });

  final String siteId;
  final String category;
  final int amount;
  final int count;

  Map<String, Object?> toJson() => {
    'siteId': siteId,
    'category': category,
    'amount': amount,
    'count': count,
  };

  static TotalDelta? fromJson(Object? raw) {
    if (raw is! Map ||
        raw['siteId'] is! String ||
        raw['category'] is! String ||
        raw['amount'] is! int ||
        raw['count'] is! int) {
      return null;
    }
    return TotalDelta(
      siteId: raw['siteId'] as String,
      category: raw['category'] as String,
      amount: raw['amount'] as int,
      count: raw['count'] as int,
    );
  }
}

/// The counted part of an entry: where its amount is added to totals.
typedef CountedEntry = ({String siteId, String category, int amount});

/// The total changes from [before] to [after]; null means not counted
/// (not created yet, or deleted).
List<TotalDelta> totalDeltas(CountedEntry? before, CountedEntry? after) {
  if (before == after) return const [];
  return [
    if (before != null)
      TotalDelta(
        siteId: before.siteId,
        category: before.category,
        amount: -before.amount,
        count: -1,
      ),
    if (after != null)
      TotalDelta(
        siteId: after.siteId,
        category: after.category,
        amount: after.amount,
        count: 1,
      ),
  ];
}

abstract interface class PendingTotalsStore {
  Future<String?> read();
  Future<void> write(String value);
}

class PreferencesPendingTotalsStore implements PendingTotalsStore {
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  static const _key = 'pending_total_deltas';

  @override
  Future<String?> read() => _preferences.getString(_key);

  @override
  Future<void> write(String value) => _preferences.setString(_key, value);
}

/// Total changes this phone has written that the server has not confirmed.
/// Aggregation queries only count synced entries, and the last-known totals
/// shown offline predate local changes, so totals add these on top
/// (plan.md Section 5, "Site totals"). Each change is removed once its write
/// is acknowledged or rejected; changes left from an earlier app run are
/// removed after Firestore confirms its pending writes.
class PendingTotals {
  PendingTotals(this._store);

  final PendingTotalsStore _store;
  final Map<String, List<TotalDelta>> _byChange = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();
  Future<void>? _loaded;
  Future<void> _writes = Future.value();

  /// Emits after every record or settle.
  Stream<void> get changes => _changes.stream;

  Future<void> _ensureLoaded() => _loaded ??= _load();

  Future<void> _load() async {
    try {
      final raw = await _store.read();
      if (raw == null) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      for (final MapEntry(:key, :value) in decoded.entries) {
        _byChange[key] = (value as List)
            .map(TotalDelta.fromJson)
            .nonNulls
            .toList(growable: false);
      }
    } catch (_) {
      // A damaged record only costs offline accuracy until the next fetch.
    }
  }

  Future<void> record(String changeId, List<TotalDelta> deltas) async {
    if (deltas.isEmpty) return;
    await _ensureLoaded();
    _byChange[changeId] = deltas;
    await _save();
  }

  Future<void> settle(Iterable<String> changeIds) async {
    await _ensureLoaded();
    var removed = false;
    for (final id in changeIds) {
      removed = _byChange.remove(id) != null || removed;
    }
    if (removed) await _save();
  }

  /// Settles everything recorded before this call once [waitForPendingWrites]
  /// finishes, covering writes whose app run ended before they synced.
  Future<void> settleWhenSynced(
    Future<void> Function() waitForPendingWrites,
  ) async {
    await _ensureLoaded();
    final ids = _byChange.keys.toList();
    if (ids.isEmpty) return;
    try {
      await waitForPendingWrites();
    } catch (_) {
      // Rejected or abandoned writes are not pending either.
    }
    await settle(ids);
  }

  Future<({int amount, int count})> forSite(
    String siteId, {
    String? category,
  }) async {
    await _ensureLoaded();
    var amount = 0;
    var count = 0;
    for (final delta in _byChange.values.expand((deltas) => deltas)) {
      if (delta.siteId == siteId &&
          (category == null || delta.category == category)) {
        amount += delta.amount;
        count += delta.count;
      }
    }
    return (amount: amount, count: count);
  }

  Future<void> _save() {
    final value = jsonEncode(
      _byChange.map(
        (id, deltas) => MapEntry(id, deltas.map((d) => d.toJson()).toList()),
      ),
    );
    _changes.add(null);
    return _writes = _writes
        .then((_) => _store.write(value))
        .catchError((Object _) {});
  }
}
