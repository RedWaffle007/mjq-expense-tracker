import 'package:intl/intl.dart';

/// Indian-English date formats used across the app.
/// Requires `initializeDateFormatting('en_IN')` at startup (see main.dart).

/// "12 Oct 2026"
String formatDate(DateTime date) =>
    DateFormat('d MMM yyyy', 'en_IN').format(date);

/// "12 Oct, 4:32 PM". The time uses plain English because en_IN writes
/// "pm" in lower case.
String formatDateTime(DateTime date) =>
    '${DateFormat('d MMM', 'en_IN').format(date)}, ${DateFormat('h:mm a', 'en').format(date)}';
