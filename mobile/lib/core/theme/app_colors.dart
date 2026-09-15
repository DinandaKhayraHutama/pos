import 'package:flutter/material.dart';

import 'brand_colors.dart';

export 'brand_colors.dart' show BrandColors, BrandAccent, BlobSpec;

/// Selectable brand identity.
///
/// Each preset carries a stable [id] (persisted in preferences), a [name] for
/// the Settings swatch list, a representative [swatch] color used only for the
/// swatch chip, and the [accent] payload that drives the hand-tuned
/// [BrandColors] returned by [light] / [dark].
///
/// Adding a brand is one entry in [presets]: add the [BrandAccent] and the
/// Settings swatch list renders it automatically.
class BrandPreset {
  const BrandPreset({
    required this.id,
    required this.name,
    required this.swatch,
    required this.accent,
  });

  /// Stable id persisted in preferences.
  final String id;

  /// Human-readable label (localized at the UI layer).
  final String name;

  /// Representative color used to paint the Settings swatch chip. NOT the seed
  /// of a `ColorScheme.fromSeed` derivation anymore — the real palette comes
  /// from [accent] via [BrandColors.fromAccent]. Kept as a field so the swatch
  /// UI keeps working without touching screen files.
  final Color swatch;

  /// Hand-tuned accent payload merged onto the shared neutral base.
  final BrandAccent accent;

  /// Tokens for the light theme. Re-derived on every access; cheap because it
  /// only runs when a theme is built (app start, brand change, rebuild).
  BrandColors get light => BrandColors.fromAccent(accent, Brightness.light);

  /// Tokens for the dark theme.
  BrandColors get dark => BrandColors.fromAccent(accent, Brightness.dark);

  /// Built-in selectable brand presets. Add/remove freely here.
  static const List<BrandPreset> presets = [
    // First in the list, and therefore the default: `byId` falls back to
    // `presets.first`, and `AppPreferences.brand` names this id. NTI's own
    // deep blue — a till is a tool someone stares at for eight hours, and a
    // saturated warm accent that reads as energetic in a screenshot reads as
    // shouting by the afternoon.
    BrandPreset(
      id: 'nti',
      name: 'NTI Blue',
      swatch: Color(0xFF1E40AF),
      accent: BrandAccent(
        primary: Color(0xFF1E40AF),
        onPrimary: Colors.white,
        secondary: Color(0xFF0369A1),
        // Dark mode needs a lighter blue or the brand disappears: #1E40AF on
        // the dark surface base is about 1.8:1, which is a button nobody can
        // find. #60A5FA reads at roughly 6.7:1 and still says "this is the
        // blue brand"; the fill is then light, so its foreground goes dark.
        primaryDark: Color(0xFF60A5FA),
        onPrimaryDark: Color(0xFF0B1220),
        secondaryDark: Color(0xFF38BDF8),
        gradient: [Color(0xFFF1F5FB), Color(0xFFDCE6F7)],
        blobs: [Color(0xFF1E40AF), Color(0xFF0369A1)],
        success: Color(0xFF15803D),
        warning: Color(0xFFB45309),
        // Kept clearly distinct from the primary. With a blue brand, an error
        // in the usual red-orange is the only thing on screen that is not
        // blue, which is exactly the prominence an error should have.
        error: Color(0xFFDC2626),
        info: Color(0xFF0284C7),
      ),
    ),
    BrandPreset(
      id: 'flame',
      name: 'Flame',
      swatch: Color(0xFFE85D04),
      accent: BrandAccent(
        primary: Color(0xFFE85D04),
        onPrimary: Colors.white,
        secondary: Color(0xFFB91C1C),
        gradient: [Color(0xFFFFF4EC), Color(0xFFFDE3CE)],
        blobs: [Color(0xFFE85D04), Color(0xFFDC2626)],
        success: Color(0xFF16A34A),
        warning: Color(0xFFD97706),
        error: Color(0xFFDC2626),
        info: Color(0xFF0284C7),
      ),
    ),
    BrandPreset(
      id: 'crimson',
      name: 'Crimson',
      swatch: Color(0xFFE11D48),
      accent: BrandAccent(
        primary: Color(0xFFE11D48),
        onPrimary: Colors.white,
        secondary: Color(0xFFBE123C),
        gradient: [Color(0xFFFFF1F3), Color(0xFFFCE0E5)],
        blobs: [Color(0xFFE11D48), Color(0xFF831843)],
        success: Color(0xFF16A34A),
        warning: Color(0xFFD97706),
        error: Color(0xFFBE123C),
        info: Color(0xFF0284C7),
      ),
    ),
    BrandPreset(
      id: 'royal',
      name: 'Royal',
      swatch: Color(0xFF7C3AED),
      accent: BrandAccent(
        primary: Color(0xFF7C3AED),
        onPrimary: Colors.white,
        secondary: Color(0xFF4F46E5),
        gradient: [Color(0xFFF6F3FF), Color(0xFFE9DEFF)],
        blobs: [Color(0xFF7C3AED), Color(0xFF4F46E5)],
        success: Color(0xFF16A34A),
        warning: Color(0xFFD97706),
        error: Color(0xFFDC2626),
        info: Color(0xFF2563EB),
      ),
    ),
    BrandPreset(
      id: 'ocean',
      name: 'Ocean',
      swatch: Color(0xFF0EA5E9),
      accent: BrandAccent(
        primary: Color(0xFF0EA5E9),
        onPrimary: Colors.white,
        secondary: Color(0xFF06B6D4),
        gradient: [Color(0xFFF0F9FF), Color(0xFFDBEAFE)],
        blobs: [Color(0xFF0EA5E9), Color(0xFF06B6D4)],
        success: Color(0xFF16A34A),
        warning: Color(0xFFD97706),
        error: Color(0xFFDC2626),
        info: Color(0xFF0284C7),
      ),
    ),
    BrandPreset(
      id: 'forest',
      name: 'Forest',
      swatch: Color(0xFF16A34A),
      accent: BrandAccent(
        primary: Color(0xFF16A34A),
        onPrimary: Colors.white,
        secondary: Color(0xFF0D9488),
        gradient: [Color(0xFFF0FDF4), Color(0xFFDCFCE7)],
        blobs: [Color(0xFF16A34A), Color(0xFF0D9488)],
        success: Color(0xFF16A34A),
        warning: Color(0xFFD97706),
        error: Color(0xFFDC2626),
        info: Color(0xFF0284C7),
      ),
    ),
    BrandPreset(
      id: 'amber',
      name: 'Amber',
      swatch: Color(0xFFF59E0B),
      accent: BrandAccent(
        primary: Color(0xFFF59E0B),
        onPrimary: Color(0xFF3A2A00),
        secondary: Color(0xFFEA580C),
        gradient: [Color(0xFFFFFBEB), Color(0xFFFEE9C8)],
        blobs: [Color(0xFFF59E0B), Color(0xFFEA580C)],
        success: Color(0xFF16A34A),
        warning: Color(0xFFD97706),
        error: Color(0xFFDC2626),
        info: Color(0xFF0284C7),
      ),
    ),
  ];

