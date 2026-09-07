# Premium Glassmorphism Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the seed-derived Material palette with a hand-tuned, multi-brand premium token system and a custom glassmorphism component library, then restyle every existing screen onto it — same features, new look — verified by emulator screenshots.

**Architecture:** A `BrandColors` `ThemeExtension` carries the hand-tuned palette per brand (light + dark). `AppTheme` builds `ColorScheme` *manually from tokens* (no `ColorScheme.fromSeed`) so every existing `colorScheme.*` call site automatically resolves to the new premium palette without per-file edits. `AppBackground` paints an ambient gradient + color blobs as the substrate that makes `BackdropFilter` glass surfaces read as alive. A `lib/core/widgets/glass/` library of reusable primitives (cards, nav, buttons, sheets, inputs, chips, steppers, skeletons) becomes the vocabulary every screen composes.

**Tech Stack:** Flutter 3.10+ / Dart · Riverpod · go_router · `BackdropFilter` + `ImageFilter.blur` · bundled Plus Jakarta Sans font · sqflite (unchanged) · existing `flutter_test` + `integration_test`.

---

## Global Constraints

Copied verbatim from the spec + repo rules. Every task's requirements implicitly include these.

- **No `ColorScheme.fromSeed` anywhere in app code after Task 1.** Palettes are hand-tuned literals.
- **No hardcoded user-facing strings.** Every label/snackbar/dialog/empty state goes through `context.l10n.*`. New keys added to **both** `lib/l10n/app_en.arb` and `lib/l10n/app_id.arb`, then `flutter gen-l10n`. Brand name and DB-derived data are the only literal strings.
- **No literal colors in widgets.** Resolve via `Theme.of(context).colorScheme.*` (now token-backed) or `context.design.*` / `context.semantic.*`.
- **Spacing from `AppDimensions`.** No magic padding/radius.
- **Grid tiles sized by content, never `childAspectRatio` when tile contains text.** Keep using `productCardExtent` / `mainAxisExtent`.
- **Responsiveness:** phone < 900dp < tablet, via `AppDimensions.tabletWidth`. Verify every restyled screen at phone and ≥900dp.
- **iOS build mandate:** `flutter build ios --debug --simulator --no-codesign --no-tree-shake-icons` (never tree-shake icons; variants render as tofu otherwise).
- **Never render emoji in the UI.** Material icons via `iconFromKey` only.
- **After every write that changes data, invalidate affected providers** (existing convention).
- **`routerProvider` must never `ref.watch` another provider** (existing guard; `test/router_stability_test.dart` enforces).
- **Commits:** Conventional Commits, `<type>(<scope>): <subject>`. **No Claude co-author trailer** (user preference).
- **Keep `flutter analyze` clean and `flutter test` green at every commit.**

---

## File Structure

New / changed files. Decomposition is locked here.

**Token core (Task 1)**
- Modify `lib/core/theme/app_colors.dart` — replace `BrandPreset.seed` model with hand-tuned `BrandColors` + palettes; keep `AppSemanticColors`/`CategoryColor`/`ColorUtils` names where call sites use them.
- Create `lib/core/theme/brand_colors.dart` — `BrandColors extends ThemeExtension<BrandColors>` (the token object) + `BrandColors.fromAccent(...)` factory + shared neutral bases + the 6 brand accent sets.
- Modify `lib/core/theme/app_theme.dart` — build `ColorScheme` manually from `BrandColors`; plug `BrandColors` into `extensions`; Plus Jakarta Sans `TextTheme` (Task 2).
- Modify `lib/core/theme/app_theme.dart` extension — `context.design` returns `BrandColors`; `context.semantic` aliased to `BrandColors` (superset, backward-compatible).

**Background (Task 3)**
- Create `lib/core/widgets/app_background.dart` — ambient gradient + blobs.

**Glass primitives (Tasks 4–13) — `lib/core/widgets/glass/`**
- `glass_card.dart`, `glass_buttons.dart`, `glass_sheet.dart`, `glass_app_bar.dart`, `glass_text_field.dart`, `glass_segmented.dart`, `glass_chip.dart`, `glass_stepper.dart`, `skeleton.dart`. Plus restyle `lib/core/widgets/empty_state.dart`, `lib/core/widgets/status_badge.dart`, `lib/core/widgets/loading_indicator.dart`.

**Navigation (Task 14)**
- Create `lib/core/widgets/glass/glass_nav.dart` — `GlassNav` (bottom) + `GlassNavRail` (side). Modify `lib/features/shared/main_shell.dart` to use it.

**Screen restyles (Tasks 15–23)** — modify each existing `lib/features/**/*_page.dart` / sheet. No new screens.

**Motion (Task 24)** — modify `lib/core/router/app_router.dart` (iOS page transitions).

**Docs (Task 25)** — modify `CLAUDE.md`, `AGENTS.md` theming section.

**Verification (Task 26)** — manual screenshot pass; create `docs/superpowers/screenshots/` for evidence.

---

## Conventions used in every task

- **Run tests:** `flutter test` (all) or the specific file `flutter test test/<file> -n "<name>"`.
- **Analyze:** `flutter analyze` must report no new issues.
- **iOS visual verify (when a task says "screenshot"):**
  ```bash
  flutter build ios --debug --simulator --no-codesign --no-tree-shake-icons
  xcrun simctl install 810AB071-8AFC-41C5-B526-02246E314C4B build/ios/iphonesimulator/Runner.app
  xcrun simctl launch 810AB071-8AFC-41C5-B526-02246E314C4B com.example.ntiPos
  # navigate to the screen, then:
  xcrun simctl io 810AB071-8AFC-41C5-B526-02246E314C4B screenshot /tmp/<name>.png
  ```
  Tablet layout: `flutter run -d macos` and resize the window past 900dp width.
- **Commit per task** unless the task says otherwise. No co-author trailer.

---

## Task 1: Brand token core — `BrandColors` + hand-tuned palettes, `AppTheme` off the seed

**Files:**
- Create: `lib/core/theme/brand_colors.dart`
- Modify: `lib/core/theme/app_colors.dart` (redefine `BrandPreset`)
- Modify: `lib/core/theme/app_theme.dart` (manual `ColorScheme`, plug extension)
- Test: `test/brand_tokens_test.dart`

