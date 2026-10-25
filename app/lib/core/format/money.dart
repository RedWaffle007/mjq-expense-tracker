import 'package:intl/intl.dart';

/// Money is stored as integer paise (plan.md Section 5) and shown in Indian
/// grouping: 10000000 paise → "₹1,00,000".
final NumberFormat _rupees = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '₹',
  decimalDigits: 0,
);

final NumberFormat _rupeesWithPaise = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '₹',
  decimalDigits: 2,
);

/// "₹1,00,000" for whole rupees, "₹1,00,000.50" when there are paise.
String formatPaise(int paise) {
  final format = paise % 100 == 0 ? _rupees : _rupeesWithPaise;
  return format.format(paise / 100);
}

/// Parses what a user types in a rupee field ("1,20,000", "380.5") to paise.
/// Returns null for empty or invalid input, or more than two decimals.
int? parseRupeesToPaise(String input) {
  final cleaned = input.replaceAll(RegExp(r'[₹,\s]'), '');
  if (cleaned.isEmpty) return null;
  final match = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(cleaned);
  if (match == null) return null;
  final rupees = int.parse(match.group(1)!);
  final fraction = (match.group(2) ?? '').padRight(2, '0');
  return rupees * 100 + int.parse(fraction);
}
