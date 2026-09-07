# Phase 2 — Test Maturity

**Status:** Approved (2026-07-22)
**Scope:** Comprehensive test coverage (unit + widget + integration) for ALL existing features and use cases. No new product features, no redesign. Pure coverage hardening so the current feature set is mature and verified.

---

## 1. Context & motivation

Phase 1 shipped the glassmorphism redesign (merged to `main`). The app's test suite today is heavy on widget tests of the glass primitives (18 files) but has:
- **Zero unit tests** for models, cart math, formatters, providers, and repositories.
- **One smoke integration test** (`app_e2e_test.dart`: login + visit each tab) and a screenshot test — not per-use-case flows.

The product decision (owner-approved): before building new features (deferred), make the **current** features mature via exhaustive tests across three layers — unit, widget, integration — for every specific use case.

### Decomposition
This is one cohesive effort (test maturity) executed layer-first. It is large (~25–30 tasks) but single-subsystem (testing), so one spec + one plan. Execution is again subagent-driven, task-by-task, with the same review gates used in Phase 1.

---

## 2. Locked decisions

| Decision | Choice |
|---|---|
| Repository / DB testing | **`sqflite_common_ffi`** — real SQLite, in-memory, on the macOS test runner. Catches SQL + migration + query bugs (incl. the `LEFT JOIN COUNT` that backs `resolvedItemCount`). |
| Order of work | **Layer-first**: Layer 0 (infra) → Layer 1 (unit) → Layer 2 (widget) → Layer 3 (integration). Fast/foundational first; slow sim flows last. |
| Coverage target | **Exhaustive** — every model method, every screen state, every use-case flow. |

---

## 3. Layer 0 — Test infrastructure

**Dev dependency:** add `sqflite_common_ffi` to `dev_dependencies` in `pubspec.yaml`.

**`test/helpers/db_helper.dart`:**
- `Future<Database> setupInMemoryDb()` — calls `sqfliteFfiInit()`, sets `databaseFactory = databaseFactoryFfi`, opens the app's `AppDatabase` against an in-memory path (`:memory:` or a temp file), runs the migration chain to the current schema version (v4), optionally seeds.
- Per-test teardown closes the DB.
- Must NOT affect production code — `sqflite_common_ffi` only imported in test.

**`test/helpers/provider_helpers.dart`:**
- `ProviderContainer makeContainer({List<Override> overrides = const []})` — for provider tests; disposes in teardown.
- A helper that wires the in-memory DB into the repo singletons or a `databaseProvider` override so provider/repo tests hit the real in-memory DB.

**Verify early:** a smoke repo test (open in-memory DB, insert a product, read it back) must pass before any other Layer 1 work — this de-risks the `sqflite_common_ffi` setup on the macOS runner.

---

## 4. Layer 1 — Unit tests

Fast, deterministic, no Flutter binding required (where possible). TDD where it fits.

### 4.1 Models (`test/models/`)
For each model — `Order` (incl. `fromMapRow` reading optional `item_count`), `OrderItem`, `Product`, `Category`, `RestaurantTable`:
- `fromMap` ↔ `toMap` round-trip (every field preserved).
- `copyWith` (changed fields update, others preserved).
- Edge cases: null/missing optional fields; `Order.fromMapRow` without `item_count` → `resolvedItemCount == 0` (the gotcha CLAUDE.md flags); `Order.fromMapRow` with `item_count` → correct count.

### 4.2 Cart math (`test/cart/`)
`CartNotifier` behavior + computed values:
- `add`, `decrement` (removes line when qty hits 0), `removeLine`, `clear`, `setType`, `setTable`, `setDiscount` (if present).
- Computed: `subtotal`, `discountAmount`, `taxFor(rate)`, `totalFor(rate)`, `itemCount`, `isEmpty`, `lines` — across tax rates (0%, 11%), discount, all three `OrderType`s, dine-in with/without table.

### 4.3 Utils (`test/utils/`)
- `MoneyFormatter.format` / `.compact` / `.format(symbol:)` — typical amounts, zero, large numbers, symbol override.
- `DateFormatter.time` / date formats.
- `iconFromKey` — every whitelisted key resolves; an unknown key falls back to `restaurant`; `iconKeys` exposes the whitelist.

### 4.4 Providers (`test/providers/`)
- `SettingsNotifier`: each setter (`setThemeMode`, `setBrand`, `setLocale`, `setTaxRate`, `setCurrency`, `setStoreName`, `setStoreAddress`, `setCashierName`, `setLoggedIn`, `logout`) updates state correctly; persistence is stubbed/mocked.
- `placeOrderFromCart(ref)`: builds the order, calls the repo, and **invalidates** the right providers (`ordersProvider`, `tablesProvider` for dine-in, `dashboardSummaryProvider`, `topProductsProvider`) — assert invalidation happens.
- `catalog` notifier: `upsert`/`delete` invalidate `productsProvider`/`categoriesProvider`.

### 4.5 Repositories (`test/repositories/`) — real in-memory DB via `sqflite_common_ffi`
- `ProductRepository`: `all`, `upsert` (insert + update), `delete`, availability toggle (via upsert `available`).
- `CategoryRepository`: `all`, `upsert`, `delete`.
- `TableRepository`: `all`, `setStatus`.
- `OrderRepository`: `create` (writes order + items), `all` (returns rows WITH `item_count` from the LEFT JOIN COUNT — assert `resolvedItemCount`), `byId` (full items), `updateStatus`.
- **Migration test**: open DB at v1, assert v1 schema; run `_onUpgrade` chain to v4; assert each migration step's columns/data (v2 image_url/icon_key on products, v3 null dead image URLs, v4 category icon_key + backfill) applied correctly.

