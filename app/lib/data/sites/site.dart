import 'package:cloud_firestore/cloud_firestore.dart';

enum SiteStatus { active, archived }

class Site {
  const Site({
    required this.id,
    required this.name,
    required this.location,
    required this.notes,
    required this.status,
    required this.createdBy,
    this.createdAt,
  });

  final String id;
  final String name;
  final String location;
  final String notes;
  final SiteStatus status;
  final String createdBy;
  final DateTime? createdAt;

  bool get isActive => status == SiteStatus.active;

  static Site? fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    if (data == null) return null;
    final status = SiteStatus.values
        .where((value) => value.name == data['status'])
        .firstOrNull;
    if (status == null) return null;
    return Site(
      id: doc.id,
      name: data['name'] as String? ?? '',
      location: data['location'] as String? ?? '',
      notes: data['notes'] as String? ?? '',
      status: status,
      createdBy: data['createdBy'] as String? ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
