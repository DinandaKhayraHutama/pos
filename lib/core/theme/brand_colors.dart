import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Position and radius of a single ambient brand-color blob on the substrate
/// that [AppBackground] (added in a later task) will paint behind the glass
/// surfaces. [radiusFraction] is a factor of the screen's largest dimension.
class BlobSpec {
  const BlobSpec(this.color, this.alignment, this.radiusFraction);

  final Color color;
  final Alignment alignment;
  final double radiusFraction;
}

/// Small per-brand accent payload that [BrandColors.fromAccent] merges onto a
/// shared neutral base. Only the colors that actually vary per brand live here;
/// everything else (surfaces, text tiers, glass, semantic containers) derives
/// deterministically in the factory.
@immutable
class BrandAccent {
  const BrandAccent({
    required this.primary,
    required this.onPrimary,
    required this.secondary,
    required this.gradient,
    required this.blobs,
    required this.success,
    required this.warning,
    required this.error,
    required this.info,
    this.primaryDark,
    this.onPrimaryDark,
    this.secondaryDark,
  });

  final Color primary;
  final Color onPrimary;
  final Color secondary;

  /// Dark-mode overrides for the accent trio. Null means "the light value
  /// works in the dark too", which is true of every bright accent here.
  ///
  /// A DARK brand accent is the case that needs these. NTI's #1E40AF against
  /// the dark surface base is about 1.8:1 — a button nobody can find. There is
  /// no honest automatic fix either: lightening far enough to be legible
  /// changes the hue people recognise as the brand, so the lighter tone is
  /// chosen by hand, per brand, exactly like the light one.
  final Color? primaryDark;
  final Color? onPrimaryDark;
  final Color? secondaryDark;

  /// The accent trio resolved for [brightness].
  Color primaryFor(Brightness b) =>
      b == Brightness.dark ? (primaryDark ?? primary) : primary;

  Color onPrimaryFor(Brightness b) =>
      b == Brightness.dark ? (onPrimaryDark ?? onPrimary) : onPrimary;

  Color secondaryFor(Brightness b) =>
      b == Brightness.dark ? (secondaryDark ?? secondary) : secondary;

  final List<Color> gradient;
  final List<Color> blobs;
  final Color success;
  final Color warning;
  final Color error;
  final Color info;
}

/// Hand-tuned design-token palette for a single brand in a single brightness.
///
/// This is the superset of everything the UI reads through `context.design`
/// (and the legacy `context.semantic` alias): substrate gradients and blobs for
/// the eventual [AppBackground], glass presets, three surface tiers, the accent
/// palette Material's [ColorScheme] needs, three text tiers, and the semantic
/// colors (success / warning / info / error) with their soft containers.
///
/// Build one via [BrandColors.fromAccent] — never by hand. The neutral bases
/// ([_neutralLight] / [_neutralDark]) and the per-brand [BrandAccent]s are the
/// only inputs; containers and dark semantic foregrounds derive from them so
/// the palette stays consistent without 8 hand-picked containers per brand.
class BrandColors extends ThemeExtension<BrandColors> {
  BrandColors._({
    required this.brightness,
    required this.gradient,
    required this.blobs,
    required this.glassTint,
    required this.glassBorder,
    required this.glassBlurSigma,
    required this.glassOpacity,
    required this.surfaceBase,
    required this.surfaceRaised,
    required this.surfaceOverlay,
    required this.primary,
    required this.onPrimary,
    required this.secondary,
    required this.onSecondary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.tertiary,
    required this.tertiaryContainer,
    required this.onTertiary,
    required this.onTertiaryContainer,
    required this.textHigh,
    required this.textMedium,
    required this.textLow,
    required this.success,
    required this.successContainer,
    required this.warning,
    required this.warningContainer,
    required this.info,
    required this.infoContainer,
    required this.error,
    required this.errorContainer,
  });

