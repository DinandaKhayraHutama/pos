# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` holds the longer-form project memory (file map, common tasks, backend migration path). This file is the condensed operating guide; read `AGENTS.md` when you need more detail.

## Project

**JustClick POS** — Flutter restaurant Point of Sale app for FnB clients. Mobile-first (iOS + Android) with a responsive tablet/desktop split view. Offline-first on local SQLite, structured so the data layer can later be swapped for a REST API without touching UI code.

Stack: Flutter / Dart `^3.10.8` · Riverpod · go_router · sqflite · shared_preferences · intl.
Sign-in PINs come from the `employees` table, not a constant: `9999` (Farhan Sabili, **owner**), `1234` (Siwi Wiyono Raharjo, **manager**), `2345` (Siti Rahayu) / `3456` (Dani Rycki Dinata) (**cashiers**). The PIN identifies WHO is at the till, so orders, receipts and the dashboard greeting all follow the signed-in person — and WHAT they can reach, which differs substantially per role.

**Sign-in is two steps: pick the account, then type its PIN.** `AccountPicker` (`core/auth/account_picker.dart`) lists the active staff with initials, name and role; the keypad follows, under a `SelectedAccountHeader` that names the choice and offers a way back. A bare keypad assumed you already knew both that accounts existed and which one was yours, which hid the whole multi-cashier model on the first screen a client sees. The PIN is then checked against the **chosen row** (`EmployeeRepository.verify`), not globally — with `byPin` you could tap one name, type another person's PIN, and be signed in as them, making the choice theatre. Both flows that pick an account use this; the manager-override prompt deliberately does **not** (see below).

**Multi-cashier.** One device, several people through the day. The POS header carries an on-duty chip (initials → name → role); tapping it opens the same pick-then-PIN sheet and hands the till over, with the outgoing cashier's tile marked "on duty". The new person's name is what lands on every subsequent order, and they get their own shift and their own scoped history. **The cart deliberately survives the handover** — a shift change mid-order is the common case, and discarding a customer's basket to make the attribution tidy is the wrong trade. Going through the login screen instead would clear it, which is why `requestCashierSwitch` exists rather than a logout shortcut.

## Roles and permissions

Three roles, one table. `lib/core/auth/permissions.dart` maps each `EmployeeRole` to a set of `AppPermission`, and **screens ask for a permission, never for a role**:

```dart
if (settings.can(AppPermission.adjustStock)) ...
```

A `== EmployeeRole.manager` comparison in the UI is a bug waiting for the fourth role — it is also how a screen quietly keeps working for someone who should have lost it.

**The till belongs to cashiers only.** `sell` and `openCloseShift` are the `_till` set, and neither a manager nor an owner holds them — their focus is the data and the money. A manager or owner covering the counter signs in on a cashier account, which is also the honest outcome for attribution: the sale belongs to whoever was actually at the till and the drawer to whoever counted it. Consequences that are easy to miss:

- `homeRouteFor` sends **everyone except a cashier** to `/dashboard`; a manager landing on `/` would be bounced straight back out.
- `'/'` is in `routePermissions`. Hiding the tab is presentation; the router is what stops an owner typing `/` — one keystroke away on the web demo.
- Anything added to `routePermissions` must keep every role's `homeRouteFor` reachable, or `redirect` ping-pongs between two closed doors.
- `_owner` is `AppPermission.values.toSet().difference(_till)` — still derived, so a new permission still reaches the owner automatically.
- The E2E flows that drive the till sign in with `2345` (a cashier), not `1234`.

