import 'package:expensetracker/data/entries/quantity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('leadingQuantity', () {
    test('reads the number a quantity starts with', () {
      expect(leadingQuantity('50'), 50);
      expect(leadingQuantity('50 bags'), 50);
      expect(leadingQuantity('50bags'), 50);
      expect(leadingQuantity(' 2.5 ton'), 2.5);
      expect(leadingQuantity('1,200 bricks'), 1200);
      expect(leadingQuantity('1,00,000 nos'), 100000);
      expect(leadingQuantity('1/2 load'), 0.5);
      expect(leadingQuantity('.5 cft'), 0.5);
    });

    test('is null without a positive leading number', () {
      expect(leadingQuantity(null), isNull);
      expect(leadingQuantity(''), isNull);
      expect(leadingQuantity('one load'), isNull);
      expect(leadingQuantity('bags 50'), isNull);
      expect(leadingQuantity('0 bags'), isNull);
      expect(leadingQuantity('1/0'), isNull);
      expect(leadingQuantity('-5 bags'), isNull);
    });
  });

  group('amountFor', () {
    test('multiplies by the leading number', () {
      expect(amountFor('50 bags', 38000), 1900000);
      expect(amountFor('2.5', 100000), 250000);
    });

    test('uses the price alone when there is no number', () {
      expect(amountFor(null, 500000), 500000);
      expect(amountFor('', 500000), 500000);
      expect(amountFor('one truck load', 500000), 500000);
    });

    test('rejects amounts that round to zero', () {
      expect(amountFor('0.001 kg', 100), isNull);
    });
  });

  test('quantityText accepts stored text and older numeric values', () {
    expect(quantityText('  50 bags '), '50 bags');
    expect(quantityText(''), isNull);
    expect(quantityText(null), isNull);
    expect(quantityText(50), '50');
    expect(quantityText(50.0), '50');
    expect(quantityText(2.5), '2.5');
  });
}
