# AGENTS.md — JustClick POS

Project memory for AI coding agents (Claude, Cursor, Copilot, etc.). Read this **before** making changes.

## 📋 Project Overview

**JustClick POS** — Restaurant Point of Sale mobile app for FnB clients (dkriuk / rocket chicken style).
Built end-to-end with Flutter, ready to demo. Designed so the backend team can later swap the local
SQLite layer for a REST API without touching UI code.

- **Stack:** Flutter 3.38+ / Dart 3.10+ / Riverpod / go_router / sqflite
- **Target:** Mobile-first (iOS + Android), with responsive tablet/desktop split-view
- **Sign-in PINs:** `1234` manager, `2345` / `3456` cashiers (rows in `employees`, not a constant)

## 🚨 Critical Conventions

### Build flag for iOS — MANDATORY
The Material Icons font must NOT be tree-shaken, or icon variants (`_outlined`, `_rounded`) render
as tofu boxes on iOS. Always build/install with:

```bash
flutter build ios --debug --simulator --no-codesign --no-tree-shake-icons
xcrun simctl install <device-id> build/ios/iphonesimulator/Runner.app
xcrun simctl launch <device-id> com.example.ntiPos
```

`flutter run` does **not** support `--no-tree-shake-icons`. For day-to-day dev use macOS desktop
(it bundles the full font automatically), or use the build+install pattern above for iOS.

### Theming — token system, single source of truth
Colors come from hand-tuned `BrandColors` tokens (a `ThemeExtension` in `lib/core/theme/brand_colors.dart`), NOT a seed. `AppTheme._build` (`lib/core/theme/app_theme.dart`) constructs `ColorScheme` MANUALLY from the active `BrandColors` — no `ColorScheme.fromSeed` anywhere. Each `BrandPreset` (`lib/core/theme/app_colors.dart`) carries a `BrandAccent` payload that `BrandColors.fromAccent` merges onto a shared neutral base, separately for light and dark, so both brightnesses are hand-tuned per brand.

**Never hardcode colors** — resolve via:
- `context.design.*` — accents, surface tiers (`surfaceBase`/`surfaceRaised`/`surfaceOverlay`), text tiers (`textHigh`/`textMedium`/`textLow`), glass presets, substrate (`gradient`/`blobs`), semantic (`success`/`warning`/`info`/`error` + containers). Superset.
- `context.semantic.*` — alias of `context.design` for legacy call sites (same instance).
- `Theme.of(context).colorScheme.*` — works because the scheme is built from the same tokens; use for standard Material roles.

The ambient substrate is `AppBackground` (`lib/core/widgets/app_background.dart`), which paints the brand gradient + blobs behind every screen — `MainShell` provides it for tabbed routes, pushed routes wrap themselves. Glass primitives live in `lib/core/widgets/glass/` (`GlassCard` + `.solid`, glass buttons, `GlassSheet`/`showGlassSheet`, `GlassAppBar`, `GlassTextField`, `GlassSegmented`, `GlassFilterChip`, `GlassStepper`, `Skeleton`, `GlassNav`/`GlassNavRail`); prefer them over raw `Card`/`Container`/`AppBar`. Plus Jakarta Sans (static 400/500/600/700 in `assets/fonts/plus_jakarta/`) is bundled and set globally as `fontFamily` in `AppTheme._build`.

To add a brand: add a `BrandPreset` with a hand-tuned `BrandAccent` (primary, onPrimary, secondary, gradient, blobs, semantic accents) to `BrandPreset.presets`. The factory derives containers and dark semantic foregrounds — NOT a seed, NOT one line. The Settings page auto-renders the new swatch.

### Localization
- Source files: `lib/l10n/app_en.arb`, `lib/l10n/app_id.arb`
- Generated: `lib/l10n/gen/app_localizations*.dart` (committed)
- Access in code: `context.l10n.someKey` (extension in `lib/core/localization/l10n.dart`)
- After editing arb files: `flutter gen-l10n`

### Product thumbnail priority
`lib/core/widgets/product_thumbnail.dart`:
1. Network image (`Product.imageUrl`) — Unsplash URL in seed data
2. Material Icon (`Product.iconKey` mapped via `iconFromKey()` in `lib/core/utils/icon_map.dart`)
3. Emoji (`Product.emoji`) — last resort, used in receipts & top-product bar only

