import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/localization/l10n.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/brand_mark.dart';
import 'data/preferences/app_preferences.dart';
import 'l10n/gen/app_localizations.dart';
import 'providers/settings_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Read the saved brand before the first frame. settingsProvider still loads
  // asynchronously, but its loading frame can now be painted in the user's own
  // brand colour instead of a hardcoded fallback.
  final prefs = await AppPreferences.instance();
  runApp(
    ProviderScope(
      child: NtiPosApp(brand: prefs.brand, themeMode: prefs.themeMode),
    ),
  );
}

/// Root widget. Wires router, theme and localization together.
class NtiPosApp extends ConsumerWidget {
  const NtiPosApp({super.key, required this.brand, required this.themeMode});

  /// Brand and theme mode read from preferences before `runApp`, used only to
  /// theme the bootstrap frames. Once [settingsProvider] resolves, its own
  /// values take over and stay reactive.
  final BrandPreset brand;
  final ThemeMode themeMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final settings = ref.watch(settingsProvider);

    return settings.when(
      loading: () => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(brand),
        darkTheme: AppTheme.dark(brand),
        themeMode: themeMode,
        home: const _BootstrapScaffold(),
      ),
      error: (e, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(brand),
        darkTheme: AppTheme.dark(brand),
        themeMode: themeMode,
        home: _BootstrapScaffold(error: '$e'),
      ),
      data: (data) => MaterialApp.router(
        debugShowCheckedModeBanner: false,
        title: 'JustClick POS',
        routerConfig: router,
        theme: data.lightTheme,
        darkTheme: data.darkTheme,
        themeMode: data.themeMode,
        locale: data.locale,
        supportedLocales: kSupportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        localeResolutionCallback: (deviceLocale, supported) {
          if (deviceLocale == null) return kDefaultLocale;
          for (final l in supported) {
            if (l.languageCode == deviceLocale.languageCode) return l;
          }
          return kDefaultLocale;
        },
        builder: (context, child) {
          final scale = MediaQuery.textScalerOf(
            context,
          ).scale(1.0).clamp(0.85, 1.15);
          return MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child ?? const SizedBox.shrink(),
          );
        },
      ),
    );
  }
}

class _BootstrapScaffold extends StatelessWidget {
  const _BootstrapScaffold({this.error});
  final String? error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.primary,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandMark.plated(size: 88),
            const SizedBox(height: 16),
            Text(
              'JustClick POS',
              style: TextStyle(
                color: scheme.onPrimary,
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 24),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onPrimary),
                ),
              )
            else
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.onPrimary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
