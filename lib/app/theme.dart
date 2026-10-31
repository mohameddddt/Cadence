import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../core/settings/settings_store.dart';

/// Hearts use their own warm red so favourites read the same in every palette.
const Color favoriteRed = Color(0xFFFF4D5E);

// ---------------------------------------------------------------------------
// Palettes: the neutrals are generated from the palette's hue, so every palette
// gets its own "paper" and "ink" and a single accent.
// ---------------------------------------------------------------------------

class PaletteSpec {
  const PaletteSpec(this.label, this.hue, this.saturation, this.accentLight, this.accentDark);

  final String label;
  final double hue;
  final double saturation;
  final Color accentLight;
  final Color accentDark;

  static PaletteSpec of(AppPalette p) => switch (p) {
    AppPalette.green => const PaletteSpec('Green', 142, 0.10, Color(0xFF15803D), Color(0xFF2BD46F)),
    AppPalette.coral => const PaletteSpec('Coral', 40, 0.26, Color(0xFFE5532D), Color(0xFFFF7246)),
    AppPalette.sage => const PaletteSpec('Sage', 100, 0.16, Color(0xFF4E7A57), Color(0xFF93C9A0)),
    AppPalette.ocean => const PaletteSpec('Ocean', 215, 0.20, Color(0xFF2D5BD2), Color(0xFF8DB0FF)),
    AppPalette.amber => const PaletteSpec('Amber', 44, 0.36, Color(0xFFB5761A), Color(0xFFF3B95C)),
    AppPalette.rose => const PaletteSpec('Rose', 340, 0.18, Color(0xFFC23F6A), Color(0xFFFF8FB3)),
    AppPalette.violet => const PaletteSpec('Violet', 250, 0.22, Color(0xFF5B4BD6), Color(0xFFB8AEFF)),
    AppPalette.ink => const PaletteSpec('Ink', 0, 0, Color(0xFF1A1A1A), Color(0xFFF2F2F2)),
    AppPalette.custom => PaletteSpec.custom(160, 0.5),
  };

  /// The palette the user chose, including their custom colour.
  static PaletteSpec fromSettings(SettingsStore s) => s.palette == AppPalette.custom ? PaletteSpec.custom(s.customHue, s.customTint) : of(s.palette);

  /// Any hue as a palette: a vivid accent tuned for each mode, and paper tinted by [tint] (0-1).
  factory PaletteSpec.custom(double hue, double tint) {
    final s = 0.04 + 0.36 * tint.clamp(0.0, 1.0);
    // Yellows and greens are bright at any lightness, so step the accent away from the
    // paper until it clearly stands out (3:1) in each mode.
    Color accent(double l, double sat, Color paper, double step) {
      var c = _hsl(hue, sat, l);
      for (var i = 0; i < 20 && _contrast(c, paper) < 3; i++) {
        l += step;
        c = _hsl(hue, sat, l);
      }
      return c;
    }

    return PaletteSpec(
      'Custom',
      hue,
      s,
      accent(0.44, 0.62, _hsl(hue, s, 0.936), -0.02),
      accent(0.72, 0.85, _hsl(hue, s * 0.45, 0.055), 0.02),
    );
  }

  /// A palette built around any accent: wallpaper colours or a cover's dominant colour.
  factory PaletteSpec.around(Color light, Color dark, {double tint = 0.3}) {
    final hsl = HSLColor.fromColor(light);
    return PaletteSpec('Custom', hsl.hue, (hsl.saturation * tint).clamp(0.06, 0.34), light, dark);
  }
}

Color _hsl(double h, double s, double l) => HSLColor.fromAHSL(1, h % 360, s.clamp(0.0, 1.0), l.clamp(0.0, 1.0)).toColor();

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05);
}

/// Ink or white, whichever reads better on [background] (pastel accents need ink).
Color _onColor(Color background) {
  const ink = Color(0xFF141210);
  final l = background.computeLuminance();
  final onInk = (l + 0.05) / (ink.computeLuminance() + 0.05);
  final onWhite = 1.05 / (l + 0.05);
  return onInk >= onWhite ? ink : Colors.white;
}

Color _mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;

