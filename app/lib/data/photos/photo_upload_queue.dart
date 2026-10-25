import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../entries/entry_repository.dart';
import '../worker/worker_client.dart';

class QueuedPhoto {
  const QueuedPhoto({
    required this.id,
    required this.entryId,
    required this.siteId,
    required this.localPath,
    this.publicId,
    this.error,
  });

  final String id;
  final String entryId;
  final String siteId;
  final String localPath;
  final String? publicId;
  final String? error;

  QueuedPhoto copyWith({
    String? publicId,
    String? error,
    bool clearError = false,
  }) => QueuedPhoto(
    id: id,
    entryId: entryId,
    siteId: siteId,
    localPath: localPath,
    publicId: publicId ?? this.publicId,
    error: clearError ? null : error ?? this.error,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'entryId': entryId,
    'siteId': siteId,
    'localPath': localPath,
    'publicId': publicId,
    'error': error,
  };

  static QueuedPhoto? fromJson(Object? raw) {
    if (raw is! Map ||
        raw['id'] is! String ||
        raw['entryId'] is! String ||
        raw['siteId'] is! String ||
        raw['localPath'] is! String) {
      return null;
    }
    return QueuedPhoto(
      id: raw['id'] as String,
      entryId: raw['entryId'] as String,
      siteId: raw['siteId'] as String,
      localPath: raw['localPath'] as String,
      publicId: raw['publicId'] as String?,
      error: raw['error'] as String?,
    );
  }
}

/// Durable bill-photo queue. It survives process restarts and automatically
/// retries when the app starts, connectivity returns, or the user taps Retry.
class PhotoUploadQueue extends ChangeNotifier with WidgetsBindingObserver {
  PhotoUploadQueue(
    this._worker,
    this._entries,
    this._auth, {
    Connectivity? connectivity,
    http.Client? httpClient,
  }) : _connectivity = connectivity ?? Connectivity(),
       _http = httpClient ?? http.Client();

  final WorkerClient _worker;
  final EntryRepository _entries;
  final FirebaseAuth _auth;
  final Connectivity _connectivity;
  final http.Client _http;
  final List<QueuedPhoto> _items = [];
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  File? _store;
  bool _processing = false;
  bool _initialized = false;
  Timer? _retryTimer;

  List<QueuedPhoto> get items => List.unmodifiable(_items);
  int get pendingCount => _items.length;
  int get errorCount => _items.where((item) => item.error != null).length;
  bool get isProcessing => _processing;
  bool get isInitialized => _initialized;

  Future<void> start() async {
    if (_initialized) return;
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/bill_photos');
    await directory.create(recursive: true);
    _store = File('${support.path}/photo_upload_queue.json');
    if (await _store!.exists()) {
      try {
        final decoded = jsonDecode(await _store!.readAsString()) as List;
        _items.addAll(decoded.map(QueuedPhoto.fromJson).nonNulls);
      } catch (_) {
        // Keep the app usable if the queue file was interrupted/corrupted.
      }
    }
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    notifyListeners();
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((
      result,
    ) {
      if (!result.contains(ConnectivityResult.none)) {
        _scheduleRetry(const Duration(seconds: 3));
      }
    });
    await process();
  }