**Interfaces:**
- Produces: `BrandColors` (ThemeExtension) with fields listed below; `BrandPreset(id, name, swatch, light, dark)` with `presets` (6) and `byId(id)`; `AppTheme.light(BrandPreset)` / `.dark(BrandPreset)` returning `ThemeData` whose `colorScheme` is built from tokens and whose extensions include the `BrandColors`; `context.design` and `context.semantic` both return the active `BrandColors`.
- Preserves: `BrandPreset.presets`, `BrandPreset.byId`, `AppTheme.light/dark(brand)` signatures, `AppSemanticColors.of(brightness)` (kept as a thin compatibility shim delegating to a neutral-brand `BrandColors` — only used by `checkout_sheet.dart` receipt which passes `Brightness.light`; will migrate in Task 18), `CategoryColor`, `ColorUtils`. This keeps `test/bootstrap_theme_test.dart` green (it asserts `scaffold.backgroundColor == AppTheme.light(brand).colorScheme.primary` and that presets differ).

### `BrandColors` fields (exact)

```dart
class BrandColors extends ThemeExtension<BrandColors> {
  final Brightness brightness;
  // ambient background
  final List<Color> gradient;
  final List<BlobSpec> blobs;
  // glass
  final Color glassTint;
  final Color glassBorder;
  final double glassBlurSigma;
  final double glassOpacity;
  // surfaces
  final Color surfaceBase;
  final Color surfaceRaised;
  final Color surfaceOverlay;
  // accents
  final Color primary;
  final Color onPrimary;
  final Color secondary;
  final Color onSecondary;
  final Color primaryContainer;   // icon-chip soft bg
  final Color onPrimaryContainer;
  final Color tertiary;
  final Color tertiaryContainer;
  final Color onTertiary;
  final Color onTertiaryContainer;
  // text
  final Color textHigh;
  final Color textMedium;
  final Color textLow;
  // semantic (kept names so context.semantic.* call sites still compile)
  final Color success;
  final Color successContainer;
  final Color warning;
  final Color warningContainer;
  final Color info;
  final Color infoContainer;
  final Color error;
  final Color errorContainer;
}
```

`BlobSpec` = `(Color color, Alignment alignment, double radiusFraction)`.

### Factory + neutral base + 6 accent sets (exact values)

`BrandColors.fromAccent` merges a small per-brand accent onto a shared neutral base chosen by brightness. Semantic **containers** are derived from their foreground at fixed alpha (DRY — no 8 hand-picked containers per brand).

```dart
class BrandAccent {
  final Color primary;
  final Color onPrimary;
  final Color secondary;
  final List<Color> gradient;   // 2 stops
  final List<Color> blobs;      // 1–3 saturated brand colors
  final Color success;
  final Color warning;
  final Color error;
  final Color info;
  const BrandAccent({
    required this.primary, required this.onPrimary, required this.secondary,
    required this.gradient, required this.blobs,
    required this.success, required this.warning, required this.error, required this.info,
  });
}
```

Neutral bases:

```dart
BrandColors._neutralLight() // surfaceBase 0xFFFBFBFD, surfaceRaised 0xFFFFFFFF,
                            // surfaceOverlay 0xFFFFFFFF, textHigh 0xFF0B0C0F,
                            // textMedium 0xFF5A5E6A, textLow 0xFF9A9FAE,
                            // glassTint white, glassBorder white, sigma 18, opacity 0.55
BrandColors._neutralDark()  // surfaceBase 0xFF0B0C10, surfaceRaised 0xFF16181E,
                            // surfaceOverlay 0xFF1E2128, textHigh 0xFFF5F6FA,
                            // textMedium 0xFFB4B8C4, textLow 0xFF7A7F8E,
                            // glassTint white, glassBorder white, sigma 22, opacity 0.10
```

`BrandColors.fromAccent(BrandAccent a, Brightness b)`:
- start from neutral base by brightness
- `primary = a.primary`, `onPrimary = a.onPrimary`, `secondary = a.secondary`, `onSecondary = white`
- `gradient = a.gradient`, `blobs = a.blobs.map((c) => BlobSpec(c, <staggered alignment>, 0.6)).toList()`
- `primaryContainer = a.primary.withOpacity(b.light ? 0.14 : 0.22)`, `onPrimaryContainer = b.light ? darken(a.primary,0.45) : lighten(a.primary,0.3)`
- `tertiary = a.secondary`, containers derived similarly
- semantic: `success/warning/error/info = a.*` (dark: lighten 0.12); `*Container = fg.withOpacity(b.light ? 0.14 : 0.22)`
- `error/errorContainer` from `a.error`

The 6 brand presets (accent values, light). Dark variants reuse the same accents with the dark neutral base + dark gradient derived as `[darken(a.primary,0.82), surfaceBaseDark]` and dark blobs = `a.blobs`.

```dart
static const List<BrandPreset> presets = [
  BrandPreset(id: 'flame',   name: 'Flame',   swatch: Color(0xFFE85D04), /* accent below */),
  BrandPreset(id: 'crimson', name: 'Crimson', swatch: Color(0xFFE11D48)),
  BrandPreset(id: 'royal',   name: 'Royal',   swatch: Color(0xFF7C3AED)),
  BrandPreset(id: 'ocean',   name: 'Ocean',   swatch: Color(0xFF0EA5E9)),
  BrandPreset(id: 'forest',  name: 'Forest',  swatch: Color(0xFF16A34A)),
  BrandPreset(id: 'amber',   name: 'Amber',   swatch: Color(0xFFF59E0B)),
];
```