ColorScheme schemeFor(PaletteSpec p, Brightness brightness) {
  final h = p.hue;
  final s = p.saturation;
  if (brightness == Brightness.light) {
    final accent = p.accentLight;
    final background = _hsl(h, s, 0.936);
    final ink = _hsl(h, s * 0.4, 0.095);
    return ColorScheme(
      brightness: Brightness.light,
      primary: accent,
      onPrimary: _onColor(accent),
      primaryContainer: _mix(background, accent, 0.18),
      onPrimaryContainer: _mix(ink, accent, 0.35),
      secondary: _hsl(h, s * 0.3, 0.4),
      onSecondary: Colors.white,
      secondaryContainer: _hsl(h, s * 0.8, 0.89),
      onSecondaryContainer: ink,
      tertiary: _hsl(h, s * 0.6, 0.38),
      onTertiary: Colors.white,
      tertiaryContainer: _hsl(h, s, 0.86),
      onTertiaryContainer: ink,
      surface: background,
      onSurface: ink,
      onSurfaceVariant: _hsl(h, s * 0.35, 0.44),
      surfaceTint: Colors.transparent,
      inverseSurface: ink,
      onInverseSurface: background,
      inversePrimary: p.accentDark,
      outline: _hsl(h, s * 0.5, 0.66),
      outlineVariant: _hsl(h, s * 0.7, 0.84),
      error: const Color(0xFFC8341F),
      onError: Colors.white,
      scrim: Colors.black,
      shadow: Colors.black,
      surfaceBright: _hsl(h, s, 0.985),
      surfaceDim: _hsl(h, s, 0.88),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: _hsl(h, s, 0.972),
      surfaceContainer: _hsl(h, s * 0.9, 0.918),
      surfaceContainerHigh: _hsl(h, s * 0.85, 0.889),
      surfaceContainerHighest: _hsl(h, s * 0.8, 0.857),
    );
  }
  // Dark mode is near-black and almost neutral (the stage), so covers and the accent carry the colour.
  final accent = p.accentDark;
  final n = s * 0.12;
  final background = _hsl(h, n, 0.071);
  final paper = _hsl(h, n, 0.97);
  return ColorScheme(
    brightness: Brightness.dark,
    primary: accent,
    onPrimary: _onColor(accent),
    primaryContainer: _mix(background, accent, 0.25),
    onPrimaryContainer: _mix(paper, accent, 0.3),
    secondary: _hsl(h, n, 0.7),
    onSecondary: background,
    secondaryContainer: _hsl(h, n, 0.16),
    onSecondaryContainer: paper,
    tertiary: _hsl(h, s, 0.72),
    onTertiary: background,
    tertiaryContainer: _hsl(h, s * 0.5, 0.22),
    onTertiaryContainer: paper,
    surface: background,
    onSurface: paper,
    onSurfaceVariant: _hsl(h, n, 0.70),
    surfaceTint: Colors.transparent,
    inverseSurface: paper,
    onInverseSurface: background,
    inversePrimary: p.accentLight,
    outline: _hsl(h, n, 0.36),
    outlineVariant: _hsl(h, n, 0.2),
    error: const Color(0xFFFF7A66),
    onError: const Color(0xFF3A0700),
    scrim: Colors.black,
    shadow: Colors.black,
    surfaceBright: _hsl(h, n, 0.2),
    surfaceDim: background,
    surfaceContainerLowest: _hsl(h, n, 0.04),
    surfaceContainerLow: _hsl(h, n, 0.095),
    surfaceContainer: _hsl(h, n, 0.118),
    surfaceContainerHigh: _hsl(h, n, 0.155),
    surfaceContainerHighest: _hsl(h, n, 0.19),
  );
}

/// Black backgrounds with the palette's containers pulled towards black.
ColorScheme pureBlack(ColorScheme s) => s.copyWith(
  surface: Colors.black,
  surfaceDim: Colors.black,
  surfaceContainerLowest: Colors.black,
  surfaceContainerLow: _mix(Colors.black, s.surfaceContainerLow, 0.7),
  surfaceContainer: _mix(Colors.black, s.surfaceContainer, 0.75),
  surfaceContainerHigh: _mix(Colors.black, s.surfaceContainerHigh, 0.8),
  surfaceContainerHighest: _mix(Colors.black, s.surfaceContainerHighest, 0.85),
  onInverseSurface: Colors.black,
);

