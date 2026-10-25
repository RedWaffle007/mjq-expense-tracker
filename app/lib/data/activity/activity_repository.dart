import 'package:cloud_firestore/cloud_firestore.dart';

class ActivityItem {
  const ActivityItem({
    required this.id,
    required this.entryId,
    required this.summary,
    required this.actorId,
    required this.createdAt,
    required this.type,
  });
  final String id;
  final String entryId;
  final String summary;
  final String actorId;
  final DateTime? createdAt;
  final String type;

  static ActivityItem fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    return ActivityItem(
      id: doc.id,
      entryId: data['entryId'] as String? ?? '',
      summary: data['summary'] as String? ?? 'Expense changed',
      actorId: data['actorId'] as String? ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      type: data['type'] as String? ?? 'update',
    );
  }
}

class ActivityRepository {
  ActivityRepository(this._db);
  final FirebaseFirestore _db;
  Stream<List<ActivityItem>> watchLatest() => _db
      .collection('activity')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots()
      .map((snapshot) => snapshot.docs.map(ActivityItem.fromDoc).toList());
}