Accents (light gradient stops + blobs + semantic):
- **flame:** primary `0xFFE85D04`, onPrimary white, secondary `0xFFB91C1C`, gradient `[0xFFFFF4EC, 0xFFFDE3CE]`, blobs `[0xFFE85D04, 0xFFDC2626]`, success `0xFF16A34A`, warning `0xFFD97706`, error `0xFFDC2626`, info `0xFF0284C7`.
- **crimson:** primary `0xFFE11D48`, secondary `0xFFBE123C`, gradient `[0xFFFFF1F3, 0xFFFCE0E5]`, blobs `[0xFFE11D48, 0xFF831843]`, semantic success `0xFF16A34A`, warning `0xFFD97706`, error `0xFFBE123C`, info `0xFF0284C7`.
- **royal:** primary `0xFF7C3AED`, secondary `0xFF4F46E5`, gradient `[0xFFF6F3FF, 0xFFE9DEFF]`, blobs `[0xFF7C3AED, 0xFF4F46E5]`, info `0xFF2563EB`.
- **ocean:** primary `0xFF0EA5E9`, secondary `0xFF06B6D4`, gradient `[0xFFF0F9FF, 0xFFDBEAFE]`, blobs `[0xFF0EA5E9, 0xFF06B6D4]`, info `0xFF0284C7`.
- **forest:** primary `0xFF16A34A`, secondary `0xFF0D9488`, gradient `[0xFFF0FDF4, 0xFFDCFCE7]`, blobs `[0xFF16A34A, 0xFF0D9488]`, success `0xFF16A34A`, info `0xFF0284C7`.
- **amber:** primary `0xFFF59E0B`, onPrimary `0xFF3A2A00`, secondary `0xFFEA580C`, gradient `[0xFFFFFBEB, 0xFFFEE9C8]`, blobs `[0xFFF59E0B, 0xFFEA580C]`, warning `0xFFD97706`.

(For brands where a semantic isn't listed, reuse flame's defaults.)

### `AppTheme` manual `ColorScheme`

Replace `ColorScheme.fromSeed(...)` in `AppTheme.light/dark` with:

```dart
static ThemeData light(BrandPreset brand) => _build(brand.light, Brightness.light);
static ThemeData dark(BrandPreset brand)  => _build(brand.dark,  Brightness.dark);

static ThemeData _build(BrandColors bc, Brightness brightness) {
  final scheme = ColorScheme(
    brightness: brightness,
    primary: bc.primary, onPrimary: bc.onPrimary,
    primaryContainer: bc.primaryContainer, onPrimaryContainer: bc.onPrimaryContainer,
    secondary: bc.secondary, onSecondary: bc.onSecondary,
    tertiary: bc.tertiary, onTertiary: bc.onTertiary,
    tertiaryContainer: bc.tertiaryContainer, onTertiaryContainer: bc.onTertiaryContainer,
    error: bc.error, onError: Colors.white, errorContainer: bc.errorContainer, onErrorContainer: Colors.white,
    surface: bc.surfaceBase, onSurface: bc.textHigh,
    onSurfaceVariant: bc.textMedium,
    surfaceContainerLowest: brightness.light ? Colors.white : const Color(0xFF070809),
    surfaceContainerLow: bc.surfaceRaised,
    surfaceContainer: bc.surfaceOverlay,
    surfaceContainerHigh: brightness.light ? const Color(0xFFF0F1F5) : const Color(0xFF22252D),
    surfaceContainerHighest: brightness.light ? const Color(0xFFE9EBF0) : const Color(0xFF2A2D36),
    outline: bc.textMedium, outlineVariant: bc.textLow,
    inverseSurface: bc.textHigh, onInverseSurface: bc.surfaceBase,
  );
  // ...existing ThemeData(...) but:
  //   scaffoldBackgroundColor: Colors.transparent  (AppBackground paints the substrate)
  //   extensions: [bc, /* AppSemanticColors removed; bc is the superset */]
  //   keep component themes, but they now read from token-backed scheme
}
```

Extensions on `BuildContext` in `app_theme.dart`:

```dart
extension DesignContext on BuildContext {
  BrandColors get design => Theme.of(this).extension<BrandColors>()!;
  BrandColors get semantic => design; // backward-compat alias (BrandColors has the semantic fields)
}
```

Remove the old `AppSemanticColorsX` extension (replaced). Keep `AppSemanticColors` class as a deprecated shim ONLY if `checkout_sheet.dart`'s `AppSemanticColors.of(Brightness.light)` is not yet migrated — it is migrated in Task 18, so during Tasks 1–17 keep a minimal:
```dart
// Temporary shim until checkout receipt migrates to context.semantic (Task 18).
class AppSemanticColors {
  static BrandColors of(Brightness b) => BrandPreset.presets.first.light; // b ignored; receipt uses light tokens
}
```
Actually `checkout_sheet.dart` calls `AppSemanticColors.of(Brightness.light)` then `.success` / `.successContainer` — `BrandColors` has those, so this shim compiles. Task 18 replaces it with `context.semantic`.

- [ ] **Step 1: Write the failing test** `test/brand_tokens_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';

void main() {
  test('ColorScheme.primary equals the hand-tuned brand token, not a seed derivation', () {
    for (final b in BrandPreset.presets) {
      expect(AppTheme.light(b).colorScheme.primary, b.light.primary, reason: b.id);
      expect(AppTheme.dark(b).colorScheme.primary, b.dark.primary, reason: b.id);
    }
  });

  test('every preset paints a distinct bootstrap primary', () {
    final xs = BrandPreset.presets.map((b) => AppTheme.light(b).colorScheme.primary).toSet();
    expect(xs.length, BrandPreset.presets.length);
  });

  test('context.design and context.semantic resolve to BrandColors inside the theme', () {
    final b = BrandPreset.presets.first;
    final root = MaterialApp(
      theme: AppTheme.light(b),
      home: Builder(builder: (c) {
        expect(c.design, isA<BrandColors>());
        expect(c.semantic, same(c.design));
        expect(c.design.success, isNotNull);
        return const SizedBox.shrink();
      }),
    );
    pumpWidget(root); // in testWidgets wrapper — see note
  });
}
```
(The third case must be inside `testWidgets`; convert it to `testWidgets` and pump `root`. The first two are sync.)

- [ ] **Step 2: Run, verify failure** — `flutter test test/brand_tokens_test.dart` → FAIL (`BrandColors` / `brand.light` undefined).

- [ ] **Step 3: Implement** — create `brand_colors.dart` (class + factory + neutral bases + accent sets), rewrite `BrandPreset` in `app_colors.dart` (keep `id/name`, replace `seed` with `swatch`/`light`/`dark`; remove the old `seed` field — search-replace `brand.seed` usages: none in app code except the old `app_theme.dart` being rewritten; `CategoryColor`/`ColorUtils` untouched), rewrite `app_theme.dart` (`_build` manual scheme + `context.design`/`context.semantic` extensions). Add the `AppSemanticColors` shim.

