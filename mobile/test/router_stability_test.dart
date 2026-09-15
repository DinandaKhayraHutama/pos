import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nti_pos/core/router/app_router.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/providers/settings_provider.dart';

/// Changing a setting must not rebuild the router.
///
/// [routerProvider] feeds `MaterialApp.router`. If a settings change produces a
/// new [GoRouter], Flutter remounts the router at `initialLocation` and the
/// user is thrown back to the POS home page mid-task - which is exactly what
/// happened when switching theme, brand colour or language from Settings.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'logged_in': true}));

  Future<ProviderContainer> bootedContainer() async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    return container;
  }

  test('router survives a theme change', () async {
    final container = await bootedContainer();
    final before = container.read(routerProvider);

    await container.read(settingsProvider.notifier).setThemeMode(ThemeMode.dark);

    expect(identical(container.read(routerProvider), before), isTrue);
  });

  test('router survives a brand colour change', () async {
    final container = await bootedContainer();
    final before = container.read(routerProvider);

    await container
        .read(settingsProvider.notifier)
        .setBrand(BrandPreset.presets.last);

    expect(identical(container.read(routerProvider), before), isTrue);
  });

  test('router survives a locale change', () async {
    final container = await bootedContainer();
    final before = container.read(routerProvider);

    await container
        .read(settingsProvider.notifier)
        .setLocale(const Locale('en'));

    expect(identical(container.read(routerProvider), before), isTrue);
  });

  test('router survives a store-name change', () async {
    final container = await bootedContainer();
    final before = container.read(routerProvider);

    await container.read(settingsProvider.notifier).setStoreName('Warung Baru');

    expect(identical(container.read(routerProvider), before), isTrue);
  });

  test('redirect still sees fresh settings after logout', () async {
    final container = await bootedContainer();
    final router = container.read(routerProvider);

    await container.read(settingsProvider.notifier).logout();

    // Same router instance, but its redirect must now read loggedIn == false.
    expect(identical(container.read(routerProvider), router), isTrue);
    expect(container.read(settingsProvider).valueOrNull?.loggedIn, isFalse);
  });
}