// ---------------------------------------------------------------------------
// Tokens Material's colour scheme has no slot for.
// ---------------------------------------------------------------------------

@immutable
class CadenceTokens extends ThemeExtension<CadenceTokens> {
  const CadenceTokens({required this.isDark, required this.hairline, required this.raised, required this.glassTint, required this.glassBorder, required this.blur});

  factory CadenceTokens.of(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    return CadenceTokens(
      isDark: dark,
      hairline: scheme.outlineVariant,
      raised: dark ? _mix(scheme.surfaceContainerHighest, Colors.white, 0.08) : Colors.white,
      glassTint: scheme.surfaceContainerLow.withValues(alpha: dark ? 0.62 : 0.68),
      glassBorder: dark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.06),
      blur: 20,
    );
  }

  final bool isDark;

  /// Thin dividers and outlines.
  final Color hairline;

  /// The raised thumb of segmented controls.
  final Color raised;

  /// Tint laid over blurred content for floating "glass" bars.
  final Color glassTint;
  final Color glassBorder;
  final double blur;

  @override
  CadenceTokens copyWith({bool? isDark, Color? hairline, Color? raised, Color? glassTint, Color? glassBorder, double? blur}) => CadenceTokens(
    isDark: isDark ?? this.isDark,
    hairline: hairline ?? this.hairline,
    raised: raised ?? this.raised,
    glassTint: glassTint ?? this.glassTint,
    glassBorder: glassBorder ?? this.glassBorder,
    blur: blur ?? this.blur,
  );

  // Value equality, so rebuilding an identical theme does not start a theme animation.
  @override
  bool operator ==(Object other) =>
      other is CadenceTokens && other.isDark == isDark && other.hairline == hairline && other.raised == raised && other.glassTint == glassTint && other.glassBorder == glassBorder && other.blur == blur;

  @override
  int get hashCode => Object.hash(isDark, hairline, raised, glassTint, glassBorder, blur);

  @override
  CadenceTokens lerp(CadenceTokens? other, double t) {
    if (other == null) return this;
    return CadenceTokens(
      isDark: t < 0.5 ? isDark : other.isDark,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      raised: Color.lerp(raised, other.raised, t)!,
      glassTint: Color.lerp(glassTint, other.glassTint, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      blur: lerpDouble(blur, other.blur, t)!,
    );
  }
}

extension CadenceThemeX on BuildContext {
  CadenceTokens get tokens => Theme.of(this).extension<CadenceTokens>() ?? CadenceTokens.of(Theme.of(this).colorScheme);
}

// ---------------------------------------------------------------------------
// Type: a display face for titles and a body face for everything else.
// ---------------------------------------------------------------------------

class TypeSpec {
  const TypeSpec(this.label, this.description, this.display, this.displayWeight, this.displayScale, this.displayTracking, this.body);

  final String label;
  final String description;
  final String? display;
  final FontWeight displayWeight;
  final double displayScale;
  final double displayTracking;
  final String? body;

  static TypeSpec of(FontPairing f) => switch (f) {
    FontPairing.clean => const TypeSpec('Clean', 'Plus Jakarta Sans', 'PlusJakartaSans', FontWeight.w800, 0.8, -0.8, 'PlusJakartaSans'),
    FontPairing.editorial => const TypeSpec('Editorial', 'Instrument Serif & Manrope', 'InstrumentSerif', FontWeight.w400, 1, -0.4, 'Manrope'),
    FontPairing.classic => const TypeSpec('Classic', 'Playfair Display & Manrope', 'PlayfairDisplay', FontWeight.w500, 0.82, -0.6, 'Manrope'),
    FontPairing.modern => const TypeSpec('Modern', 'Space Grotesk', 'SpaceGrotesk', FontWeight.w500, 0.8, -1.4, 'SpaceGrotesk'),
    FontPairing.rounded => const TypeSpec('Rounded', 'Nunito', 'Nunito', FontWeight.w800, 0.78, -0.6, 'Nunito'),
    FontPairing.cadence => const TypeSpec('Cadence', 'Sora & Manrope', 'Sora', FontWeight.w700, 0.72, -1.0, 'Manrope'),
    FontPairing.system => const TypeSpec('System', "Your phone's font", null, FontWeight.w600, 0.78, -0.8, null),
  };