  /// Shared light neutral base. Brand accent overlays this in
  /// [fromAccent]; the values below are the parts of the palette that do
  /// NOT vary per brand.
  BrandColors._neutralLight()
    : brightness = Brightness.light,
      gradient = const [Color(0xFFFBFBFD), Color(0xFFF3F4F8)],
      blobs = const [],
      glassTint = Colors.white,
      // Neutral hairline, not white. Once the substrate went flat there was no
      // gradient left for a white edge to read against, so cards dissolved into
      // the page; a grey border is what separates them now.
      glassBorder = const Color(0xFFD9DDE4),
      // Blur off, tint opaque. At 0.92 opacity over a flat surface the blur was
      // paying for an effect nobody could see — and BackdropFilter is one of
      // the most expensive operations on Flutter web, which is the demo target.
      glassBlurSigma = 0,
      glassOpacity = 1.0,
      surfaceBase = const Color(0xFFF6F7F9),
      surfaceRaised = const Color(0xFFFFFFFF),
      surfaceOverlay = const Color(0xFFFFFFFF),
      primary = Colors.transparent,
      onPrimary = Colors.transparent,
      secondary = Colors.transparent,
      onSecondary = Colors.white,
      primaryContainer = Colors.transparent,
      onPrimaryContainer = Colors.transparent,
      tertiary = Colors.transparent,
      tertiaryContainer = Colors.transparent,
      onTertiary = Colors.white,
      onTertiaryContainer = Colors.transparent,
      textHigh = const Color(0xFF0B0C0F),
      textMedium = const Color(0xFF5A5E6A),
      textLow = const Color(0xFF9A9FAE),
      success = const Color(0xFF16A34A),
      successContainer = const Color(0xFFDCFCE7),
      warning = const Color(0xFFD97706),
      warningContainer = const Color(0xFFFEF3C7),
      info = const Color(0xFF0284C7),
      infoContainer = const Color(0xFFE0F2FE),
      error = const Color(0xFFDC2626),
      errorContainer = const Color(0xFFFEE2E2);

  /// Shared dark neutral base.
  BrandColors._neutralDark()
    : brightness = Brightness.dark,
      gradient = const [Color(0xFF0B0C10), Color(0xFF111319)],
      blobs = const [],
      glassTint = const Color(0xFF16181E),
      glassBorder = const Color(0xFF2E333D),
      glassBlurSigma = 0,
      glassOpacity = 1.0,
      surfaceBase = const Color(0xFF0B0C10),
      surfaceRaised = const Color(0xFF16181E),
      surfaceOverlay = const Color(0xFF1E2128),
      primary = Colors.transparent,
      onPrimary = Colors.transparent,
      secondary = Colors.transparent,
      onSecondary = Colors.white,
      primaryContainer = Colors.transparent,
      onPrimaryContainer = Colors.transparent,
      tertiary = Colors.transparent,
      tertiaryContainer = Colors.transparent,
      onTertiary = Colors.white,
      onTertiaryContainer = Colors.transparent,
      textHigh = const Color(0xFFF5F6FA),
      textMedium = const Color(0xFFB4B8C4),
      textLow = const Color(0xFF7A7F8E),
      success = const Color(0xFF4ADE80),
      successContainer = const Color(0xFF14532D),
      warning = const Color(0xFFFBBF24),
      warningContainer = const Color(0xFF451A03),
      info = const Color(0xFF38BDF8),
      infoContainer = const Color(0xFF0C4A6E),
      error = const Color(0xFFFCA5A5),
      errorContainer = const Color(0xFF451A1A);

