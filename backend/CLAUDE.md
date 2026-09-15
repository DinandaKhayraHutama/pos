# CLAUDE.md — backend

Guidance for the Laravel API + web Backoffice. The Flutter till app lives in
`../mobile/` and has its own `CLAUDE.md`; read that one before touching
anything under `mobile/`.

## What this is

**JustClick POS backend** — one Laravel application serving two surfaces:

| Surface | Path | Auth | Who |
|---|---|---|---|
| Web Backoffice | `/backoffice` | session, `backoffice` guard | Owner, Manager |
| JSON API | `/api/v1` | Sanctum device token (`device` middleware) | the Flutter till app |
| Platform admin | not built yet | session, `platform` guard | super admins |

Both surfaces call the same domain services (`app/Domain/**`). Filament never
calls the API internally, and API controllers hold no business logic — that way
splitting the Backoffice into its own frontend later stays possible without
rewriting anything that matters.

Stack: Laravel 12 · PHP 8.4 · PostgreSQL 18 · Filament v5 · Pest 3.

## Commands

All run from `backend/` (this directory):

```bash
php artisan serve                 # http://localhost:8000
php artisan migrate:fresh --seed  # rebuild the dev database
php artisan test                  # Pest — must stay green
vendor/bin/pint                   # code style, before committing
composer audit                    # security advisories, before committing
php artisan tenant:create         # onboard a merchant + its Owner
```

Demo credentials after `--seed` (local only): Owner `farhan@nti.test` /
`password`, Manager `siwi@nti.test` / `password`. PINs mirror the Flutter app:
`9999` owner, `1234` manager, `2345` / `3456` cashiers.

**`composer require pkg:"^5.0"` silently loses the caret on Windows.** Composer
is a `.bat`, and `^` is cmd.exe's escape character, so the constraint arrives as
the exact version `5.0` and pins you to the oldest release in the range. This
already happened once and installed a Filament with two high-severity CVEs. Edit
`composer.json` by hand, then `composer update <pkg>`.

## Multi-tenancy — the thing that must never break

One shared database. Every merchant-owned row carries `tenant_id`, and
isolation is **automatic, never hand-written**:

```php
use App\Models\Concerns\BelongsToTenant;   // that is the whole opt-in
```

The trait installs `TenantScope` (adds `WHERE tenant_id = ?` to every read) and
stamps `tenant_id` on every write. **No controller, service, Filament resource
or widget may write `where('tenant_id', ...)` by hand** — a filter that has to
be remembered is one that eventually is not.

Three behaviours worth knowing, all deliberate:

- **Reads fail closed.** With no tenant resolved the scope matches *nothing*
  (`WHERE 1 = 0`), never everything. A forgotten `TenantContext::set()` must
  produce an empty screen, not another merchant's data.
- **Writes fail loud.** Creating a tenant-owned row with no tenant resolved
  throws. A row with a null `tenant_id` is invisible to every later query and
  nobody notices until a total comes up short.
- **Crossing tenants is greppable.** `TenantContext::runUnscoped()` is the only
  way through, so auditing "what can read across merchants" is a search for one
  method name. `runAs($tenant, …)` is its scoped sibling for console commands.

`Tenant` and `SuperAdmin` deliberately do **not** use the trait: the first is
what the scope is resolved *from*, the second belongs to no merchant.

**This bites in seeders and commands.** Console code has no authenticated user,
so nothing is resolved — `$tenant->employees()->update([...])` there silently
matches zero rows, which is the scope working correctly and the caller being
wrong. Wrap console writes in `runAs()`. This exact bug shipped in the first
draft of `DatabaseSeeder` and was caught by verifying the seeded rows rather
than trusting the exit code.

`tests/Feature/TenantIsolationTest.php` is the most important file in the
project. **Every new tenant-owned entity gets a case there before it is
considered done.**

## Roles and permissions

`app/Domain/Auth/Permission.php` and `Role.php` are a **deliberate port of
`mobile/lib/core/auth/permissions.dart`**, kept in code rather than in database
rows. The string values are byte-identical to the Dart enum names so a device
and the server can name the same permission without a translation table.

Two properties are the reason it is not a DB table:

1. **`owner` is derived** — every permission except the till set (`sell`,
   `openCloseShift`), so a newly added permission reaches the owner
   automatically. A seeded role-permission table cannot do that; it would need
   re-seeding on every new permission, and forgetting is silent.
2. **One source of truth.** A database copy would be free to drift from the
   device's copy — which is the exact failure "ask for a permission, never a
   role" exists to prevent.

