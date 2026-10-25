import '../../data/entries/expense_entry.dart';

class VoiceFields {
  const VoiceFields({
    this.item,
    this.category,
    this.amountRupees,
    this.quantity,
    this.unit,
    this.rateRupees,
    this.vendor,
    this.note,
    this.onDevice = false,
  });
  final String? item;
  final ExpenseCategory? category;
  final num? amountRupees;
  final num? quantity;
  final String? unit;
  final num? rateRupees;
  final String? vendor;
  final String? note;
  final bool onDevice;

  factory VoiceFields.fromJson(Map<String, dynamic> json) => VoiceFields(
    item: json['item'] as String?,
    category: ExpenseCategory.values
        .where((v) => v.name == json['category'])
        .firstOrNull,
    amountRupees: json['amount'] as num?,
    quantity: json['quantity'] as num?,
    unit: json['unit'] as String?,
    rateRupees: json['rate'] as num?,
    vendor: json['vendor'] as String?,
    note: json['note'] as String?,
  );
}

/// Conservative offline parser: it fills only patterns it can identify and
/// leaves required fields null for the confirmation form to highlight.
VoiceFields parseOnDevice(String transcript) {
  final raw = transcript.trim();
  final text = raw.toLowerCase().replaceAll(',', ' ');
  num? quantity;
  String? unit;
  num? rate;
  num? amount;
  String? vendor;

  const units = [
    'bags',
    'bag',
    'kg',
    'ton',
    'cft',
    'sqft',
    'nos',
    'trips',
    'days',
    'litre',
    'liters',
  ];
  final quantityMatch = RegExp(
    r'(\d+(?:\.\d+)?)\s*(bags?|kg|tons?|cft|sqft|nos|trips?|days?|litres?|liters?)\b',
  ).firstMatch(text);
  if (quantityMatch != null) {
    quantity = num.tryParse(quantityMatch.group(1)!);
    unit = _normaliseUnit(quantityMatch.group(2)!);
  }
  final rateMatch = RegExp(
    r'(?:at|@|rate|each)\s*(?:rs\.?|₹)?\s*([\d.]+(?:\s*(?:lakh|lac|hazaar|hazar|thousand))?)',
  ).firstMatch(text);
  if (rateMatch != null) rate = _indianNumber(rateMatch.group(1)!);
  final amountMatch = RegExp(
    r'(?:total|amount|paid|for)\s*(?:rs\.?|₹)?\s*([\d.]+(?:\s*(?:lakh|lac|hazaar|hazar|thousand))?)',
  ).firstMatch(text);
  if (amountMatch != null) amount = _indianNumber(amountMatch.group(1)!);
  if (amount == null && quantity != null && rate != null) {
    amount = quantity * rate;
  }
  final vendorMatch = RegExp(
    r'\b(?:from|vendor)\s+(.+?)(?:\s+(?:total|amount|paid|for|on)\b|$)',
  ).firstMatch(raw);
  if (vendorMatch != null) vendor = vendorMatch.group(1)?.trim();

  final category =
      text.contains('labour') ||
          text.contains('labor') ||
          text.contains('mazdoor')
      ? ExpenseCategory.labour
      : text.contains('transport') ||
            text.contains('truck') ||
            text.contains('tempo')
      ? ExpenseCategory.transport
      : text.contains('equipment') ||
            text.contains('machine') ||
            text.contains('rent')
      ? ExpenseCategory.equipment
      : text.contains('cement') ||
            text.contains('steel') ||
            text.contains('sand') ||
            text.contains('brick')
      ? ExpenseCategory.material
      : ExpenseCategory.other;
  var item = raw;
  for (final token in [
    ...units,
    'from',
    'vendor',
    'total',
    'amount',
    'paid',
    'rate',
    'each',
  ]) {
    item = item.replaceAll(RegExp('\\b$token\\b.*', caseSensitive: false), '');
  }
  item = item.replaceAll(RegExp(r'^\s*\d+(?:\.\d+)?\s*'), '').trim();
  return VoiceFields(
    item: item.isEmpty ? null : item,
    category: category,
    amountRupees: amount,
    quantity: quantity,
    unit: unit,
    rateRupees: rate,
    vendor: vendor,
    note: raw,
    onDevice: true,
  );
}

num? _indianNumber(String value) {
  final match = RegExp(
    r'([\d.]+)\s*(lakh|lac|hazaar|hazar|thousand)?',
  ).firstMatch(value);
  final number = num.tryParse(match?.group(1) ?? '');
  if (number == null) return null;
  return switch (match?.group(2)) {
    'lakh' || 'lac' => number * 100000,
    'hazaar' || 'hazar' || 'thousand' => number * 1000,
    _ => number,
  };
}

String _normaliseUnit(String value) => switch (value) {
  'bag' => 'bags',
  'tons' => 'ton',
  'trip' => 'trips',
  'day' => 'days',
  'litres' || 'liters' => 'litre',
  _ => value,
};
