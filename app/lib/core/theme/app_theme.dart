import 'package:flutter/material.dart';

/// App-wide theme. Deliberately plain Material 3 from one brand seed colour;
/// screens use `Theme.of(context)` roles rather than hard-coded colours.
abstract final class AppTheme {
  static const Color _seed = Color(0xFF1F4E79); // deep construction blue

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16),
      ),
    );
  }
}

/// Screen padding shared by forms and centred states.
const EdgeInsets kScreenPadding = EdgeInsets.symmetric(
  horizontal: 24,
  vertical: 16,
);