`spatie/laravel-permission` was installed and then **removed** for those
reasons. It earns its place when merchant-editable custom roles arrive (a later
phase); those layer on top of these three defaults rather than replacing them.

Ask `$employee->hasPermission(Permission::VoidOrder)` or `$user->can('voidOrder')`
(every permission is registered as a Gate in `AppServiceProvider`). **Never
compare roles in a controller or a Filament resource.**

## Identity

Two authenticatables on two guards, not one table with a flag:

- **`Employee`** (`backoffice` guard) — a merchant's staff. Both credentials are
  nullable and neither implies the other: `password` only for staff who open a
  browser, `pin_hash` only for staff who stand at a till. One row per person, so
  the Owner who signs into the Backoffice and the name on a receipt are the same
  record.
- **`SuperAdmin`** (`platform` guard) — platform staff. Creating merchants is not
  a permission a merchant can ever hold, and separate guards make that
  structural rather than a check someone has to remember.

`email` is **globally** unique (login resolves an account from the email alone,
so the same address in two merchants would be ambiguous). PIN uniqueness is
**per tenant and checked in application code** — bcrypt is salted, so the same
PIN hashes differently every time and uniqueness genuinely cannot be a unique
index. See `Employee::pinTakenWithinTenant()`.

**Authentication must resolve identity before tenant middleware runs.** The
`employees` auth provider uses `App\Auth\EmployeeUserProvider`, which wraps only
credential, session-ID and remember-token lookups in `runUnscoped()`. Ordinary
Employee queries still fail closed, and the tombstone scope remains active.
Using the default Eloquent provider here makes every valid login fail because
no tenant exists yet. `BackofficeLoginTest` submits the actual Filament login
form and reloads the session; `actingAs()` alone cannot detect this regression.

**Keep tenant context alive for the entire Livewire HTTP request.**
`ResolveTenant` wraps the panel's normal middleware stack and the `web` group
(which handles Livewire POSTs). Do not register it as persistent middleware:
Livewire replays that middleware in an inner pipeline that finishes BEFORE
component hydration, actions, and rendering. Its `finally` would clear the
merchant too early, causing create actions to return 403 and polling widgets
to display zero staff. Filament authentication remains persistent; tenant
cleanup still runs at the end of the outer request, including failures.
`BackofficeLivewireRequestTest` sends signed snapshots to the actual update
route because `Livewire::test()` skips the persistent middleware pipeline.

The backoffice requires PHP `intl` for table number formatting. Check `php -m`
and `php --ini`; after enabling the extension, restart the HTTP PHP process as
well. An existing `artisan serve` worker retains its old extension configuration.

`Employee::verifyPin()` is scoped to one row on purpose: the device picks the
account first, then checks the PIN against *that* choice. A colleague's own
valid PIN must be rejected exactly like a wrong one, or the account choice is
theatre.

Three independent conditions gate the Backoffice (`canAccessBackoffice()`): the
account is active, the role uses the Backoffice (cashiers do not), and a
password was actually set. Filament calls this *after* accepting a password, so
it is the difference between "these credentials are real" and "this person still
works here".

## Device activation

How a physical tablet becomes a till the server recognises. `app/Domain/Devices/`
holds the whole flow; the controller and the Filament actions are thin shells
over it.

**The trust chain, and why it points the way it does.** An Owner creates an
outlet and a register in the Backoffice, issues an activation code for that
register, and reads the code to whoever is holding the tablet. The tablet posts
`{code, device_uuid}` to `/api/v1/devices/activate` and gets back a Sanctum
token plus the outlet and register it now belongs to.

`tenant_id`, `outlet_id` and `pos_register_id` are `prohibited` in that
endpoint's validation — not merely ignored. **The code is the only thing that
selects a merchant.** Accepting a tenant id from an unauthenticated request
would let anyone bind a device to any business by editing a JSON body, and
silently ignoring the field would leave that looking like it worked.

**Codes are stored as an HMAC, never in plain text** (`DeviceActivation::fingerprint`).
The plaintext is returned exactly once, from the issuing call, and is never
written to a model, a log, or a Filament notification — an earlier draft put it
in a flash notification, which parks a live credential in the session store.
Twelve characters from a 32-symbol alphabet with `I`/`O`/`0`/`1` removed: high
enough entropy to survive being guessable, unambiguous enough to read aloud
across a counter.

**Three properties are enforced structurally, not by convention:**

