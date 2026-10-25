import 'package:cloud_firestore/cloud_firestore.dart';

enum UserRole {
  ceo,
  manager;

  static UserRole? tryParse(Object? value) =>
      UserRole.values.where((r) => r.name == value).firstOrNull;

  String get label => switch (this) {
    UserRole.ceo => 'CEO',
    UserRole.manager => 'Manager',
  };
}

/// `users/{uid}` (plan.md Section 5). Written by the Worker only.
class AppUser {
  const AppUser({
    required this.uid,
    required this.name,
    required this.email,
    required this.role,
    required this.active,
    this.createdAt,
  });

  final String uid;
  final String name;
  final String email;
  final UserRole role;
  final bool active;
  final DateTime? createdAt;

  bool get isCeo => role == UserRole.ceo;

  /// Returns null for a malformed doc rather than throwing, so one bad doc
  /// can't break a whole list.
  static AppUser? fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    if (data == null) return null;
    final role = UserRole.tryParse(data['role']);
    if (role == null) return null;
    return AppUser(
      uid: doc.id,
      name: data['name'] as String? ?? '',
      email: data['email'] as String? ?? '',
      role: role,
      active: data['active'] == true,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
