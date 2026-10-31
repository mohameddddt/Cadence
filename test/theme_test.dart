import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/app/theme.dart';
import 'package:musicplayer/core/settings/settings_store.dart';
import 'package:musicplayer/ui/widgets/kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

final _theme = AppTheme.themeFor(schemeFor(PaletteSpec.of(AppPalette.coral), Brightness.light));

Widget host(Widget child, {double width = 400}) => MaterialApp(
      theme: _theme,
      home: Scaffold(body: Center(child: SizedBox(width: width, child: child))),
    );

void main() {
  group('palettes', () {
    for (final p in AppPalette.values) {
      for (final b in Brightness.values) {
        test('${p.name} ${b.name} keeps text readable on its paper', () {
          final s = schemeFor(PaletteSpec.of(p), b);
          expect(s.brightness, b);
          expect(contrast(s.onSurface, s.surface), greaterThanOrEqualTo(7), reason: 'ink on paper');
          expect(contrast(s.onSurfaceVariant, s.surface), greaterThanOrEqualTo(3), reason: 'secondary text');
          expect(contrast(s.onInverseSurface, s.inverseSurface), greaterThanOrEqualTo(7), reason: 'ink pills');
          expect(contrast(s.onPrimary, s.primary), greaterThanOrEqualTo(3), reason: 'accent buttons');
        });
      }
    }

    test('each palette gets its own paper', () {
      final papers = {for (final p in AppPalette.values) schemeFor(PaletteSpec.of(p), Brightness.light).surface};
      expect(papers.length, AppPalette.values.length);
    });

    test('custom colours stay readable at any hue and tint', () {
      for (var hue = 0.0; hue < 360; hue += 15) {
        for (final tint in [0.0, 0.5, 1.0]) {
          for (final b in Brightness.values) {
            final s = schemeFor(PaletteSpec.custom(hue, tint), b);
            final where = 'hue $hue tint $tint ${b.name}';
            expect(contrast(s.onSurface, s.surface), greaterThanOrEqualTo(7), reason: where);
            expect(contrast(s.onPrimary, s.primary), greaterThanOrEqualTo(3), reason: where);
            expect(contrast(s.primary, s.surface), greaterThanOrEqualTo(3), reason: 'accent visible on paper, $where');
          }
        }
      }
    });

    test('the custom palette follows the stored hue and tint', () async {
      SharedPreferences.setMockInitialValues({'ui.palette': 'custom', 'ui.customHue': 200.0, 'ui.customTint': 1.0});
      final s = await SettingsStore.load();
      final spec = PaletteSpec.fromSettings(s);
      expect(spec.hue, 200);
      final theme = AppTheme.build(settings: s).light;
      expect(theme.colorScheme.primary, spec.accentLight);
      await s.setCustomHue(20);
      expect(AppTheme.build(settings: s).light.colorScheme.primary, isNot(spec.accentLight), reason: 'theme rebuilds for a new hue');
    });

    test('pure black turns the page black but keeps the accent', () {
      final s = schemeFor(PaletteSpec.of(AppPalette.ocean), Brightness.dark);
      final black = pureBlack(s);
      expect(black.surface, Colors.black);
      expect(black.primary, s.primary);
    });

    test('a palette around an accent keeps that accent', () {
      const light = Color(0xFF2E7D32), dark = Color(0xFF81C784);
      final spec = PaletteSpec.around(light, dark);
      expect(schemeFor(spec, Brightness.light).primary, light);
      expect(schemeFor(spec, Brightness.dark).primary, dark);
    });
  });

  group('type', () {
    test('display styles use the pairing face and body styles its body face', () {
      expect(textThemeFor(FontPairing.clean).displayMedium!.fontFamily, 'PlusJakartaSans');
      final editorial = textThemeFor(FontPairing.editorial);
      expect(editorial.displayMedium!.fontFamily, 'InstrumentSerif');
      expect(editorial.bodyMedium!.fontFamily, 'Manrope');
      expect(textThemeFor(FontPairing.modern).titleLarge!.fontFamily, 'SpaceGrotesk');
      expect(textThemeFor(FontPairing.system).displayMedium!.fontFamily, isNull);
    });

    test('the theme carries the Cadence tokens', () {
      final t = AppTheme.themeFor(schemeFor(PaletteSpec.of(AppPalette.rose), Brightness.dark), FontPairing.rounded);
      expect(t.extension<CadenceTokens>()!.isDark, isTrue);
      expect(t.textTheme.headlineSmall!.fontFamily, 'Nunito');
    });
  });

  group('appearance settings', () {
    Future<SettingsStore> store([Map<String, Object> initial = const {}]) async {
      SharedPreferences.setMockInitialValues(initial);
      return SettingsStore.load();
    }

    test('defaults to dark, the green palette and the clean sans pairing', () async {
      final s = await store();
      expect(AppTheme.modeOf(s.themePreference), ThemeMode.dark);
      expect(s.palette, AppPalette.green);
      expect(s.fontPairing, FontPairing.clean);
      expect(s.pureBlack, isFalse);
      expect(s.ambientBackdrop, isTrue);
    });

    test('the old AMOLED theme reads as dark + pure black', () async {
      final s = await store({'ui.theme': 'amoled'});
      expect(AppTheme.modeOf(s.themePreference), ThemeMode.dark);
      expect(s.pureBlack, isTrue);
    });

    test('choosing Dark after AMOLED keeps pure black on', () async {
      final s = await store({'ui.theme': 'amoled'});
      await s.setThemePreference(ThemePreference.dark);
      expect(s.themePreference, ThemePreference.dark);
      expect(s.pureBlack, isTrue);
    });

    test('unrelated setting changes reuse the built themes; appearance changes rebuild them', () async {
      final s = await store();
      final a = AppTheme.build(settings: s);
      await s.setWifiOnly(true);
      expect(identical(AppTheme.build(settings: s).light, a.light), isTrue);
      await s.setPalette(AppPalette.sage);
      final b = AppTheme.build(settings: s);
      expect(identical(b.light, a.light), isFalse);
      expect(b.light.colorScheme.primary, PaletteSpec.of(AppPalette.sage).accentLight);
    });

    test('turning pure black off after AMOLED leaves plain dark', () async {
      final s = await store({'ui.theme': 'amoled'});
      await s.setPureBlack(false);
      expect(s.themePreference, ThemePreference.dark);
      expect(s.pureBlack, isFalse);
    });
  });

  group('kit', () {
    const items = [
      DockItem('Home', Icons.home_outlined, Icons.home),
      DockItem('Library', Icons.library_music_outlined, Icons.library_music),
      DockItem('Downloads', Icons.download_outlined, Icons.download, badge: 2),
    ];

    testWidgets('the bottom bar labels every tab, badges and reports taps', (tester) async {
      var selected = 0;
      await tester.pumpWidget(host(StatefulBuilder(
        builder: (context, set) => BottomBar(items: items, selectedIndex: selected, onSelect: (i) => set(() => selected = i)),
      )));
      for (final label in ['Home', 'Library', 'Downloads']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('2'), findsOneWidget, reason: 'badge');
      expect(find.byIcon(Icons.home), findsOneWidget, reason: 'selected tab shows its filled icon');
      await tester.tap(find.bySemanticsLabel('Library'));
      await tester.pumpAndSettle();
      expect(selected, 1);
      expect(find.byIcon(Icons.library_music), findsOneWidget);
      expect(find.byIcon(Icons.home_outlined), findsOneWidget);
    });

    test('recent searches keep the newest first, drop prefixes and cap at eight', () async {
      SharedPreferences.setMockInitialValues({});
      final s = await SettingsStore.load();
      for (final q in ['ab', 'abb', 'abba', 'queen', 'ABBA']) {
        await s.addRecentSearch(q);
      }
      expect(s.recentSearches, ['ABBA', 'queen']);
      for (var i = 0; i < 10; i++) {
        await s.addRecentSearch('song $i x');
      }
      expect(s.recentSearches.length, 8);
      expect(s.recentSearches.first, 'song 9 x');
      await s.clearRecentSearches();
      expect(s.recentSearches, isEmpty);
    });

    testWidgets('segmented pills select the tapped option', (tester) async {
      String? picked;
      await tester.pumpWidget(host(SegmentedPills<String>(options: const ['a', 'b', 'c'], selected: 'a', label: (s) => s.toUpperCase(), onSelect: (v) => picked = v)));
      await tester.tap(find.text('C'));
      expect(picked, 'c');
    });

    testWidgets('playing bars animate only while playing', (tester) async {
      await tester.pumpWidget(host(const PlayingBars(playing: false)));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(const PlayingBars(playing: true)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpWidget(host(const PlayingBars(playing: false)));
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
    });

    test('greeting follows the time of day', () {
      expect(greeting(DateTime(2026, 1, 1, 3)), 'Up late');
      expect(greeting(DateTime(2026, 1, 1, 9)), 'Good morning');
      expect(greeting(DateTime(2026, 1, 1, 14)), 'Good afternoon');
      expect(greeting(DateTime(2026, 1, 1, 21)), 'Good evening');
    });
  });
}
