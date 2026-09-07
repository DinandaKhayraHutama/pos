import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_dimensions.dart';

/// Builds light & dark [ThemeData] from a [BrandPreset]'s hand-tuned
/// [BrandColors] tokens.
///
/// This is the only place [ThemeData] is constructed. UI code never hardcodes
/// colors — everything resolves via [Theme.of], [Theme.of(context).colorScheme],
/// or `context.design` / `context.semantic` (which both return the active
/// [BrandColors]).
class AppTheme {
  AppTheme._();

  static ThemeData light(BrandPreset brand) => _build(brand.light, Brightness.light);
  static ThemeData dark(BrandPreset brand) => _build(brand.dark, Brightness.dark);

  static ThemeData _build(BrandColors bc, Brightness brightness) {
    final isLight = brightness == Brightness.light;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: bc.primary,
      onPrimary: bc.onPrimary,
      primaryContainer: bc.primaryContainer,
      onPrimaryContainer: bc.onPrimaryContainer,
      secondary: bc.secondary,
      onSecondary: bc.onSecondary,
      secondaryContainer: bc.tertiaryContainer,
      onSecondaryContainer: bc.onTertiaryContainer,
      tertiary: bc.tertiary,
      onTertiary: bc.onTertiary,
      tertiaryContainer: bc.tertiaryContainer,
      onTertiaryContainer: bc.onTertiaryContainer,
      error: bc.error,
      onError: Colors.white,
      errorContainer: bc.errorContainer,
      onErrorContainer: Colors.white,
      surface: bc.surfaceBase,
      onSurface: bc.textHigh,
      onSurfaceVariant: bc.textMedium,
      surfaceContainerLowest:
          isLight ? Colors.white : const Color(0xFF070809),
      surfaceContainerLow: bc.surfaceRaised,
      surfaceContainer: bc.surfaceOverlay,
      surfaceContainerHigh:
          isLight ? const Color(0xFFF0F1F5) : const Color(0xFF22252D),
      surfaceContainerHighest:
          isLight ? const Color(0xFFE9EBF0) : const Color(0xFF2A2D36),
      outline: bc.textMedium,
      outlineVariant: bc.textLow,
      inverseSurface: bc.textHigh,
      onInverseSurface: bc.surfaceBase,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // Transparent: a later task paints AppBackground as the substrate. For
      // now every screen sets its own Scaffold background via colorScheme, so
      // the screens still paint.
      scaffoldBackgroundColor: Colors.transparent,
      brightness: brightness,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      // No global pageTransitionsTheme. The iOS-style slide is applied
      // PER-ROUTE in app_router.dart via CustomTransitionPage on pushed routes
      // (`/orders/:id`, `/products`). Tab switches inside the ShellRoute use
      // NoTransitionPage (also set explicitly in app_router.dart) — leaving
      // them on the default MaterialPage inherits the platform
      // pageTransitionsTheme (zoom/fade on Android) and makes tab switches
      // visibly animate, which clashes with the bottom-nav mental model.
      splashFactory: InkSparkle.splashFactory,
      extensions: [bc],
      // Bundled Plus Jakarta Sans is the global face. Every widget that does
      // not pick its own fontFamily inherits this; _textTheme also sets it
      // explicitly so the TextTheme entries (which otherwise inherit from
      // Typography.material2021 with no family) resolve correctly.
      fontFamily: 'PlusJakartaSans',
      typography: Typography.material2021(),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: AppDimensions.radiusLg),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.6),
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: _inputDecoration(scheme),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: AppDimensions.radiusMd),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(borderRadius: AppDimensions.radiusMd),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: AppDimensions.radiusMd),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: AppDimensions.radiusMd),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimensions.radius32),
        ),
        side: BorderSide.none,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: scheme.surface,
        modalElevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppDimensions.radius28),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: AppDimensions.radiusLg),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.onSurface,
        contentTextStyle: TextStyle(color: scheme.surface),
        shape: RoundedRectangleBorder(borderRadius: AppDimensions.radiusMd),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.outlineVariant,
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: 0.12),
        trackHeight: 4,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        circularTrackColor: scheme.outlineVariant.withValues(alpha: 0.4),
        linearTrackColor: scheme.outlineVariant.withValues(alpha: 0.4),
      ),
      textTheme: _textTheme(scheme),
    );
  }

  static InputDecorationTheme _inputDecoration(ColorScheme scheme) {
    return InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppDimensions.space16,
        vertical: AppDimensions.space14,
      ),
      border: OutlineInputBorder(
        borderRadius: AppDimensions.radiusMd,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppDimensions.radiusMd,
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppDimensions.radiusMd,
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: AppDimensions.radiusMd,
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: AppDimensions.radiusMd,
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
    );
  }

  static TextTheme _textTheme(ColorScheme scheme) {
    final base = Typography.material2021().black;
    const family = 'PlusJakartaSans';
    const tabular = <FontFeature>[FontFeature.tabularFigures()];

    TextStyle style(
      TextStyle? s, {
      double? letterSpacing,
      List<FontFeature>? fontFeatures,
      FontWeight? fontWeight,
   }) {
      final src = s ?? const TextStyle();
      return src.copyWith(
        fontFamily: family,
        color: scheme.onSurface,
        letterSpacing: letterSpacing,
        fontFeatures: fontFeatures,
        fontWeight: fontWeight,
      );
    }

    // Display/headline/titleLarge get tight tracking for that premium
    // display-type feel; body/label/titleMedium carry tabular figures so
    // prices, quantities and receipt columns don't jitter as digits change.
    return TextTheme(
      displayLarge: style(base.displayLarge, letterSpacing: -0.5),
      displayMedium: style(base.displayMedium, letterSpacing: -0.5),
      displaySmall: style(base.displaySmall, letterSpacing: -0.5),
      headlineLarge: style(base.headlineLarge, letterSpacing: -0.3),
      headlineMedium: style(base.headlineMedium, letterSpacing: -0.3),
      headlineSmall: style(base.headlineSmall, letterSpacing: -0.3),
      titleLarge: style(base.titleLarge, letterSpacing: -0.2),
      titleMedium: style(base.titleMedium, fontFeatures: tabular),
      titleSmall: style(base.titleSmall, fontFeatures: tabular),
      bodyLarge: style(
        base.bodyLarge,
        fontFeatures: tabular,
        fontWeight: FontWeight.w500,
      ),
      bodyMedium: style(
        base.bodyMedium,
        fontFeatures: tabular,
        fontWeight: FontWeight.w500,
      ),
      bodySmall: style(base.bodySmall, fontFeatures: tabular),
      labelLarge: style(base.labelLarge, fontFeatures: tabular),
      labelMedium: style(base.labelMedium, fontFeatures: tabular),
      labelSmall: style(base.labelSmall, fontFeatures: tabular),
    );
  }
}

/// Read the active [BrandColors] design tokens from the theme.
extension DesignContext on BuildContext {
  /// Design tokens for the current theme (superset of [semantic]).
  BrandColors get design => Theme.of(this).extension<BrandColors>()!;

  /// Backward-compat alias for legacy call sites that read semantic colors.
  /// [BrandColors] is a superset (it has the semantic fields), so this returns
  /// the same instance as [design]. Prefer [design] in new code.
  BrandColors get semantic => design;
}
