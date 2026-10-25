import 'dart:async';

import 'package:expensetracker/data/entries/pending_totals.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements PendingTotalsStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

void main() {
  const cement = (siteId: 'a', category: 'other', amount: 1900000);

  group('totalDeltas', () {
    test('adds on create and subtracts on delete', () {
      final created = totalDeltas(null, cement).single;
      expect(
        (created.siteId, created.amount, created.count),
        ('a', 1900000, 1),
      );
      final deleted = totalDeltas(cement, null).single;
      expect(
        (deleted.siteId, deleted.amount, deleted.count),
        ('a', -1900000, -1),
      );
    });

    test('moves the amount between sites on a site change', () {
      final deltas = totalDeltas(cement, (
        siteId: 'b',
        category: 'other',
        amount: 2000000,
      ));
      expect(deltas.map((d) => (d.siteId, d.amount, d.count)), [
        ('a', -1900000, -1),
        ('b', 2000000, 1),
      ]);
    });

    test('is empty when nothing counted changed', () {
      expect(totalDeltas(cement, cement), isEmpty);
      expect(totalDeltas(null, null), isEmpty);
    });
  });

  test('sums pending changes per site and category until settled', () async {
    final store = _MemoryStore();
    final pending = PendingTotals(store);
    await pending.record('c1', totalDeltas(null, cement));
    await pending.record(
      'c2',
      totalDeltas(cement, (siteId: 'a', category: 'other', amount: 2000000)),
    );
    expect(await pending.forSite('a'), (amount: 2000000, count: 1));
    expect(await pending.forSite('a', category: 'labour'), (
      amount: 0,
      count: 0,
    ));
    expect(await pending.forSite('b'), (amount: 0, count: 0));

    await pending.settle(['c1']);
    expect(await pending.forSite('a'), (amount: 100000, count: 0));

    final reloaded = PendingTotals(store);
    expect(await reloaded.forSite('a'), (amount: 100000, count: 0));
  });

  test('settles earlier changes only after pending writes finish', () async {
    final pending = PendingTotals(_MemoryStore());
    await pending.record('old', totalDeltas(null, cement));
    final synced = Completer<void>();
    final settling = pending.settleWhenSynced(() => synced.future);
    await Future<void>.delayed(Duration.zero);
    expect((await pending.forSite('a')).amount, 1900000);

    synced.complete();
    await settling;
    expect((await pending.forSite('a')).amount, 0);
  });
}
