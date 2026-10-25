import 'package:expensetracker/core/format/dates.dart';
import 'package:expensetracker/core/format/money.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('en_IN'));

  group('formatPaise', () {
    test('uses Indian grouping and drops zero paise', () {
      expect(formatPaise(10000000), '₹1,00,000');
      expect(formatPaise(1900000), '₹19,000');
      expect(formatPaise(12345678900), '₹12,34,56,789');
      expect(formatPaise(0), '₹0');
    });

    test('shows paise when present', () {
      expect(formatPaise(12000050), '₹1,20,000.50');
      expect(formatPaise(38050), '₹380.50');
    });
  });

  group('parseRupeesToPaise', () {
    test('accepts plain, grouped, and decimal input', () {
      expect(parseRupeesToPaise('380'), 38000);
      expect(parseRupeesToPaise('1,20,000'), 12000000);
      expect(parseRupeesToPaise('₹ 380.5'), 38050);
      expect(parseRupeesToPaise('0.05'), 5);
    });

    test('rejects empty and invalid input', () {
      expect(parseRupeesToPaise(''), isNull);
      expect(parseRupeesToPaise('abc'), isNull);
      expect(parseRupeesToPaise('1.234'), isNull);
      expect(parseRupeesToPaise('-5'), isNull);
    });
  });

  test('dates use Indian-English formats', () {
    final d = DateTime(2026, 10, 12, 16, 32);
    expect(formatDate(d), '12 Oct 2026');
    expect(formatDateTime(d), '12 Oct, 4:32 PM');
  });
}