| | cashier | manager | owner |
|---|---|---|---|
| **Sell, open/close own shift (the till)** | ✅ | — | — |
| Seat and clear tables | ✅ | ✅ | ✅ |
| See own sales (today only) | ✅ | ✅ | ✅ |
| See all sales, all history | — | ✅ | ✅ |
| Void / refund, manual discount | — | ✅ | ✅ |
| Cash drawer for every open shift | — | ✅ | ✅ |
| Stock in/out with a reason | — | ✅ | ✅ |
| Dashboard (today's takings) | — | ✅ | ✅ |
| Outlets: open, rename, close a branch | — | ✅ | ✅ |
| POS/registers: add, configure, retire a till | — | ✅ | ✅ |
| Catalogue, prices, variants | — | — | ✅ |
| Sales report, profit, CSV | — | — | ✅ |
| Staff accounts and PINs | — | — | ✅ |
| Promotions | — | — | ✅ |
| Store config, demo reset | — | — | ✅ |

Enforcement is in **three** places and all three are load-bearing:

1. **`redirect` in `app_router.dart`**, against `routePermissions`. This is the one that actually holds — the demo runs on the web, where a typed URL walks past every hidden button. Adding a guarded route means adding a row to that map. One further gate sits beside it in the same `redirect` and answers a different question: `tableServiceRoutes` (does this till seat guests). The POS-session requirement — is this device signed on to a till at all — is **not** a `redirect` gate; see "POS registers and sessions" for why and where it actually lives.
2. **`MainShell`** derives its visible tabs from permissions, so a cashier's bar has four destinations and an owner's five. The selected index is computed from the *visible* list; a hardcoded index map is what made Settings highlight the wrong slot when Dashboard was hidden. Below 900dp those tabs render as `GlassNav` (bottom bar); at and above it as `GlassNavRail` (side rail) — one list, two presentations.
3. **Individual actions** — the void/refund buttons, the manual-discount field — check the permission themselves and fall back to the override prompt.

**The manager override.** `requestAuthorization(context, permission:, reason:)` in `core/auth/authorize_sheet.dart` asks someone senior to approve one action. The cashier stays signed in and keeps the cart; the approver's name is written onto the order. Signing out and back in would lose the cart and misattribute the rest of the shift. The prompt rejects a PIN that lacks the permission — including the cashier's own valid PIN.

## Multi-outlet

The business can have more than one branch. `outlets` is the table; **an outlet is not a register** — two tills at one counter share the shelf, the tables and the menu and only need telling apart for attribution, while two outlets share almost nothing.

Exactly what they share is a **product decision**, and every query that forgets it becomes a wrong number on a report:

| Per outlet | Shared across the chain |
|---|---|
| Stock (`outlet_stock`) | Menu, prices, variants |
| Floor plan (`tables.outlet_id`) | Promos |
| Sales, dashboard, sales report | Store identity, tax, currency |
| Stock ledger (`stock_movements.outlet_id`) | Staff accounts |
| Tills (`pos_registers.outlet_id`) and their sessions | |

**Which outlet a device is standing in is device-local** (`AppPreferences.outletId` → `SettingsState.outletId` → `activeOutletProvider`) and must never become a business-wide setting: the tablet in Bintaro and the tablet in Kemang are in different shops. Empty resolves to the first open outlet rather than refusing to sell — blocking the till over missing configuration is the worse failure. `AppPermission.manageOutlets` (manager + owner) gates `/outlets`.

`products.stock` still exists but **is no longer the truth about any shelf** — it is the catalogue's opening count. Reads `COALESCE(os.stock, p.stock)` so a product added after a branch opened is not invisible there; writes always go to `outlet_stock`. Every catalogue and table read takes a **required** `outletId`: there is no sensible "any outlet" answer, and a default would let a call site quietly ask the wrong shop.

Two rules that are easy to break:

- **Voiding credits the branch that SOLD the order**, read from `orders.outlet_id` — not the branch the person pressing Void is standing in. A manager can void a Kemang sale from the Bintaro tablet.
- **Every revenue aggregate carries the outlet predicate**, for the same reason they all carry `kRevenueStatusSql`: six figures scoped to one branch and a seventh summing the chain is a set of numbers that do not add up, and nobody notices until someone reconciles them. `report(outletId: null)` means the whole chain deliberately.

**Migration ordering is now structural.** `_onUpgrade` is split in two: per-version blocks that change the SCHEMA ONLY, then one deferred section that WRITES ROWS. Every writer builds rows from today's models, so it must run against the finished schema — `growFloorPlan` inserts `RestaurantTable.toMap()`, which grew an `outlet_id` at v15, and from a v1 install it ran three versions before that column existed and took the whole migration down. Anything that inserts or updates rows belongs in that deferred section, in an order where rows exist before they are filed under a branch. `_addColumnIfMissing` exists because an `ALTER TABLE ADD COLUMN` cannot assume the table is old: an earlier step may already have CREATEd it from today's schema.

A fresh seed **distributes** the demo month 60/40 across branches; an upgrade **does not** — an upgrading install's sales are real and all happened at the one shop it had, and splitting them would invent a history the owner never had.

## POS registers and sessions

An outlet has **tills**, and selling means being signed on to one. This is the Moka/Odoo shape: a cashier picks a POS and opens a session before any money moves, so every order can name the drawer it went into.

`pos_registers` is the table; `PosRegister` the model. A register belongs to exactly one outlet, and its name is unique **per outlet** — every branch is allowed its own "Kasir 1", and forcing "Bintaro Kasir 1" onto the button a cashier taps forty times a shift is the tail wagging the dog.

**`shifts` IS the POS session.** It already knew the cashier, the times and the money; v16 added `pos_id` / `pos_name` / `outlet_id` / `outlet_name` and `closed_by_id` / `closed_by_name`. Two rows describing one drawer is one row too many to keep in step, so there is no second table — and `/shift`, `ShiftRepository`, `shift_provider.dart` and every `shift*` l10n key stayed put.

The rules, and what breaks if you forget one:

- **The session belongs to the REGISTER, not the person.** The device's session id is device-local (`AppPreferences.posSessionId` → `SettingsState.posSessionId`), exactly like `outletId`. A handover via the on-duty chip therefore KEEPS it — `signIn(employee, keepPosSession: true)` — because the cash box does not change hands when the person in front of it does. Signing in from the login screen does **not** keep it; that path re-resolves, so nobody silently inherits somebody else's drawer.
- **One open session per till, enforced by a partial unique index** (`shifts(pos_id) WHERE closed_at IS NULL AND pos_id IS NOT NULL`), with `ShiftRepository.open` doing its check-and-insert inside one transaction. A UI check alone loses the race between two cashiers tapping Open together, and the loser gets a second drawer on a till that already has one — two expected balances for one cash box, unreconcilable afterwards. `RegisterBusyException` carries the holder's name so the picker can say who has it.
- **`ShiftRepository.totalsFor` attributes by `pos_session_id`, not by cashier-and-clock.** After a handover the second cashier's sales are physically in the same drawer and must count towards the same expectation. The query keeps a `pos_session_id IS NULL AND cashier_id = ? AND created_at BETWEEN ?` branch for sessions opened before v16, scoped so it can never double-count.
- **Session ids are UUIDs.** They used to be `shift_<millisecondsSinceEpoch>`, which is not unique — two tills opened in the same millisecond collided on the primary key and the second open silently lost its row.
- **`SettingsNotifier.logout()` still clears the session pref without closing the session** — that primitive is unchanged, and stays correct for the case that motivated it (a device simply forgetting which till it was on). But the **Settings screen's Logout button no longer calls it while a session is open.** `SettingsPage._handleLogout` checks `SettingsState.hasPosSession` first and, if true, shows a dialog explaining that the session has to be closed and offering a button straight to `/shift` — it never reaches `logout()` at all. This is a deliberate tightening over the primitive: a session a device merely *forgot* is recoverable (whoever opened it signs back in and it is still there to close), but a cashier who logs out is leaving for the day, and a drawer nobody is coming back to count is the exact failure the till exists to prevent. The on-duty handover (`requestCashierSwitch` / `signIn(keepPosSession: true)`) never calls `logout()` either, so it is untouched by this gate.
- **Closing a session re-asks for the SIGNED-IN cashier's own PIN**, the same way sign-in does. `_CloseShiftSheet`'s Close button no longer saves the count directly — `_confirmAndClose` first calls `requestSessionClosePin(context, employeeId:)` (`core/auth/authorize_sheet.dart`), which is `_PinPromptSheet` in its narrowest mode: `verifyAgainstEmployeeId` set, no picker, no permission check, PIN verified with `EmployeeRepository.verify(id:, pin:)` against that ONE id. A colleague's own valid PIN is rejected exactly like a wrong one — this is an identity re-check, not a manager override, so `requestAuthorization`'s "any senior" shape does not apply. Only a confirmed PIN reaches `_close()`, which is what actually writes `counted_cash` / `closed_by_*` and calls `closePosSession()`; a wrong PIN or a dismissed prompt leaves the session open and nothing written.
- **Sign-out clears the session pref without closing the session.** The drawer is still owed a count, which is the cashier's to make; the device simply stops being signed on, so the next person meets the picker and finds that till shown as taken. Whoever opened it adopts it again at sign-in — that is resolution step 2 in `SettingsNotifier._resolvePosContext`.

**Opening a session is NOT a router gate.** It used to be — `posSessionRoutes` redirected a cashier with no session from `/` to the pushed `/shift` route — and that was a bug: `/` is a `ShellRoute` tab, `/shift` is not, so the redirect took `MainShell` (bottom nav / rail) down with it and left a cashier who had just closed their drawer on a screen with no way to switch tabs. The fix moved the check INSIDE `PosPage`: `build()` reads `SettingsState.hasPosSession` itself and renders `PosSessionOpenCard` (the same widget `ShiftPage` shows when nothing is open, made public and shared — see its doc comment) in place of the catalogue when there is no session. Same URL, same `ShellRoute` child, so `MainShell` keeps painting the nav around it exactly as it does for every other tab — a cashier can freely tap Orders / Tables / Settings from the gate and come straight back to it. `/shift` itself is still a normal pushed route, reachable from Settings for session history and the manager's cash-drawer view; nothing routes there automatically any more.

**Table service is a per-register setting, not a store one.** `SettingsState.tableServiceEnabled` kept its NAME — so `MainShell`, `CartPanel`, `tableServiceRoutes` and `placeOrderFromCart` are untouched — but is now **derived**, resolved in `SettingsNotifier`:

1. the register of the open session, when there is one — the till the cashier is actually standing at;
2. otherwise whether ANY active register at the active outlet runs tables — the answer for a manager or owner, who never hold a session;
3. otherwise true, so an unconfigured store keeps the floor plan it has always had.

`AppPreferences.tableServiceEnabled` and the Settings switch are **gone**. Because that value lived in SharedPreferences where a DB migration cannot reach it, `SettingsNotifier._foldLegacyTableServiceIntoRegisters` carries it over once, guarded by a `table_service_migrated_to_registers` flag — without the flag it would re-apply on every launch and stamp over a per-till setting someone has since changed.

Anything that changes the answer must call `refreshPosContext()`: `setOutletId`, `openPosSession`, `closePosSession`, and `PosRegistersNotifier.save` / `remove`. There is no global invalidation layer.

Turning table service off **deletes nothing** — tables, their statuses and past orders' table names all survive, so a till that runs the floor plan sees the board exactly as it was. `placeOrderFromCart` enforces that: it reads the *current* flag rather than the cart, because a cart deliberately survives a handover to a cashier standing at the takeaway counter and would otherwise seat a guest at a board nobody can open.

Dine-in stays sellable with tables off — a warung where guests sit wherever they like is a real business, and dine-in-without-a-table is what that looks like.

`AppPermission.manageOutlets` gates `/registers` too. No new permission: the holder set would be identical (manager + owner), and a second row in the table is a second thing to keep in step.

`SettingsState.employeeRole` defaults to `owner` when unknown. That only happens for a session created before roles existed, and demoting such a user would take away screens they used yesterday.

## Table management

**A table's CONFIGURATION (name, capacity, area/floor, active) is a separate concern from its operational STATUS (available/occupied/reserved).** `RestaurantTable.active` (v21) is Manager/Owner setup — how many tables exist and what they're for — while `status` stays exactly what it always was: something a cashier flips as guests come and go. Neither field derives the other; deactivating a table does not touch its `status`, and clearing a table does not touch `active`.

**`TableManagementPage` (`/floorplan`, gated by `AppPermission.manageOutlets`) is deliberately a different screen from `TablesPage` (`/tables`, gated by `AppPermission.manageTables`)**, not an edit mode bolted onto the cashier board — the two routes need different permissions (a cashier holds `manageTables` to seat and clear guests, but must not be able to add or retire a table), so they cannot share a route the way `tableServiceRoutes` shares `/tables` between roles. Scoped per outlet, and linked from an `/outlets` row exactly like `/registers?outlet=` — reaching it through Settings would land on whichever branch the device happens to be standing in, the wrong one whenever somebody is configuring a shop they are not at.

**Deactivated, never deleted — the same call already made for `Outlet` and `PosRegister`.** `orders.table_id` / `table_name` are a snapshot copied at checkout (unenforced by any FK, exactly like `pos_id` / `pos_name`), so a deleted row wouldn't corrupt a single past receipt — but it would leave nothing for an admin to turn back on when a table comes back into use, and unlike a till or a branch a table was never going to accumulate a delete-blocking guard's worth of history queries, so there is no hard-delete path at all here, not even a blocked one.

**An inactive table can still be mid-service, and the floor board has to say so.** `TableRepository.operational(outletId)` — `active = 1 OR status != 'available'` — is what `tablesProvider` (the board) reads: a table deactivated while a guest is seated keeps showing, marked with a small eye-off glyph next to its status badge, so staff can still see it needs clearing. It drops off the board on its own the moment it returns to `available`, no separate cleanup step. `TableRepository.byOutlet(outletId, onlyActive: true)` — strictly active, regardless of status — is the stricter query behind `activeTablesProvider`, which every "start a NEW dine-in order" picker (`TablePickerSheet`, and `TablesPage`'s own "Start order" button, which only ever offers an `available` table in the first place) reads instead. Two providers over one repository, same split `PosRegisterRepository.byOutlet`/`registerSlotsProvider` already established for tills: the admin screen's `tableManagementProvider` (a family by outlet, sees inactive rows too, so there is something to switch back on) is the third leg of that shape.

**Floor/area is free text (v21), not the `floor_1`..`floor_4` set it used to imply.** Table count and area names are per-outlet configuration, not a fixed template — a business with two floors and one with a rooftop terrace both use the same field, and it stores whatever the admin typed and shows it back verbatim (`TableManagementPage`'s grouping just sorts on that string). Rows seeded before this was editable still render through `TablesPage`/`TablePickerSheet`'s existing `floor_1..4 → localized label` switch for backward compatibility; a table created through the management screen bypasses that switch entirely because its `floor` is never one of those literal keys.

## Product modifiers and category sales

**A modifier group is reusable; it is not a second `ProductVariant`.** A variant is a single-select axis baked onto the product row (Regular/Large). A modifier group (`modifier_groups` + `modifier_options`) is defined once and attached to as many products as apply through the join table `product_modifier_groups` — "Level Pedas" is one row, not one per dish that can be spicy. A group is `single` or `multiple` selection, optionally `required`, and a `multiple` group can cap the count with `maxSelect`. Both systems sit on the same product independently: `_addToCart` resolves a variant first (unchanged), then uses valid product defaults; it opens `ModifierPickerSheet` when an active required group still needs a choice — a product with neither stays one tap.

**A required group with zero active options never blocks a sale.** `ModifierPickerSheet._canSubmit` treats that as vacuously satisfied — same call as `_outletRunsTableService` defaulting to `true` when there's no register to ask. An admin's mistake (or disabling every option in a group already live on a product) must never make that product unsellable. `_ModifierGroupFormSheet` shows a non-blocking warning banner for the identical condition — an earlier chance to notice, not a second gate.

**Attaching a group to a product is not the same as offering all its options.** `product_modifier_groups` says a product uses "Topping"; `product_modifier_options` (v18) says WHICH of Topping's options it shows — a food item and a coffee can both attach the same reusable group and each display a different subset (or, for a single-select group like "Level Pedas", a different NUMBER of choices). This is a second join table rather than a flag on `product_modifier_groups`, because it has its own FK target (`modifier_options`, not `modifier_groups`) and its own lifecycle: deleting an OPTION must drop it from every product's scope, independent of the group surviving. `ModifierPickerSheet` needed no changes for this — `pos_page.dart`/`cart_panel.dart` already resolve `{group, options}` pairs before the sheet ever opens, so scoping is just one more `.where()` at that resolution point; a product scoped to zero options in a group hits the exact same "vacuously satisfied" path a misconfigured admin group already did.

**A newly-attached group defaults to ALL its active options, then the admin narrows it down.** `_ModifierGroupPicker` in `product_form_sheet.dart` seeds `_selectedOptionIds` from every active option the moment a group's `FilterChip` is toggled on — matching what catalogue-wide attachment used to give for free, so turning a group on still shows something useful before anyone touches the per-option chips beneath it. Toggling the group back off drains its option ids back out of the flat set; both directions are folded into one `setOptionScopeForProduct` write on Save, alongside `setGroupsForProduct`, so a half-applied save is not possible.

**`ModifierRepository.replaceOptions` had to stop being a delete-then-reinsert, once `product_modifier_options` existed to break.** It looked harmless when nothing referenced `modifier_options.id`: whole-list replace, same shape as `setGroupsForProduct`. But `product_modifier_options` has `FOREIGN KEY (option_id) REFERENCES modifier_options(id) ON DELETE CASCADE`, and `INSERT OR REPLACE` — which looks like the obvious way to keep this a one-liner — does NOT dodge that: SQLite's REPLACE conflict resolution physically deletes the pre-existing row before reinserting, firing `ON DELETE CASCADE` even though the same id comes right back a moment later. Under the old delete-all-then-reinsert-all shape, or under `INSERT OR REPLACE`, editing a group's price or adding one new option would silently wipe every product's scoping for every option in that group. `replaceOptions` now diffs against the existing rows: options that survive the edit (same id) get a plain `UPDATE`, which never touches `ON DELETE CASCADE`; only options genuinely dropped by the admin are `DELETE`d, correctly taking their scoping with them. `test/repositories/modifier_repository_test.dart`'s "replaceOptions on the group PRESERVES scoping" case is what catches a regression here — read it before changing this method again.

**`order_item_modifiers` carries no FK to `modifier_groups` / `modifier_options`.** Same call as `pos_registers` / `outlet_stock`: the table is written mid-checkout-transaction, and a catalogue-consistency failure there must never abort a customer's sale. What it stores — `group_name` / `option_name` / `price_delta` — is a **snapshot** copied at the moment of sale, so deleting a group or an option later never rewrites a past receipt. Its one enforced FK is to `order_items` itself.

**`order_items.category_id` / `category_name` are resolved inside `OrderRepository.create()`, never through a Riverpod provider.** They're snapshotted the same way `product_name` / `variant_name` already are, but the resolution is two plain `WHERE id IN (...)` reads — `products` then `categories` — run against `productId` alone, inside the same transaction that writes the order. Not a watch on `categoriesProvider`: an `AutoDisposeAsyncNotifier` is fine for a screen that's demonstrably mounted (`activeOutletProvider` today), but a financial snapshot written at checkout shouldn't depend on some other widget happening to be listening. `placeOrderFromCart` and `CartLine` know nothing about categories at all.

**The category breakdown on the sales report groups by `category_id`, not by name — unlike `byCashier`.** A renamed or departed cashier's old and new history is generally *not* expected to merge; a category renamed mid-range is expected to stay one continuous bucket. `OrderRepository.report()`'s category query and `aggregateCategorySales` resolve a display name in priority order: the **live** `categories.name` (LEFT JOIN) when the category still exists, else the **most recent** snapshot name for that id (by `order_created_at`), else `CategorySales.uncategorizedId` — reserved for rows with no `category_id` at all (a product deleted before v17 ever ran, so nothing was ever snapshotted). Two different ids that happen to share a name stay two separate rows on purpose.

**Discount is allocated to each category with the largest-remainder method, not independent division** — so `Σ(category.netSales)` reconciles to `subtotal − discount` **exactly**, not approximately. A naive `floor(discount × categoryLineTotal / subtotal)` per category leaves a rounding remainder unaccounted for; `aggregateCategorySales` sums the floors per order and hands the leftover to the one category with the largest line total in that order (ties broken by `category_id` string order, so it's deterministic either way). Two real bugs shipped in the first draft of this function and were only caught by its unit tests: net was computed as the discount *share* itself rather than gross minus that share, and a name-resolution guard blocked a newer snapshot name from ever overwriting an older one for the same id. Read `test/repositories/order_repository_report_test.dart` before changing the aggregation.

**The category breakdown is pre-tax and pre-service-charge on purpose.** Gross/Net Sales are standard pre-tax accounting terms, and PB1 and Service Charge already have their own lines in the report (Subtotal → Discount → Service Charge → PB1 → Revenue) — allocating either per category would be a second proportional split nobody asked for. `Σ(byCategory.netSales)` therefore matches `subtotal − discount`, **not** `report.revenue`. Both the on-screen section and the CSV export carry that caveat explicitly, the same way `_ProfitSection` carries its own gross-vs-net-profit caveat.


**Per-product defaults (v20).** `product_modifier_options.is_default` defaults to 0; upgrades retain every allowed option without inventing a default. `saveConfiguration` validates and commits group attachments, scoped options, and defaults in one transaction. Defaults must be scoped, active options and respect single/multiple caps. Product/group updates use UPDATE, not SQLite REPLACE, which would cascade-delete modifier relationships. Catalogue changes are resolved defensively: inactive/deleted defaults are ignored and reduced caps trim selections in catalogue order.

The product form shows attached-group summaries. `ProductModifierConfigPage` owns a draft with searchable, expandable groups, applicable-option checkboxes and default stars. Cancel/Back discards the editor draft; Save returns it to the form, and only saving the product writes it to SQLite. Add resolves variants first, then uses defaults directly if all active required groups are satisfied. Optional choices can be changed by tapping the cart line; editing uses the existing selection, never reapplies defaults. POS waits for modifier configuration before enabling the catalogue, so loading cannot bypass required choices. Different selections split cart lines, and checkout sums their quantities per product for stock. Transaction snapshots continue to store the selected labels/prices independently of catalogue settings.

**Full-width themed buttons inside Row must be flex children.** The FilledButton theme uses `Size.fromHeight(52)` (infinite minimum width). A plain FilledButton inside Row receives unbounded width and throws `BoxConstraints forces an infinite width`; a modal barrier may then remain visible while its body fails to paint. Wrap the button in Expanded/Flexible or give it an explicit finite width. This caused the first modifier configuration editor to appear frozen.
## PB1 and Service Charge

**What was one flat "tax" is now two independent charges.** PB1 (Pajak Restoran) is what `SettingsState.taxRate` already was, renamed to `pb1Rate` for clarity now that a second charge exists alongside it — `AppPreferences`'s SharedPreferences key stays the literal string `'tax_rate'` and `orders.tax` stays the literal column name, both deliberately unchanged, because renaming either buys nothing behaviorally and each is read/written from enough call sites that the rename would be pure risk. Service Charge is new: a single global percentage (`serviceChargeRate`), independently toggled (`serviceChargeEnabled`) — no per-product override the way PB1 has one, because a service charge is a blanket restaurant policy, not a tax classification like a zero-rated item.

**Service Charge is computed first, and PB1's base includes it — not two independent charges on the same subtotal.** `CartState`'s chain is `subtotal → discountAmount → taxableBase → serviceChargeFor(rate) → pb1For(pb1Rate, serviceChargeRate)`, where `pb1For`'s per-line base is `lineTotal − discountShare + serviceChargeShare` (the service-charge share is computed and added to each line's base exactly the way the discount share already was, before this feature existed). This is the standard Indonesian restaurant/hotel receipt convention — PB1 taxes the full amount a customer pays for F&B service, which includes the service charge — confirmed with the business owner before implementing, since guessing the wrong order here is a compliance-shaped bug, not a cosmetic one. `totalFor` is `taxableBase + serviceCharge + pb1`. Service Charge itself has no per-line variant: it's one flat calculation on `taxableBase`, rounded half-up once, since there's no per-product override to honor the way PB1's loop exists for.

**PB1 defaults to 10% for an install that has never configured it — but only that install.** `AppPreferences.pb1Rate` uses `containsKey`, not a plain `?? 10.0` fallback: a store that already set a rate (11%, or even a deliberate 0%) keeps exactly that number after upgrading to v19, while only a genuinely absent key (a fresh install, or an old install that never touched the setting) resolves to 10%. A plain `getDouble(...) ?? 10.0` cannot tell "never configured" apart from "explicitly set to 0.0", and bumping every store's actual configured rate to 10% on upgrade would be the wrong kind of surprise for someone who'd already set 11%. Service Charge has no such ambiguity to resolve — it's a brand-new concept, so `serviceChargeEnabled` defaults to `false` and `serviceChargeRate` to `5.0` for every install, fresh or upgrading, with a plain `??` fallback: an opt-in charge must never silently start appearing on a bill nobody configured.

**`orders` snapshots both the rate AND the amount for each charge, not just the amount** — the gap the old single `tax` column had (no way to know what rate produced it, so a later Settings change couldn't be told apart from history on an old receipt). `pb1_rate` / `service_charge_rate` are nullable and stay NULL for a pre-v19 row: the exact rate in effect back then is genuinely unrecoverable if the store's configured rate ever changed, the same reasoning that already leaves `order_items.category_id` NULL for an orphaned pre-migration line rather than guessing. `service_charge_amount` is NOT NULL, defaulting to `0` for those same old rows — that zero is a fact (the feature did not exist yet), not a guess. None of the three are touched by void/refund, exactly like `subtotal`/`discount`/`tax` already weren't — pure historical snapshot.

## Commands

```bash
flutter pub get
flutter run                     # day-to-day dev
flutter run -d macos            # best for exercising the ≥900dp split layout
flutter analyze                 # lint (flutter_lints)
flutter test                    # unit + widget
flutter test test/widget_test.dart -n "substring of test name"   # single test
flutter gen-l10n                # regenerate lib/l10n/gen/ after editing .arb files
```

E2E on an iOS simulator:

```bash
flutter test integration_test/app_e2e_test.dart -d <ios-sim-id>
```

The E2E test force-logs-out, enters PIN `1234`, taps a product, and visits every tab. Assertions are deliberately **locale-agnostic** (icons, `GridView`, widget types — never localized text). Keep new assertions that way.

### iOS builds — MANDATORY flag

Material Icons must not be tree-shaken or the `_outlined` / `_rounded` icon variants render as tofu boxes on iOS:

```bash
flutter build ios --debug --simulator --no-codesign --no-tree-shake-icons
xcrun simctl install <device-id> build/ios/iphonesimulator/Runner.app
xcrun simctl launch <device-id> com.example.ntiPos
```

`flutter run` does **not** accept `--no-tree-shake-icons`; use macOS desktop for iteration, or this build+install pattern for iOS.

### Web — the demo channel

Web is how the app gets shown remotely (a static bundle behind ngrok), so it has to keep working.

```bash
flutter build web --release          # produces build/web — a single static bundle
(cd build/web && python3 -m http.server 8080)
```

Two things make web different, both already wired up:

- **`sqflite` and `path_provider` have no web implementation.** [db_platform.dart](lib/data/database/db_platform.dart) is the seam: a conditional export picks [db_platform_io.dart](lib/data/database/db_platform_io.dart) (documents dir + default factory) on native, and [db_platform_web.dart](lib/data/database/db_platform_web.dart) (SQLite-on-wasm + IndexedDB) on web. `AppDatabase._open` just calls `configureDatabaseFactory()` then `resolveDatabasePath()`. Nothing above the database layer knows which platform it is on. Before this seam existed, every DB-backed screen on web rendered empty with `MissingPluginException(... getApplicationDocumentsDirectory ...)`.
- **`web/sqlite3.wasm` is committed and version-locked.** It must match the resolved `sqlite3` version in `pubspec.lock`; see the re-download command in the header of `db_platform_web.dart`. The upstream `dart run sqflite_common_ffi_web:setup` generator does **not** work on this toolchain (it shells out to `webdev`, which fails with "'dart compile' does not support build hooks" on Dart 3.10), which is why the app uses `databaseFactoryFfiWebNoWebWorker` — that path needs only the wasm, no generated worker.

**Testing gotcha that will waste your time:** Flutter registers a service worker, so a reloaded page happily serves the *previous* build and your fix looks like it did nothing. Always unregister it before judging a change:

```js
const r = await navigator.serviceWorker.getRegistrations(); for (const x of r) await x.unregister();
const k = await caches.keys(); for (const c of k) await caches.delete(c);
```

Also note **release web builds hide errors**: Flutter's release `ErrorWidget` is a blank box, so a crash looks like a plain white page. Reproduce with `flutter run -d web-server --web-port=8900` to get the real exception in the browser console.

**A stale `web_plugin_registrant.dart` silently disables a web plugin — run `flutter clean` after adding one.** The registrant is generated into `.dart_tool/flutter_build/<hash>/` and the incremental build can keep serving an old copy: `printing` was in `.flutter-plugins-dependencies` for a full day while the cached registrant still listed only `SharedPreferencesPlugin`. The symptom is not a build error. `Printing.layoutPdf` falls through to the method-channel implementation, which on web throws `MissingPluginException`, so "Print receipt" simply did nothing — and in a release build the exception surfaces as a bare `Error` with no message. To check:

```bash
find .dart_tool/flutter_build -name web_plugin_registrant.dart -exec grep registerWith {} \;
```

Every web plugin in `pubspec.yaml` must appear there. If one is missing, `flutter clean && flutter pub get && flutter build web --release`.

## Architecture

```
lib/features/**  →  lib/providers/**  →  lib/data/repositories/**  →  sqflite
   (UI only)        (Riverpod)            (only layer touching the DB)
```

- **`lib/data/repositories/*_repository.dart`** — singletons (`XRepository.instance`), the *only* place that talks to sqflite. Swapping to REST means replacing method bodies here; models and UI stay untouched.
- **`lib/data/models/*.dart`** — plain Dart classes with `fromMap` / `toMap` / `copyWith`. No framework imports.
- **`lib/providers/*_provider.dart`** — Riverpod. `settingsProvider` is a root `AsyncNotifier`; catalog/orders/tables are `AutoDisposeAsyncNotifier`. Feature pages never import sqflite.
- **`lib/features/<feature>/`** — screens only.

### Bootstrap and routing

`main.dart` watches `settingsProvider` and only builds `MaterialApp.router` once settings resolve (a bootstrap scaffold covers loading/error). `routerProvider` (`lib/core/router/app_router.dart`) redirects on `settings.valueOrNull?.loggedIn`: `/splash` → `/` or `/login`, and any non-`/login` path while logged out → `/login`.

Tabbed routes (`/`, `/orders`, `/tables`, `/dashboard`, `/settings`) live inside a `ShellRoute` rendering `MainShell`. `/orders/:id` and `/products` sit outside the shell.

### State refresh convention

There is no global cache invalidation layer. After a write, the caller explicitly calls `ref.invalidate(...)` on the affected providers — see `placeOrderFromCart` in `lib/providers/order_provider.dart` (invalidates `ordersProvider`, plus `tablesProvider` when a dine-in table was assigned). When you add a write path, invalidate every provider whose data it changes, including `dashboardSummaryProvider` / `topProductsProvider` for anything revenue-related.

Note: `checkoutProvider` is a decoy — it throws `UnimplementedError` on purpose. Checkout goes through the `placeOrderFromCart(ref)` function.

## Checklist for every new screen or widget

Localization, theming, and responsive behaviour are **not optional polish** — they are part of "done" here. Before considering any new feature complete:

1. **No literal user-facing strings.** Every label, button, hint, error, empty state, snackbar, and dialog goes through `context.l10n.someKey`. Add the key to **both** `app_en.arb` and `app_id.arb` (never only one), then run `flutter gen-l10n`. The only strings that stay literal are the brand name and data coming from the DB.
2. **No literal colors.** Nothing hardcoded — resolve from `context.design.*` (the `BrandColors` `ThemeExtension`: accents, surface tiers, text tiers, glass presets, semantic colors) or `Theme.of(context).colorScheme.*` for Material roles (now token-backed, built from the same `BrandColors`); `context.semantic` is a kept alias of `context.design`. The widget must look correct in light **and** dark mode, and under every `BrandPreset`, because each brand ships hand-tuned light + dark tokens — there is no seed derivation to hide behind.
3. **No magic spacing.** Use `AppDimensions` constants rather than inventing padding/radius values.
4. **Layout survives phone → tablet.** Never assume a phone width. Switch layout on `AppDimensions.tabletWidth` (900dp), or use an intrinsically fluid delegate. Grids should use `SliverGridDelegateWithMaxCrossAxisExtent` (as `tables_page.dart` does) unless a fixed column count is genuinely required.
5. **Never size a grid tile with `childAspectRatio` when the tile contains text.** A ratio is a guess about height, and text height depends on the user's `textScaler` (main.dart allows up to 1.15), so the guess eventually clips the card. Compute a `mainAxisExtent` from the tile width instead — `productCardExtent` in `product_card.dart` is the worked example, and `test/product_card_layout_test.dart` locks it down. Reserve **whole pixels per text line** (`ceilToDouble`): paragraph line heights round up, and reserving the exact fractional height overflows by a fraction of a pixel.
6. **New tests stay locale-agnostic** — assert on icons, widget types, and keys, never on translated text.

> **Testing policy:** do **not** write widget/integration/E2E tests for new features by default — verify via the `dart` MCP + simulator/Playwright instead. Unit tests (models, repositories, formatters, cart math) are still written; existing regression guards are kept. Full rules: [.claude/rules/testing-policy.md](.claude/rules/testing-policy.md).

### The one legitimate exception

`_BootstrapScaffold` in `main.dart` hardcodes its **text** ("JustClick POS", the brand name) because it renders in the `loading` / `error` branches of `settingsProvider`, before `MaterialApp.router` and therefore before `AppLocalizations` exists. Nothing else in the app has that excuse. The same exemption covers the wordmark in `GlassNavRail`'s header — a product name is not a translatable string.

Its **colors are not exempt**. `main()` awaits `AppPreferences.instance()` before `runApp` and passes the saved `BrandPreset` / `ThemeMode` into `NtiPosApp`, so even the bootstrap `MaterialApp` carries a real theme and `_BootstrapScaffold` resolves `colorScheme.primary` like everything else. It used to paint `Colors.orange.shade400`, which read as "the brand colour never applied" on every launch after the user picked a different brand. If you add anything to the bootstrap branches, theme it — the `ColorScheme` is there.

### Coverage reality check

Only `pos_page.dart` and `main_shell.dart` currently react to the tablet breakpoint. The other feature pages are single-column lists that happen to scale, and `tables_page.dart` is fluid via `maxCrossAxisExtent`. So "the app is responsive" holds fully for POS only — verify any new screen at ≥900dp yourself rather than assuming the surrounding code already handles it.

**The side rail collapses**, and the choice is remembered (`AppPreferences.navRailExpanded` → `SettingsState.navRailExpanded`). That preference is deliberately **nullable**: null means "never toggled", which lets `MainShell` default from the window — expanded at ≥`AppDimensions.desktopWidth` (1180), collapsed below, because a 248dp rail is a quarter of a 900dp tablet and most of that is empty label space. Once someone toggles it, their choice wins at every width; an expanded rail on a 950dp window does squeeze the POS split to two product columns, which is the honest cost of honouring the choice rather than overriding it.

Rows in the rail are always laid out at the **expanded** width and clipped by the animating container, with labels faded via `AnimatedOpacity`. Rebuilding them per intermediate width would relayout text on every frame and overflow on the way through; fading means the text is gone before the clip reaches it. Anything added to the rail needs the same treatment — the on-duty footer was missed at first and its name bled through the clip as two sliced letters.

## Conventions that matter

### Theming — hand-tuned tokens, never hardcode colors

Colors come from hand-tuned `BrandColors` tokens (a `ThemeExtension` in `lib/core/theme/brand_colors.dart`), NOT a seed. `AppTheme._build` (`lib/core/theme/app_theme.dart`) constructs `ColorScheme` MANUALLY from the active `BrandColors`; there is no `ColorScheme.fromSeed` anywhere in the app. Each `BrandPreset` (`lib/core/theme/app_colors.dart`) carries a `BrandAccent` payload that `BrandColors.fromAccent` merges onto a shared neutral base — separately for light and dark — so both brightnesses are hand-tuned per brand.

Resolve colors through:
- `context.design.*` — the superset: primary/secondary/tertiary (+ containers), surface tiers (`surfaceBase` / `surfaceRaised` / `surfaceOverlay`), text tiers (`textHigh` / `textMedium` / `textLow`), glass presets (`glassTint` / `glassBorder` / `glassBlurSigma` / `glassOpacity`), substrate (`gradient` / `blobs`), semantic (`success` / `warning` / `info` / `error` + containers).
- `context.semantic.*` — alias of `context.design` for legacy call sites; same instance. Prefer `context.design` in new code.
- `Theme.of(context).colorScheme.*` — works because the `ColorScheme` is built from the same tokens; use it for standard Material roles.

`AppBackground` (`lib/core/widgets/app_background.dart`) paints the brand gradient + blobs substrate behind every screen — `MainShell` provides it for tabbed routes, pushed routes wrap themselves. Glass primitives (`GlassCard` + `.solid`, glass buttons, `GlassSheet` / `showGlassSheet`, `GlassAppBar`, `GlassTextField`, `GlassSegmented`, `GlassFilterChip`, `GlassStepper`, `Skeleton`, `GlassNav` / `GlassNavRail`) live in `lib/core/widgets/glass/`; prefer them over raw `Card` / `Container` / `AppBar`. The bundled typeface is Plus Jakarta Sans (static 400 / 500 / 600 / 700 in `assets/fonts/plus_jakarta/`), set globally in `AppTheme._build`.

The default brand is **`nti`** — NTI's own deep blue, and `BrandPreset.presets.first`, which is also what `byId` falls back to. The two are kept in step by a test so the stated default and the fallback cannot drift apart.

**Where a hex literal is allowed.** Exactly two places, and nowhere else:

1. **`lib/core/theme/`** — the token definitions themselves. A `BrandAccent` is a list of hex values by definition; that is what makes it the single source.
2. **`web/index.html`** — the boot splash runs before any Dart loads, so it cannot read `BrandColors`. It mirrors the default preset's four values and names each one in a comment, plus `#FFFFFF` for the plate under the brand mark (the logo is a blue-and-grey shape on transparency and needs a light ground; it mirrors what `BrandMark.plated` resolves from `colorScheme.onPrimary`). Change the default brand and those have to move with it, or the first second of the app is the old colour. `web/manifest.json` carries the same two brand values again — `theme_color` / `background_color` — and drifted to a stale orange once already, so change it in the same commit.

Everything else resolves through `context.design` / `colorScheme`. `Colors.transparent`, the sheet scrim, and `GlassCard`'s white sheen are the pre-existing sanctioned exceptions, each commented at its site.

**A dark brand accent needs a `primaryDark`.** `BrandAccent` takes optional `primaryDark` / `onPrimaryDark` / `secondaryDark`, defaulting to the light values — fine for a bright accent, wrong for a dark one. NTI's `#1E40AF` reads at about **1.8:1** on the dark surface base, which is a button nobody can find; it carries `#60A5FA` (≈6.7:1) for dark, and because that fill is light its foreground flips dark. There is no honest automatic fix: lightening far enough to be legible changes the hue people recognise as the brand, so the tone is picked by hand per brand, exactly like the light one. Containers and their foregrounds derive from the *resolved* tone, not the light one, or a soft container would be tinted in one hue while the button beside it used another.

`test/brand_tokens_test.dart` asserts every preset's dark primary clears 3:1. Two pre-existing presets are below par in **light** mode and are left as the palette owner's call: `ocean` primary-on-surface is 2.59:1 and `flame` white-on-primary is 3.50:1. The contrast test is therefore strict for the default brand and dark-mode-wide for the rest, rather than encoding those two as expected-to-stay-wrong.

Adding a brand = adding a `BrandPreset` with a hand-tuned `BrandAccent` to `BrandPreset.presets` (the factory derives containers and dark semantic foregrounds). It is NOT one line and NOT a seed. The Settings swatch list renders the new entry automatically, and `swatch` must equal the light primary — a test pins that, because a Settings chip painting a colour the app never uses is a promise the theme does not keep.

### Localization

Edit `lib/l10n/app_en.arb` and `lib/l10n/app_id.arb`, then run `flutter gen-l10n`. Generated files under `lib/l10n/gen/` are **committed**. Read strings via `context.l10n.someKey`. `en` is the template locale; `kSupportedLocales` / `kDefaultLocale` live in `lib/core/localization/l10n.dart`.

### Product thumbnails

`lib/core/widgets/product_thumbnail.dart` resolves in order: network `imageUrl` → Material icon from `iconKey` → emoji. Always set `iconKey` to a key present in the `_iconByKey` whitelist in `lib/core/utils/icon_map.dart`; anything else silently falls back to `restaurant`.

### DB migrations

`lib/data/database/app_database.dart` — bump `currentVersion` and add the step in `_onUpgrade`. Current version: **21** — v21 added `tables.active` (see "Table Management" below); `DEFAULT 1` needs no backfill, since every table that already existed was already visible on the board. Previous version: **20** — v20 added per-product modifier defaults (`product_modifier_options.is_default`); existing scope is preserved with no defaults assigned. Previous version: **19** — **v19 added `pb1_rate`, `service_charge_rate`, and `service_charge_amount` on `orders`** (see "PB1 and Service Charge" below). Additive — three new columns, no deferred backfill step at all: the two rate columns stay NULL-by-absence on a pre-v19 row (the exact PB1 rate that produced its `tax` amount is genuinely unrecoverable if the store rate ever changed), and `service_charge_amount`'s `DEFAULT 0` needs no backfill `UPDATE` because 0 is a fact for those rows, not a guess — the feature did not exist yet. Earlier steps: (v2 added `image_url` / `icon_key` to products; v3 nulled seed image URLs that went 404; v4 added `icon_key` to categories and backfilled it; v5 backfilled photos for the 13 seed products that had none, guarded by `image_url IS NULL`; v6 seeded a week of demo orders, guarded on `orders` being empty so real transactions are never mixed with fabricated ones; v7 added nullable `cost` / `sku` / `stock` to products and gave the packaged seed items an opening count; v8 added the `employees` table and seeded three staff; v9 added `shifts`; v10 added the owner role, `product_variants`, `promos`, the `stock_movements` ledger, per-product `tax_rate`, per-line `variant_name` / `unit_cost`, and the void/refund columns on `orders`; v11 renamed three seeded staff and every snapshot of their names; v12 grew the floor plan to 31 tables and replaced the seeded week with a generated month; v13 added `outlets` and the outlet columns on `orders`; v14 added `outlet_stock`; v15 gave `tables` an `outlet_id`; v16 added `pos_registers`, the till/branch/closed-by columns on `shifts`, `pos_id` / `pos_name` / `pos_session_id` on `orders`, and the partial unique index that allows one open session per till; v17 added `modifier_groups`, `modifier_options`, `product_modifier_groups`, `order_item_modifiers`, and `category_id` / `category_name` on `order_items`; v18 added `product_modifier_options`, narrowing which of an attached group's options a product actually offers). Seed data (26 products, 5 categories, **31 tables**, **~1,500 orders over 30 days**, 4 staff, 3 promos, 6 variant sets, **3 tills**, **4 modifier groups**) lives here; Settings → "Reset demo data" re-seeds all of it.

`backfillOrderItemCategory` runs the same `UPDATE ... WHERE category_id IS NULL` shape as `backfillOrderItemCost`: rows written before v17 get `category_id` / `category_name` filled in from whatever `products` / `categories` still exist at migration time, and rows whose product was already deleted stay NULL — the information genuinely no longer exists, so leaving it NULL is honest rather than a bug. `seedModifiers` follows `seedVariants`'s FK-safety pattern exactly, checking `products` for a row before inserting into `product_modifier_groups`, for the same reason: a partially-seeded or user-edited catalogue must not abort the whole migration over one missing product.

`seedPosRegisters` gives every branch one till and the FIRST branch two — "Kasir 1" with table service on and "Takeaway" with it off. One per outlet would be indistinguishable from the implicit single till the app had before, and every per-register scoping bug needs a second till for state to leak between.

**v16 deliberately does two nothings, and both are the same refusal to invent a till nobody stood at.** `distributeSeedOrdersAcrossRegisters` runs from `_seed` (via `applyOutletScoping`, last, so an order knows its branch before it is filed under one of that branch's tills) but **not** from `_onUpgrade` — an upgrading install's sales are real, and a stamped `pos_id` would be a name on history nobody can check. And an OPEN legacy shift is **not** backfilled onto a register: it keeps `pos_id` NULL, stays sellable, is re-adopted by its owner at sign-in and closes normally. The alternatives were guessing a till or force-closing a drawer against a count nobody made.

`seedPosRegisters` runs **before** `backfillEmptyOrders` in the deferred section, because that step seeds a demo month and then calls `applyOutletScoping` — the tills have to exist by then, or a v1 install produces a demo whose orders name no register while a fresh install's do.

**Every v10 step is additive** — nullable columns and new tables — so an existing catalogue, order history and staff list survive untouched. Two of its seeds are worth knowing about:

- `attributeSeedOrdersToStaff` rewrites the placeholder `cashier_id = 'cashier'` onto the three real seeded staff, in rotation. Without it the per-cashier report showed one fictional "Kasir Demo" and a signed-in cashier filtering to their own sales saw nothing. Scoped to the placeholder id, so a real sale is never reattributed. It runs from **both** `_seed` and the v10 upgrade, so fresh and migrated installs end up identical.
- `applySeedCost` gives the catalogue a demo cost of goods (a per-category ratio of price, rounded to 500), guarded on `cost IS NULL`. It exists so the profit report opens with a plausible margin instead of a column of zeroes, which reads as a broken report. Real costs are typed per product.

`seedVariants` skips products that are not present. `product_variants` has an enforced FK, and a partially-migrated schema — or a catalogue where someone deleted a seeded coffee — would otherwise abort the whole migration with SQLite error 787.

**Seeded orders** (`seedOrders`) exist because an empty Dashboard, Orders tab and table board read as a broken app rather than an empty one. They are timestamped relative to *today*, so the current day always has revenue and the 7-day Top Products window always ranks something. Ten of today's orders are deliberately left mid-kitchen (`preparing` / `ready` / `served`), which is also what puts ten tables into `occupied` and makes the status filters return rows. Insert the parent `orders` row **before** its `order_items` — both FKs are enforced (`_onConfigure` turns `PRAGMA foreign_keys` ON) and the reverse order fails with SQLite error 787.

Since v12 they are **generated, not hand-written**: a busy restaurant's month is ~1,500 orders, so `_generateSeedOrders` describes the shape (weekend peaks, party sizes, weighted product pools, a few voids and refunds, a mid-service tail today) and produces the rows from a **fixed-seeded `Random`**. Fixed because "Reset demo data" has to produce the same restaurant every time, or two screenshots of one install disagree. `test/repositories/seed_volume_test.dart` guards the shape with wide bounds — tight enough to catch an empty day or halved takings, loose enough to survive tuning the pools.

Three things that bite when touching this:

- **`seedOrders` writes v10 columns, so it must run against the finished schema.** The v6 upgrade step used to call it inline; that now fails on a v1 install with *"table orders has no column named authorized_by"*, because v6 runs four steps before those columns exist. Its call is deferred to the end of `_onUpgrade` as `backfillEmptyOrders`, and any seeder added to a migration belongs there too.
- **Today is seeded as a full trading day, not truncated at the clock.** A demo opened at 09:00 would otherwise land on a near-empty Dashboard — the exact failure this seed exists to prevent. The cost is a few timestamps later than the wall clock on a morning demo.
- **The board is derived, and `reserved` must not overwrite `occupied`.** Whichever tables hold a non-terminal dine-in order read occupied; `_seedReservedTables` then claims bookings from what is *still free*, listing four candidates for three slots and guarding on `status = 'available'`. Without that guard it ran after the occupancy pass and silently took a table with food in the kitchen.

The kitchen tail is also forced to dine-in on distinct tables. Left to the ordinary type distribution most of it came out takeaway, and a thirty-one table board showed two covers — a restaurant nobody visits.

**Renaming a seeded employee is not a one-line seed edit.** `orders.cashier_name`, `orders.authorized_by`, `shifts.employee_name` and `stock_movements.employee_name` are **snapshots**, not joins — the name is copied in at write time so a receipt reprinted next year still says who actually sold it. `renameSeedStaff` (v11) therefore updates all five tables from one `_seedStaffRenames` list, each scoped to the exact previous name so a staff member the user renamed in Settings keeps their chosen name. What it cannot reach is `shared_preferences`: a session that is still signed in shows the cached name until the next sign-in.

Changing seed data only affects fresh installs. Existing installs keep their rows, so a data fix needs a migration step too — v3 is the worked example.

### Product images are network-only

The only bundled image is the brand mark (`assets/images/justclick_logo.png`, wrapped by [brand_mark.dart](lib/core/widgets/brand_mark.dart)). Every **product** photo is a remote Unsplash URL — don't add one to `assets:`. As of v5 all **26 seed products carry a photo** — every slug was HEAD-verified to return 200 before landing.

The trap: [product_thumbnail.dart](lib/core/widgets/product_thumbnail.dart) swallows load failures via `errorBuilder` and falls back to the `iconKey`. Good UX, but it means a broken image is **silent** — the card still looks fine. Two distinct causes, both previously hit:

- **Dead URL.** Unsplash slugs rot. 12 went 404 unnoticed (cleaned up in v3), and the v5 backfill re-sourced 13 products that had ended up with no photo at all. Re-run a HEAD sweep over the URLs before relying on them for a demo.
- **No network permission.** On macOS the app is sandboxed, so every image silently falls back to its icon unless `com.apple.security.network.client` is set in **both** `macos/Runner/DebugProfile.entitlements` and `Release.entitlements`. Both are set now — don't drop them.

Always set a valid `iconKey` regardless, so the fallback stays meaningful.

### Responsive

Breakpoint is `AppDimensions.tabletWidth` (900dp), used in `pos_page.dart` to switch between the bottom-sheet cart and the inline split layout. `CartPanel` supports both mounts — pass the `scrollController` when it lives in a `DraggableScrollableSheet`, otherwise it owns its own.

## Gotchas

- **`routerProvider` must never `ref.watch` another provider.** It returns the `GoRouter` handed to `MaterialApp.router`; watching anything rebuilds the provider, produces a *new* `GoRouter`, and Flutter remounts it at `initialLocation` — throwing the user back to POS mid-task. It used to watch `settingsProvider`, so every theme, brand-colour, language or store-name change kicked you out of Settings. `redirect` reads settings via `ref.read` and `refreshListenable` re-runs it; that is the mechanism for reacting to state. `test/router_stability_test.dart` locks this down, and STEP 5 of the E2E asserts the nav index survives a settings change.
- **A `redirect` gate must never send a `ShellRoute` tab to a route outside the shell.** The POS-session check used to do exactly that — `redirect` sent a cashier with no session from `/` to the pushed `/shift` route, which is not inside `MainShell`'s `ShellRoute`, so the whole shell (bottom nav / rail) unmounted with it. A cashier who had just closed their drawer landed on a screen with no way to switch tabs at all: closing the session, changing tabs, and coming back to `/` re-triggered the same redirect every time. The fix is not a routing fix — it moved the check INSIDE the tab's own page (`PosPage.build()` reads `SettingsState.hasPosSession` and renders `PosSessionOpenCard` in place of the catalogue), so the tab stays mounted as the shell's child and the nav never disappears. If a future gate needs to block a `ShellRoute` tab, render the blocked state inside that tab's page — do not `redirect` it to a pushed route. `test/features/splash/splash_test.dart` locks this down with a widget test that leaves and returns to `/` with no session and asserts the nav bar survives.
- **Never pop a fixed number of routes when the layout decides how many are open.** `CheckoutSheet._placeOrder` used to call `Navigator.pop()` twice unconditionally. That is right on phones (cart sheet + checkout sheet) but wrong at ≥900dp, where the cart is inline and checkout is the *only* route — the second pop unmounted the shell route, the Navigator asserted `!_debugLocked` while finalizing the tree, and the app went blank right after a successful sale. The order was already committed, so nothing was lost but the screen. It now derives the count from the same `AppDimensions.tabletWidth` predicate `_openCartSheet` uses. Phone-sized widget tests never caught this; it reproduces on macOS, tablet and web.
- `_indexFromLocation` in `lib/features/shared/main_shell.dart` resolves against the **visible** tab list, not a fixed map, and matches the longest path first so `/orders/abc` never falls through to `/`. Adding a tab means one entry in `_tabs` plus a case in `_label` — and, if it should be gated, a row in `routePermissions`.
- `Order.fromMapRow` reads an optional `item_count` column produced by a `LEFT JOIN COUNT` in the list query. Remove the JOIN and `resolvedItemCount` returns 0 on list views.
- **Every revenue query filters on `kRevenueStatusSql`, never on `status != 'cancelled'`.** Refunds are excluded from revenue too, and the predicate lives in `enums.dart` because it appears in seven aggregates — a report where six of them exclude refunds and the seventh does not is a bug nobody spots until the columns fail to add up.
- **`setStatus` throws on `cancelled` / `refunded`.** Those need a name and a reason, so they go through `voidOrder` / `refundOrder`, which write the authorizer in the same UPDATE as the status. `_settle` reads the previous status inside the transaction and no-ops when already settled — a double-tap on Void would otherwise credit the stock twice, and the second credit is invisible until someone counts the shelf.
- **The stock count and its ledger row are written together, inside one transaction.** `products.stock` is the running balance and `stock_movements` is the evidence; a balance that moved with no matching row makes the whole history useless for the one job it has. The ledger records the *clamped* delta, not the requested one.
- Plain-text PINs are a documented shortcut for a local demo till. Real auth belongs behind the API — see AGENTS.md.
- **Never render an emoji in the UI. Use a Material icon via `iconFromKey`.** The app used to show emoji for the store logo, greeting, category chips, empty states and stat cards; all of them were tofu boxes (`⍰`) on the iOS Simulator, whose runtimes ship only `AppleColorEmoji-160px.ttc` under `Fonts/CoreAddition/` and no `AppleColorEmoji.ttc` under `Fonts/Core/` (both the 18.6 and 26.3 runtimes — not a version gap).

  Bundling an emoji font does **not** solve it, and this was tested to exhaustion: Noto Color Emoji in CBDT form still rendered tofu, and in COLRv1 form the glyphs came out blank (the full font also broke word spacing). `--no-enable-impeller` changed nothing, and Apple Color Emoji cannot be redistributed. Material Icons render correctly on every platform, so the app now stores an `icon_key` on both products and categories and renders `Icon(iconFromKey(key))` everywhere.

  The `emoji` columns still exist on `products` and `categories` as legacy data — nothing reads them for display. Don't reintroduce emoji rendering; add a key to the `_iconByKey` whitelist in `lib/core/utils/icon_map.dart` instead. `iconKeys` exposes that whitelist and backs the icon pickers in the product and category forms.

## Commits

Conventional Commits — `<type>(<scope>): <subject>`, e.g. `feat(pos): add discount input to checkout`, `fix(ios): bundle full MaterialIcons font to prevent tofu`.
Types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `style`, `perf`.