- [ ] **Step 4: Run all tests** — `flutter test` → PASS (incl. `bootstrap_theme_test.dart`). `flutter analyze` clean.

- [ ] **Step 5: Screenshot** — rebuild iOS, launch. Bootstrap frame + login now use token colors. Capture `/tmp/01_tokens.png`.

- [ ] **Step 6: Commit**
  ```bash
  git add lib/core/theme/brand_colors.dart lib/core/theme/app_colors.dart lib/core/theme/app_theme.dart test/brand_tokens_test.dart
  git commit -m "feat(theme): replace seed palette with hand-tuned BrandColors tokens"
  ```

---

## Task 2: Bundle Plus Jakarta Sans + token `TextTheme`

**Files:**
- Create: `assets/fonts/plus_jakarta/` (4 `.ttf`: Regular 400, Medium 500, SemiBold 600, Bold 700)
- Modify: `pubspec.yaml` (`flutter.fonts:` block)
- Modify: `lib/core/theme/app_theme.dart` (`_build` sets `fontFamily: 'PlusJakartaSans'`, `_textTheme` adds tight heading `letterSpacing` + `tabularFigures` on number styles)
- Create: `lib/core/theme/app_text_styles.dart` — named styles: `priceStyle`, `headlineStyle`, etc., all with `fontFeatures: [FontFeature.tabularFigures()]` where numeric.
- Test: `test/typography_test.dart`

**Interfaces:** Produces global `fontFamily` so every `Text` inherits Plus Jakarta Sans; `context.money` style helper for tabular-figure money.

- [ ] **Step 1: Acquire font** — download Plus Jakarta Sans (SIL Open Font License) Static `.ttf`s into `assets/fonts/plus_jakarta/` named `PlusJakartaSans-Regular.ttf`, `-Medium.ttf`, `-SemiBold.ttf`, `-Bold.ttf`.

- [ ] **Step 2: Register** — add to `pubspec.yaml` under `flutter:`:
  ```yaml
  fonts:
    - family: PlusJakartaSans
      fonts:
        - asset: assets/fonts/plus_jakarta/PlusJakartaSans-Regular.ttf
        - asset: assets/fonts/plus_jakarta/PlusJakartaSans-Medium.ttf
          weight: 500
        - asset: assets/fonts/plus_jakarta/PlusJakartaSans-SemiBold.ttf
          weight: 600
        - asset: assets/fonts/plus_jakarta/PlusJakartaSans-Bold.ttf
          weight: 700
  ```

- [ ] **Step 3: Failing test** `test/typography_test.dart`:
  ```dart
  testWidgets('default font family is PlusJakartaSans', (t) async {
    await t.pumpWidget(MaterialApp(theme: AppTheme.light(BrandPreset.presets.first), home: const Text('x')));
    await t.pump();
    final txt = t.widget<Text>(find.byType(Text));
    expect(txt.style?.fontFamily ?? Theme.of(t.element(find.byType(Text))).textTheme.bodyMedium?.fontFamily, 'PlusJakartaSans');
  });
  ```
- [ ] **Step 4: Implement** — in `_build`: `fontFamily: 'PlusJakartaSans'`; rewrite `_textTheme` to set negative `letterSpacing` on display/headline/title and `fontFeatures: const [FontFeature.tabularFigures()]` on bodyMedium/labelLarge. Add `app_text_styles.dart`.
- [ ] **Step 5: Run tests + analyze** — `flutter test` green; `flutter pub get` ran implicitly by pubspec change.
- [ ] **Step 6: Commit** — `git add ... && git commit -m "feat(theme): bundle Plus Jakarta Sans + tabular-figure text styles"`

---

## Task 3: `AppBackground` — ambient gradient + blobs

**Files:**
- Create: `lib/core/widgets/app_background.dart`
- Test: `test/app_background_test.dart`

**Interfaces:** Produces `AppBackground({Widget child, bool scaffoldSafeArea = true})` that paints a `CustomPaint` (gradient + blobs) behind `child`, reading `context.design`.

- [ ] **Step 1: Failing test** — asserts `AppBackground` renders a `CustomPaint` and its child.
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement:**
  ```dart
  class AppBackground extends StatelessWidget {
    const AppBackground({super.key, required this.child});
    final Widget child;
    @override
    Widget build(BuildContext context) {
      return DecoratedBox(
        decoration: const BoxDecoration(color: Color(0x00000000)),
        child: Stack(children: [
          Positioned.fill(child: CustomPaint(painter: _AmbientPainter(context.design))),
          child,
        ]),
      );
    }
  }
  ```
  `_AmbientPainter` paints: `LinearGradient`(design.gradient, topLeft→bottomRight) then for each blob a `RadialGradient`(transparent→blob.withOpacity(0.5)) at its alignment/radius. Use `context.design.blobs`.
- [ ] **Step 4: Pass.** `flutter test`.
- [ ] **Step 5: Commit.**

---

## Task 4: `GlassCard`

**Files:** Create `lib/core/widgets/glass/glass_card.dart`. Test `test/glass_card_test.dart`.

**Interfaces:** `GlassCard({Widget? child, EdgeInsets padding, BorderRadius radius, bool blur = true, Color? tint, VoidCallback? onTap, Widget? trailing})`. `GlassCard.solid(...)` = `blur:false` (for scroll-list items to avoid N `BackdropFilter`s). When `blur`, wraps child in `ClipRRect` + `BackdropFilter(filter: ImageFilter.blur(sigmaX: design.glassBlurSigma, sigmaY: ...))` over `Container(color: design.glassTint.withOpacity(design.glassOpacity))`, plus a hairline `Border.all(color: design.glassBorder.withOpacity(0.4))` and soft shadow.

- [ ] **Step 1: Failing test** — `GlassCard.solid` renders child; tapping `onTap` variant fires callback.
- [ ] **Step 2:** fail.
- [ ] **Step 3:** implement (as above).
- [ ] **Step 4:** pass.
- [ ] **Step 5:** commit `feat(ui): add GlassCard primitive`.

---

## Task 5: Glass buttons — `PrimaryButton`, `SecondaryButton`, `GhostButton`, `DangerButton`