When adding a new product, ALWAYS set `iconKey` to one of the keys in `_iconByKey` whitelist
(`lib/core/utils/icon_map.dart`). Using a key outside the whitelist falls back to `restaurant`.

Image loads fail **silently** — `errorBuilder` drops to the icon, so a broken photo still looks
fine. Two causes seen in practice: rotted Unsplash slugs (HEAD-sweep before a demo) and the
macOS sandbox missing `com.apple.security.network.client` in both `macos/Runner/*.entitlements`.
See "Product images are network-only" in CLAUDE.md.

## 🏗 Architecture

```
UI (features/) → Riverpod providers → repositories → sqflite
                                              ↑
                                  swappable to REST later
```

- `lib/data/repositories/*_repository.dart` — only place that touches DB. Replace bodies with
  `http.get/post` to migrate to REST API. Models & UI stay untouched.
- `lib/data/models/*.dart` — plain Dart classes with `fromMap` / `toMap` / `copyWith`.
- `lib/providers/*_provider.dart` — Riverpod `AsyncNotifier` / `StateNotifier`.
- `lib/features/<feature>/` — UI screens. Never import sqflite directly here.

### Platforms
iOS / Android / macOS use `sqflite` on a real file. **Web** has no `sqflite` or `path_provider`, so
it runs SQLite-on-wasm against IndexedDB via the conditional-export seam in
`lib/data/database/db_platform.dart`. `web/sqlite3.wasm` is committed and must match the resolved
`sqlite3` version in `pubspec.lock`. See "Web — the demo channel" in CLAUDE.md.

### DB Migrations
`lib/data/database/app_database.dart` — bump `currentVersion` and add migration in `_onUpgrade`.
Current version: **16**. `_onUpgrade` is split in two: per-version blocks that change the SCHEMA
ONLY, then a deferred section that WRITES ROWS against the finished schema — v6 and v12 both broke
by ignoring that, so any new seeder belongs in the deferred part. v13 added `outlets`; v14
`outlet_stock`; v15 `tables.outlet_id`; **v16 added `pos_registers` (a branch's tills, each with
its own `table_service`), the till/branch/closed-by columns on `shifts` — which IS the POS session
— `pos_id` / `pos_name` / `pos_session_id` on `orders`, and a partial unique index allowing one
open session per till.** Earlier steps: (v2 added `image_url` / `icon_key` to `products`; v3 nulled seed image
URLs that went 404; v4 added `icon_key` to `categories` and backfilled it; v5 backfilled photos
for the 13 seed products that had none, only where `image_url IS NULL`; v6 seeded a week of demo
orders, only when `orders` is empty; v7 added nullable `cost` / `sku` / `stock` to
`products`; v8 added `employees`; v9 added `shifts`; v10 added the owner role,
`product_variants`, `promos`, `stock_movements`, per-product `tax_rate`, per-line
`variant_name` / `unit_cost`, and `promo_name` / `authorized_by` / `void_reason` /
`refunded_amount` on `orders`; v11 renamed three seeded staff — and, because names are stored
as snapshots rather than joined, every copy of those names in `orders`, `shifts` and
`stock_movements`; v12 grew the floor plan to 31 tables and replaced the seeded week with a
generated month of ~1,500 orders). The v6 seeder no longer runs in v6 position — it writes v10
columns, so it is deferred to the end of `_onUpgrade` as `backfillEmptyOrders`. NULL stock means "not counted", which is different from 0
("counted, none left") — and NULL `tax_rate` means "use the store rate", which is different
from a literal 0 ("this item is genuinely zero-rated").

## 🔐 Roles

Three roles — cashier, manager, owner — with one permission table in
`lib/core/auth/permissions.dart`. Screens ask `settings.can(AppPermission.x)`; nothing in the
UI compares roles. Enforcement lives in `redirect` (against `routePermissions`), in `MainShell`'s
tab derivation, and in the individual actions. The router guard is the one that matters: the demo
runs on the web, where a typed URL bypasses every hidden button.

