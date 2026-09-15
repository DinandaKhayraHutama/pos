# CLAUDE.md — backend-go

Guidance for the Go backend. The Flutter till lives in `../mobile/` and has its
own `CLAUDE.md`; the Laravel backend in `../backend/` is being replaced by this
one and stays only as a reference until the pilot gate.

## What this is

**Current work (2026-09-15): Fase 0–5 regression-checked; Fase 6 floor-plan,
table-status sync, modifiers and outlet-scoped promos implemented on both sides.**
See `docs/PHASE_0_2_VERIFICATION.md`, `docs/PHASE_3_VERIFICATION.md`,
`../mobile/docs/PHASE_4_VERIFICATION.md`, `docs/PHASE_5_VERIFICATION.md` and
`docs/PHASE_6_VERIFICATION.md` for
evidence and production-readiness limits. The pilot gate still needs hardware
UAT and the scaled load test.

**JustClick POS backend**, second edition — one Go binary serving:

| Surface | Path | Auth | Who |
|---|---|---|---|
| Device API | `/api/v2` | device bearer token | the Flutter till |
| Web Backoffice | `/backoffice` | session cookie, `justclick_backoffice` | Owner, Manager |
| Platform admin | not built yet | separate guard, separate cookie | super admins |

Stack: Go 1.27 · chi · pgx/v5 · goose · templ + HTMX 2 · scs (Postgres store) ·
gorilla/csrf · go-redis v9 · PostgreSQL 18 · Redis 8 · Caddy.

**The rewrite is not "PHP was slow."** It exists to remove four defects that
were verified in the Laravel code and would have hit a wall long before language
choice mattered — chiefly that every pushed order took `SELECT … FOR UPDATE` on
the *tenant row*, so all 5,000 outlets serialised behind one lock. See
`../backend/app/Domain/Sync/OrderIngest.php` lines 76-79 for the original.

## Commands

All run from `backend-go/`:

```bash
docker compose up -d --build api           # rebuild the API after source changes; starts Postgres/Redis too
docker compose up -d caddy                 # local HTTPS on :8443
go run ./cmd/justclick migrate up          # goose, on MIGRATE_DATABASE_URL
go run ./cmd/justclick roles set-password  # credentials for the two login roles
go run ./cmd/justclick tenant create --name … --slug … --owner-name … --owner-email …
go run ./cmd/justclick serve               # API + Backoffice on :9000
templ generate                             # after editing any .templ
go test ./... -count=1                     # needs real Postgres AND Redis
go run ./scripts/verify-activation         # against a running server
go run ./scripts/verify-backoffice         # against a running server
go run ./scripts/verify-backoffice-crud    # against a running server: panel writes reach the till
go run ./scripts/verify-sync               # against a running server
go run ./scripts/verify-push               # 200 receipts x3 through HTTP; isolated disposable tenant
go run ./cmd/justclick worker              # River: partitions, stock reconcile, report rollups/exports/schedules
go run ./scripts/verify-reports            # Fase 7 gate: 30-day seed, rollup == raw, < 200 ms, exports
go generate ./api ./internal/store         # pinned OpenAPI + SQL generators
go run ./scripts/verify-sync-load          # disposable 2000-device k6 fleet against Compose
```

`https://localhost:8443` is the same server behind Caddy with a local CA
certificate. The verification scripts accept `VERIFY_BASE_URL` and, for that
certificate only, `VERIFY_INSECURE_TLS=1`.

**PostgreSQL 18 images mount at `/var/lib/postgresql`, not `/var/lib/postgresql/data`.**
Mounting the old path makes the container restart-loop with a message about
`pg_ctlcluster` that does not obviously say "your volume is in the wrong place".

## The credential split — the thing that must never break

**PostgreSQL exempts superusers and table owners from every RLS policy, and it
does so silently.** No error, no warning; the policies simply do not apply. That
single fact shapes everything here.

Three credentials, and the difference between them *is* the security boundary:

| Role | Bypasses RLS | Used for |
|---|---|---|
| `justclick` (owner) | yes | DDL only. `MIGRATE_DATABASE_URL` is never present in the serving process. |
| `justclick_app` | **no** | every request. `DATABASE_URL`. |
| `justclick_unscoped` | yes, deliberately | only lookups that resolve an identity before a tenant is known. `UNSCOPED_DATABASE_URL`. |

`pg.AssertPools` runs at startup and refuses to continue if either pool is wired
to the wrong role. **It checks both directions**, because both fail badly and
only one is obvious:

- A tenant pool that *can* bypass RLS disables tenant isolation entirely, and
  the first symptom is one merchant reading another's rows.
- An unscoped pool that *cannot* leaks nothing, but device sign-in finds no rows
  and a till that cannot authenticate looks like a network fault.

An earlier draft connected as the owner and merely did `SET LOCAL ROLE
justclick_app` inside `pg.InTenantTx`. That made isolation a matter of
remembering to use the helper: any query that went straight to the pool ran as a
superuser. The role switch is gone now — the pool's own credential is already
unprivileged, so switching per transaction would be a round trip that buys
nothing.

