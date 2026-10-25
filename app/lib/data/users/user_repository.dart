import 'package:cloud_firestore/cloud_firestore.dart';

import '../worker/worker_client.dart';
import 'app_user.dart';

/// Reads `users/` from Firestore; changes go through the Worker.
class UserRepository {
  UserRepository(this._db, this._worker);

  final FirebaseFirestore _db;
  final WorkerClient _worker;

  CollectionReference<Map<String, dynamic>> get _users =>
      _db.collection('users');

  /// A user's doc, or null if it doesn't exist (not signed up yet).
  Stream<AppUser?> watchUser(String uid) =>
      _users.doc(uid).snapshots().map(AppUser.fromDoc);

  /// Everyone, sorted by name.
  Stream<List<AppUser>> watchAll() => _users
      .orderBy('name')
      .snapshots()
      .map((snap) => snap.docs.map(AppUser.fromDoc).nonNulls.toList());

  /// CEO only (enforced by the Worker).
  Future<void> setActive(String uid, {required bool active}) =>
      _worker.post('/users/set-active', {'uid': uid, 'active': active});

  Future<void> addFcmToken(String uid, String token) => _users.doc(uid).update({
    'fcmTokens': FieldValue.arrayUnion([token]),
  });

  Future<void> removeFcmToken(String uid, String token) =>
      _users.doc(uid).update({
        'fcmTokens': FieldValue.arrayRemove([token]),
      });

  Future<List<AppUser>> allForExport() async => (await _users.get(
    const GetOptions(source: Source.server),
  )).docs.map(AppUser.fromDoc).nonNulls.toList();
}