**Files:** Create `lib/core/widgets/glass/glass_buttons.dart`. Test `test/glass_buttons_test.dart`.

**Interfaces:** each is a `StatelessWidget` with `{required VoidCallback? onPressed, required Widget child, bool loading = false, bool expanded = true}`. Min height 52, radius `radiusLg`, press-scale via `AnimatedScale` (scale 0.97 while tapping). `PrimaryButton` = filled `design.primary`; `SecondaryButton` = glass (`GlassCard.solid` + `design.primary` text); `GhostButton` = transparent + outline; `DangerButton` = `design.error`. `loading` swaps child for a 18px spinner (color `onPrimary`/equivalent).

- [ ] **Step 1–5:** TDD per usual. Test: tapping fires `onPressed`; `loading:true` shows `CircularProgressIndicator` and disables tap.

Commit `feat(ui): add glass button family`.

---

## Task 6: `GlassSheet` + `showGlassSheet`

**Files:** Create `lib/core/widgets/glass/glass_sheet.dart`. Test `test/glass_sheet_test.dart`.

**Interfaces:** `showGlassSheet({required BuildContext context, required WidgetBuilder builder})` — `showModalBottomSheet` with `backgroundColor: Colors.transparent`, `isScrollControlled: true`, builder wraps content in a `ClipRRect(top corners radius28)` + `BackdropFilter` glass container with a grabber. This replaces the repeated `showModalBottomSheet(...)` boilerplate in POS/cart/checkout/table-picker.

- [ ] **Step 1–5:** TDD. Test: `showGlassSheet` presents a `BackdropFilter` and the provided child.

Commit `feat(ui): add GlassSheet modal helper`.

---

## Task 7: `GlassAppBar` (blurred, optional large title)

**Files:** Create `lib/core/widgets/glass/glass_app_bar.dart`. Test `test/glass_app_bar_test.dart`.

**Interfaces:** `GlassAppBar({String? title, Widget? titleWidget, List<Widget> actions, Widget? leading, PreferredSizeWidget? bottom, bool large = false})` implements `PreferredSizeWidget`. Renders a `SliverAppBar`/`AppBar` with `flexibleSpace` = `BackdropFilter` blur over a translucent `design.glassTint`. `large:true` shows an iOS-style large title row.

- [ ] **Step 1–5:** TDD. Test: renders title text + actions; height when `bottom` provided.

Commit `feat(ui): add GlassAppBar`.

---

## Task 8: `GlassTextField`

**Files:** Create `lib/core/widgets/glass/glass_text_field.dart`. Test `test/glass_text_field_test.dart`.

**Interfaces:** `GlassTextField({controller, String? label, String? hint, IconData? prefix, Widget? suffix, TextInputType, bool obscure, List<TextInputFormatter>? inputFormatters, ValueChanged<String>? onChanged})`. Wraps a `TextField` themed via `InputDecoration` sitting on `GlassCard.solid`. Keeps `FilteringTextInputFormatter` usage from checkout/settings working.

- [ ] **Step 1–5:** TDD. Test: typing updates controller; prefix icon renders.

Commit `feat(ui): add GlassTextField`.

---

## Task 9: `GlassSegmented` (iOS-style)

**Files:** Create `lib/core/widgets/glass/glass_segmented.dart`. Modify `lib/core/widgets/segmented_selector.dart` to re-export / become a thin alias so existing imports (`SegmentedSelector`, `Segment`) keep working. Test `test/glass_segmented_test.dart`.

**Interfaces:** keep public API `SegmentedSelector<T>({required T value, required ValueChanged<T> onChanged, required List<Segment<T>> segments})`. Reimplement internals: a `GlassCard.solid` container holding a row of segments with a sliding `AnimatedPositioned` pill (`design.primary`) behind the selected segment. `Segment<T>({required T value, required String label, IconData? icon})` unchanged.

- [ ] **Step 1–5:** TDD. Test: tapping a segment fires `onChanged` with its value; selected segment's label color = `onPrimary`.

Commit `feat(ui): iOS-style GlassSegmented, replace SegmentedSelector internals`.

---

## Task 10: `GlassChip` / `GlassFilterChip`

**Files:** Create `lib/core/widgets/glass/glass_chip.dart`. Test `test/glass_chip_test.dart`.

**Interfaces:** `GlassFilterChip({required String label, IconData? icon, required bool selected, required VoidCallback onTap})`. Selected = `design.primary` fill + `onPrimary` text; unselected = `GlassCard.solid` mini. Same visual language used by POS category chips, Orders filter chips, Tables status chips — so all three converge on this one widget (reusable per the requirement).

- [ ] **Step 1–5:** TTD. Test: tap fires; selected state colors differ.

Commit `feat(ui): add GlassFilterChip`.

---

## Task 11: `GlassStepper`

**Files:** Create `lib/core/widgets/glass/glass_stepper.dart`. Test `test/glass_stepper_test.dart`.

**Interfaces:** `GlassStepper({required int quantity, required VoidCallback onAdd, required VoidCallback onDecrement, GlassStepperVariant variant = GlassStepperVariant.full})`. `variant.full` = the `[-][n][+]` row used in cart; when `quantity==0` it can render as an Add button (used by POS tile). Replaces `_QtyStepper` (cart_panel) and `_QuantityAction` (product_card) internals — both delegate here.

- [ ] **Step 1–5:** TDD. Test: add/decrement fire; `quantity==0` shows add affordance.

Commit `feat(ui): add GlassStepper, unify qty controls`.

---

## Task 12: `Skeleton` shimmer

**Files:** Create `lib/core/widgets/glass/skeleton.dart`. Modify `lib/core/widgets/loading_indicator.dart` — keep `LoadingIndicator` but add a `LoadingIndicator.skeleton(...)` factory. Test `test/skeleton_test.dart`.

**Interfaces:** `Skeleton({double w, double h, BorderRadius})` — a `Shimmer`-styled box (gradient sweep using `design.surfaceContainerHigh` → `surfaceContainerHighest`). Used by dashboard/orders/tables list loading.

- [ ] **Step 1–5:** TDD. Test: renders a `CustomPaint`/`DecoratedBox` of the given size.

