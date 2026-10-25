import 'package:cloud_firestore/cloud_firestore.dart';

import '../users/app_user.dart';

/// `invites/{emailLowercase}` (plan.md Section 5). Written by the Worker only.
class Invite {
  const Invite({
    required this.email,
    required this.name,
    required this.phone,
    required this.role,
    required this.claimed,
    this.createdAt,
  });

  final String email;
  final String name;
  final String phone;
  final UserRole role;
  final bool claimed;
  final DateTime? createdAt;

  static Invite? fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    if (data == null) return null;
    final role = UserRole.tryParse(data['role']);
    if (role == null) return null;
    return Invite(
      email: doc.id,
      name: data['name'] as String? ?? '',
      phone: data['phone'] as String? ?? '',
      role: role,
      claimed: data['claimed'] == true,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