  Future<String> prepare(XFile source) async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/bill_photos');
    await directory.create(recursive: true);
    final stem =
        '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}';
    final target = '${directory.path}/$stem.jpg';
    XFile? compressed;
    for (final quality in const [82, 68, 55, 42]) {
      compressed = await FlutterImageCompress.compressAndGetFile(
        source.path,
        target,
        minWidth: 1600,
        minHeight: 1600,
        quality: quality,
        format: CompressFormat.jpeg,
        keepExif: false,
      );
      if (compressed == null) break;
      if (await File(compressed.path).length() <= 500 * 1024) break;
    }
    if (compressed == null) throw StateError('Could not prepare image');
    return compressed.path;
  }

  Future<void> enqueue({
    required String entryId,
    required String siteId,
    required Iterable<String> paths,
  }) async {
    for (final path in paths) {
      _items.add(
        QueuedPhoto(
          id: '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}',
          entryId: entryId,
          siteId: siteId,
          localPath: path,
        ),
      );
    }
    await _persist();
    notifyListeners();
    unawaited(process());
  }

  Future<void> retry() async {
    for (var i = 0; i < _items.length; i++) {
      _items[i] = _items[i].copyWith(clearError: true);
    }
    await _persist();
    notifyListeners();
    await process();
  }

  Future<void> process() async {
    if (!_initialized || _processing || _items.isEmpty) return;
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    final connectivity = await _connectivity.checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) return;
    _processing = true;
    notifyListeners();
    try {
      var index = 0;
      while (index < _items.length) {
        var item = _items[index];
        try {
          if (!await File(item.localPath).exists()) {
            throw StateError('The local photo is no longer available.');
          }
          if (item.publicId == null) {
            final publicId = await _upload(item);
            item = item.copyWith(publicId: publicId, clearError: true);
            _items[index] = item;
            await _persist();
          }
          await _entries.attachUploadedPhoto(
            entryId: item.entryId,
            publicId: item.publicId!,
            uid: uid,
          );
          final local = File(item.localPath);
          if (await local.exists()) await local.delete();
          _items.removeAt(index);
          await _persist();
          notifyListeners();
        } catch (error) {
          debugPrint('Bill photo sync failed: $error');
          _items[index] = item.copyWith(error: _message(error));
          await _persist();
          index++;
        }
      }
    } finally {
      _processing = false;
      notifyListeners();
      if (_items.isNotEmpty) _scheduleRetry(const Duration(seconds: 30));
    }
  }

  Future<String> _upload(QueuedPhoto item) async {
    final signed = await _worker.post('/photos/sign-upload', {
      'siteId': item.siteId,
      'entryId': item.entryId,
    });
    final uploadUrl = signed['uploadUrl'];
    final publicId = signed['publicId'];
    if (uploadUrl is! String || publicId is! String) {
      throw const WorkerException('invalid-response');
    }
    final request = http.MultipartRequest('POST', Uri.parse(uploadUrl));
    for (final key in [
      'apiKey',
      'timestamp',
      'publicId',
      'format',
      'type',
      'signature',
    ]) {
      final value = signed[key];
      if (value == null) throw const WorkerException('invalid-response');
      request.fields[switch (key) {
        'apiKey' => 'api_key',
        'publicId' => 'public_id',
        _ => key,
      }] = value
          .toString();
    }
    request.files.add(
      await http.MultipartFile.fromPath('file', item.localPath),
    );
    final streamed = await _http
        .send(request)
        .timeout(const Duration(seconds: 45));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = 'Photo upload failed (${response.statusCode}).';
      try {
        final errorBody = jsonDecode(response.body) as Map<String, dynamic>;
        final message = (errorBody['error'] as Map?)?['message'];
        if (message is String && message.isNotEmpty) detail = message;
      } catch (_) {
        // Keep the status-only message for a non-JSON response.
      }
      throw StateError(detail);
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['public_id'] != publicId) {
      throw StateError('Photo upload was not confirmed.');
    }
    return publicId;
  }

  String _message(Object error) {
    if (error is WorkerException) return workerErrorMessage(error);
    if (error is TimeoutException) return 'Photo upload timed out. Tap Retry.';
    if (error is StateError) return '${error.message} Tap Retry.';
    if (error is FirebaseException) {
      return error.code == 'unavailable'
          ? 'The expense hasn\'t reached the server yet. Tap Retry when online.'
          : 'Photo uploaded but couldn\'t be attached (${error.code}). Tap Retry.';
    }
    return 'Photo is waiting to sync. Tap Retry when online.';
  }

  void _scheduleRetry(Duration delay) {
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () => unawaited(process()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _items.isNotEmpty) {
      _scheduleRetry(const Duration(seconds: 1));
    }
  }

  Future<void> _persist() async {
    final store = _store;
    if (store == null) return;
    final temporary = File('${store.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(_items.map((item) => item.toJson()).toList()),
      flush: true,
    );
    await temporary.rename(store.path);
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _retryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _http.close();
    super.dispose();
  }
}