Cashier sells and counts their own drawer — but only after **signing on to a POS register**.
That check is NOT a `redirect` gate (a router redirect to the pushed `/shift` route once took
`MainShell`'s bottom nav down with it — see the Gotchas). `PosPage.build()` reads
`SettingsState.hasPosSession` itself and renders `PosSessionOpenCard` in place of the catalogue
when there is none, staying mounted as the `/` tab so the nav bar never disappears. Manager adds
void, refund, manual discount, the floor-wide cash drawer, stock adjustments, outlets and the
tills inside them. Owner adds the catalogue, financial reports, staff accounts and promotions.
When a cashier hits a blocked action, `requestAuthorization()` asks a senior for a PIN and
records their name on the result — the cashier stays signed in and keeps the cart.

Two more PIN-gated rules around the session itself: **Settings' Logout button refuses to run
while `hasPosSession` is true** (a dialog points to `/shift` instead — see
`SettingsPage._handleLogout`), and **closing a session re-asks for the signed-in cashier's own
PIN** via `requestSessionClosePin()` before `_CloseShiftSheet` saves anything (`core/auth/
authorize_sheet.dart`, `_PinPromptSheet`'s `verifyAgainstEmployeeId` mode — accepts THAT one
employee id only, never a colleague's otherwise-valid PIN).

## 🧭 File Map

| Path | Purpose |
|---|---|
| `lib/main.dart` | Production entry — wires router + theme + locale |
| `lib/main_driver.dart` | Integration test entry (enables `FlutterDriverExtension`) |
| `lib/core/theme/` | `AppTheme`, `AppColors` (BrandPreset, CategoryColor), `AppDimensions` |
| `lib/core/router/app_router.dart` | go_router config + auth and **role** redirect |
| `lib/core/auth/permissions.dart` | Role → permission table; the single source of authority |
| `lib/core/auth/authorize_sheet.dart` | Manager-override PIN prompt, and the pick-then-PIN cashier handover |
| `lib/core/auth/account_picker.dart` | Account list + chosen-account header, shared by login and handover |
| `lib/core/auth/role_display.dart` | Role label + icon for the UI |
| `lib/core/widgets/pin_pad.dart` | Shared 4-dot PIN entry (login + override) |
| `lib/core/widgets/glass/glass_nav.dart` | Bottom bar (<900dp) + collapsible side rail (≥900dp) |
| `lib/core/widgets/app_snack_bar.dart` | `showAppSnackBar` — moved out of `main_shell.dart` so `core/` need not import `features/` |
| `lib/core/widgets/` | Reusable: `ProductThumbnail`, `StatusBadge`, `EmptyState`, etc. |
| `lib/core/utils/icon_map.dart` | String iconKey → IconData whitelist |
| `lib/data/database/app_database.dart` | sqflite schema + seed data (25 products, 5 categories, 8 tables) |
| `lib/data/preferences/app_preferences.dart` | SharedPreferences wrapper (theme, locale, store info) |
| `lib/providers/settings_provider.dart` | Reactive theme/locale/business settings |
| `lib/providers/cart_provider.dart` | In-memory cart state, computed totals |
| `lib/features/pos/` | POS page, ProductCard, CartPanel, CheckoutSheet, TablePickerSheet |
| `lib/features/orders/` | Order history + detail with status flow |
| `lib/features/tables/` | Dine-in floor plan |
| `lib/features/products/` | CRUD products & categories, incl. variants and per-product tax |
| `lib/features/inventory/` | Low stock, stock in/out with a reason, movement history |
| `lib/features/promos/` | Owner-configured discounts |
| `lib/features/dashboard/` | Today's revenue, top products, recent orders, low-stock banner |
| `lib/features/reports/` | Ranged sales report, gross profit, CSV export |
| `lib/features/shift/` | Pick a POS, open/close its session, variance, floor-wide cash drawer |
| `lib/features/registers/` | Tills per outlet, and whether each runs table service |
| `lib/features/employees/` | Staff accounts, roles and PINs |
| `lib/features/settings/` | Theme, brand color, language, business config (role-gated) |
| `integration_test/app_e2e_test.dart` | Smoke test: login → POS → each tab |

## 🧪 Testing

### Unit / widget
```bash
flutter test
```

### E2E integration test (iOS simulator)
```bash
flutter test integration_test/app_e2e_test.dart -d <ios-sim-id>
```
The test boots the app, force-logs-out, enters PIN `1234`, taps a product, then visits each tab.
All assertions are locale-agnostic (use icons / GridView / widget types, not localized text).

### Manual smoke checklist
0. Login PIN `2345` (a cashier) → land on the POS picker → open "Kasir 1" with a float
1. Login PIN `1234` → land on POS
2. Tap product → cart badge increments
3. Open cart (bottom bar / side panel) → adjust qty
4. Checkout → success receipt → order appears in Orders tab
5. Tables tab → change status → mark occupied
6. Dashboard → revenue / top products render
7. Settings → toggle dark mode, brand color, language (id/en)

## 🔄 Common Tasks

### Add a new product to seed data
Edit `lib/data/database/app_database.dart` → `_seedProducts()`. Bump DB `_version` and add migration
in `_onUpgrade`, OR call Settings → "Reset demo data" to re-seed.

### Add a new screen
1. Create `lib/features/<feature>/<feature>_page.dart`
2. Register route in `lib/core/router/app_router.dart`
3. If accessible from bottom nav: add path to `_routes` map in `lib/features/shared/main_shell.dart`
   and add `NavigationDestination` to the `NavigationBar`

### Add a new locale
1. Copy `lib/l10n/app_en.arb` → `lib/l10n/app_xx.arb`, translate strings
2. Add `Locale('xx')` to `kSupportedLocales` in `lib/core/localization/l10n.dart`
3. Add radio entry in `lib/features/settings/settings_page.dart` `_LangTile` list
4. Run `flutter gen-l10n`

## ⚠️ Gotchas

- **Bottom nav index resolution** (`main_shell.dart:_indexFromLocation`) — checks specific paths
  (`/orders`, `/tables`, etc.) before defaulting to POS (`/`). Don't reorder the map without updating.
- **Cart panel** supports being mounted both in a `DraggableScrollableSheet` (phone) and inline
  (tablet) — pass `scrollController` from the sheet, otherwise it owns its own.
- **Order.fromMapRow** reads optional `item_count` column from the list query (LEFT JOIN COUNT).
  Don't remove the JOIN or `resolvedItemCount` will return 0 on list views.
- **Login page** PIN is hardcoded `1234` for demo. Real auth should live behind a repository.
- **iOS 26.3 simulator + Xcode 26.3** is the current test target. Older iOS may have emoji font gaps.

## 📦 Dependencies (why each one)

| Package | Why |
|---|---|
| `flutter_riverpod` | State management (settings, cart, catalog, orders) |
| `go_router` | Declarative routing + auth redirect |
| `sqflite` + `path` + `path_provider` | Local DB — swappable with REST |
| `shared_preferences` | Persist theme/locale/store info |
| `intl` | Money & date formatting (id_ID locale) |
| `uuid` | Order/item IDs |
| `cupertino_icons` | iOS-style icons fallback |
| `flutter_driver` + `integration_test` | E2E tests |

## 🔌 Backend migration path (for the backend team)

The repo is structured so swapping in REST is mechanical. For each repository in
`lib/data/repositories/`:

```dart
// Before (local)
Future<List<Product>> all() async {
  final db = await AppDatabase.instance.db;
  return (await db.query('products')).map(Product.fromMap).toList();
}

// After (REST)
Future<List<Product>> all() async {
  final res = await http.get(Uri.parse('$baseUrl/products'));
  return (jsonDecode(res.body) as List).map(Product.fromMap).toList();
}
```

UI code never changes. Recommended next step: introduce a `ApiClient` class and `dio` for
interceptors / auth headers, then migrate one repository at a time.

## 📝 Commit style

Conventional Commits — `<type>(<scope>): <subject>`:
- `feat(pos): add discount input to checkout`
- `fix(ios): bundle full MaterialIcons font to prevent tofu`
- `chore(deps): bump go_router to 14.8`
- `docs: add AGENTS.md`

Types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `style`, `perf`.
