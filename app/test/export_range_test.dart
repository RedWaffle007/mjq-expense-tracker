import 'package:expensetracker/features/admin/export/export_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final today = DateTime(2026, 9, 27, 14);

  test(
    'this month includes the first day and today, but not earlier dates',
    () {
      expect(
        exportIncludesDate(DateTime(2026, 9), ExportRange.thisMonth, today),
        isTrue,
      );
      expect(
        exportIncludesDate(
          DateTime(2026, 9, 27, 23),
          ExportRange.thisMonth,
          today,
        ),
        isTrue,
      );
      expect(
        exportIncludesDate(DateTime(2026, 8, 31), ExportRange.thisMonth, today),
        isFalse,
      );
      expect(
        exportIncludesDate(DateTime(2026, 9, 28), ExportRange.thisMonth, today),
        isFalse,
      );
    },
  );

  test('all time includes older expenses through today', () {
    expect(
      exportIncludesDate(DateTime(2020), ExportRange.allTime, today),
      isTrue,
    );
    expect(
      exportIncludesDate(DateTime(2026, 9, 27, 23), ExportRange.allTime, today),
      isTrue,
    );
    expect(
      exportIncludesDate(DateTime(2026, 9, 28), ExportRange.allTime, today),
      isFalse,
    );
  });
}