  /// Sora is a variable font whose default instance is not the weight we want.
  List<FontVariation>? get displayVariations => display == 'Sora' ? [FontVariation.weight(displayWeight.value.toDouble())] : null;

  TextStyle displayStyle(double size) => TextStyle(fontFamily: display, fontWeight: displayWeight, fontVariations: displayVariations, fontSize: size * displayScale, letterSpacing: displayTracking * (size / 44));
}

TextTheme textThemeFor(FontPairing fonts) {
  final spec = TypeSpec.of(fonts);
  TextStyle display(double size, double line) => spec.displayStyle(size).copyWith(height: line / size);
  TextStyle body(double size, double line, FontWeight weight, [double tracking = 0]) =>
      TextStyle(fontFamily: spec.body, fontWeight: weight, fontSize: size, height: line / size, letterSpacing: tracking);
  return TextTheme(
    displayLarge: display(52, 56),
    displayMedium: display(44, 50),
    displaySmall: display(34, 40),
    headlineLarge: display(30, 36),
    headlineMedium: display(26, 32),
    headlineSmall: display(23, 28),
    titleLarge: body(19, 26, FontWeight.w700, -0.2),
    titleMedium: body(16, 22, FontWeight.w600, -0.1),
    titleSmall: body(14, 20, FontWeight.w600),
    bodyLarge: body(16, 24, FontWeight.w500),
    bodyMedium: body(14, 20, FontWeight.w500),
    bodySmall: body(12.5, 18, FontWeight.w500),
    labelLarge: body(14, 18, FontWeight.w600),
    labelMedium: body(12, 16, FontWeight.w600, 0.2),
    labelSmall: body(11, 14, FontWeight.w700, 0.4),
  );
}

// ---------------------------------------------------------------------------

class AppTheme {
  const AppTheme._();

  static ThemeMode modeOf(ThemePreference p) => switch (p) {
    ThemePreference.system => ThemeMode.system,
    ThemePreference.light => ThemeMode.light,
    ThemePreference.dark || ThemePreference.amoled => ThemeMode.dark,
  };

  /// The light and dark themes for the chosen palette, or for the wallpaper's colours when the
  /// user asked for them and the system provides them.
  static ({ThemeData light, ThemeData dark}) build({Color? dynamicLightPrimary, Color? dynamicDarkPrimary, required SettingsStore settings}) {
    final useDynamic = settings.dynamicColor && dynamicLightPrimary != null && dynamicDarkPrimary != null;
    // Settings notify for every change; reuse the themes unless an input changed, so MaterialApp
    // does not animate between two identical themes.
    final custom = settings.palette == AppPalette.custom;
    final key = (useDynamic ? dynamicLightPrimary : null, useDynamic ? dynamicDarkPrimary : null, settings.palette, custom ? settings.customHue : null, custom ? settings.customTint : null, settings.pureBlack, settings.fontPairing);
    final cached = _cache;
    if (cached != null && cached.key == key) return cached.themes;
    final palette = useDynamic ? PaletteSpec.around(dynamicLightPrimary, dynamicDarkPrimary) : PaletteSpec.fromSettings(settings);
    var darkScheme = schemeFor(palette, Brightness.dark);
    if (settings.pureBlack) darkScheme = pureBlack(darkScheme);
    final themes = (light: themeFor(schemeFor(palette, Brightness.light), settings.fontPairing), dark: themeFor(darkScheme, settings.fontPairing));
    _cache = (key: key, themes: themes);
    return themes;
  }

  static ({Object key, ({ThemeData light, ThemeData dark}) themes})? _cache;