  /// First preset with matching id, or the first preset as a fallback.
  static BrandPreset byId(String id) {
    return presets.firstWhere((p) => p.id == id, orElse: () => presets.first);
  }
}

/// Light/dark color manipulation helpers.
class ColorUtils {
  ColorUtils._();

  /// Lighten [color] by [amount] (0.0 - 1.0). 0 = no change, 1 = white.
  static Color lighten(Color color, [double amount = 0.1]) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness + amount).clamp(0.0, 1.0))
        .toColor();
  }

  /// Darken [color] by [amount] (0.0 - 1.0). 0 = no change, 1 = black.
  static Color darken(Color color, [double amount = 0.1]) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness - amount).clamp(0.0, 1.0))
        .toColor();
  }

  /// Overlay a translucent color on top of a background (used for shadows/tints).
  static Color withAlpha(Color color, double alpha) {
    return color.withValues(alpha: alpha.clamp(0.0, 1.0));
  }
}

/// Per-category accent colors used for product tiles, chips and avatars.
/// Returns a stable pair (foreground, soft background) based on category id.
class CategoryColor {
  const CategoryColor._();

  static const _palette = <String, (Color, Color)>{
    'cat_food': (Color(0xFFEF4444), Color(0xFFFEE2E2)),
    'cat_drinks': (Color(0xFF3B82F6), Color(0xFFDBEAFE)),
    'cat_snacks': (Color(0xFFF59E0B), Color(0xFFFEF3C7)),
    'cat_dessert': (Color(0xFFEC4899), Color(0xFFFCE7F3)),
    'cat_coffee': (Color(0xFF92400E), Color(0xFFFED7AA)),
  };

  static const _fallbackPalette = <(Color, Color)>[
    (Color(0xFF8B5CF6), Color(0xFFEDE9FE)),
    (Color(0xFF10B981), Color(0xFFD1FAE5)),
    (Color(0xFF06B6D4), Color(0xFFCFFAFE)),
    (Color(0xFFF97316), Color(0xFFFFEDD5)),
    (Color(0xFF84CC16), Color(0xFFECFCCB)),
  ];

  /// Returns (fg, softBg) for a given key (usually category id).
  static (Color, Color) of(String? key) {
    if (key != null && _palette.containsKey(key)) return _palette[key]!;
    final code = key?.hashCode ?? 0;
    return _fallbackPalette[code.abs() % _fallbackPalette.length];
  }
}
