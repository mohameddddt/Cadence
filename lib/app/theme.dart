import 'package:flutter/material.dart';

import '../core/settings/settings_store.dart';
import 'brand.dart';

/// Light / dark / AMOLED-black themes in the Cadence palette. Wallpaper (Material You)
/// colours are an opt-in override on Android 12+.
class AppTheme {
  const AppTheme._();

  static ThemeMode modeOf(ThemePreference p) => switch (p) {
    ThemePreference.system => ThemeMode.system,
    ThemePreference.light => ThemeMode.light,
    ThemePreference.dark || ThemePreference.amoled => ThemeMode.dark,
  };

  /// Picks the scheme pair: the brand palette, or wallpaper colours when the user asked for
  /// them and the system provides them. dynamic_color hands over its own ColorScheme type,
  /// so only the primary colour is taken and expanded with Flutter's tonal palette.
  static ({ThemeData light, ThemeData dark}) build({Color? dynamicLightPrimary, Color? dynamicDarkPrimary, required SettingsStore settings}) {
    final useDynamic = settings.dynamicColor && dynamicLightPrimary != null && dynamicDarkPrimary != null;
    final lightScheme = useDynamic ? ColorScheme.fromSeed(seedColor: dynamicLightPrimary) : Brand.lightScheme;
    var darkScheme = useDynamic ? ColorScheme.fromSeed(seedColor: dynamicDarkPrimary, brightness: Brightness.dark) : Brand.darkScheme;
    if (settings.themePreference == ThemePreference.amoled) darkScheme = amoled(darkScheme);
    return (light: themeFor(lightScheme), dark: themeFor(darkScheme));
  }

  static ColorScheme amoled(ColorScheme s) => s.copyWith(
    surface: Colors.black,
    surfaceDim: Colors.black,
    surfaceContainerLowest: Colors.black,
    surfaceContainerLow: const Color(0xFF080808),
    surfaceContainer: const Color(0xFF101010),
    surfaceContainerHigh: const Color(0xFF181818),
    surfaceContainerHighest: const Color(0xFF202020),
  );

  /// Sora for display and title styles (geometric, a little wide - it gives Cadence its voice);
  /// the platform font stays for body text so long lists remain compact and readable.
  static TextTheme _textTheme(TextTheme base) {
    TextStyle? brand(TextStyle? s, double weight, {double? spacing}) => s?.copyWith(
      fontFamily: Brand.fontFamily,
      fontWeight: FontWeight.values[((weight / 100).round() - 1).clamp(0, 8)],
      fontVariations: [FontVariation.weight(weight)],
      letterSpacing: spacing,
    );
    return base.copyWith(
      displayLarge: brand(base.displayLarge, 700, spacing: -1),
      displayMedium: brand(base.displayMedium, 700, spacing: -0.8),
      displaySmall: brand(base.displaySmall, 700, spacing: -0.5),
      headlineLarge: brand(base.headlineLarge, 700, spacing: -0.5),
      headlineMedium: brand(base.headlineMedium, 700, spacing: -0.3),
      headlineSmall: brand(base.headlineSmall, 700, spacing: -0.2),
      titleLarge: brand(base.titleLarge, 700, spacing: -0.2),
      titleMedium: brand(base.titleMedium, 600, spacing: 0),
    );
  }

  static ThemeData themeFor(ColorScheme scheme) {
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    final text = _textTheme(base.textTheme);
    final shape20 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(20));
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      textTheme: text,
      primaryTextTheme: _textTheme(base.primaryTextTheme),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.primaryContainer,
        height: 68,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
            color: states.contains(WidgetState.selected) ? scheme.onSurface : scheme.onSurfaceVariant,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(color: states.contains(WidgetState.selected) ? scheme.onPrimaryContainer : scheme.onSurfaceVariant)),
      ),
      listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
      cardTheme: CardThemeData(elevation: 0, color: scheme.surfaceContainerHigh, margin: EdgeInsets.zero, shape: shape20, clipBehavior: Clip.antiAlias),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: const StadiumBorder(),
          side: BorderSide(color: scheme.outlineVariant),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant),
        backgroundColor: Colors.transparent,
        selectedColor: scheme.primaryContainer,
        labelStyle: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w600, fontSize: 13),
        secondaryLabelStyle: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w700, fontSize: 13),
        checkmarkColor: scheme.onPrimaryContainer,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        // Underline-style borders keep a floating label inside the fill (outline borders push it onto the edge).
        border: UnderlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        enabledBorder: UnderlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        focusedBorder: UnderlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      tabBarTheme: TabBarThemeData(
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelStyle: const TextStyle(fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: scheme.primaryContainer,
          selectedForegroundColor: scheme.onPrimaryContainer,
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      sliderTheme: const SliderThemeData(trackHeight: 3, thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6)),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary, linearTrackColor: scheme.surfaceContainerHighest),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {TargetPlatform.android: PredictiveBackPageTransitionsBuilder()}),
    );
  }

  /// Colours for a Now Playing screen derived from the cover art.
  static Future<ColorScheme> fromCover(ImageProvider image, Brightness brightness) => ColorScheme.fromImageProvider(provider: image, brightness: brightness);
}
