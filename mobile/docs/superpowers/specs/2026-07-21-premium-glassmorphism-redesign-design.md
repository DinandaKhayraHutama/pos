# Phase 1 — Premium Glassmorphism Redesign

**Status:** Approved (2026-07-21)
**Scope:** Foundation-first. Build a new premium design system and restyle **all existing screens**. No new product features (those are Phase 2). Full visual verification via emulator screenshots throughout.

---

## 1. Context & motivation

The app is currently built entirely on `ColorScheme.fromSeed(seedColor)` per `BrandPreset`, with `Theme.of(context).colorScheme.*` referenced in every screen. That seed-derived palette reads as generic / not premium enough, and the overall look is default Material 3.

The product decision (owner-approved): **break free from the seed system** and adopt a **premium, custom, iOS-native glassmorphism** design language using **hand-tuned brand palettes** and **custom components**, while keeping Flutter's structural primitives (`Scaffold` safe-area, `go_router`, `TextField` editing, gesture system) as the skeleton.

This is a design-system rewrite, not a retouch.

### Decomposition (why Phase 1 is design-system-only)

The full ask — redesign + major new features + full screenshot test harness — is too large for one spec. Agreed ordering:

- **Phase 1 (this spec):** New design tokens, glassmorphism primitives, restyle every existing screen. Deliverable: a fully working, beautiful app with the *current* feature set.
- **Phase 2 (separate spec):** Major new features (reservations, split payment, report export, …) built on the new system.
- **Phase 3 (separate spec):** Integration-test harness that screenshots every screen/state.

Rationale: features built on the old look are wasted work once the redesign lands. Foundation first means everything that follows is automatically on-brand.

---

## 2. Locked decisions

| Decision | Choice |
|---|---|
| Brand strategy | **Multi-brand kept.** Each `BrandPreset` becomes a hand-tuned `BrandTheme` (light + dark), not a seed. |
| Distance from Material | **Replace all visible chrome; keep the bones.** Custom glass cards/nav/buttons/sheets/app-bars/dialogs. Still use `Scaffold`, `go_router`, `TextField` editing, gesture system. |
| Typography | **Bundle one premium humanist font** (Plus Jakarta Sans) for iOS/Android/desktop consistency. |
| Verification | Screenshot every restyled screen on iOS simulator + macOS desktop (resize for responsive). Existing tests stay green. |

---

## 3. Design tokens (replaces the seed system)

Location: `lib/core/theme/`.

A new `BrandTheme` holds an explicitly-designed palette. No `ColorScheme.fromSeed` anywhere in app code.

### `BrandTheme` shape (illustrative)

```dart
class BrandTheme {
  final String id;
  final String name;
  final BrandColors light;
  final BrandColors dark;
}

class BrandColors {
  final List<Color> gradient;     // ambient background stops (2–3)
  final List<BlobSpec> blobs;     // soft radial color blobs (position, color, radius)
  final Color glassTint;          // tint applied to glass surfaces
  final Color glassBorder;        // hairline border on glass
  final Color surfaceBase;        // plain surface behind glass
  final Color surfaceRaised;      // card-level
  final Color surfaceOverlay;     // modal/dialog
  final Color primary;            // accent (hand-picked)
  final Color onPrimary;
  final Color secondary;
  final Color textHigh;           // primary text
  final Color textMedium;         // secondary text
  final Color textLow;            // tertiary / hints
  final SemanticColors semantic;  // success/warning/error/info, tuned per brand
  final double glassBlurSigma;    // backdrop blur strength
  final double glassOpacity;
}
```

- Each `BrandPreset` (e.g. the existing orange/red/green/etc.) is redefined as a `BrandTheme` literal with both `light` and `dark` hand-tuned. The Settings swatch list keeps rendering them automatically.
- A `ColorScheme` is still constructed from the tokens and handed to `MaterialApp` so remaining M3 primitives (`TextField`, `Switch`, scrollbar) have sane defaults during migration — **but the tokens are the source of truth**, not the `ColorScheme`.
- `ThemeMode` (light/dark/system) stays user-switchable in Settings.

### Access

```dart
extension DesignContext on BuildContext {
  BrandColors get design => AppTheme.of(this).resolve(brightness);
  // AppTheme caches the active BrandTheme; resolves light/dark by MediaQuery brightness.
}
```

All `Theme.of(context).colorScheme.*` references migrate to `context.design.*` as each file is restyled.