- **Single-use and race-proof.** Issuance, activation and revocation all take
  `lockForUpdate()` on the tenant row first, so two tablets racing on one code
  serialise instead of both winning. `tests/Concurrency/ActivationRaceTest.php`
  proves it with two real PostgreSQL connections contending for the same lock —
  which is why that suite uses `DatabaseMigrations` rather than
  `RefreshDatabase`: a second process cannot see rows inside another
  connection's open transaction.
- **Short-lived.** `expires_at` is required, and issuing a new code for a
  register cancels any outstanding one. A code that never expires is a permanent
  credential sitting in someone's chat history.
- **Cross-tenant references are impossible, not just unlikely.**
  `2026_09_08_060400_enforce_device_tenant_consistency` adds composite foreign
  keys — `devices(tenant_id, outlet_id, pos_register_id)` references
  `pos_registers(tenant_id, outlet_id, id)`. A device pointing at another
  merchant's register is rejected by the database, so it cannot survive a bug in
  application code.

**Revocation is immediate and total.** `revoke()` sets `revoked_at`, deletes
every Sanctum token, and cancels any pending code for that register. The device
row stays — a stolen tablet is something an Owner needs to keep seeing.
Re-activating with a *new* code rotates every previous token, so a reinstall
never leaves an old credential alive.

**`AuthenticateDevice` re-checks the whole chain on every request**, not just the
token signature: the device is not revoked, its tenant is active, its register
and outlet are both still active, and the register belongs to that outlet. A
tablet in a branch the Owner closed yesterday stops working today. It also
clears `TenantContext` in a `finally`, for the same reason `ResolveTenant` does.

**A Backoffice session is not a device identity.** The middleware forces the
`sanctum` guard, so a browser cookie can never authenticate an API call meant
for a till.

## Catalogue sync

The first data that actually travels to a till. `GET /api/v1/sync/pull?entity=products&after_seq=412`
returns `{rows, next_seq, has_more}`; the device stores `next_seq` and asks for
everything above it next time.

**`sync_seq` is a counter, not a timestamp.** Two tablets and a server never
agree on the clock to the millisecond, and the Flutter schema has no
`updated_at` anywhere to fall back on. `tenant_sync_counters` holds one
monotonic number per merchant, and every write — creates AND updates — takes a
fresh one. A price change that kept its old number is a change no device would
ever ask for again.

**The counter must be allocated inside the writer's transaction**, and
`SyncCursor::next()` throws rather than run without one. This is not defensive
tidiness; it is the one thing standing between this design and silent data loss:

> Writer A takes seq 10 and is slow to commit. Writer B takes 11 and commits
> immediately. A device pulls, sees only B, moves its cursor to 11. A finally
> commits — and the device is already past row 10, so it never asks again. The
> product simply never appears on that till.

`INSERT … ON CONFLICT DO UPDATE … RETURNING` prevents it because PostgreSQL
holds the counter row's lock until the transaction *ends*, so B cannot take 11
until A has committed 10. `Syncable::save()` opens a transaction when the caller
has not, so even a bare `save()` is safe.

**Deletes are tombstones.** `Syncable::delete()` stamps `deleted_at` and takes a
new `sync_seq`, so the deletion is itself a change a device can receive. A row
that just vanished server-side would linger on every till forever — "gone" is
not something a delta can express by absence. A global scope hides tombstones
from ordinary reads, so Backoffice screens behave as if the row is gone; only
the pull endpoint asks for them with `withTombstones()`.

**`SyncRegistry` is an allow-list, and the order in it is load-bearing.** The
entity name arrives from a client, so mapping it to a model class by convention
is how an endpoint ends up serving `employees` — password hashes included — to
anything holding a device token. The order (categories → products →
product_variants) is what the device applies in, because its SQLite has
`PRAGMA foreign_keys` ON and a product landing before its category fails with
error 787. It is published at `/api/v1/sync/manifest` rather than hardcoded on
the client, so adding an entity stays a server-only change.

**Every catalogue write goes through `CatalogueManager`.** Not a style
preference — it is what guarantees the transaction the counter depends on, for
the Filament panel and any future API alike. Catalogue is `manageCatalogue`,
the *owner's* permission, so it gets its own `CataloguePolicy`; reusing
`InfrastructurePolicy` would have handed the menu to managers, who hold
`manageOutlets` but must not set prices.

### Staff sync

`employees` is in the feed too, so a cashier can sign in on a tablet with no
network at all. What travels is `id, name, pin_hash, role, active, sort_order` —
and the **absences are the design**: `password` and `email` never leave the
server. A browser credential is of no use to a till, and shipping it to every
tablet in every branch would put it somewhere far easier to extract.

