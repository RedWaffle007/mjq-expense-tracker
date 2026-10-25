import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'entry_repository.dart';

class OfflineEditQueue extends ChangeNotifier {
  OfflineEditQueue(this._entries, {Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final EntryRepository _entries;
  final Connectivity _connectivity;
  final List<Map<String, dynamic>> _items = [];
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  File? _store;
  bool _initialized = false;
  bool _processing = false;

  int get pendingCount => _items.length;
  int get errorCount => _items.where((item) => item['error'] != null).length;
  bool get isProcessing => _processing;

  Future<void> start() async {
    if (_initialized) return;
    final support = await getApplicationSupportDirectory();
    _store = File('${support.path}/offline_edit_queue.json');
    if (await _store!.exists()) {
      try {
        final decoded = jsonDecode(await _store!.readAsString()) as List;
        _items.addAll(
          decoded.cast<Map>().map((item) => item.cast<String, dynamic>()),
        );
      } catch (_) {
        // A damaged queue is surfaced as empty instead of preventing startup.
      }
    }
    _initialized = true;
    notifyListeners();
    _subscription = _connectivity.onConnectivityChanged.listen((result) {
      if (!result.contains(ConnectivityResult.none)) unawaited(process());
    });
    await process();
  }

  Future<void> enqueue({
    required String entryId,
    required String localChangeId,
    required String baseChangeId,
    required Map<String, Object?> before,
    required Map<String, Object?> desired,
    required String uid,
  }) async {
    _items.add({
      'entryId': entryId,
      'localChangeId': localChangeId,
      'baseChangeId': baseChangeId,
      'before': _encode(before),
      'desired': _encode(desired),
      'uid': uid,
      'error': null,
    });
    await _persist();
    notifyListeners();
  }

  Future<void> retry() async {
    for (final item in _items) {
      item['error'] = null;
    }
    await _persist();
    notifyListeners();
    await process();
  }

  Future<void> process() async {
    if (!_initialized || _processing || _items.isEmpty) return;
    final connectivity = await _connectivity.checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) return;
    _processing = true;
    notifyListeners();
    try {
      try {
        await _entries.waitForPendingWrites().timeout(
          const Duration(seconds: 20),
        );
      } catch (_) {
        // A server-rejected local write can complete by throwing; replay below
        // still compares against the authoritative server version.
      }
      var index = 0;
      while (index < _items.length) {
        final item = _items[index];
        try {
          await _entries.replayOfflineEdit(
            entryId: item['entryId'] as String,
            localChangeId: item['localChangeId'] as String,
            baseChangeId: item['baseChangeId'] as String,
            before: _decodeMap(item['before']),
            desired: _decodeMap(item['desired']),
            uid: item['uid'] as String,
          );
          _items.removeAt(index);
          await _persist();
          notifyListeners();
        } catch (_) {
          item['error'] = 'Offline edit could not sync. Tap Retry.';
          index++;
          await _persist();
        }
      }
    } finally {
      _processing = false;
      notifyListeners();
    }
  }

  Object? _encode(Object? value) {
    if (value is Timestamp) {
      return {'_timestampMs': value.millisecondsSinceEpoch};
    }
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), _encode(item)));
    }
    if (value is List) return value.map(_encode).toList();
    return value;
  }

  Object? _decode(Object? value) {
    if (value is Map && value.length == 1 && value['_timestampMs'] is int) {
      return Timestamp.fromMillisecondsSinceEpoch(value['_timestampMs'] as int);
    }
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), _decode(item)));
    }
    if (value is List) return value.map(_decode).toList();
    return value;
  }

  Map<String, Object?> _decodeMap(Object? value) =>
      Map<String, Object?>.from(_decode(value) as Map);

  Future<void> _persist() async {
    final store = _store;
    if (store == null) return;
    final temporary = File('${store.path}.tmp');
    await temporary.writeAsString(jsonEncode(_items), flush: true);
    await temporary.rename(store.path);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