### Token scale

- `AppDimensions` already holds spacing/radius. Extend with a **fluid spacing scale** (clamp at phone vs tablet breakpoints) where relevant; static constants remain for predictability.
- Shadow tokens: soft, large-blur, low-opacity (premium), not Material's sharp elevation.

---

## 4. Background system (enables glassmorphism)

Glass looks dead on a flat background. The redesign introduces an `AppBackground` widget placed at the `Scaffold` level (in `MainShell` and on standalone screens: login, splash):

- A linear/radial **brand gradient** fills the surface.
- Two–three soft **color blobs** (`RadialGradient`, blurred, low-opacity) positioned for depth.
- Glass surfaces (`BackdropFilter` + tint) sit on top and the blur picks up the gradient/blob colors.

`AppBackground` reads `context.design` so each brand has its own ambient palette.

---

## 5. Glass primitives (reusable components)

Location: `lib/core/widgets/glass/`. These are the reusable building blocks the rest of the app composes.

| Component | Replaces / purpose |
|---|---|
| `GlassCard` | Workhorse container. Blur + tint + hairline border + soft shadow. |
| `GlassNav` | Phone bottom nav: blur bar + sliding pill indicator. |
| `GlassNavRail` | Tablet/desktop (≥900dp) side rail. |
| `PrimaryButton` / `SecondaryButton` / `GhostButton` / `DangerButton` | iOS-native feel: large radius, subtle press-scale. |
| `GlassSheet` | Modal bottom sheet: blur + grabber + iOS spring. |
| `GlassAppBar` | Blurred top bar, optional large-title (iOS style). |
| `GlassTextField` | Glass-filled input with floating label. |
| `GlassSegmented` | iOS-style segmented control (replaces current `SegmentedSelector` look). |
| `GlassChip` / `GlassFilterChip` | Pill chips (POS categories, order filters, status pickers). |
| `GlassStepper` | Quantity stepper (cart, POS tile). |
| `StatCard`, `SectionHeader`, `IconTile` | Dashboard / list building blocks. |
| `Skeleton` | Shimmer loading (replaces bare spinner where a layout skeleton exists). |
| `EmptyState` (premium) | Restyled empty states. |
| `StatusBadge` (restyle) | Glass pill status badge. |

These satisfy the "component always reusable" requirement and are the vocabulary every restyled screen uses.

---

## 6. Typography

- Bundle **Plus Jakarta Sans** (Regular, Medium, Semibold, Bold) under `assets/fonts/` and register in `pubspec.yaml`.
- `app_theme.dart` builds a `TextTheme` using the family, with:
  - Tighter letter-spacing on headings (`letterSpacing` negative).
  - `FontFeature.tabularFigures()` on money/number styles so totals don't jitter as quantities change.
- Set the default `fontFamily` globally so every `Text` inherits it.

---

## 7. Motion

- Page transitions: iOS-style (`CupertinoPageTransition`) wired through `go_router` page builders for shell + detail routes.
- Tap feedback: subtle scale-down on buttons/cards (`AnimatedScale`).
- Snackbars: glass-styled (replace current `showAppSnackBar` chrome; keep the helper signature).
- Skeleton shimmer for loading states that have a known layout.
- No heavy hero animations on day one; revisit in Phase 2 if needed.

---

## 8. Responsiveness

- Breakpoint stays `AppDimensions.tabletWidth` (900dp).
- Fluid spacing scale clamps between phone and tablet.
- ≥900dp:
  - Nav → `GlassNavRail` (side).
  - POS keeps its split (catalog + cart panel) — already handled.
  - Dashboard / Orders / Tables adopt multi-column layouts where they improve density (e.g., dashboard stat row + two-column recent/top on tablet).
- Phone (<900dp): current single-column flow, restyled.
- Login / splash: centered, `maxWidth`-constrained, look great at any width.

---

## 9. Restyle scope (Phase 1 — existing screens only)

Every existing surface is restyled onto the new system. Functionality is unchanged.

