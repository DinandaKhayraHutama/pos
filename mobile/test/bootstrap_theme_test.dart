import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/main.dart';
import 'package:nti_pos/providers/settings_provider.dart';

/// The bootstrap frames - rendered while [settingsProvider] is still loading -
/// used to hardcode an orange background, so every launch flashed the wrong
/// brand before the real theme appeared. `main()` now reads the saved brand
/// before `runApp` and hands it to [NtiPosApp], so those frames are themed too.
class _NeverSettles extends SettingsNotifier {
  @override
  Future<SettingsState> build() => Completer<SettingsState>().future;
}

void main() {
  Future<void> pumpBootstrap(WidgetTester tester, BrandPreset brand) async {
    // Tear the tree down first: MaterialApp lerps between themes over
    // kThemeAnimationDuration, so swapping the brand in place would leave the
    // previous brand's colour on screen for the frame we assert on.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith(_NeverSettles.new)],
        child: NtiPosApp(brand: brand, themeMode: ThemeMode.light),
      ),
    );
  }

  testWidgets('bootstrap frame paints the saved brand, never a fixed orange', (
    tester,
  ) async {
    for (final brand in BrandPreset.presets) {
      await pumpBootstrap(tester, brand);
      await tester.pump();

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(
        scaffold.backgroundColor,
        AppTheme.light(brand).colorScheme.primary,
        reason: 'bootstrap should use the ${brand.id} brand primary',
      );
      expect(scaffold.backgroundColor, isNot(Colors.orange.shade400));
    }
  });

  testWidgets('bootstrap brand differs between presets', (tester) async {
    final backgrounds = <Color?>[];
    for (final brand in BrandPreset.presets) {
      await pumpBootstrap(tester, brand);
      await tester.pump();
      backgrounds.add(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      );
    }
    // A single hardcoded colour would make every entry identical.
    expect(backgrounds.toSet().length, greaterThan(1));
  });
}