PINs are bcrypt, set through `StaffManager`, and only ever sent as a hash.
Uniqueness within a merchant is an application check (`pinTakenWithinTenant`),
not an index — bcrypt is salted, so the same PIN hashes differently every time
and `WHERE pin_hash = ?` can never match. It matters for the manager-override
prompt, which resolves an approver from a PIN alone.

`StaffManager` refuses to save an account nobody can sign into: a cashier with
no PIN cannot reach the till, and a manager with neither PIN nor password cannot
reach anything. Both look saved and produce a person who cannot work. It also
refuses to deactivate the last active owner, or the actor themselves.

Staff get a **third** policy (`StaffPolicy`, `manageEmployees`). Reusing the
catalogue's would have let a manager mint themselves a till account and walk
around the entire role split.

The migration that made `employees` syncable had to **backfill `sync_seq` for
existing rows**. The column defaults to 0 and a device pulls everything
*greater than* its cursor, which also starts at 0 — so every employee that
already existed would have been permanently invisible to every device. No error,
no empty result to notice: just a till nobody can sign into.

Modifiers are deliberately **not** in this slice. `product_modifier_options` has
`ON DELETE CASCADE` on `option_id`, and the device applies pulled rows with
`ConflictAlgorithm.replace` — which deletes before reinserting, and would
silently wipe every product's option scoping. That needs the diff-not-replace
treatment `ModifierRepository.replaceOptions` already uses on the device, and it
gets its own slice.

## Push — rows a till authored

`POST /api/v1/sync/push` is the other direction. Everything before it was
written in the Backoffice and pulled down; these rows arrive already created,
with an id the tablet chose, possibly hours late.

**The device's UUID is the idempotency key.** A till generates it before writing
the row locally, so a push that timed out *after* the server committed can be
retried safely — the second attempt updates the same row instead of opening a
second drawer. This is the whole reason devices generate keys rather than asking
for one.

**The response names what was accepted and what was refused**, per row. A
blanket 200 would leave the device guessing what it may drop from its queue, and
guessing about money means either sending a sale twice or losing it. One bad row
never fails the batch: the rest is money already taken from customers.

**A closed session never reopens.** The device is the authority on a drawer
while it is open, but once a count is signed off, a late packet describing the
earlier open state must not erase it — that would delete a variance somebody has
already explained.

**Outlet and register come from the token, never the payload**, marked
`prohibited` like everywhere else. A till that could name its own register would
be a till that could write into another branch's books.

`pos_sessions` deliberately has **no `sync_seq`** — that column exists so devices
can page through server changes, and these rows never travel back down. It also
mirrors the device's partial unique index (`WHERE closed_at IS NULL`), so a
second tablet cannot open a drawer on a register that already has one. The check
also lives in `SessionIngest` so the error names who holds the till, which is
what the cashier standing in front of it needs; the index alone surfaces as an
opaque constraint violation.

### Orders — the part that must never be wrong

`OrderIngest` carries three guarantees, and each is a different way money goes
missing:

**Never twice.** The device's UUID is the key. Without idempotency, a flaky
connection inflates a merchant's takings — the till retries a push that already
committed and the sale is counted again.

**Never partly.** An order, its lines and their modifiers arrive as ONE nested
payload and are written in one transaction. Splitting them across requests would
let a header land without its lines: a total nobody can explain, which passes
every check that only looks at `orders`. `items` is `required|min:1` for the
same reason.

**Never rolled back.** Once a sale is settled — voided or refunded — a late
packet describing the earlier state changes nothing. `applyUpdate` returns early
on `isSettled()`. This mirrors the device's `_settle`, which no-ops when the
order already returned its stock: a double-tap on Void must not credit the shelf
twice, and a stale push must not un-void a sale a manager signed off.

A retry also never restates the figures. Only status and its audit trail
(`authorized_by`, `void_reason`, `refunded_amount`) are updated on an existing
order; the money and the lines are written once, at creation.

**Almost nothing has a foreign key.** `product_id`, `employee_id`, `table_id`
are plain columns. A till sells offline for a day and pushes afterwards; by then
a product may have been deleted. Rejecting the sale would be refusing to record
something that demonstrably happened — the same position the device takes.

`Order::scopeRevenue()` is the server's `kRevenueStatusSql`. Every aggregate
goes through it, because six queries excluding refunds and a seventh that does
not is a set of numbers that quietly fails to add up.

Cash sessions get their own `CashSessionPolicy` on `viewCashDrawer` — the
manager's permission, matching the device. `InfrastructurePolicy` was close
enough to reuse and wrong: `manageOutlets` is about configuring branches, not
about who may see what the tills took. Every write verb is false; editing a
counted drawer from a browser is the opposite of what the screen is for.