1. **Splash** — branded ambient background, logo glass tile.
2. **Login** — glass PIN pad, glass logo card, ambient background.
3. **Main shell** — `GlassNav` (phone) / `GlassNavRail` (tablet), cart badge.
4. **POS** — header (greeting + date), search, category chips, product grid (glass tiles), cart panel, open-cart bar.
5. **Cart panel** — glass line tiles, glass stepper, summary, table field.
6. **Checkout sheet** — total card, payment segmented, quick-cash chips, change row, place-order.
7. **Success receipt** — glass receipt card, success animation.
8. **Table picker sheet** — glass grid of tables.
9. **Orders** — glass filter bar, glass order tiles.
10. **Order detail** — glass sections, status flow, line items, totals.
11. **Tables** — glass summary row, glass table tiles, action sheet.
12. **Dashboard** — glass header card, stat row, top-product bars, recent order tiles.
13. **Settings** — glass section cards, theme/brand/lang/business/about tiles.
14. **Product management** — glass tab bar, glass list tiles (products + categories).
15. **Product form sheet** — glass inputs, icon picker.
16. **Category form sheet** — glass inputs, icon picker.

### Bugs fixed along the way
- `tables_page.dart` literal `'Total'` → localized key (add to both `.arb` files, `flutter gen-l10n`).
- Any other literal-string / hardcoded-color / clipping issues found during the per-screen pass.

---

## 10. Localization

- No literal user-facing strings. New component labels reuse existing keys where possible; new keys added to **both** `app_en.arb` and `app_id.arb`, then `flutter gen-l10n`.
- The bootstrap exception in `main.dart` (`_BootstrapScaffold`) keeps its hardcoded brand text but uses the new tokens for color once `MaterialApp` exists — same rule as today.

---

## 11. Execution & migration strategy

1. **Add tokens + primitives without breaking existing screens.** `BrandTheme` introduced; `ColorScheme` populated from tokens so untouched screens still render sanely. `context.design` extension available.
2. **Introduce `AppBackground`** and the glass primitives as standalone widgets with their own widget tests.
3. **Restyle screen-by-screen**, migrating `colorScheme.*` → `context.design.*` inside each touched file. One Conventional Commit per screen (e.g. `feat(theme): restyle dashboard to glass design system`) so each step is reviewable and individually revertible.
4. **After each screen:** rebuild iOS sim (`--no-tree-shake-icons`), install, screenshot; also verify tablet layout via macOS desktop resize. Visually confirm light + dark.
5. **Last step:** update `CLAUDE.md` / `AGENTS.md` theming section to describe the token system (replaces the single-seed rule), so docs match reality.

---

## 12. Testing & verification

- `flutter analyze` stays clean.
- `flutter test` stays green. Existing guards remain in force:
  - `test/router_stability_test.dart` — `routerProvider` must not rebuild on settings changes.
  - `test/product_card_layout_test.dart` — tile sizing from content, not ratio.
  - widget/e2e tests.
- **New widget tests** for primitives where behavior matters: `GlassSegmented` selection callback, `GlassStepper` callbacks, `GlassNav` index mapping, `GlassFilterChip` selection, `EmptyState`/`StatusBadge` rendering.
- **Visual verification:** screenshots of every restyled screen on the iOS simulator (phone) and macOS desktop (tablet width) captured as each screen lands. These are the evidence the result is "matang."
- iOS build mandate preserved: `flutter build ios --debug --simulator --no-codesign --no-tree-shake-icons` (never tree-shake icons).

---

## 13. Risks & mitigations

| Risk | Mitigation |
|---|---|
| `BackdropFilter` cost on low-end Android | Coarse blur sigma, `RepaintBoundary` + layer caching, avoid stacking many blurs in scroll lists. |
| Token migration touches every file | Mechanical, one commit per file; existing tests guard regressions; `ColorScheme` stays populated so partial states still render. |
| Text contrast over glass in light/dark | Verify every glass surface in both themes; tune `glassTint`/opacity per theme; keep text colors at AA. |
| Plus Jakarta Sans adds asset weight | Subset weights (400/500/600/700); acceptable for a premium look. |
| iOS tree-shake breaks icon variants | Always build with `--no-tree-shake-icons` (already mandated). |

---

## 14. Non-goals (deferred)

- New product features (reservations, split payment, report export, discount input, order editing, etc.) → **Phase 2**.
- Integration-test harness that screenshots every screen/state programmatically → **Phase 3**. (During Phase 1, verification is manual screenshotting per screen as it lands.)

---

## 15. Deliverable

A working NTI POS app, same features as today, wearing a hand-tuned, multi-brand, premium glassmorphism design system built on custom components — verified by screenshots on phone and tablet layouts, with existing tests green and new primitive tests added.
