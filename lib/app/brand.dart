import 'package:flutter/material.dart';

/// The app's identity in one place: name, tagline and colour tokens.
///
/// **Cadence** - the rhythm that closes a musical phrase. The palette is a deep
/// midnight-violet "ink" with a warm coral-to-amber accent, like a record under a lamp.
class Brand {
  const Brand._();

  static const String name = 'Cadence';
  static const String tagline = 'Your music, in rhythm.';
  static const String fontFamily = 'Sora';

  // Accent
  static const Color coral = Color(0xFFFF6B4A);
  static const Color coralSoft = Color(0xFFFF8A70);
  static const Color coralDeep = Color(0xFFC93B1D);
  static const Color amber = Color(0xFFFFB84D);
  static const Color violet = Color(0xFF7C6CFF);
  static const Color mint = Color(0xFF45D9B0);
  static const Color cream = Color(0xFFFFF1E8);

  // Midnight ink (dark surfaces)
  static const Color ink900 = Color(0xFF0B0819);
  static const Color ink800 = Color(0xFF0F0B22);
  static const Color ink700 = Color(0xFF14102A);
  static const Color ink600 = Color(0xFF1A1533);
  static const Color ink500 = Color(0xFF221C3F);
  static const Color ink400 = Color(0xFF2C2550);

  // Paper (light surfaces)
  static const Color paper = Color(0xFFFBF7F3);

  /// The signature gradient, used for the logo, hero tiles and the primary progress arc.
  static const LinearGradient flame = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [coral, amber]);

  /// Background of the app icon and splash.
  static const LinearGradient night = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF2A2058), ink900]);

  static ColorScheme get lightScheme => ColorScheme.fromSeed(seedColor: coral).copyWith(
    primary: coralDeep,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFFFDBD2),
    onPrimaryContainer: const Color(0xFF3F0A00),
    secondary: const Color(0xFF5B4BD6),
    onSecondary: Colors.white,
    secondaryContainer: const Color(0xFFE5E0FF),
    onSecondaryContainer: const Color(0xFF17085F),
    tertiary: const Color(0xFF8A5100),
    onTertiary: Colors.white,
    tertiaryContainer: const Color(0xFFFFDDB0),
    onTertiaryContainer: const Color(0xFF2C1700),
    surface: paper,
    onSurface: const Color(0xFF1C1826),
    onSurfaceVariant: const Color(0xFF4E4860),
    outline: const Color(0xFF7B7590),
    outlineVariant: const Color(0xFFD9D2E4),
    surfaceDim: const Color(0xFFE6DFDA),
    surfaceBright: paper,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: const Color(0xFFF6F1EC),
    surfaceContainer: const Color(0xFFF0EAE5),
    surfaceContainerHigh: const Color(0xFFEAE3DE),
    surfaceContainerHighest: const Color(0xFFE4DDD8),
  );

  static ColorScheme get darkScheme => ColorScheme.fromSeed(seedColor: coral, brightness: Brightness.dark).copyWith(
    primary: coralSoft,
    onPrimary: const Color(0xFF3A0E02),
    primaryContainer: const Color(0xFF5C1F10),
    onPrimaryContainer: const Color(0xFFFFDAD1),
    secondary: const Color(0xFFB8AEFF),
    onSecondary: const Color(0xFF24196B),
    secondaryContainer: const Color(0xFF383066),
    onSecondaryContainer: const Color(0xFFE4DEFF),
    tertiary: const Color(0xFFFFC46B),
    onTertiary: const Color(0xFF402800),
    tertiaryContainer: const Color(0xFF5C3D00),
    onTertiaryContainer: const Color(0xFFFFDDAA),
    surface: ink800,
    onSurface: const Color(0xFFECE8F7),
    onSurfaceVariant: const Color(0xFFB5AECB),
    outline: const Color(0xFF7F7896),
    outlineVariant: const Color(0xFF3A3358),
    surfaceDim: ink900,
    surfaceBright: const Color(0xFF332B5A),
    surfaceContainerLowest: ink900,
    surfaceContainerLow: ink700,
    surfaceContainer: ink600,
    surfaceContainerHigh: ink500,
    surfaceContainerHighest: ink400,
  );
}