Commit `feat(ui): add Skeleton shimmer loading`.

---

## Task 13: Restyle `EmptyState` + `StatusBadge` + `LoadingIndicator`

**Files:** Modify `lib/core/widgets/empty_state.dart`, `lib/core/widgets/status_badge.dart`, `lib/core/widgets/loading_indicator.dart`. Tests updated.

**Interfaces:** unchanged public API (`EmptyState({IconData icon, String title, String? subtitle})`, `StatusBadge({OrderStatus/TableStatus status, bool compact})`). `EmptyState` now renders inside a `GlassCard.solid` with the icon in a soft tinted circle. `StatusBadge` becomes a glass pill.

- [ ] **Step 1–5:** TDD. Test: `EmptyState` renders title + a `GlassCard`; `StatusBadge(status: OrderStatus.paid)` renders text.

Commit `refactor(ui): restyle EmptyState + StatusBadge onto glass system`.

---

## Task 14: `GlassNav` (bottom) + `GlassNavRail` (side) + wire `MainShell`

**Files:** Create `lib/core/widgets/glass/glass_nav.dart`. Modify `lib/features/shared/main_shell.dart`. Test `test/glass_nav_test.dart` + keep `test/router_stability_test.dart` green.

**Interfaces:** `GlassNav({required int index, required ValueChanged<int> onChanged, required List<GlassNavItem> items})` — a `BackdropFilter` bottom bar with a sliding pill behind the active item; `GlassNavRail` same vertically for ≥900dp. `GlassNavItem({required IconData active, required IconData inactive, required String label, int? badge})`.

- [ ] **Step 1: Failing test** — `GlassNav` renders 5 items, tapping index 2 fires `onChanged(2)`.
- [ ] **Step 2:** fail.
- [ ] **Step 3: Implement** `GlassNav` + `GlassNavRail`.
- [ ] **Step 4: Wire MainShell** — in `main_shell.dart`:
  - Replace `Scaffold(bottomNavigationBar: NavigationBar(...))` with `Scaffold(body: AppBackground(child: Row(...))` where at ≥900dp a `GlassNavRail` (width 84) precedes `child`, and at phone a `GlassNav` sits in `bottomNavigationBar`.
  - Map `_routes`/`_indexFromLocation` unchanged. Keep `showAppSnackBar` (its body restyled to glass in Task 22 — or here: restyle snackbar now since it lives in this file).
  - Convert the 5 `NavigationDestination`s to 5 `GlassNavItem`s preserving icons + the POS cart badge.
- [ ] **Step 5:** Run `flutter test test/router_stability_test.dart` (must stay green — nav index survives settings change) + `flutter test`.
- [ ] **Step 6: Screenshot** — `/tmp/02_nav_phone.png`, `/tmp/02_nav_tablet.png` (macOS resize).
- [ ] **Step 7: Commit** `feat(nav): GlassNav bottom bar + side rail for tablet`.

---

## Task 15: Restyle Splash + Login

**Files:** Modify `lib/features/splash/splash_page.dart`, `lib/features/auth/login_page.dart`. Tests stay green.

- [ ] **Step 1: Splash** — wrap in `AppBackground`; logo tile becomes `GlassCard` with `Icons.restaurant_rounded`. Animated fade.
- [ ] **Step 2: Login** — wrap `Scaffold` body in `AppBackground`. Logo container → `GlassCard`. PIN dots + error text read `context.design`. Number-pad keys → `GlassCard.solid` (blur, since they sit on the ambient background) with press-scale; the `_key` helper swaps its `Material(surfaceContainerHigh)` for a `GlassCard.solid` + `InkWell`. Demo-PIN info box → `GlassCard.solid` tinted `infoContainer`.
- [ ] **Step 3:** `flutter test` (login has no dedicated test; ensure `flutter analyze` clean). Rebuild iOS, enter PIN `1234`, screenshot `/tmp/03_login.png` before + after.
- [ ] **Step 4: Commit** `feat(auth): restyle login + splash with glassmorphism`.

---

## Task 16: Restyle POS

**Files:** Modify `lib/features/pos/pos_page.dart`, `lib/features/pos/product_card.dart`. Keep `test/product_card_layout_test.dart` green.

- [ ] **Step 1: Header** — `_topBar` logo container → `GlassCard.solid` circle; greeting row reads `context.design`. `_searchField` → `GlassTextField` (prefix search icon). Category chips → `GlassFilterChip` (delete local `_chip`).
- [ ] **Step 2: Grid tile** — `ProductCard`: outer `Material` → `GlassCard(blur: false)` (tiles in a grid over the catalog; use solid glass to avoid N blurs); the in-cart tint uses `design.primaryContainer`. **Keep** `productCardExtent` math untouched (test guards it). Swap `_QuantityAction` internals to delegate to `GlassStepper` (variant that shows Add when qty==0). Unavailable overlay keeps using `design` tokens.
- [ ] **Step 3: Cart bar** — `_OpenCartBar` → `GlassCard` with `design.primary` fill (blur over the nav), press-scale.
- [ ] **Step 4: Background** — `_buildPhone`/`_buildSplit` wrap the body in `AppBackground`. Split panel (`CartPanel`) sits on a `GlassCard`-style container (Task 17).
- [ ] **Step 5:** `flutter test test/product_card_layout_test.dart` green; analyze clean. Rebuild iOS — tap a few products, open cart; screenshot phone `/tmp/04_pos_phone.png` and tablet `/tmp/04_pos_tablet.png` (macOS ≥900dp).
- [ ] **Step 6: Commit** `feat(pos): restyle catalog + header + cart bar with glass system`.

---

## Task 17: Restyle Cart panel + Table picker sheet

**Files:** Modify `lib/features/pos/cart_panel.dart`, `lib/features/pos/table_picker_sheet.dart`. Replace their `showModalBottomSheet` calls with `showGlassSheet`.

- [ ] **Step 1: CartPanel** — header row + segment control (`SegmentedSelector` already glass from Task 9) + table field + line tiles. `_CartLineTile` container → `GlassCard.solid`; `_QtyStepper` → delegate to `GlassStepper`; `_CartSummary` rows on a `GlassCard`. `_EmptyCart` icon in a glass circle. `Dismissible` keep.
- [ ] **Step 2: TablePickerSheet** — tiles → `GlassCard` grid of tables; selected table highlighted `design.primary`.
- [ ] **Step 3:** analyze + rebuild iOS; open cart (add items), open table picker; screenshot `/tmp/05_cart.png`, `/tmp/05_tablepicker.png`.
- [ ] **Step 4: Commit** `feat(pos): restyle cart panel + table picker`.

