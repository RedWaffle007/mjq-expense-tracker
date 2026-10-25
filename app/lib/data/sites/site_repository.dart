import 'package:cloud_firestore/cloud_firestore.dart';

import 'site.dart';

class SiteRepository {
  SiteRepository(this._db);

  final FirebaseFirestore _db;

  Stream<List<Site>> watchAll() =>
      _db.collection('sites').snapshots().map((snapshot) {
        final sites = snapshot.docs.map(Site.fromDoc).nonNulls.toList()
          ..sort((a, b) {
            if (a.status != b.status) return a.isActive ? -1 : 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
        return sites;
      });

  Stream<List<Site>> watchActive() => _db
      .collection('sites')
      .where('status', isEqualTo: SiteStatus.active.name)
      .snapshots()
      .map(
        (snapshot) => snapshot.docs.map(Site.fromDoc).nonNulls.toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          ),
      );

  Future<List<Site>> allForExport() async =>
      (await _db
              .collection('sites')
              .get(const GetOptions(source: Source.server)))
          .docs
          .map(Site.fromDoc)
          .nonNulls
          .toList();

  Future<void> create({
    required String uid,
    required String name,
    required String location,
    required String notes,
  }) => _db.collection('sites').add({
    'name': name.trim(),
    'location': location.trim(),
    'notes': notes.trim(),
    'status': SiteStatus.active.name,
    'createdBy': uid,
    'createdAt': FieldValue.serverTimestamp(),
  });

  Future<void> update(
    Site site, {
    required String name,
    required String location,
    required String notes,
    required SiteStatus status,
  }) => _db.collection('sites').doc(site.id).update({
    'name': name.trim(),
    'location': location.trim(),
    'notes': notes.trim(),
    'status': status.name,
  });
}
