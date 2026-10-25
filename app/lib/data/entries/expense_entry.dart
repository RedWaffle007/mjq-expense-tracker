import 'package:cloud_firestore/cloud_firestore.dart';

import 'quantity.dart';

enum ExpenseCategory { material, labour, equipment, transport, other }

extension ExpenseCategoryLabel on ExpenseCategory {
  String get label => switch (this) {
    ExpenseCategory.material => 'Material',
    ExpenseCategory.labour => 'Labour',
    ExpenseCategory.equipment => 'Equipment',
    ExpenseCategory.transport => 'Transport',
    ExpenseCategory.other => 'Other',
  };
}

class ExpenseEntry {
  const ExpenseEntry({
    required this.id,
    required this.siteId,
    required this.item,
    required this.category,
    required this.amount,
    required this.storedQuantity,
    required this.unit,
    required this.rate,
    required this.vendor,
    required this.note,
    required this.photos,
    required this.pendingPhotoCount,
    required this.expenseDate,
    required this.createdBy,
    required this.createdAt,
    required this.updatedBy,
    required this.updatedAt,
    required this.isDeleted,
    required this.lastChangeId,
    required this.hasConflict,
    required this.hasPendingWrites,
  });

  final String id;
  final String siteId;
  final String item;
  final ExpenseCategory category;
  final int amount;

  /// Free text; entries saved before quantity became text hold a number.
  /// Kept as stored so edit history records the exact previous value.
  final Object? storedQuantity;
  final String? unit;
  final int? rate;
  final String? vendor;
  final String? note;
  final List<BillPhoto> photos;
  final int pendingPhotoCount;
  final DateTime expenseDate;
  final String createdBy;
  final DateTime? createdAt;
  final String updatedBy;
  final DateTime? updatedAt;
  final bool isDeleted;
  final String lastChangeId;
  final bool hasConflict;
  final bool hasPendingWrites;

  String? get quantity => quantityText(storedQuantity);

  Map<String, Object?> get editableFields => {
    'siteId': siteId,
    'item': item,
    'category': category.name,
    'amount': amount,
    'quantity': storedQuantity,
    'unit': unit,
    'rate': rate,
    'vendor': vendor,
    'note': note,
    'expenseDate': Timestamp.fromDate(expenseDate),
  };

  static ExpenseEntry? fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    if (data == null) return null;
    final category = ExpenseCategory.values
        .where((value) => value.name == data['category'])
        .firstOrNull;
    final date = data['expenseDate'];
    if (category == null || date is! Timestamp || data['amount'] is! int) {
      return null;
    }
    return ExpenseEntry(
      id: doc.id,
      siteId: data['siteId'] as String? ?? '',
      item: data['item'] as String? ?? '',
      category: category,
      amount: data['amount'] as int,
      storedQuantity: data['quantity'] is String || data['quantity'] is num
          ? data['quantity']
          : null,
      unit: data['unit'] as String?,
      rate: data['rate'] as int?,
      vendor: data['vendor'] as String?,
      note: data['note'] as String?,
      photos: (data['photos'] as List? ?? const [])
          .map(BillPhoto.fromValue)
          .nonNulls
          .toList(growable: false),
      pendingPhotoCount: data['pendingPhotoCount'] as int? ?? 0,
      expenseDate: date.toDate(),
      createdBy: data['createdBy'] as String? ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedBy: data['updatedBy'] as String? ?? '',
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      isDeleted: data['isDeleted'] == true,
      lastChangeId: data['lastChangeId'] as String? ?? '',
      hasConflict: data['conflict'] != null,
      hasPendingWrites: doc.metadata.hasPendingWrites,
    );
  }
}

class BillPhoto {
  const BillPhoto({required this.publicId, required this.uploadedAt});

  final String publicId;
  final DateTime? uploadedAt;

  Map<String, Object?> toMap() => {
    'publicId': publicId,
    'uploadedAt': uploadedAt == null
        ? FieldValue.serverTimestamp()
        : Timestamp.fromDate(uploadedAt!),
  };

  static BillPhoto? fromValue(Object? value) {
    if (value is! Map || value['publicId'] is! String) return null;
    return BillPhoto(
      publicId: value['publicId'] as String,
      uploadedAt: (value['uploadedAt'] as Timestamp?)?.toDate(),
    );
  }
}

class EntryHistory {
  const EntryHistory({
    required this.id,
    required this.action,
    required this.by,
    required this.at,
    required this.changes,
    required this.conflict,
  });

  final String id;
  final String action;
  final String by;
  final DateTime? at;
  final Map<String, dynamic> changes;
  final bool conflict;

  static EntryHistory? fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    return EntryHistory(
      id: doc.id,
      action: data['action'] as String? ?? '',
      by: data['by'] as String? ?? '',
      at: (data['at'] as Timestamp?)?.toDate(),
      changes: Map<String, dynamic>.from(data['changes'] as Map? ?? const {}),
      conflict: data['conflict'] == true,
    );
  }
}