  static ThemeData themeFor(ColorScheme scheme, [FontPairing fonts = FontPairing.clean]) {
    final tokens = CadenceTokens.of(scheme);
    final spec = TypeSpec.of(fonts);
    final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: spec.body, textTheme: textThemeFor(fonts));
    final text = base.textTheme;
    final hairline = BorderSide(color: tokens.hairline);
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      extensions: [tokens],
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.headlineSmall?.copyWith(color: scheme.onSurface),
      ),
      iconTheme: IconThemeData(color: scheme.onSurface, size: 22),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 18),
        iconColor: scheme.onSurfaceVariant,
        titleTextStyle: text.bodyLarge?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w600),
        subtitleTextStyle: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainer,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        clipBehavior: Clip.antiAlias,
      ),
      // Primary actions are accent pills; secondary ones are outlined.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          shape: const StadiumBorder(),
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          textStyle: text.titleSmall,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          shape: const StadiumBorder(),
          side: hairline,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          textStyle: text.titleSmall,
        ),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: scheme.primary, shape: const StadiumBorder(), textStyle: text.labelLarge)),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: scheme.onSurface)),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 6,
        shape: const StadiumBorder(),
        extendedTextStyle: text.titleSmall,
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide.none,
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.primary,
        labelStyle: text.labelLarge?.copyWith(color: scheme.onSurface),
        secondaryLabelStyle: text.labelLarge?.copyWith(color: scheme.onPrimary),
        checkmarkColor: scheme.onPrimary,
        iconTheme: IconThemeData(color: scheme.onSurface, size: 16),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? scheme.surfaceContainerHighest : Colors.white),
        trackColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return scheme.surfaceContainerHigh;
          return s.contains(WidgetState.selected) ? scheme.primary : scheme.surfaceContainerHighest;
        }),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        thumbIcon: const WidgetStatePropertyAll(null),
      ),
      radioTheme: RadioThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.primary : scheme.outline)),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        side: BorderSide(color: scheme.outline, width: 1.5),
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.primary : Colors.transparent),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        // Underline-style borders keep a floating label inside the fill (outline borders push it onto the edge).
        border: UnderlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        enabledBorder: UnderlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        focusedBorder: UnderlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: scheme.primary, width: 2)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: text.headlineMedium?.copyWith(color: scheme.onSurface),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: scheme.outline,
        dragHandleSize: const Size(36, 4),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: hairline),
        textStyle: text.bodyLarge,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: hairline)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(color: scheme.onInverseSurface),
        actionTextColor: scheme.inversePrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      // Tabs are pills: the selected one is an ink capsule.
      tabBarTheme: TabBarThemeData(
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        indicator: ShapeDecoration(color: scheme.primary, shape: const StadiumBorder()),
        labelColor: scheme.onPrimary,
        unselectedLabelColor: scheme.onSurface,
        labelStyle: text.labelLarge,
        unselectedLabelStyle: text.labelLarge,
        labelPadding: const EdgeInsets.symmetric(horizontal: 16),
        splashBorderRadius: BorderRadius.circular(100),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: scheme.primary,
          selectedForegroundColor: scheme.onPrimary,
          side: hairline,
          textStyle: text.labelLarge,
        ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.onSurface.withValues(alpha: 0.14),
        thumbColor: scheme.primary,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7, elevation: 0, pressedElevation: 0),
        overlayShape: SliderComponentShape.noOverlay,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary, linearTrackColor: tokens.hairline, circularTrackColor: Colors.transparent),
      dividerTheme: DividerThemeData(color: tokens.hairline, space: 1, thickness: 1),
      badgeTheme: BadgeThemeData(backgroundColor: scheme.primary, textColor: scheme.onPrimary),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: scheme.inverseSurface, borderRadius: BorderRadius.circular(10)),
        textStyle: text.labelMedium?.copyWith(color: scheme.onInverseSurface),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {TargetPlatform.android: PredictiveBackPageTransitionsBuilder()}),
    );
  }

  /// Colours for Now Playing taken from the cover art: its dominant colour becomes the accent
  /// and tints the paper, so each album gets its own room.
  static Future<ColorScheme> fromCover(ImageProvider image, Brightness brightness, {bool pureBlackDark = false}) async {
    final light = await ColorScheme.fromImageProvider(provider: image);
    final dark = await ColorScheme.fromImageProvider(provider: image, brightness: Brightness.dark);
    final scheme = schemeFor(PaletteSpec.around(light.primary, dark.primary, tint: 0.45), brightness);
    return brightness == Brightness.dark && pureBlackDark ? pureBlack(scheme) : scheme;
  }
}