**`internal/store/unscoped` is the greppable escape hatch.** Importing it is the
audit trail for "what can read across merchants", the role
`TenantContext::runUnscoped()` played in the Laravel original. Its callers are
expected to stay countable on one hand: device token resolution, backoffice
login by email, and tenant provisioning.

**Roles are declared in a migration; passwords are not.** A password in a
migration is a password in version control. `justclick roles set-password` reads
`APP_DB_PASSWORD` / `UNSCOPED_DB_PASSWORD` and asks PostgreSQL itself to build
the statement with `format('ALTER ROLE %I PASSWORD %L', …)`, keeping the quoting
rules where the quoting rules live.

**`pgtest` hands services the real credentials.** Seeding goes through the
owner, but anything under test receives `pg.Pools` exactly as the server does,
and the harness calls `AssertPools` on itself. Give a service the owner pool and
every isolation test in the suite quietly stops testing anything — which is
precisely what happened the first time these tests ran, and why all four failed.

## No lock on the tenant row

The rule, and it is worth putting on a wall: **a write may only lock the row
whose invariant it protects.** There is a CI job (`no-tenant-lock`) that fails
the build on `FROM tenants … FOR UPDATE`. Treat it as a build error, not a
style note.

Activation is the worked example. Single use, expiry, cancellation, and the
liveness of tenant/outlet/register are all predicates on **one statement**:

```sql
UPDATE activation_codes ac SET consumed_at = now()
FROM pos_registers r JOIN outlets o ON … JOIN tenants t ON …
WHERE ac.fingerprint = $1
  AND ac.consumed_at IS NULL AND ac.cancelled_at IS NULL
  AND ac.expires_at > now()
  AND r.active AND o.active AND t.status = 'active'
RETURNING …
```

Eight tablets racing one code serialize on that register and the code row.
Issuance, activation and revoke acquire register before code/device, so the
auth-generation trigger cannot introduce a reversed lock order.
`TestConcurrentActivationsExactlyOneWins` proves exactly one wins and exactly
one device is bound.

Returning zero rows conflates "code already used" with "register deactivated",
and that is deliberate: both are `ErrInvalidCode` to the caller, so the response
does not tell an attacker which condition they tripped.

## Device activation

`internal/domain/devices/` holds the flow; the HTTP handlers are thin.

**Codes are stored as an HMAC, never in plaintext.** The plaintext is returned
exactly once, by the issuing call, and is never written to a row, a log, or a
flash message. Twelve characters from a 32-symbol alphabet with `I`, `O`, `0`
and `1` removed — enough entropy to survive guessing, unambiguous enough to read
aloud across a counter. The alphabet length divides 256 exactly, so the modulo
in `newCode` is unbiased; changing its length breaks that.

**Tokens are 32 random bytes stored as SHA-256, not bcrypt.** A high-entropy
secret does not need a slow hash, and bcrypt on the auth path would cost ~100ms
per request. PINs and passwords *are* bcrypt, cost 10 — that must not be raised,
because the Flutter till verifies `pin_hash` on-device so a cashier can sign in
with no network, and a cheap tablet feels every extra round.

**Re-activation rotates the token** by overwriting `token_sha256` in the upsert.
The upsert's `WHERE devices.pos_register_id = EXCLUDED.pos_register_id` is what
makes moving an installation between registers return `ErrBoundToAnother`
instead of quietly re-binding it.

**`AuthenticateDevice` re-checks the whole chain on every request**, not just the
token: device not revoked, tenant active, outlet and register both active and
still related. A tablet in a branch the owner closed yesterday stops working
today.

**Cross-tenant references are impossible, not merely unlikely.** Composite
foreign keys carry `tenant_id` through `pos_registers → outlets`,
`devices → pos_registers`, and `activation_codes → devices / employees`. The
last of those originally referenced `devices(id)` alone; it now uses
`ON DELETE SET NULL (device_id)` with an explicit column list (PostgreSQL 15+),
because the default form would try to null `tenant_id`, which is `NOT NULL`.

## The sync feed — how a row reaches a till

`internal/domain/syncfeed` publishes server-owned rows; `internal/domain/catalogue`
is the first thing that writes through it. The package is named `syncfeed` and
not `sync` so a file in it can still use the standard library's `sync` — the
race tests here need `sync.WaitGroup`.

**`AllocSeq` must run inside the writing transaction, and it refuses rather than
tolerating a nil one.** This is the invariant the whole feed rests on, and the
failure it prevents is silent:

1. Writer A takes seq 10 and is slow to commit.
2. Writer B takes seq 11 and commits immediately.
3. A device pulls, sees only row B, and moves its cursor to 11.
4. Writer A commits. Row 10 is visible now, but the device is past it and will
   never ask again.

The product disappears from one till and nobody finds out until a cashier tries
to sell it. `INSERT … ON CONFLICT DO UPDATE … RETURNING` closes it because
PostgreSQL holds the counter row's lock until the surrounding transaction
**ends**. A plain `SEQUENCE` is not a substitute: `nextval` releases at once and
survives rollback, which is the same bug with extra steps.
`TestTheCounterLockIsHeldUntilTheWriterCommits` is the reproduction — read it
before touching `counters.go`.