  /// Build a [BrandColors] by overlaying [accent] on the shared neutral base
  /// for [brightness]. Containers derive from their foreground at a fixed
  /// alpha; dark semantic foregrounds lighten slightly so they read against
  /// dark surfaces.
  factory BrandColors.fromAccent(BrandAccent a, Brightness brightness) {
    final isLight = brightness == Brightness.light;
    final base = isLight ? BrandColors._neutralLight() : BrandColors._neutralDark();
    final containerAlpha = isLight ? 0.14 : 0.22;

    // Resolved once so every accent-derived token below agrees on the tone.
    final primaryTone = a.primaryFor(brightness);
    final secondaryTone = a.secondaryFor(brightness);

    // Accent-derived semantic foregrounds. In dark mode lighten so they pop
    // against dark surfaces; in light mode the brand accent is already saturated.
    Color fg(Color c) => isLight ? c : ColorUtils.lighten(c, 0.12);

    final success = fg(a.success);
    final warning = fg(a.warning);
    final info = fg(a.info);
    final error = fg(a.error);

    // Brand gradient and blobs: light uses the brand-tinted pastel stops, dark
    // uses a primary-derived near-black + the dark surface base.
    final List<Color> gradient =
        isLight
            ? a.gradient
            : [ColorUtils.darken(a.primary, 0.82), base.surfaceBase];

    // Stagger blob alignments across the list so multiple blobs don't stack.
    const alignments = <Alignment>[
      Alignment.topLeft,
      Alignment.bottomRight,
      Alignment.centerRight,
    ];
    final blobs = <BlobSpec>[];
    for (var i = 0; i < a.blobs.length; i++) {
      blobs.add(
        BlobSpec(a.blobs[i], alignments[i % alignments.length], 0.85),
      );
    }
    // Premium-glass cue: when a brand only declares two blobs, add a softer
    // third pass with the secondary accent at the next staggered alignment so
    // the stronger backdrop blur has richer color to pick up.
    if (a.blobs.length == 2) {
      blobs.add(BlobSpec(a.secondary, alignments[2], 0.75));
    }

    return BrandColors._(
      brightness: brightness,
      gradient: gradient,
      blobs: blobs,
      glassTint: base.glassTint,
      glassBorder: base.glassBorder,
      glassBlurSigma: base.glassBlurSigma,
      glassOpacity: base.glassOpacity,
      surfaceBase: base.surfaceBase,
      surfaceRaised: base.surfaceRaised,
      surfaceOverlay: base.surfaceOverlay,
      primary: primaryTone,
      onPrimary: a.onPrimaryFor(brightness),
      secondary: secondaryTone,
      onSecondary: Colors.white,
      // Containers and their foregrounds derive from the SAME resolved accent
      // as `primary`, not from the light one. Deriving from the light value in
      // dark mode would tint a soft container in one hue while the button next
      // to it used another.
      primaryContainer: primaryTone.withValues(alpha: containerAlpha),
      onPrimaryContainer:
          isLight
              ? ColorUtils.darken(primaryTone, 0.45)
              : ColorUtils.lighten(primaryTone, 0.3),
      tertiary: secondaryTone,
      tertiaryContainer: secondaryTone.withValues(alpha: containerAlpha),
      onTertiary: Colors.white,
      onTertiaryContainer:
          isLight
              ? ColorUtils.darken(secondaryTone, 0.45)
              : ColorUtils.lighten(secondaryTone, 0.3),
      textHigh: base.textHigh,
      textMedium: base.textMedium,
      textLow: base.textLow,
      success: success,
      successContainer: success.withValues(alpha: containerAlpha),
      warning: warning,
      warningContainer: warning.withValues(alpha: containerAlpha),
      info: info,
      infoContainer: info.withValues(alpha: containerAlpha),
      error: error,
      errorContainer: error.withValues(alpha: containerAlpha),
    );
  }

  final Brightness brightness;

  // Ambient substrate (painted by AppBackground in a later task).
  final List<Color> gradient;
  final List<BlobSpec> blobs;

  // Glass presets.
  final Color glassTint;
  final Color glassBorder;
  final double glassBlurSigma;
  final double glassOpacity;

  // Surface tiers.
  final Color surfaceBase;
  final Color surfaceRaised;
  final Color surfaceOverlay;

  // Accents that map onto ColorScheme roles.
  final Color primary;
  final Color onPrimary;
  final Color secondary;
  final Color onSecondary;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color tertiary;
  final Color tertiaryContainer;
  final Color onTertiary;
  final Color onTertiaryContainer;

  // Text tiers.
  final Color textHigh;
  final Color textMedium;
  final Color textLow;

  // Semantic colors. Read via `context.design` (or its `context.semantic`
  // alias); the field set mirrors what the old AppSemanticColors shim exposed.
  final Color success;
  final Color successContainer;
  final Color warning;
  final Color warningContainer;
  final Color info;
  final Color infoContainer;
  final Color error;
  final Color errorContainer;

  @override
  BrandColors copyWith({
    Brightness? brightness,
    List<Color>? gradient,
    List<BlobSpec>? blobs,
    Color? glassTint,
    Color? glassBorder,
    double? glassBlurSigma,
    double? glassOpacity,
    Color? surfaceBase,
    Color? surfaceRaised,
    Color? surfaceOverlay,
    Color? primary,
    Color? onPrimary,
    Color? secondary,
    Color? onSecondary,
    Color? primaryContainer,
    Color? onPrimaryContainer,
    Color? tertiary,
    Color? tertiaryContainer,
    Color? onTertiary,
    Color? onTertiaryContainer,
    Color? textHigh,
    Color? textMedium,
    Color? textLow,
    Color? success,
    Color? successContainer,
    Color? warning,
    Color? warningContainer,
    Color? info,
    Color? infoContainer,
    Color? error,
    Color? errorContainer,
  }) {
    return BrandColors._(
      brightness: brightness ?? this.brightness,
      gradient: gradient ?? this.gradient,
      blobs: blobs ?? this.blobs,
      glassTint: glassTint ?? this.glassTint,
      glassBorder: glassBorder ?? this.glassBorder,
      glassBlurSigma: glassBlurSigma ?? this.glassBlurSigma,
      glassOpacity: glassOpacity ?? this.glassOpacity,
      surfaceBase: surfaceBase ?? this.surfaceBase,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      surfaceOverlay: surfaceOverlay ?? this.surfaceOverlay,
      primary: primary ?? this.primary,
      onPrimary: onPrimary ?? this.onPrimary,
      secondary: secondary ?? this.secondary,
      onSecondary: onSecondary ?? this.onSecondary,
      primaryContainer: primaryContainer ?? this.primaryContainer,
      onPrimaryContainer: onPrimaryContainer ?? this.onPrimaryContainer,
      tertiary: tertiary ?? this.tertiary,
      tertiaryContainer: tertiaryContainer ?? this.tertiaryContainer,
      onTertiary: onTertiary ?? this.onTertiary,
      onTertiaryContainer: onTertiaryContainer ?? this.onTertiaryContainer,
      textHigh: textHigh ?? this.textHigh,
      textMedium: textMedium ?? this.textMedium,
      textLow: textLow ?? this.textLow,
      success: success ?? this.success,
      successContainer: successContainer ?? this.successContainer,
      warning: warning ?? this.warning,
      warningContainer: warningContainer ?? this.warningContainer,
      info: info ?? this.info,
      infoContainer: infoContainer ?? this.infoContainer,
      error: error ?? this.error,
      errorContainer: errorContainer ?? this.errorContainer,
    );
  }

