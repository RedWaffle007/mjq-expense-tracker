/// Item quantity is optional free text ("50 bags", "2.5 ton", "1 load").
/// When it starts with a number, the amount is that number × the price per
/// item; otherwise the price per item is the whole amount.
final _leadingNumber = RegExp(
  r'^\s*((?:\d{1,3}(?:,\d{2,3})+|\d+)(?:\.\d+)?|\.\d+)(?:\s*/\s*(\d+))?',
);

/// The positive number a quantity starts with: "50 bags" → 50,
/// "1,200 bricks" → 1200, "1/2 load" → 0.5. Null when there isn't one.
num? leadingQuantity(String? text) {
  final match = _leadingNumber.firstMatch(text ?? '');
  if (match == null) return null;
  num? value = num.tryParse(match.group(1)!.replaceAll(',', ''));
  final divisor = match.group(2);
  if (value != null && divisor != null) {
    final by = int.parse(divisor);
    value = by == 0 ? null : value / by;
  }
  return value != null && value.isFinite && value > 0 ? value : null;
}

/// The amount in paise for [ratePaise] per item, or null when it would not be
/// a positive amount.
int? amountFor(String? quantity, int ratePaise) {
  final amount = ((leadingQuantity(quantity) ?? 1) * ratePaise).round();
  return amount > 0 ? amount : null;
}

/// A stored quantity as display text. Entries saved before quantity became
/// text hold a number.
String? quantityText(Object? raw) => switch (raw) {
  final String text when text.trim().isNotEmpty => text.trim(),
  final num value => formatQuantityNumber(value),
  _ => null,
};

/// "50" rather than "50.0"; "2.5" stays as is.
String formatQuantityNumber(num value) =>
    value == value.roundToDouble() ? value.toInt().toString() : '$value';