## Reporting

`SalesReporter` is the only place sales figures are defined — the dashboard
widget, the Sales report page and anything exported later all call it. Putting
the SQL in a page would make that screen the definition, and the first export
would quietly disagree with it.

**Never join `order_items` in a total.** The join fans each order into one row
per line, so every `SUM` over `orders` is multiplied by its line count. The
result looks plausible and is simply too big, which is why it is guarded by a
test rather than left to be noticed.

**Every aggregate carries `Order::scopeRevenue()`.** One exception, deliberate:
the "voided and refunded" query, which exists to show exactly what the others
excluded.

`outletId: null` means the whole chain. That is how an owner compares branches,
so it is the default rather than an edge case, and `by_outlet` is present even
when the report is narrowed so the response shape never depends on the filter.

**The discount split uses largest-remainder** (`CategorySalesAggregator`).
Flooring `discount × lineTotal / subtotal` per category loses up to
`(categories − 1)` rupiah per order; over a month the category breakdown stops
reconciling to `subtotal − discount`, with nothing anywhere to say so. The
floors are summed and the leftover handed whole to the largest line, ties
broken on category id so two runs agree.

The two bugs the Dart original shipped are both re-guarded in
`tests/Unit/CategorySalesAggregatorTest.php`: net computed as the discount SHARE
rather than gross minus it, and an older snapshot name overwriting a newer one
for a deleted category. That suite is pure logic over raw rows — no database —
which is why it catches arithmetic the SQL tests cannot.

**Category figures are pre-tax and pre-service-charge.** PB1 and service charge
have their own lines, and allocating either per category would be a second
proportional split nobody asked for. So `Σ net_sales` reconciles to
`Σ(subtotal − discount)`, **not** to `revenue` — the page says so where the
numbers are, not in a footnote.

`cost_coverage` is the fraction of items sold that carried a cost. Without it a
half-costed catalogue reports a margin that looks excellent and means nothing;
the page warns below 66%.

The Sales report page is gated on `viewFinancialReports` — the owner's. A
manager gets the dashboard and the cash drawers.

## Testing

Pest, and **tests run against real PostgreSQL** (`justclick_pos_test`), not
SQLite in-memory. The invariants this system will depend on — partial unique
indexes for one-open-session-per-register, row-level tenant predicates — behave
differently on SQLite, so a green SQLite suite would not prove the production
schema is correct. `phpunit.xml` carries that override.

Every write endpoint gets an idempotency test once the sync layer lands: sending
the same payload two or three times must leave the database identical to sending
it once.

Three suites, and the third is not optional:

- `tests/Unit` — pure logic (the role map).
- `tests/Feature` — HTTP and database behaviour, including the Filament actions
  driven through Livewire rather than by calling the service behind them.
- `tests/Concurrency` — two real PostgreSQL connections contending for a lock.
  Anything whose correctness depends on a transaction winning a race belongs
  here; a single-connection test cannot fail the way production does.

`scripts/verify-device-activation.php` checks the same flow against a **real
running HTTP server** — including the 429 and `Retry-After` that rate limiting
produces, which the Pest suite does not exercise. Run it after touching the
activation flow or the middleware order:

```bash
php artisan serve &          # in one terminal
php scripts/verify-device-activation.php
```

It creates a disposable tenant and deletes it in a `finally`. It prints no
credentials.

`php scripts/verify-backoffice.php` verifies a running local server on port
8000 (or pass a loopback base URL). It logs in through the real form, polls the
dashboard three times, creates an outlet/register/category/product through
Livewire HTTP actions, and opens Staff. It uses a disposable merchant and
removes it in `finally`, without modifying the user's demo merchant.

## Schema conventions

- **UUID primary keys** on everything a device can reference (`tenants`,
  `employees`, and every entity the sync layer will carry). The Flutter app
  already generates UUIDs client-side for orders, shifts and stock movements, so
  a device can create a row offline and name its own key with no round trip —
  and that key doubles as the idempotency key when it is pushed.
- `super_admins` keeps an auto-increment id: platform-internal, never synced.
- **Money is integer** (rupiah), never float — matching the Flutter schema.
- **Snapshot columns stay snapshots.** When order/receipt tables arrive they
  copy `product_name`, `cashier_name`, rates and prices at write time exactly as
  the device does. Normalising them into joins would make old receipts reword
  themselves after a rename, which is a behaviour change, not a cleanup.