---

## Task 18: Restyle Checkout sheet + Success receipt

**Files:** Modify `lib/features/pos/checkout_sheet.dart`. Migrate the `AppSemanticColors.of(Brightness.light)` shim away.

- [ ] **Step 1:** Total card → `GlassCard` tinted `primaryContainer`. Payment method → `GlassSegmented` (already). Quick-cash chips → `GlassFilterChip`. Cash input → `GlassTextField`. Place-order button → `PrimaryButton(loading: _busy)`. Replace `showModalBottomSheet` with `showGlassSheet`.
- [ ] **Step 2: Receipt** — `_SuccessReceipt`: replace `final semantic = AppSemanticColors.of(Brightness.light);` with `final semantic = context.design;`. Success circle → glass tinted `successContainer`. Receipt body → `GlassCard`. Buttons → `PrimaryButton`/`GhostButton`.
- [ ] **Step 3:** Remove the `AppSemanticColors` shim from `app_colors.dart` now that no call sites remain (grep `AppSemanticColors.of` → none).
- [ ] **Step 4:** analyze + rebuild; run a checkout flow, screenshot `/tmp/06_checkout.png`, `/tmp/06_receipt.png`.
- [ ] **Step 5: Commit** `feat(pos): restyle checkout + receipt; drop AppSemanticColors shim`.

---

## Task 19: Restyle Orders + Order detail

**Files:** Modify `lib/features/orders/orders_page.dart`, `lib/features/orders/order_detail_page.dart`.

- [ ] **Step 1: OrdersPage** — `AppBar` → `GlassAppBar(bottom: filter bar)`. Filter chips → `GlassFilterChip`. `_OrderTile` container → `GlassCard.solid`; type-icon circle uses `design.primaryContainer`. Wrap list in `AppBackground` (via the shell — the shell already paints background; ensure `Scaffold` backgroundColor transparent).
- [ ] **Step 2: OrderDetailPage** — sections → `GlassCard`; status flow chips → `GlassFilterChip`; line items on `GlassCard.solid`; totals block → `GlassCard`. `AppBar` → `GlassAppBar`.
- [ ] **Step 3:** analyze + rebuild; screenshot `/tmp/07_orders.png`, `/tmp/07_order_detail.png`.
- [ ] **Step 4: Commit** `feat(orders): restyle list + detail with glass system`.

---

## Task 20: Restyle Tables + fix literal `'Total'`

**Files:** Modify `lib/features/tables/tables_page.dart`. Modify `lib/l10n/app_en.arb`, `lib/l10n/app_id.arb`.

- [ ] **Step 1: Bug fix** — `tables_page.dart:162` literal `'Total'` → add key `tablesTotal` to **both** `.arb` files:
  - `app_en.arb`: `"tablesTotal": "Total"`
  - `app_id.arb`: `"tablesTotal": "Total"`
  - run `flutter gen-l10n`; replace `'Total'` with `l10n.tablesTotal`.
- [ ] **Step 2: Restyle** — `AppBar` → `GlassAppBar`. `_SummaryRow._StatTile` → `GlassCard.solid` tinted. `_TableTile` → `GlassCard` with status-tinted icon circle (`context.semantic.*Container`). Action sheet → `showGlassSheet`; status chips → `GlassFilterChip`. Confirm the `childAspectRatio: 0.92` grid tile still doesn't clip (tile has 2 text lines + icon row — verify at `textScaler` 1.15; if it clips, switch that grid to a computed `mainAxisExtent` like the POS tile).
- [ ] **Step 3:** analyze + `flutter gen-l10n` committed; rebuild; tap a table, change status; screenshot `/tmp/08_tables.png`.
- [ ] **Step 4: Commit** `fix(tables): localize 'Total' label + restyle tables with glass system`.

---

## Task 21: Restyle Dashboard

**Files:** Modify `lib/features/dashboard/dashboard_page.dart`.

- [ ] **Step 1:** `AppBar` → `GlassAppBar`. `_HeaderCard` → `GlassCard` with the primary gradient as a tinted surface (keep the gradient feel, but now over glass). `_BigStat`/`_SmallStat` → `GlassCard.solid`. `_TopProductBar` → `GlassCard.solid` row with the progress bar (`LinearProgressIndicator` reading `design`). `_RecentOrderTile` → `GlassCard.solid`. Loading states → `Skeleton` rows (Task 12) instead of bare spinner. `_EmptyInline` → `GlassCard`.
- [ ] **Step 2:** Tablet (≥900dp): make `_statsRow` + top-products/recent go two-column when width ≥ 900 (wrap in a `LayoutBuilder`/`Row` of two `Expanded` columns). Phone stays single column.
- [ ] **Step 3:** analyze + rebuild; screenshot phone `/tmp/09_dashboard_phone.png` + tablet `/tmp/09_dashboard_tablet.png`.
- [ ] **Step 4: Commit** `feat(dashboard): restyle stat cards + tablet two-column layout`.

---

## Task 22: Restyle Settings + snackbar

**Files:** Modify `lib/features/settings/settings_page.dart`, `lib/features/shared/main_shell.dart` (`showAppSnackBar`).

- [ ] **Step 1:** `_Card` → `GlassCard`. `_SectionTitle`/`_Label` read `context.design`. `_SettingTile`/`_LangTile`/`_ChoiceChip` rows unchanged structurally, restyled via `GlassCard` parent. Brand swatches keep their `p.seed`→`p.swatch` color (rename field usage: `p.seed` → `p.swatch`). Dialogs (`_edit`, `_editNumber`, `_confirmReset`) → keep `AlertDialog` (acceptable; they sit over glass already) but inputs use `GlassTextField`.
- [ ] **Step 2: Snackbar** — `showAppSnackBar` content → a `GlassCard`-styled `SnackBar` (behavior floating, shape `radiusLg`, margin).
- [ ] **Step 3:** analyze + rebuild; toggle theme/brand/lang; screenshot `/tmp/10_settings.png`. Run `test/router_stability_test.dart` (settings change must not remount router).
- [ ] **Step 4: Commit** `feat(settings): restyle cards + glass snackbar`.