**Counters are sharded, and the shard axis is the one devices already page
along.** The Laravel original held one row per merchant, so every catalogue and
staff write in a 5,000-outlet company queued behind it. Scope keys are
`t:{tenant}/e:{entity}` and, from Fase 5, `t:{tenant}/o:{outlet}/e:{entity}`.

**One sequence number per row, never one per write.** Two rows sharing a number
can be split by a page boundary, and everything still sitting at that number is
never delivered — the next request asks for strictly greater. `SeqBlock`
reserves a run of them for a cascading tombstone in one round trip.

**Deletes are tombstones.** A delta page says what changed; an absence says
nothing at all, so a till can never infer a deletion. `DeleteProduct` also
retires the product's variants and modifier attachments, because on the device
those tables cascade — the till deletes them locally the moment it applies the
product's tombstone, and rows left alive on the server would never be mentioned
again.

**Rows and the scope's mark must share ONE SNAPSHOT, not merely one transaction.**
`Pull` uses `pg.InTenantReadTx`: explicit `REPEATABLE READ READ ONLY`, with the
same transaction-local tenant context as writes. PostgreSQL's default
`READ COMMITTED` takes a new snapshot for every statement. A writer committing
between the row scan and the counter query used to make `next_seq` acknowledge
a row absent from the response, skipping it permanently.
`TestPullDoesNotSkipACommitBetweenRowsAndCounter` uses a pgx query tracer to
commit a separate writer at exactly that boundary, for both empty and partial
pages. It was run against the old code and failed in both cases before the fix.
Do not weaken this to `InTenantTx`; writers still use their existing isolation
and hold the counter lock until commit.

**Published columns are an allow-list, and the covering index must match it.**
Every feed table has `(tenant_id, sync_seq) INCLUDE (…published columns…)` so an
index-only plan is possible. `TestPullUsesAnIndexOnlyScan` and `verify-sync`
check **all 12 feeds**, with 5,000 rows per feed, `after_seq=4500`, `limit=500`,
after VACUUM ANALYZE; neither disables sequential scans. The old verifier used
1,200 products and selected half the table, where a Seq Scan is a legitimate
planner choice. An Index Only Scan can still perform heap visibility checks on
recently changed pages; VACUUM/visibility-map state matters. `syncfixture` is
test/script data for fresh tenants only, not a Backoffice write API.
Text length CHECKs bound published values, but do not equate character lengths
with UTF-8 byte sizes when extending the covering indexes.

The allow-list itself is why `employees` publishes `pin_hash` but never `email`
or `password`. In the Laravel original, mapping an entity name to a model by
convention had once served the whole employees row to anything holding a device
token.

**Watermarks are published after commit, never before.** Announcing a mark first
points tills at rows nobody can read yet. A watermark that reads too *low* is
the direction that hurts — a till compares it, sees no change, and does not
pull — so a failed publish deletes the key rather than leaving it behind, and
every key carries a TTL so any lost write is bounded rather than permanent.
`sync_counters` is the authority; Redis is a copy of it.

**All three sync routes require `X-Schema-Version`.** Missing or below
`MinDeviceSchemaVersion` returns `409 device_schema_outdated`; non-integer
returns `400 malformed_request`. Current and newer versions pass. The check is
in manifest, changes and pull, with HTTP regression tests. `/time`, `/health`
and device activation keep their existing contracts. Flutter v2 will send the
header in Fase 4; no Flutter code is changed in Fase 2A.

**`apply` travels in the manifest, and `product_modifier_options` must be
`upsert`.** The till's `ConflictAlgorithm.replace` deletes before inserting, and
on the device that table cascades from `modifier_options` — replacing one row
would take every product's option scoping with it, and menus would start
offering choices nobody priced.

## The auth cache, and the rule that keeps it honest

**If flushing Redis on a live system would cause anything worse than a slowdown
or a re-login, it does not belong in Redis.** That excludes orders, sessions,
the stock ledger, `sync_seq` allocation, idempotency records and the job queue.

What earns its place: the device-auth cache, rate limiting, and the sync change
watermarks.

**Every write path must go through `CachedAuthenticator`, never the bare
`Service`.** Both `Activate` and `Authenticate` sit on the `v2.DeviceService`
interface for that reason — activation rotates a token, so a handler that
reached past the wrapper would leave the cache serving a credential the database
has already replaced. That was a real bug: the token remained valid for up to
five minutes.

Invalidation is by **generation counter**, never key enumeration. An entry
records the `gen:tenant:…`, `gen:outlet:…`, `gen:register:…` versions read in the
same PostgreSQL snapshot as the binding. Revoke publishes the newer database
version monotonically; a delayed old cache fill cannot adopt it. Missing keys
are cache misses, not generation zero. Re-activation bumps the register rather than deleting the old
entry, because finding that entry would mean reading the old hash before
overwriting it — sibling tills pay one extra database read, which is cheaper
than a credential outliving its replacement.

`TestTheCacheGenuinelyServesStaleBindings` is the guard here. It revokes through
the bare service and asserts the cache **still** serves the binding, which is
what makes the other cache tests non-vacuous. Read it before changing anything
in `cache.go`.

**Redis failures fall through to PostgreSQL and never fail open.** The rate
limiter is the deliberate exception: it *allows* on failure, because losing it
costs one unthrottled window while failing closed would take the whole till
fleet offline over a cache outage.