  @override
  BrandColors lerp(ThemeExtension<BrandColors>? other, double t) {
    if (other is! BrandColors) return this;
    if (t == 0) return this;
    if (t == 1) return other;
    Color? lerpC(Color? a, Color? b) => Color.lerp(a, b, t);
    List<Color> lerpList(List<Color> a, List<Color> b) {
      if (a.length == b.length) {
        return List.generate(a.length, (i) => Color.lerp(a[i], b[i], t)!);
      }
      return t < 0.5 ? a : b;
    }

    List<BlobSpec> lerpBlobs(List<BlobSpec> a, List<BlobSpec> b) {
      double lerpNum(double x, double y) => x + (y - x) * t;
      if (a.length == b.length) {
        return List.generate(a.length, (i) {
          final x = a[i];
          final y = b[i];
          final align = Alignment.lerp(x.alignment, y.alignment, t)!;
          return BlobSpec(
            Color.lerp(x.color, y.color, t)!,
            align,
            lerpNum(x.radiusFraction, y.radiusFraction),
          );
        });
      }
      return t < 0.5 ? a : b;
    }

    return BrandColors._(
      brightness: t < 0.5 ? brightness : other.brightness,
      gradient: lerpList(gradient, other.gradient),
      blobs: lerpBlobs(blobs, other.blobs),
      glassTint: lerpC(glassTint, other.glassTint)!,
      glassBorder: lerpC(glassBorder, other.glassBorder)!,
      glassBlurSigma:
          glassBlurSigma + (other.glassBlurSigma - glassBlurSigma) * t,
      glassOpacity: glassOpacity + (other.glassOpacity - glassOpacity) * t,
      surfaceBase: lerpC(surfaceBase, other.surfaceBase)!,
      surfaceRaised: lerpC(surfaceRaised, other.surfaceRaised)!,
      surfaceOverlay: lerpC(surfaceOverlay, other.surfaceOverlay)!,
      primary: lerpC(primary, other.primary)!,
      onPrimary: lerpC(onPrimary, other.onPrimary)!,
      secondary: lerpC(secondary, other.secondary)!,
      onSecondary: lerpC(onSecondary, other.onSecondary)!,
      primaryContainer: lerpC(primaryContainer, other.primaryContainer)!,
      onPrimaryContainer: lerpC(onPrimaryContainer, other.onPrimaryContainer)!,
      tertiary: lerpC(tertiary, other.tertiary)!,
      tertiaryContainer: lerpC(tertiaryContainer, other.tertiaryContainer)!,
      onTertiary: lerpC(onTertiary, other.onTertiary)!,
      onTertiaryContainer: lerpC(onTertiaryContainer, other.onTertiaryContainer)!,
      textHigh: lerpC(textHigh, other.textHigh)!,
      textMedium: lerpC(textMedium, other.textMedium)!,
      textLow: lerpC(textLow, other.textLow)!,
      success: lerpC(success, other.success)!,
      successContainer: lerpC(successContainer, other.successContainer)!,
      warning: lerpC(warning, other.warning)!,
      warningContainer: lerpC(warningContainer, other.warningContainer)!,
      info: lerpC(info, other.info)!,
      infoContainer: lerpC(infoContainer, other.infoContainer)!,
      error: lerpC(error, other.error)!,
      errorContainer: lerpC(errorContainer, other.errorContainer)!,
    );
  }
}