---

## Task 23: Restyle Product management + forms

**Files:** Modify `lib/features/products/product_management_page.dart`, `lib/features/products/product_form_sheet.dart`.

- [ ] **Step 1:** `AppBar` + `TabBar` → `GlassAppBar(bottom: TabBar)` with glass-tab styling. `_ProductListTile` container → `GlassCard.solid`; the switch/delete column keeps `Switch.adaptive` + delete `IconButton`. Category list tiles → `GlassCard.solid`. FAB stays but restyle to glass-tinted.
- [ ] **Step 2:** `ProductFormSheet` + `_CategoryFormSheet` inputs → `GlassTextField`; icon picker boxes → `GlassCard.solid` selected-state. Sheets via `showGlassSheet`.
- [ ] **Step 3:** analyze + rebuild; add/edit a product + category; screenshot `/tmp/11_product_mgmt.png`.
- [ ] **Step 4: Commit** `feat(products): restyle management + forms with glass system`.

---

## Task 24: iOS-style page transitions

**Files:** Modify `lib/core/router/app_router.dart`. Keep `test/router_stability_test.dart` green.

- [ ] **Step 1:** For detail routes (`/orders/:id`) and any `GoRoute` outside the shell, set `pageBuilder: (c,s) => CupertinoPage(child: ...)` (or `CustomTransitionPage` with `CupertinoPageTransitionsBuilder`). Shell routes keep default. Do NOT make `routerProvider` `ref.watch` anything (guard).
- [ ] **Step 2:** `flutter test test/router_stability_test.dart` green; `flutter test`.
- [ ] **Step 3: Commit** `feat(router): iOS-style page transitions`.

---

## Task 25: Update docs (CLAUDE.md + AGENTS.md theming section)

**Files:** Modify `CLAUDE.md`, `AGENTS.md`.

- [ ] **Step 1:** Replace the "single seed / `ColorScheme.fromSeed`" guidance with the token system: hand-tuned `BrandColors` per `BrandPreset`, `AppTheme` builds `ColorScheme` manually, `context.design`/`context.semantic` resolve `BrandColors`, `AppBackground` substrate, glass primitives in `lib/core/widgets/glass/`. Keep the iOS `--no-tree-shake-icons` mandate, no-emoji rule, grid-tile rule.
- [ ] **Step 2:** Bump the "DB migrations current version: 4" note only if untouched (it is untouched — no DB changes in this plan). Leave as-is.
- [ ] **Step 3: Commit** `docs: rewrite theming section for the glass token system`.

---

## Task 26: Full screenshot verification pass

**Files:** Evidence saved to `docs/superpowers/screenshots/`.

- [ ] **Step 1:** Rebuild iOS. For each of: login, POS (phone+tablet), cart, checkout, receipt, orders, order detail, tables, dashboard (phone+tablet), settings, product mgmt — capture a screenshot in **light** and repeat in **dark**, for the default `flame` brand, into `docs/superpowers/screenshots/<screen>_<theme>.png`.
- [ ] **Step 2:** Smoke two more brands (ocean, royal) on POS + dashboard to confirm palette swap looks right.
- [ ] **Step 3:** Visually verify: no clipping at `textScaler` 1.15, text contrast over glass is readable in both themes, no tofu icons, no literal strings (toggle to `id` locale and re-spot-check).
- [ ] **Step 4:** `flutter analyze` clean; `flutter test` green; E2E `flutter test integration_test/app_e2e_test.dart -d 810AB071-8AFC-41C5-B526-02246E314C4B` green.
- [ ] **Step 5: Commit** the screenshot evidence: `docs: add Phase 1 redesign screenshot evidence`.

---

## Self-review (run after writing)

**Spec coverage:**
- Tokens replace seed → Task 1. ✓
- Background system → Task 3. ✓
- Glass primitives list → Tasks 4–13 (every component in spec §5 mapped). ✓
- Typography (Plus Jakarta Sans, tabular figures, tight headings) → Task 2. ✓
- Motion (iOS transitions, press-scale, glass snackbar) → Tasks 5/22/24. ✓
- Responsiveness (900dp, nav rail, dashboard two-column) → Tasks 14/21. ✓
- Restyle scope (16 screens) → Tasks 15–23 (all enumerated). ✓
- Bug fix (`'Total'` literal) → Task 20 Step 1. ✓
- Localization both arb files → each restyle task + Task 20. ✓
- Migration safety (ColorScheme populated, per-file commits, tests guard) → Global Constraints + per-task commits. ✓
- Testing (existing green + new primitive tests) → every primitive task + Task 26. ✓
- Docs update → Task 25. ✓
- Verification (screenshots phone+tablet) → each restyle task + Task 26. ✓

**Placeholder scan:** None. Brand accent values, factory fields, neutral bases, and per-screen swaps are all concrete. Where a restyle says "→ `GlassCard.solid`", that maps an exact existing `Container(decoration: BoxDecoration(color: scheme.surfaceContainerLow…))` to an exact new widget.

**Type consistency:** `BrandPreset.byId` / `.presets` preserved. `AppTheme.light/dark(brand)` signatures preserved. `context.semantic` returns `BrandColors` (has `success/successContainer/warning/warningContainer/info/infoContainer`) — matches every existing call site. `SegmentedSelector`/`Segment` API preserved (Task 9). `productCardExtent` untouched (Task 16). `showAppSnackBar` signature preserved (Task 22). `EmptyState`/`StatusBadge`/`LoadingIndicator` APIs preserved (Task 13). `routerProvider` watch-guard preserved (Task 24).

**One refinement logged:** spec §3 said "migrate all `colorScheme.*` → `context.design`". Because Task 1 fully populates `ColorScheme` from tokens, existing `colorScheme.*` call sites are automatically correct; the plan migrates to `context.design` only where a token has no `ColorScheme` equivalent (gradient, blobs, glass specifics). This reduces churn and risk without changing the outcome. No spec edit required — the outcome ("break from seed, token-driven") is preserved.