---

## 5. Layer 2 — Widget tests per screen

Each screen pumped with `ProviderScope` overrides (fake repos returning controlled data). Locale-agnostic assertions where possible (icons/types/keys), per CLAUDE.md. `pumpAndSettle` before asserting sheet content.

- **Login**: append digit, backspace, auto-verify at 4 digits, wrong PIN → error state + clear, correct PIN (`1234`) → `setLoggedIn(true)`.
- **Splash**: redirect to `/login` when logged out, `/` when logged in.
- **POS**: tap product → cart count increments; search filters list; category chip filters; popular chip filters; empty (no match) state; unavailable overlay; cart bar appears when cart non-empty.
- **CartPanel**: line add/dec/remove (incl. Dismissible swipe), `clear`, order-type segment switch, table field (dine-in), summary rows math, empty state.
- **CheckoutSheet**: payment method switch clears cash field; cash input + quick-cash chip + exact-cash button; change calc; place-order success → receipt shown; busy state disables button.
- **OrdersPage**: filter chips filter the list; order tile renders; empty + loading-skeleton states.
- **OrderDetailPage**: status flow (advance status), line items, totals; back.
- **TablesPage**: summary counts match data; table tile; status change via action sheet persists; "start order" navigates to POS.
- **DashboardPage**: stat row renders summary values; top-product bars; recent-order tiles; empty + loading-skeleton; refresh invalidates.
- **SettingsPage**: theme/brand/lang selection updates state; business edit dialogs save; reset confirm; logout; product-mgmt nav.
- **ProductManagementPage**: tab switch; product list; toggle available; add/edit form (validation, icon picker); delete confirm; category CRUD.

---

## 6. Layer 3 — Integration tests (real app + real DB on iOS sim)

Extend `integration_test/` with one file per flow (or grouped). Real `app.main()`, real sqflite (the app's own DB), locale-agnostic finds (icons/types/digit text — never translated labels). Each flow force-logs-out first to start clean.

- **`login_flow`**: wrong PIN → error; `1234` → land on POS.
- **`sell_flow`**: add product → cart badge → open cart → set cash → place order → success receipt → order appears in Orders → open detail → line items present.
- **`table_flow`**: open a table → change status → status persists after nav away/back; "start order" from an available table → POS.
- **`product_crud_flow`**: add a product → it appears in POS grid; edit it; toggle available → hidden from POS; delete → gone.
- **`category_crud_flow`**: add a category → it appears as a POS filter chip; edit; delete.
- **`settings_flow`**: change theme/brand/lang → persists across restart (re-launch app, assert still set); reset demo data → seeded state; logout → login screen.
- **`order_status_flow`**: from an existing order, advance pending → preparing → ready → served → paid, asserting the badge/status at each step.

The existing `app_e2e_test.dart` (smoke) and `screenshots_test.dart` stay green; these are additive.

---

## 7. Conventions

- **TDD** for unit tests (write failing assertion, implement/verify, green). Widget tests pump + assert behavior.
- **Locale-agnostic** test assertions (icons, widget types, keys, digit text) — never translated labels (CLAUDE.md rule).
- `sqflite_common_ffi` only in test code; production never imports it.
- **Commits:** Conventional Commits `test(<scope>): <subject>`. **No Claude co-author trailer.**
- Keep `flutter test` (unit + widget) green at every commit; integration tests run on the iOS sim (separate command).
- `flutter analyze lib test` clean (new test code; redirect if the `rtk` proxy masks output).

---

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| `sqflite_common_ffi` setup on macOS test runner | Layer 0 smoke test first (open DB, insert, read). If it fails, fix infra before any Layer 1 work. |
| Widget tests opening modal sheets (cart/checkout/forms) flaky in test binding | `pumpAndSettle` generously; assert on sheet content via descendant finds; isolate with `ProviderScope` overrides so no real DB needed for widget tests. |
| Integration flows need locale-agnostic navigation after the GlassNav redesign | Reuse the icon/index-based nav pattern already proven in `screenshots_test.dart` / updated `app_e2e_test.dart`. |
| Provider invalidation is easy to miss | `placeOrderFromCart` test explicitly asserts each expected invalidation. |
| Migration test requires constructing a v1 DB | Use `sqflite_common_ffi` to open a DB at the v1 schema manually, then drive `_onUpgrade` step-by-step. |

---

## 9. Non-goals

- No new product features (reservations, split payment, report export, discount input, order editing) — those remain Phase 2-features, deferred.
- No redesign / visual changes.
- No performance/benchmark tests.
- No change to production code unless a test surfaces a genuine bug (then a minimal `fix(...)` commit alongside the test, explained in the report).

---

## 10. Deliverable

A mature test suite: full unit coverage (models, cart math, utils, providers, repositories incl. migration), widget coverage for every screen's states and interactions, and integration coverage for every use-case flow — all green, locale-agnostic, with `sqflite_common_ffi`-backed real-DB repository tests. The current feature set is verified end-to-end.