## Backoffice (templ + HTMX)

**`gorilla/csrf` assumes the panel is served over TLS** and validates `Origin`
against an `https` scheme. Behind Caddy this process always sees plain HTTP even
when the browser used HTTPS, so `declareRequestScheme` decides per request from
`X-Forwarded-Proto` — not from `ENVIRONMENT`. Deciding from the environment is
the trap: it works locally and rejects every POST in production. Getting it
wrong in either direction refuses every state-changing request.

**Generated views (`*_templ.go`) are committed, not gitignored.** That is what
lets a clean CI checkout and the Docker build compile without the templ CLI, and
it is what makes the freshness check possible at all — CI installs the version
pinned in `go.mod`, runs `templ generate`, and fails on any diff. A newer CLI
emits slightly different code, which is why the version is pinned rather than
`@latest`.

**Sessions live in PostgreSQL, not Redis** — deliberately, so "flush Redis" is
never a frightening thing to do. Session write volume is trivial next to the
device API.

**Screens ask for a permission, never for a role.** `internal/domain/auth` is a
port of `mobile/lib/core/auth/permissions.dart` and the string values are
byte-identical on purpose: a device and the server must name the same permission
without a translation table. Two properties are why this is code and not rows:

1. **Owner is derived** — every permission except the till set — so a new
   permission reaches the owner automatically. A seeded table cannot do that; it
   needs re-seeding on every addition, and forgetting is silent. The failure
   mode is a new feature its own owner cannot open.
2. **One source of truth.** A database copy would be free to drift from the
   device's copy, which is the failure "ask for a permission, never a role"
   exists to prevent.

`TestPermissionStringsMatchTheDartEnum` and `TestOwnerIsDerivedFromTheFullSet`
guard both. The till permissions (`sell`, `openCloseShift`) belong to cashiers
only — a manager or owner covering the counter signs in on a cashier account,
which is also the honest outcome for attribution.

**Three independent conditions gate sign-in**, and they answer different
questions: is the password real, does this role use the Backoffice at all, and
does this person still work here. The last two are checked *after* the password,
and every failure returns one identical message — saying which half was wrong
turns the form into a way to enumerate accounts.

`requireEmployee` reloads the account on every request rather than trusting what
was true at sign-in, so deactivating someone takes effect on their next click.

## Backoffice writers (Fase 2B) — what every screen must keep true

Screens: catalogue (categories, products with search/filter/paging, sold-out
switch, inline variants, per-product modifier configuration, CSV price import),
modifier groups and options, promos with outlet scoping, staff (profile, PIN,
password, active), outlets and their registers. Each section is gated by the
permission it exercises — reading included — and the nav is built from the same
permissions, so a link never leads to a 403.

**Handlers translate; domain packages decide.** `internal/domain/{catalogue,
promos,outlets,staff}` own every rule, and every published mutation goes through
`syncfeed.Write`. A rejected value comes back as `validation.Errors`, keyed by
the form input name, and the handler re-renders the form with HTTP **200** and
the message beside its field. Forms round-trip the raw strings (`views.Form`),
so a person sees what they typed next to what was wrong with it.

**Money is read by one function, `parseRupiah`**, for forms and for the CSV
import alike. Dots are accepted only as correctly grouped thousands ("25.000");
anything else with a separator is refused. Stripping dots blindly reads
"25000.50" as 2.500.050 — a hundredfold price with no message.
`TestRupiahIsReadOnlyWhenItIsUnambiguous` guards it.

**Every update path claims its row first** (`SELECT … FOR UPDATE` inside the
tenant). Without it, an upsert naming another merchant's id collides with a row
RLS hides and fails with `42501 new row violates row-level security policy` — no
data crosses, but it is a 500 where the answer is 404, and it tells the caller the
id exists. `TestSavingUnderAnotherMerchantsIDIsNotFound` exists in each package.

**Cascades mirror the device.** On the till, a product's variants and modifier
attachments, a group's options and attachments, and a promo's scoping all hang
off their parent with `ON DELETE CASCADE`. Applying the parent's tombstone
deletes them locally, so the server must tombstone them too, or the two disagree
permanently. `retire` (catalogue) does it generically: lock the matching rows,
reserve one block of sequence numbers for exactly that many, stamp each row with
its own number by `ctid`. A category with live products refuses to be deleted
rather than cascading — that is a menu change, not bookkeeping.

**Only differences are written.** The sold-out switch, the active switches,
product modifier configuration, promo scoping and the price import all read
before they number anything; re-saving what is already there must not wake every
till in the company to pull an unchanged row. Each has a counter-unchanged test.

