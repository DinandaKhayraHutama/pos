# Test Maturity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Exhaustive test coverage (unit + widget + integration) for every existing feature/use case of NTI POS — no new features, no redesign.

**Architecture:** Three layers, built layer-first. Layer 0 stands up `sqflite_common_ffi` in-memory DB test infra. Layer 1 unit-tests pure logic (models, cart math, formatters, icon map, providers, repositories + migration). Layer 2 widget-tests each screen's states/interactions with `ProviderScope` overrides. Layer 3 integration-tests each use-case flow end-to-end on the iOS simulator with the real app + real DB.

**Tech Stack:** Flutter / Dart · `flutter_test` (unit + widget) · `integration_test` (sim) · `sqflite_common_ffi` (real in-memory SQLite for repo tests) · Riverpod `ProviderContainer` / `ProviderScope`.

---

## Global Constraints

Copied verbatim from the spec + repo rules. Every task's requirements implicitly include these.

- **Locale-agnostic test assertions** — icons, widget types, keys, digit text. NEVER translated labels. (CLAUDE.md rule; the GlassNav redesign made icon/type finds essential.)
- **`sqflite_common_ffi` only in test code** — production never imports it. `databaseFactoryFfi`/`sqfliteFfiInit` only in `test/helpers/` and integration setup.
- **`shared_preferences` in tests** — use `SharedPreferences.setMockInitialValues({...})` (the package's built-in mock) for provider/prefs tests; no production refactor needed.
- **Keep `flutter test` (unit + widget) green at every commit.** Integration tests run on the iOS sim separately (`flutter test integration_test/<file> -d <sim>`).
- **No co-author trailer** on commits (user preference). Conventional Commits `test(<scope>): <subject>`.
- **TDD for unit tests** where it fits (write the failing assertion first, then minimal code to pass — for NEW test files against EXISTING production code, the "RED" is just running the new test before the suite has it; the production code already exists, so tests go GREEN on first real run unless they surface a bug).
- **If a test surfaces a genuine production bug**, fix it minimally in a separate `fix(...)` commit alongside the test, and explain in the report. Do NOT change production behavior to make a test pass unless it's a real bug.
- **iOS sim id:** `810AB071-8AFC-41C5-B526-02246E314C4B`.
- **`flutter analyze lib test` clean** for new test code (redirect to a file if the `rtk` proxy masks output: `flutter analyze lib test > /tmp/an.txt 2>&1; tail -20 /tmp/an.txt`).

---

## File Structure

**Test infra (Task 1)**
- Create `test/helpers/db_helper.dart` — in-memory `sqflite_common_ffi` DB factory + migration-to-current helper.
- Create `test/helpers/provider_helpers.dart` — `ProviderContainer` + `ProviderScope` pump helpers.
- Modify `pubspec.yaml` — add `sqflite_common_ffi` to `dev_dependencies`.

**Layer 1 — unit (Tasks 2–7)**
- Create `test/models/` (order_test, product_test, category_test, table_test, order_item_test).
- Create `test/cart/cart_math_test.dart`.
- Create `test/utils/formatters_test.dart`, `test/utils/icon_map_test.dart`.
- Create `test/providers/settings_provider_test.dart`, `test/providers/order_provider_test.dart`, `test/providers/catalog_provider_test.dart`.
- Create `test/repositories/` (product, category, table, order repo tests + migration_test).

**Layer 2 — widget (Tasks 8–16)**
- Create `test/features/<feature>/<feature>_test.dart` per screen.

**Layer 3 — integration (Tasks 17–23)**
- Create `integration_test/<flow>_test.dart` per use-case flow.

**Final (Task 24)** — full-suite verification.

---

## Conventions used in every task

- Run focused: `flutter test test/<file>`; full suite once before commit: `flutter test`.
- Integration: `flutter test integration_test/<flow>_test.dart -d 810AB071-8AFC-41C5-B526-02246E314C4B`.
- Commit per task. No co-author trailer.

---

## Task 1: Test infra — `sqflite_common_ffi` + in-memory DB helper + smoke test

**Files:**
- Modify: `pubspec.yaml` (`dev_dependencies: sqflite_common_ffi`)
- Create: `test/helpers/db_helper.dart`
- Create: `test/helpers/provider_helpers.dart`
- Test: `test/helpers/db_helper_smoke_test.dart`

**Interfaces:**
- Produces: `Future<Database> openInMemoryAppDb({int? toVersion})` in `db_helper.dart` — inits `sqfliteFfi`, sets `databaseFactory = databaseFactoryFfi`, opens the app DB at an in-memory path and runs migrations to the current version (or `toVersion`). `provider_helpers.dart` exposes `ProviderContainer makeContainer({List<Override> overrides})` and a `pumpScreen` helper if useful.

**De-risk:** this task MUST land first — it validates `sqflite_common_ffi` works on the macOS test runner. If it fails, stop and fix infra.

- [ ] **Step 1:** `flutter pub add dev:sqflite_common_ffi` (or edit `pubspec.yaml` `dev_dependencies` + `flutter pub get`).
- [ ] **Step 2:** Read `lib/data/database/app_database.dart` — learn `_version`, `_onUpgrade` steps, table schemas, the `db` getter, and how `AppDatabase.instance` is structured (it's a singleton with a `db` getter). The helper must construct an in-memory DB with the SAME schema the app uses.
- [ ] **Step 3: Write `test/helpers/db_helper.dart`:**
  ```dart
  import 'package:sqflite_common_ffi/sqflite_ffi.dart';
  import '../../lib/data/database/app_database.dart'; // adjust to real export

  Future<void> initFfi() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  // openInMemoryAppDb: call initFfi(), then open a DB via the app's schema-creation
  // code path against an in-memory path, return it. Reuse AppDatabase's table-creation
  // SQL (extract or replicate). Run _onUpgrade to current version.
  ```
  Adapt to how `AppDatabase` actually exposes schema creation — you may need to extract the `CREATE TABLE` statements into a reusable static, or call the same `_onCreate`/`_onUpgrade` the app uses, pointed at an in-memory DB. Keep production code working.
- [ ] **Step 4: Write smoke test** `test/helpers/db_helper_smoke_test.dart` — open in-memory DB, insert a product row, read it back, assert equal. This proves the infra.
- [ ] **Step 5:** `flutter test test/helpers/db_helper_smoke_test.dart` → pass. `flutter test` (all) → still 56/56 green. `flutter analyze lib test` clean.
- [ ] **Step 6: Commit:** `test(infra): add sqflite_common_ffi in-memory DB helper + smoke test`.

---

## Task 2: Unit — models round-trip + edge cases

**Files:** Create `test/models/order_test.dart`, `product_test.dart`, `category_test.dart`, `table_test.dart`, `order_item_test.dart`.

**Interfaces:** Consumes the model classes in `lib/data/models/`. Read each model for its exact `fromMap`/`toMap`/`copyWith`.

- [ ] **Step 1:** Read `lib/data/models/{order,order_item,product,category,table,enums}.dart`.
- [ ] **Step 2:** For each model write tests: (a) `fromMap(toMap(x)) == x` round-trip for every field; (b) `copyWith` updates only the passed fields; (c) edge cases. **`Order` specifically:** `Order.fromMapRow` WITHOUT `item_count` → `resolvedItemCount == items.length`; WITH `item_count: 5` and `items: []` → `resolvedItemCount == 5` (the `LEFT JOIN COUNT` gotcha); `Order.change == amountPaid - total`. Enums: `OrderTypeX.fromWire`/`PaymentMethodX.fromWire`/`OrderStatusX.fromWire` round-trip incl. default fallback for unknown wire value.
- [ ] **Step 3:** Run `flutter test test/models/` → green. Full suite green. analyze clean.
- [ ] **Step 4: Commit:** `test(models): add round-trip + edge-case unit tests`.

---

## Task 3: Unit — cart math

**Files:** Create `test/cart/cart_math_test.dart`.

**Interfaces:** `CartNotifier` is a `StateNotifier<CartState>` — instantiate directly: `final cart = CartNotifier();`. Methods: `add(product, {qty})`, `decrement(id)`, `setQuantity`, `removeLine`, `setType`, `setTable`, `setCustomerName`, `setOrderNote`, `setDiscountPercent`, `clear`. State getters: `lines, type, table, isEmpty, itemCount, subtotal, discountAmount, taxableBase, taxFor(rate), totalFor(rate), discountPercent`. `setType` clears table when `!= dineIn`. `setDiscountPercent` clamps 0–100. `rate` is a percent (e.g. 11 = 11%).

- [ ] **Step 1:** Read `lib/providers/cart_provider.dart` (already have signatures above).
- [ ] **Step 2:** Write tests covering: add new + add existing (qty stacks); decrement at qty 1 removes line; `setQuantity` to 0 removes; `removeLine`; `clear`; `setType` switches and clears table for non-dineIn; `setTable`; `setDiscountPercent` clamps (−5→0, 150→100, 25→25). Computed math: build a cart (2 products, qty 3 + 2), assert `subtotal`, with `discountPercent=10` assert `discountAmount`, `taxableBase`, `taxFor(11)`, `totalFor(11)`; assert `itemCount == 5`, `isEmpty` flips. Use a `Product` fixture (id/price set).
- [ ] **Step 3:** `flutter test test/cart/` → green. Full suite green. analyze clean.
- [ ] **Step 4: Commit:** `test(cart): add cart math + state transition unit tests`.

---

## Task 4: Unit — formatters + icon map

**Files:** Create `test/utils/formatters_test.dart`, `test/utils/icon_map_test.dart`.

**Interfaces:** `MoneyFormatter.format(value, {symbol})` → `'Rp 25.000'`-style (id_ID locale, 0 decimals). `MoneyFormatter.compact(value, {symbol})` → `'Rp 1,2 jt'` (≥1M), `'Rp 12 rb'` (≥1K, <1M), else `'Rp 500'`. `DateFormatter.time/dateTime/day/relative`. `iconFromKey(key)` whitelist + fallback `restaurant`; `iconKeys` exposes the whitelist.

- [ ] **Step 1:** Read `lib/core/utils/formatters.dart` (signatures above) + `lib/core/utils/icon_map.dart` (`_iconByKey` whitelist, `iconFromKey`, `iconKeys`).
- [ ] **Step 2:** Tests: `format(25000)` → starts with `'Rp '` and contains `'25.000'`; `format(0)`; `format(25000, symbol: '')` no symbol; `compact(1_200_000)` → contains `'jt'`; `compact(15_000)` → contains `'rb'`; `compact(500)` → contains `'500'`; `DateFormatter.time`/`dateTime`/`day` produce non-empty strings matching expected format for a fixed `DateTime`. `iconFromKey('restaurant')` returns a real `IconData`; an unknown key (`'__nope__'`) returns the fallback (`Icons.restaurant`); `iconKeys` is non-empty and every key resolves.
- [ ] **Step 3:** `flutter test test/utils/` → green. Full suite green. analyze clean.
- [ ] **Step 4: Commit:** `test(utils): add formatter + icon map unit tests`.

---

## Task 5: Unit — providers (settings, order, catalog)

**Files:** Create `test/providers/settings_provider_test.dart`, `order_provider_test.dart`, `catalog_provider_test.dart`.

**Interfaces:** `SettingsNotifier` is an `AsyncNotifier` reading `AppPreferences.instance()` (SharedPreferences singleton). Use `SharedPreferences.setMockInitialValues({...})` per test to seed prefs, then build a `ProviderContainer`, read `settingsProvider`, await `container.read(settingsProvider.future)`, call setters, assert state. `placeOrderFromCart(ref)` (in `order_provider.dart`) builds the order from cart + settings, calls `OrderRepository`, invalidates `ordersProvider`/`tablesProvider`(dine-in)/`dashboardSummaryProvider`/`topProductsProvider`. The `catalog` notifier (`catalog_provider.dart`) `upsert`/`delete` invalidate `productsProvider`/`categoriesProvider`.

- [ ] **Step 1:** Read `lib/providers/{settings_provider,order_provider,catalog_provider}.dart` + the repo classes they call.
- [ ] **Step 2 — settings:** with mock prefs seeded (theme dark, brand ocean, locale id, tax 11, currency 'Rp', storeName 'X'), `settingsProvider.future` resolves to a `SettingsState` matching; call `setThemeMode(light)` → state + (mock) prefs updated; `setBrand`, `setLocale`, `setTaxRate`, `setCurrency`, `setStoreName`, `setCashierName`, `setLoggedIn(true)`, `logout` (= loggedIn false) each update state. Dispose container.
- [ ] **Step 3 — order:** with an in-memory DB (Task 1 helper) + a `ProviderContainer` overriding the DB/repo to use it, seed a product, set cart (via `cartProvider`) with qty 2 dine-in + a table, call `placeOrderFromCart(container.read)` → an order exists in the DB and `ordersProvider`/`tablesProvider`/`dashboardSummaryProvider`/`topProductsProvider` are invalidated (assert by listening for invalidation, e.g. a listener container that re-reads). If wiring the real DB into the provider is heavy, assert the invalidations with a lighter fake repo override + verify the order was built correctly from cart state.
- [ ] **Step 4 — catalog:** `catalog` notifier `upsert(product)` invalidates `productsProvider`; `delete(id)` invalidates `productsProvider`/`categoriesProvider` as appropriate.
- [ ] **Step 5:** `flutter test test/providers/` → green. Full suite green. analyze clean.
- [ ] **Step 6: Commit:** `test(providers): add settings/order/catalog unit tests`.

---

## Task 6: Unit — repositories (real in-memory DB)

**Files:** Create `test/repositories/product_repository_test.dart`, `category_repository_test.dart`, `table_repository_test.dart`, `order_repository_test.dart`.

**Interfaces:** repos are singletons (`XRepository.instance`) that call `AppDatabase.instance.db`. Override `databaseFactory` (via Task 1 helper) so they hit in-memory. Read `lib/data/repositories/*.dart` for exact method names (`all`, `upsert`, `delete`, `setStatus`, `create`, `byId`, `updateStatus`, the list query with `LEFT JOIN COUNT`).

- [ ] **Step 1:** Read `lib/data/repositories/{product,category,table,order}_repository.dart` + how each gets its `db`. Wire `databaseFactoryFfi` in-memory into `AppDatabase.instance` before instantiating the repo (the helper from Task 1).
- [ ] **Step 2 — product:** insert via `upsert`, `all` returns it; `upsert` again (same id, changed price) updates; `upsert` with `available: false` toggles; `delete(id)` removes.
- [ ] **Step 3 — category:** same CRUD shape; delete behavior (does it cascade or block? match the repo's actual behavior).
- [ ] **Step 4 — table:** `all` returns seeded tables; `setStatus(id, occupied)` persists (re-read confirms).
- [ ] **Step 5 — order:** `create(order with 2 items)` writes order + items; `all()` returns rows and `resolvedItemCount == 2` (the `LEFT JOIN COUNT` — critical); `byId(id)` returns the order WITH its 2 items; `updateStatus(id, paid)` persists. This is the highest-value repo test (guards the JOIN gotcha).
- [ ] **Step 6:** `flutter test test/repositories/` → green. Full suite green. analyze clean.
- [ ] **Step 7: Commit:** `test(repositories): add real-DB CRUD unit tests`.

---

## Task 7: Unit — DB migration v1→v4

**Files:** Create `test/repositories/migration_test.dart`.

**Interfaces:** `lib/data/database/app_database.dart` `_version` (current = 4) + `_onUpgrade` steps. v2 added `image_url`/`icon_key` to products; v3 nulled dead seed image URLs; v4 added `icon_key` to categories + backfill. Use `sqflite_common_ffi` to open a DB at the v1 schema manually, then drive the upgrade.

- [ ] **Step 1:** Read `app_database.dart` — the v1 `CREATE TABLE`s and each `_onUpgrade` step (the `ALTER TABLE`/`UPDATE` SQL per version bump).
- [ ] **Step 2:** Test: open in-memory DB, run the v1 `_onCreate` (replicate the original schema WITHOUT v2/v3/v4 columns), insert a v1 product + category row, assert the v1 columns exist and v2/v4 columns do NOT. Then trigger `_onUpgrade` from 1→4 (call the app's upgrade function or replay the SQL). Assert: products now have `image_url` + `icon_key` columns; categories have `icon_key`; any seed row that v3 nulls is nulled. Each migration step's effect is verified.
- [ ] **Step 3:** `flutter test test/repositories/migration_test.dart` → green. Full suite green. analyze clean.
- [ ] **Step 4: Commit:** `test(db): add v1→v4 migration unit test`.

---

## Task 8: Widget — login + splash

**Files:** Create `test/features/auth/login_test.dart`, `test/features/splash/splash_test.dart`.

- [ ] **Step 1:** Read `lib/features/auth/login_page.dart` (PIN `_append`/`_backspace`/`_verify`, `_demoPin='1234'`, auto-verify at 4 digits) + `lib/features/splash/splash_page.dart` (redirect logic).
- [ ] **Step 2 — login:** pump `LoginPage` inside a `ProviderScope`+`MaterialApp`. Tap `1`,`2`,`3` → 3 dots filled, no verify. Tap `4` → `_verify` runs; with mock prefs / overridden `settingsProvider`, assert `setLoggedIn(true)` was called (or land past login). Wrong PIN (`1`,`1`,`1`,`1`) → error text appears + `_pin` clears (4 dots empty). Backspace removes a digit. Locale-agnostic (tap `find.text(digit)`).
- [ ] **Step 3 — splash:** pump `SplashPage` (or the router) with `settings.loggedIn=false` → redirects to login; with `loggedIn=true` → to POS. Assert via the `GoRouter` location or which page is mounted.
- [ ] **Step 4:** `flutter test test/features/auth/ test/features/splash/` → green. Full suite green. analyze clean.
- [ ] **Step 5: Commit:** `test(auth): add login + splash widget tests`.

---

## Task 9: Widget — POS screen interactions

**Files:** Create `test/features/pos/pos_page_test.dart`.

- [ ] **Step 1:** Read `lib/features/pos/pos_page.dart` (`_catalogBody`, `_searchField`, `_categoryChips`, `_openCartSheet`, `_OpenCartBar`) + how `productsProvider`/`cartProvider` are watched.
- [ ] **Step 2:** Pump `PosPage` in a `ProviderScope` overriding `productsProvider` (return a controlled `AsyncData([productA, productB])`) + `categoriesProvider`. Assert: grid shows 2 product cards; tap productA → `cartProvider` itemCount becomes 1 + cart bar appears; type in search → list filters; tap a category chip → filters by that category; tap "popular" chip → only popular products; search with no match → empty state. Locale-agnostic (find by `ProductCard` type, icon keys, `GridView`).
- [ ] **Step 3:** `flutter test test/features/pos/pos_page_test.dart` → green. Full suite green. analyze clean.
- [ ] **Step 4: Commit:** `test(pos): add POS interaction widget tests`.

---

## Task 10: Widget — cart panel

**Files:** Create `test/features/pos/cart_panel_test.dart`.

- [ ] **Step 1:** Read `lib/features/pos/cart_panel.dart` (`CartPanel`, `_CartLineTile` Dismissible, `_CartSummary`, `_TableField`, order-type segment).
- [ ] **Step 2:** Pump `CartPanel` with a `cartProvider` seeded via override (2 lines). Assert: 2 line tiles; summary subtotal/tax/total render; tap `+` on a line → cart updates; tap `−` at qty 1 → line removed; dismiss a line end-to-start → removed; tap "clear" → empty state; switch order type segment → `type` updates; dine-in shows table field. Locale-agnostic.
- [ ] **Step 3:** green; full suite green; analyze clean.
- [ ] **Step 4: Commit:** `test(pos): add cart panel widget tests`.

---

## Task 11: Widget — checkout sheet

**Files:** Create `test/features/pos/checkout_sheet_test.dart`.

- [ ] **Step 1:** Read `lib/features/pos/checkout_sheet.dart` (`CheckoutSheet` payment method, cash input, quick cash, change, place order, `_SuccessReceipt`).
- [ ] **Step 2:** Pump `CheckoutSheet` with a seeded cart (total known). Assert: payment method segmented (cash/qris/card); switching to qris clears cash field; cash input + tap quick-cash chip → amount set; exact-cash button → amount == total; change row appears when paid > total; tap place-order → busy spinner then success receipt shown (override `placeOrderFromCart` to a fake that returns a fixed order). Locale-agnostic.
- [ ] **Step 3:** green; full suite green; analyze clean.
- [ ] **Step 4: Commit:** `test(pos): add checkout sheet widget tests`.

---

## Task 12: Widget — orders + order detail

**Files:** Create `test/features/orders/orders_page_test.dart`, `order_detail_page_test.dart`.

- [ ] **Step 1:** Read `lib/features/orders/orders_page.dart` (`_FilterBar`, `_OrderTile`) + `order_detail_page.dart`.
- [ ] **Step 2 — orders page:** override `ordersProvider` with 3 orders of different statuses; assert 3 tiles; tap a status filter chip → only matching orders show; empty (`AsyncData([])`) → empty state; loading → skeleton. Locale-agnostic (find by `StatusBadge`/icon/order number text — order number is data, not localized).
- [ ] **Step 3 — detail:** pump `OrderDetailPage` with a seeded order (2 items, total); assert line items + totals + status; tap "advance status" → status updates (if the UI exposes it). Locale-agnostic.
- [ ] **Step 4:** green; full suite green; analyze clean.
- [ ] **Step 5: Commit:** `test(orders): add orders + detail widget tests`.

---

## Task 13: Widget — tables

**Files:** Create `test/features/tables/tables_page_test.dart`.

- [ ] **Step 1:** Read `lib/features/tables/tables_page.dart` (`_SummaryRow`, `_TableTile`, `_showActions` sheet, status chips, start-order).
- [ ] **Step 2:** Override `tablesProvider` with a controlled set across 1 floor. Assert: summary counts (total/available/occupied) match; tiles render; tap a tile → action sheet opens; tap a status chip in the sheet → `setStatus` called + persists (override the notifier, assert call); "start order" → navigates to POS. Locale-agnostic.
- [ ] **Step 3:** green; full suite green; analyze clean.
- [ ] **Step 4: Commit:** `test(tables): add tables widget tests`.

---

## Task 14: Widget — dashboard

**Files:** Create `test/features/dashboard/dashboard_page_test.dart`.

- [ ] **Step 1:** Read `lib/features/dashboard/dashboard_page.dart` (`_statsRow`, `_TopProductBar`, `_RecentOrderTile`, loading/empty).
- [ ] **Step 2:** Override `dashboardSummaryProvider`/`topProductsProvider`/`ordersProvider` with known data. Assert: stat row shows the revenue/orders/avg values; top products bars render with the seeded products; recent orders tiles render; empty → empty state; loading → skeleton; refresh action invalidates (listener). Locale-agnostic (numbers are data; assert via `find.text` on formatted money if deterministic, else via widget types).
- [ ] **Step 3:** green; full suite green; analyze clean.
- [ ] **Step 4: Commit:** `test(dashboard): add dashboard widget tests`.

---

## Task 15: Widget — settings

**Files:** Create `test/features/settings/settings_page_test.dart`.

- [ ] **Step 1:** Read `lib/features/settings/settings_page.dart` (theme/brand/lang tiles, business edit dialogs, reset confirm, logout, product-mgmt nav).
- [ ] **Step 2:** Pump `SettingsPage` with a `ProviderContainer` (mock prefs). Assert: tapping a theme chip → `setThemeMode`; tapping a brand swatch → `setBrand`; lang tile → `setLocale`; business tile → opens edit dialog → save → `setStoreName`/`setTaxRate`/etc; reset tile → confirm dialog → `resetDemoData`; logout button → `setLoggedIn(false)`. Locale-agnostic where possible (icons, dialog presence).
- [ ] **Step 3:** green; full suite green; analyze clean.
- [ ] **Step 4: Commit:** `test(settings): add settings widget tests`.

---

## Task 16: Widget — product management + forms

**Files:** Create `test/features/products/product_management_test.dart`, `product_form_test.dart`.

- [ ] **Step 1:** Read `lib/features/products/product_management_page.dart` (tabs, `_ProductListTile`, toggle, delete) + `product_form_sheet.dart` + `_CategoryFormSheet`.
- [ ] **Step 2:** Override `productsProvider`/`categoriesProvider`. Assert: 2 tabs (products/categories); product list tiles render; toggle available → `upsert` with `available:false`; delete → confirm dialog → `delete`; tap add → form sheet opens; fill name + price + pick icon + save → `upsert` called with correct fields; empty name → save disabled/no-op; category tab CRUD analogous. Locale-agnostic.
- [ ] **Step 3:** green; full suite green; analyze clean.
- [ ] **Step 4: Commit:** `test(products): add management + form widget tests`.

---

## Task 17: Integration — login flow

**Files:** Create `integration_test/login_flow_test.dart`.

- [ ] **Step 1:** Use the `app.main()` + force-logout pattern from `app_e2e_test.dart`. Locale-agnostic.
- [ ] **Step 2:** Enter wrong PIN (`1`,`1`,`1`,`1`) → error indicator visible (the 4 dots + error state; assert via the dot color widget or that we're still on login). Then enter `1234` → land on POS (assert `GridView`/store name present). 
- [ ] **Step 3:** Run `flutter test integration_test/login_flow_test.dart -d 810AB071-8AFC-41C5-B526-02246E314C4B` → pass.
- [ ] **Step 4: Commit:** `test(integration): add login flow`.

---

## Task 18: Integration — sell flow (the core POS path)

**Files:** Create `integration_test/sell_flow_test.dart`.

- [ ] **Step 1:** Login (`1234`), tap a product (cart badge increments), open cart, set cash (exact), place order → success receipt appears, dismiss → land back on POS; navigate to Orders → the new order tile is present; tap it → order detail shows the line item.
- [ ] **Step 2:** Locale-agnostic finds (icons, digit taps, `ProductCard`, `GridView`). Assert the order appears via the order number or a widget-type present in the detail.
- [ ] **Step 3:** Run on sim → pass.
- [ ] **Step 4: Commit:** `test(integration): add sell flow`.

---

## Task 19: Integration — table flow

**Files:** Create `integration_test/table_flow_test.dart`.

- [ ] **Step 1:** Login → nav to Tables → tap a table → change status to occupied → nav away (to POS) → nav back to Tables → that table still shows occupied (persisted). Also: from an available table, "start order" → navigates to POS.
- [ ] **Step 2:** Locale-agnostic. Assert status via the `StatusBadge` / icon on the tile.
- [ ] **Step 3:** Run on sim → pass.
- [ ] **Step 4: Commit:** `test(integration): add table flow`.

---

## Task 20: Integration — product CRUD flow

**Files:** Create `integration_test/product_crud_flow_test.dart`.

- [ ] **Step 1:** Login → Settings → product management → add a product (unique name, price, icon) → nav to POS → the new product appears in the grid (find by its card). Go back → edit the product (change price) → verify. Toggle available off → nav to POS → it's gone from the grid. Delete it → gone from management list.
- [ ] **Step 2:** Locale-agnostic. The product name is data (caller-entered), so `find.text(uniqueName)` is acceptable here.
- [ ] **Step 3:** Run on sim → pass.
- [ ] **Step 4: Commit:** `test(integration): add product CRUD flow`.

---

## Task 21: Integration — category CRUD flow

**Files:** Create `integration_test/category_crud_flow_test.dart`.

- [ ] **Step 1:** Login → Settings → product management → categories tab → add a category (unique name + icon) → nav to POS → the new category appears as a filter chip; tap it → filters. Edit + delete.
- [ ] **Step 2:** Locale-agnostic; category name is data.
- [ ] **Step 3:** Run on sim → pass.
- [ ] **Step 4: Commit:** `test(integration): add category CRUD flow`.

---

## Task 22: Integration — settings persistence flow

**Files:** Create `integration_test/settings_flow_test.dart`.

- [ ] **Step 1:** Login → Settings → change theme (dark), brand (ocean), language (id) → each applies live (assert a glass surface / nav present). Then terminate + relaunch the app (`simctl terminate` + `launch`) → the theme/brand/lang still apply (persisted). Then reset demo data → confirm → seeded state. Then logout → login screen.
- [ ] **Step 2:** Locale-agnostic; assert persistence via a visible token (e.g. the brand affects `colorScheme.primary` — pump and read; or assert the language flipped by an icon-only screen still rendering). Relaunch persistence is the key assertion.
- [ ] **Step 3:** Run on sim → pass.
- [ ] **Step 4: Commit:** `test(integration): add settings persistence flow`.

---

## Task 23: Integration — order status flow

**Files:** Create `integration_test/order_status_flow_test.dart`.

- [ ] **Step 1:** Seed an order (either via the sell flow or assume one exists from prior demo data). Open Orders → open the order → advance its status through pending → preparing → ready → served → paid, asserting the status badge updates at each step.
- [ ] **Step 2:** Locale-agnostic; assert via `StatusBadge` widget type / the status icon. (If no order is seeded, run the sell flow inline first to create one.)
- [ ] **Step 3:** Run on sim → pass.
- [ ] **Step 4: Commit:** `test(integration): add order status flow`.

---

## Task 24: Final verification

**Files:** none new.

- [ ] **Step 1:** `flutter test` (unit + widget) → all green. Capture the count.
- [ ] **Step 2:** Run every integration flow on the sim: `flutter test integration_test/<each>_test.dart -d 810AB071-8AFC-41C5-B526-02246E314C4B` → all pass. Keep `app_e2e_test.dart` + `screenshots_test.dart` green too.
- [ ] **Step 3:** `flutter analyze lib test integration_test` clean (redirect if rtk masks).
- [ ] **Step 4:** If any test surfaced a real production bug that was fixed during the run, confirm those `fix(...)` commits are in and explained.
- [ ] **Step 5:** Note the final test counts in a summary (no commit needed unless docs). If desired, append a "Testing" section to `AGENTS.md` listing the test commands + layer breakdown (optional `docs:` commit).
- [ ] **Step 6: Commit (if docs touched):** `docs: document the test suite layers + commands`.

---

## Self-review (run after writing)

**Spec coverage:**
- Layer 0 infra → Task 1. ✓
- Layer 1 models/cart/utils/providers/repositories/migration → Tasks 2–7 (every section in spec §4 mapped). ✓
- Layer 2 every screen → Tasks 8–16 (login, splash, POS, cart, checkout, orders, detail, tables, dashboard, settings, product-mgmt + forms — all enumerated in spec §5). ✓
- Layer 3 every flow → Tasks 17–23 (login, sell, table, product-crud, category-crud, settings, order-status — all in spec §6). ✓
- Conventions (locale-agnostic, sqflite_common_ffi test-only, no co-author, TDD, green per commit) → Global Constraints. ✓
- Risks (sqflite_common_ffi setup de-risked by Task 1 first; sheet-flakiness via pumpAndSettle; locale-agnostic nav; migration v1 construction) → addressed in Tasks 1, 7, + Global Constraints. ✓

**Placeholder scan:** none. Exact method signatures are quoted (cart methods, MoneyFormatter thresholds, Order.fromMapRow item_count) so implementers copy real symbols. Where a method name is uncertain (repo method names, exact `_onUpgrade` SQL), the task says "read the file first" and describes the assertion — concrete, not a placeholder.

**Type consistency:** `CartNotifier`/`CartState` field + method names match across Task 3 and the quoted source. `Order.fromMapRow`/`resolvedItemCount`/`change` consistent between Task 2 and source. `MoneyFormatter.format/compact` signatures consistent. `iconFromKey`/`iconKeys` consistent.

**One refinement logged:** spec §4.4 mentions `setDiscount` ("if present"); the actual API is `setDiscountPercent(int)` + state field `discountPercent` + computed `discountAmount`/`taxableBase`. Task 3 uses the real names. No spec edit required — the outcome (cart discount + tax math tested) is preserved.
