import 'package:cloud_firestore/cloud_firestore.dart';

import '../users/app_user.dart';
import '../worker/worker_client.dart';
import 'invite.dart';

/// Invites: the CEO reads them from Firestore and creates them via the Worker.
class InviteRepository {
  InviteRepository(this._db, this._worker);

  final FirebaseFirestore _db;
  final WorkerClient _worker;

  /// Invites that haven't been used to sign up yet.
  Stream<List<Invite>> watchPending() => _db
      .collection('invites')
      .where('claimed', isEqualTo: false)
      .snapshots()
      .map(
        (snap) => snap.docs.map(Invite.fromDoc).nonNulls.toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          ),
      );

  Future<InviteDelivery> create({
    required String email,
    required String phone,
    required String name,
    required UserRole role,
  }) async {
    final result = await _worker.post('/invites/create', {
      'email': email,
      'phone': phone,
      'name': name,
      'role': role.name,
    });
    return InviteDelivery(
      phone: result['phone'] as String,
      inviteUrl: Uri.parse(result['inviteUrl'] as String),
    );
  }
}

class InviteDelivery {
  const InviteDelivery({required this.phone, required this.inviteUrl});

  final String phone;
  final Uri inviteUrl;
}