**Outlets, registers and staff are never deleted**, only deactivated — a closed
branch still has years of sales pointing at it. Outlet and register writes bump
the device-auth cache generation **after** the commit, so renaming a till reaches
its tablet's binding at once and closing a branch signs its tills out at once.
`TestClosingAnOutletSignsItsTillsOutNow` fails without the bump. A register
never moves between outlets (its devices' composite key names the outlet).

**PINs: exactly four digits, and deliberately NOT unique** (product decision,
2026-09-13). The till signs someone in by picking the account first and typing
the PIN second (`EmployeeRepository.verify(id, pin)`), so two people sharing
four digits never sign in as each other — and a 4-digit PIN has only 10,000
values, so a large company could not keep them unique anyway.
`TestStaffMayShareAPIN` pins the decision so nobody re-adds a constraint by
instinct. Fase 4 closed the last till path that resolved a PIN with no account
picked: the manager-override sheet (`authorize_sheet.dart`) now lists only the
accounts holding the permission and verifies the PIN against the chosen one,
where `byPin` used to return the first active match. The
Backoffice password is not in the feed, so setting it takes no sequence number.

**Nothing durable is derived from `APP_KEY`.** It keys ten-minute activation
codes and the CSRF secret, so rotating it costs open forms and pending codes and
nothing else. Keep it that way: no stored hash, fingerprint or published URL may
be keyed by it. (A PIN-uniqueness fingerprint once was; it went with the
constraint.)

**Product images** (`internal/infra/media`, `catalogue/images.go`,
`imageproc.go`). Uploaded on the product page, JPEG/PNG/WebP up to 10 MB, and
**always decoded and re-encoded, never stored as sent**: that strips EXIF (a
phone photo records where it was taken), makes a disguised HTML/script file
impossible to store, and bounds what a tablet decodes (longest side 1024 px).
The EXIF orientation tag is applied first — without it every portrait phone photo
lands on 15,000 tablets sideways. JPEG unless the image has transparency.
Decoding is bounded twice: 50 MP from the header before any pixel is read, and
two concurrent decodes per process.

Files live on disk (a Compose volume) under content-addressed keys,
`products/{tenant}/{sha256}.{jpg|png}`, written atomically and never modified;
Caddy serves the volume under `/media/` and the API serves the same path with the
same headers when nothing is in front. Public URL = `MEDIA_PUBLIC_BASE_URL` + key,
stored in `products.image_url` (published) with `image_key` (not published).
The file is stored **before** the row that names it is published, and old files
are never deleted on replace — a till that has not synced still shows them; a
sweep is future work. **Keep the base URL stable**: every till stores these URLs,
so moving to object storage or a CDN means repointing that host, not rewriting
product rows. MinIO was the obvious S3 choice and is no longer pullable as an
image (`pull access denied`), which is why the pilot stores on disk. The volume is
not covered by pgBackRest — back it up separately. `SaveProduct` never touches
the image, so saving the product form cannot drop a photo.

**At least one active owner, and nobody changes their own role or switch.** The
guard locks every active owner's row **in id order, before the target's own row**
(`readEmployee` unlocked → `guardLastOwner` → `relock`). Locking the target first
deadlocks two owners demoting each other; `TestTwoOwnersDemotingEachOtherLeaveExactlyOne`
reproduced `40P01` in round 1 of every run until the order was fixed.

**Promo scoping is explicit**: `promos.all_outlets` (published) decides what
`promo_outlets` means. Absence of scoping rows never reads as "everywhere" — a
promo narrowed one branch too far would otherwise spread company-wide — and the
form refuses "no outlet ticked" instead of saving a promo that is live nowhere.

**Product modifier configuration** follows the till's own
`ModifierRepository.saveConfiguration` rules, plus one it cannot recover from: a
required group must offer at least one active option. Narrowing a group below a
product's defaults, and switching off an option a product pre-selects, are
refused for the same reason. On the till an attached group with no scoped
options shows an empty picker, which is why the form says so.

## Testing

**Tests run against real PostgreSQL and real Redis, never SQLite.** RLS
policies, partial unique indexes and composite foreign keys either do not exist
there or behave differently, so a green SQLite suite would prove nothing.

`internal/infra/pgtest` clones a migrated template database per test. The
template's **name carries a hash of the migration files**, so editing a
migration produces a fresh template rather than silently reusing a stale schema,
and an unchanged schema is built once and reused across runs. Creation is
guarded by a PostgreSQL advisory lock, not `sync.Once` — `go test ./...` runs
package binaries in parallel, and two of them racing to create the same template
is a real failure that happened.

**The verification scripts are not redundant with the test suite.** They drive a
live server and catch what unit tests structurally cannot: middleware ordering,
rate limiting, `Retry-After`, the CSRF origin rules, and the JSON envelope. The
single most valuable assertion in the whole repo is in `verify-backoffice`: a
code minted **in the browser** is used to activate a till through
`POST /api/v2/devices/activate`. That proves the panel and the till agree about
one credential — something no unit test on either side can establish.

`verify-backoffice-crud` extends that proof to everything Fase 2B writes: rows
created in the browser — outlet, till, catalogue, modifiers, promo, cashier —
are pulled by a tablet activated with a code minted in the same browser, with
the values that were typed and nothing a till must not hold. It also proves the
auth-cache bumps from the outside: a rename reaches the tablet's binding at
once, and closing its branch returns 401 at once.

`verify-sync` is the same idea on the pull path: it pages the whole seeded
catalogue exactly as a till does and asserts, on every response, that the body
is a JSON **object**. That check has to live against a live server, because it
is the serialiser and the middleware stack it is really testing — and a
top-level array in a 2xx body is what the till reads as `malformed`, which on
the push path makes it delete a queued sale.

`-race` needs cgo. It runs in CI (Linux), and can also run from Windows inside
the Go Docker image with gcc/musl-dev installed. The Fase 2A closeout ran the
entire suite this way. CI also builds and starts an API and runs every live
verification script (activation through `verify-reports`) after the test suite. Those scripts must run sequentially
because their Redis-reset checks share the verification environment.

## Schema conventions

- **UUID primary keys** on everything a device can reference. The Flutter app
  generates them client-side, so a till can create a row offline and name its
  own key — and that key doubles as the idempotency key when it is pushed.
- **Money is integer rupiah**, never float.
- **Timestamps on the wire are epoch milliseconds, `int64`**, everywhere in v2.
  The v1 contract mixed epoch millis with one ISO-8601 field; v2 closes that.
- **Every 2xx body is a JSON object**, enforced by `internal/httpapi/render`.
  This is not style: the Flutter till parses any 2xx body that is not an object
  as `SyncFailure.malformed`, and a malformed push response makes it **delete
  the queued sale permanently**. A top-level array is a money-loss bug.
  `render.JSON` now marshals and validates the actual encoded top-level shape
  **before** writing HTTP status. Slices, scalars, nil, invalid RawMessage,
  unsupported Go values, and custom marshalers returning scalars produce a
  generic JSON-object 500. Tests cover these paths. The OpenAPI-wide schema
  contract test is implemented, together with real PostgreSQL row-shape tests.
- **Snapshot columns stay snapshots.** Names, rates and prices are copied at
  write time, so an old receipt never rewords itself after a rename.

## Not built yet

Platform admin (Fase 8) remains a future phase; reporting is Fase 7 and the
stock ledger Fase 5, both below. `POST /sync/push`, partitioned order/details, UUID reservations, durable
ingest audit and River maintenance are implemented, and the Flutter v2 client
(Fase 4) consumes them: batched push with per-row results, a local dead-letter
table, the `/sync/changes` fast path and `X-Schema-Version` on every sync call.
The till pulls all 16 current feeds, including modifier joins, promos and
`promo_outlets`, stock and floor-plan projections. Local schema v27 stores
promo outlet scoping and preserves unsent table events across restarts.

`api/openapi.yaml` is the generated-DTO contract for Flutter. Push advertises
`pos_sessions` then `orders`, both push-only: do not pull them or expect their
cursors in `/sync/changes`. A revision identifies an immutable outbox snapshot;
only an ACK matching the sent revision can remove it. Exact retries of the
stored revision are accepted even after settlement/closure.

Every real order change atomically marks `report_dirty_slices` and enqueues a
unique `report_slice` job; exact retry does neither. The worker consumes the
`reporting` queue (Fase 7, below); maintenance is a separate queue. River schema migrations are a restartable goose Go step because enum
additions need to commit before subsequent River versions use them.

Money semantics follow Flutter: `unit_price` already includes variant/modifier
deltas; sum `unit_price * quantity`, never add modifier deltas a second time.
Kitchen statuses are not payment progression. Only cancelled/refunded are
settled; session closure still permits the late upload of its offline receipts.

A **sweep for unreferenced image files** is not built: replaced and removed images
stay on the volume by design (a till that has not synced still shows them). A
River job that deletes files no `image_key` has named for some days is the
intended shape.

The employees feed is still company-wide, so every till holds every employee of
the merchant. With PINs no longer unique that is a size and speed question (a
till in a very large company holds and scans a long staff list), not a
correctness one; outlet-scoped staff remains an option, not a requirement.

Table status (Fase 6) and stock (below) are both outlet-scoped feeds.

## Sales reports and exports (Fase 7) — what must stay true

`internal/domain/reporting` owns rollups, the report, exports and schedules.
The worker runs it through `jobs.Reports`, the Backoffice through
`backoffice.ReportService` (`/backoffice/dashboard`, `/backoffice/reports`).

- **A report reads rollups only.** `Report` never touches `orders` or
  `order_items`; tests and `verify-reports` delete every order and get the same
  report back. "Hitung ulang" marks slices dirty and queues jobs — the page does
  not read raw tables either.
- **A slice is `(tenant, outlet, business_date)` and is rebuilt whole**: all
  seven rollup tables deleted and re-inserted in one REPEATABLE READ
  transaction. There is no incremental arithmetic, so a replayed or reordered
  push cannot double-count.
- **The dirty marker is cleared only if nothing moved.** Its generation is read
  on the rollup's own snapshot; afterwards the marker is deleted only
  `WHERE generation = g` (or, when the snapshot had none, confirmed still
  absent). Otherwise the job snoozes 30 s, which does not use up attempts.
  `SetAfterRollup` is the test seam that lands a sale in exactly that window.
- **Revenue follows the till**: status not cancelled/refunded, `unit_price`
  already includes modifiers. Order totals are summed without joining lines — a
  join fans every order out and multiplies its totals.
- **Category net is the largest-remainder split per order**
  (`AggregateCategories`, ported with the `CategorySalesAggregator` tests) and is
  computed in Go. Because the split is per order, daily rows add up to exactly
  what a whole month computed at once gives.
- **Names:** the current category/product name wins; a deleted one shows its
  newest snapshot. Cashiers are keyed by `cashier_id`, else `name:<name>`.
- **Hours use `tenants.timezone`** (default `Asia/Jakarta`). No screen edits it
  yet, and changing it needs the history recomputed.
- **Self-healing is on intervals from worker start, not a clock time:** nightly
  (24 h) re-marks every outlet's last 3 business days and purges exports older
  than 30 days; weekly, 20 random slices from the last 4 weeks are recomputed in
  a rolled-back transaction and any disagreeing table is logged as an error.
- **Exports** (`report_exports` + a `report_export` job): CSV with a UTF-8 BOM and
  formula-injection guard; XLSX written with `archive/zip` (no dependency); PDF
  via gotenberg (`GOTENBERG_URL` — unset fails the export at once, with a
  message, instead of retrying). Files are written atomically to
  `REPORTS_DIR/<tenant>/<export>.<ext>`; **the API and the worker must share that
  directory** (the `reports` volume in Compose).
- **A scheduled report mails a link, never the figures.** The token is 32 random
  bytes, only its SHA-256 is stored, it is compared in constant time and expires
  after 24 h. A mail failure keeps the file and retries only the mail. The unique
  `(schedule_id, date_from, date_to)` index stops a retried scan mailing a period
  twice; deleting a schedule detaches its exports (`ON DELETE SET NULL`).
- **`backoffice.New` must copy every `Deps` field.** It once dropped `Reports`,
  and every report route was a 404 while the rest of the panel worked;
  `routes_test.go` now walks the router for them.

`docs/PHASE_7_VERIFICATION.md` records what was checked and what was not.

## Floor plan and table status (Fase 6)

`internal/domain/tables` owns Backoffice definitions and the status projection.
The device token fixes tenant/outlet/device; neither a payload nor a URL can
move a table between branches. Deletion publishes definition + status tombstones.
Both feeds use outlet counters; there are no tenant row locks.

`table_status_events` are immutable UUID events with `client_seq` (monotonic per
device/table, unique on the server) and `basis_seq` (the table's last pulled
status sequence). Tills number `max(previous + 1, wall-clock ms)`: the
installation id — and so the device row — can outlive the till's SQLite store,
and a store that restarted at 1 would collide with the unique index. An exact
retry returns the first result, even at a newer outbox revision. A lower client
sequence cannot undo a later local action, including when clocks move backwards.
Future basis sequences are rejected. Events based on the current snapshot clear
conflicts; a following write by the same device preserves the mark. Concurrent
writers use `(occurred_at_ms, event_id)` and always publish `contested=true`.
This is auditable eventual agreement, **not an offline reservation guarantee**.

The till commits checkout + stock + its table event in one SQLite transaction.
An accepted table event requires `status_seq` and `outcome`; the outbox keeps
anything incomplete. Local pending events overlay the server snapshot until
covered, and superseded/rejected events stop masking it. After an ACK, sync
refreshes only `table_status` up to the returned watermark using the same
Retry-After gate. Rejected payloads remain recoverable in dead-letter storage.
Do not prune the local event sequence history without a durable counter replacement.

Backoffice `/backoffice/outlets/{id}/tables` owns definitions and polls its
read-only board every 15 seconds. Tills use the existing poll/manual-sync path;
SSE is deferred as allowed by the plan. See `docs/PHASE_6_VERIFICATION.md` for
the actual checks and the Windows build/UI environment blockers.

## The stock ledger (Fase 5) — what must stay true

`internal/domain/stock` owns it; the API ingest and the Backoffice both call
it, so the two surfaces cannot disagree about what a movement does.

**The ledger is append-only deltas; `outlet_stock` is its projection.** Deltas
commute, so two tills selling the same item offline converge the moment both
push, with nothing to resolve. No code writes `outlet_stock` except `apply`,
and `apply` moves it **in the same transaction** as the movement. A projection
that lagged its ledger would let a till count its own acknowledged movement on
top of a snapshot that already contains it.
`TestTwoTillsSellingOfflineConvergeOnTheOutletQuantity` is the gate: 20
received, 15+15 concurrent sales pushed three times each, projection and
ledger both land on −10 with 31 rows.

**Negative stock is recorded, never refused.** A sale that happened is a fact;
the Backoffice flags `≤ LowStockThreshold` (5, the till's own threshold)
including negatives.

**A count (stock opname) is the one server-wins case.** The row carries
`counted_qty`; `apply` replaces its delta with `counted − current` under the
projection row lock. An exact retry returns the first recorded delta, not a
second count (`TestACountBecomesADeltaAgainstTheServersQuantity`).

**Both feeds are outlet-scoped** (`t:{tenant}/o:{outlet}/e:{entity}`). A till
pulls and counts its own branch only — `PullOutlet` and `DeviceCursors` take
the outlet from the token — and contention is the tills inside one branch.
`Pull`/`Writer.SeqBlock` refuse an outlet feed (`ErrOutletRequired`) rather
than number it on the merchant's counter, which would publish rows no till
pages to. The covering indexes lead with `(tenant_id, outlet_id, sync_seq)`;
`TestPullUsesAnIndexOnlyScan` covers all 14 feeds.

**Lock order is fixed, and it is why nothing deadlocks.** Every projection row
the write touches in `(outlet, product)` order, then each branch's two counters
in outlet order, movements before stock. A writer holding a counter already
holds every row it needs. Transfers lock two branches and still follow it
(`TestConcurrentWritersAcrossBranchesNeitherDeadlockNorDrift`). No tenant row
is locked anywhere.

**`stock_seq` is how a till stops double counting.** Each accepted movement
returns (and publishes as `stock_seq`) the projection sequence of its product
after it was applied. A till adds its own movement to a snapshot only while
the snapshot is older than that sequence. The push result carries it
(`stock_seq`, `balance_after` — additive in OpenAPI 2.1.0), and so does the
pulled movement row, so a lost push response is settled by the next pull.

**Device movements are idempotent by id, identity from the token.** A
per-id advisory lock serialises concurrent retries; the canonical payload
(revision excluded — a dead letter sent again is a newer revision of the same
facts) decides exact retry versus `duplicate`. The sign must match the reason
(sale/waste negative, voidReturn/received positive); tills may not push
transfers. A product of another merchant is refused by the composite FK.

**Nightly self-heal.** The worker's `stock_reconcile` job re-derives every
active merchant's projection from its ledger (detect unlocked, repair under the
row lock with a fresh sum) and logs any repair as an error: drift means a bug or
a manual change. The worker has no Redis, so a repair publishes no watermark;
the stale key expires within five minutes.

**Backoffice** `/backoffice/stock` (permission `adjustStock`): levels per
outlet with search, alerts across outlets, ledger per product, adjustments
(received/waste/correction), count, and transfer between branches — one
transaction, two movements sharing a `ref_id`. Not built: per-product
thresholds, alert delivery, stock-aware reports.

## Fase 2A closeout and Fase 2B handoff

Review fixes on 2026-09-10: snapshot-safe pull; required schema declaration;
JSON-object response guard; 5,000-row paging and index verification for every
current feed; live verifiers in CI; repeatable k6 runner. See
[`docs/PHASE_2A_VERIFICATION.md`](docs/PHASE_2A_VERIFICATION.md) for measured
results, environment, rerun commands and the manual checklist. Load-test success
must include zero dropped iterations, zero HTTP failures, all response checks
passing, and p99 <20ms at 2,000 rps. A fast single-client run is not this gate.

Verified: 72 top-level Go tests (including the full Linux `-race` run), vet and
build passed; `verify-sync` passed 53 checks over Caddy HTTPS; activation and
Backoffice verifiers passed. Final k6 run: 2,000 arrivals/s for 60s, 120,001
measured requests, p99 **1.10ms**, zero dropped iterations, zero HTTP failures,
100% payload checks. This is one API on local Docker Desktop, sharing its host
with Postgres, Redis and k6, over internal HTTP. It does not establish production
VPS capacity; Fase 9 and the real-device pilot gates still apply.

## Fase 2B closeout and handoff

Done on 2026-09-11; see [`docs/PHASE_2B_VERIFICATION.md`](docs/PHASE_2B_VERIFICATION.md).
Fase 2A was re-verified independently first, including a mutation test proving
the snapshot test fails on READ COMMITTED.

Verified on the final code: 124 top-level Go tests (full Linux `-race` run
included), vet, build and templ freshness; `verify-backoffice-crud` 67 PASS
(twice, fresh tenants), `verify-activation` 16, `verify-backoffice` 20,
`verify-sync` 53, all over Caddy HTTPS against a rebuilt container; 19/19 checks
in headless Chrome for the HTMX behaviour the Go verifiers cannot see. Six problems
were found and fixed during the work: four are mutation-verified (the test fails
without the fix), the search-trigger fix is proven working in Chrome, and one was
caught by static analysis — see the verification document.

**The k6 gate is not stable on this host at the moment, for the old build as
well as the new one.** Interleaved A/B runs show no regression attributable to
2B (same median, comparable p99), but four of ten afternoon runs failed on brief
stalls, one with an impossible 5h58m max that points at the VM clock. Treat the
local gate as advisory until it is run on a quiet Linux host with the generator
separate from the server.

Every row created through the Backoffice is numbered in its own writing
transaction, and migration 010 numbered the rows written before that — nothing
is left at `sync_seq = 0`.

**Decisions taken on 2026-09-13** (see `docs/PHASE_2B_VERIFICATION.md`): PINs are
not unique (constraint, fingerprint column and `APP_KEY` dependency removed —
migration 009 was edited in place because it had never left this machine);
product images are uploaded, re-encoded and stored on a Compose volume served at
`/media/`; nothing durable is derived from `APP_KEY`. Re-verified after them:
142 top-level tests including the Linux `-race` run; `verify-backoffice-crud` 80
PASS both through Caddy and against the API directly (the CI path); activation
16, backoffice 20, sync 53; 25/25 in headless Chrome. `docker compose up -d
--build api caddy` — Caddy must be recreated to mount the media volume.

The end-of-Fase-2 contract and re-verification are now recorded in
`docs/PHASE_0_2_VERIFICATION.md`; continue from the current-work note at the top.
