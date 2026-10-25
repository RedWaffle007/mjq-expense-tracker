import 'package:expensetracker/data/entries/expense_entry.dart';
import 'package:expensetracker/features/voice/voice_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses quantity, rate, computed amount, material, and vendor', () {
    final value = parseOnDevice('50 bags cement at 380 each from Sai Traders');
    expect(value.quantity, 50);
    expect(value.unit, 'bags');
    expect(value.rateRupees, 380);
    expect(value.amountRupees, 19000);
    expect(value.category, ExpenseCategory.material);
    expect(value.vendor, 'Sai Traders');
    expect(value.onDevice, isTrue);
  });

  test('understands lakh and hazaar amount words', () {
    expect(parseOnDevice('steel total 1.5 lakh').amountRupees, 150000);
    expect(parseOnDevice('labour paid 20 hazaar').amountRupees, 20000);
  });

  test('does not invent a missing amount', () {
    final value = parseOnDevice('cement from Sai Traders');
    expect(value.amountRupees, isNull);
    expect(value.category, ExpenseCategory.material);
  });
}
