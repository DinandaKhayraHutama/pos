# CLAUDE.md — backend-go

Guidance for the Go backend. The Flutter till lives in `../mobile/` and has its
own `CLAUDE.md`. The Laravel backend this replaced has been deleted; what it
taught lives in the invariants below and in `../plan.md`.

## What this is

**Current work (2026-09-22): the MokaPOS feature-parity roadmap has started,
and its numbering is its own.** `../docs/RENCANA_PARITAS_FITUR_MOKAPOS.md` runs
F0 → F10; **its Fase 0 and Fase 1 are done on the code and on every automated
gate that could be run** (see `../docs/FASE_0_VERIFICATION.md` and
`../docs/FASE_1_VERIFICATION.md` for the evidence and for what still needs a
machine with Visual Studio). Do not confuse it with the original Fase 0–9
below: that roadmap is finished, and the two numbering schemes overlap.
What paritas F0 added here is till recovery — controlled takeover, quarantine of
a late sale, and a manager's decision with an audit trail. Its invariants are in
"Till recovery (Fase 0 paritas)" further down. What paritas F1 added is the
sales waterfall, the read-only transaction and shift screens, and two report
endpoints for the till; see "Reporting F1 (paritas)".

**Fase 0–9 of the original roadmap are done; Fase 10 was postponed by the
product owner. Fase 9.5 was a local stabilisation pass** — the platform panel refused
its own sign-in, and the fix plus an end-to-end proof that Backoffice, platform
and till are genuinely wired to each other is in `docs/PHASE_9_5_VERIFICATION.md`,
with the click-through script in `../docs/MANUAL_TEST_LOKAL.md`.

**Fase 9 (load test and hardening)** — a Go load harness with the plan's five scenarios, Prometheus
metrics on their own listener, a Compose observability profile with alert rules
and a provisioned Grafana dashboard, explicit pool sizing, PostgreSQL tuning and
a `pg_monitor`-only credential for the exporter. See
`docs/PHASE_0_2_VERIFICATION.md`, `docs/PHASE_3_VERIFICATION.md`,
`../mobile/docs/PHASE_4_VERIFICATION.md`, `docs/PHASE_5_VERIFICATION.md`,
`docs/PHASE_6_VERIFICATION.md`, `docs/PHASE_7_VERIFICATION.md`,
`docs/PHASE_8_VERIFICATION.md`, `docs/PHASE_9_VERIFICATION.md` and
`docs/PHASE_9_5_VERIFICATION.md` for evidence
and production-readiness limits. The pilot gate still needs hardware UAT and a
load run on the pilot VPS with the generator on a separate box — every number
recorded so far comes from one laptop that was also running the database, the
cache and the generator.

**JustClick POS backend**, second edition — one Go binary serving:

| Surface | Path | Auth | Who |
|---|---|---|---|
| Device API | `/api/v2` | device bearer token | the Flutter till |
| Web Backoffice | `/backoffice` | session cookie, `justclick_backoffice` | Owner, Manager |
| Platform admin | `/platform` | password + TOTP, session cookie `justclick_platform` | super admins |

Stack: Go 1.27 · chi · pgx/v5 · goose · templ + HTMX 2 · scs (Postgres store) ·
gorilla/csrf · go-redis v9 · PostgreSQL 18 · Redis 8 · Caddy.

**The rewrite is not "PHP was slow."** It exists to remove four defects that
were verified in the Laravel code and would have hit a wall long before language
choice mattered — chiefly that every pushed order took `SELECT … FOR UPDATE` on
the *tenant row*, so all 5,000 outlets serialised behind one lock. That tree is
gone; `../plan.md` records the four defects and the evidence for each.

## Commands

All run from `backend-go/`:

```bash
docker compose up -d --build api           # rebuild the API after source changes; starts Postgres/Redis too
docker compose up -d caddy                 # local HTTPS on :8443
go run ./cmd/justclick migrate up          # goose, on MIGRATE_DATABASE_URL
go run ./cmd/justclick roles set-password  # credentials for the two login roles
go run ./cmd/justclick tenant create --name … --slug … --owner-name … --owner-email …
go run ./cmd/justclick platform admin create --name … --email …   # prints the password once; TOTP enrols at first sign-in
go run ./cmd/justclick platform admin reset-totp --email …        # lost phone and spent recovery codes
go run ./cmd/justclick platform admin deactivate --email …        # also ends that admin's impersonations
go run ./cmd/justclick diagnostics till --tenant …                # read-only: conflicts, orphan stock effects, open recoveries
go run ./cmd/justclick serve               # API + Backoffice + /platform on :9000
templ generate                             # after editing any .templ
go test ./... -count=1                     # needs real Postgres AND Redis
go run ./scripts/verify-activation         # against a running server
go run ./scripts/verify-backoffice         # against a running server
go run ./scripts/verify-backoffice-crud    # against a running server: panel writes reach the till
go run ./scripts/verify-sync               # against a running server
go run ./scripts/verify-push               # 200 receipts x3 through HTTP; isolated disposable tenant
go run ./cmd/justclick worker              # River: partitions, stock reconcile, report rollups/exports/schedules
go run ./scripts/verify-reports            # Fase 7 gate: 30-day seed, rollup == raw, < 200 ms, exports
go run ./scripts/verify-platform           # Fase 8: TOTP, onboarding, limits, modules, impersonation, suspension
go run ./scripts/verify-recovery           # Fase 0 paritas: the manager's takeover and late-sale path, through the browser
go run ./scripts/verify-history            # Fase 1 paritas: till history filters, the two report endpoints, transactions/shifts screens
go run ./cmd/justclick diagnostics reports --tenant …   # read-only: receipts whose money does not close
go generate ./api ./internal/store         # pinned OpenAPI + SQL generators
go run ./scripts/verify-sync-load          # Fase 2A gate: disposable 2000-device k6 fleet
docker compose --profile observability up -d   # Prometheus, Grafana, exporters
go run ./scripts/loadtest smoke            # Fase 9 harness: full device lifecycle in seconds
go run ./scripts/loadtest changes --rate 2000 --duration 60s
go run ./scripts/loadtest orders --orders-per-second 200 --duration 60s --devices 600 --workers 300
go run ./scripts/loadtest rush --devices 15000 --spread both
go run ./scripts/loadtest fanout --devices 15000
go run ./scripts/loadtest datascale --orders 2000000 --days 30
```

**Measure through the container, not through a host `justclick serve`.** Add
`--base-url https://localhost:8443 --insecure-tls`. A host process reaches
Redis and PostgreSQL through Docker Desktop's published-port proxy, and that
path degrades under sustained load: in one session the same 2,000 rps run swung
from p99 5.9 ms to 227 ms on the host path while the containerised API, measured
at the same moment, stayed at a 5.5 ms mean. Stop the observability profile
before taking a gate number on a single box — its scrapes take the same CPU.

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
`TenantContext::runUnscoped()` played in the Laravel original. Its importers are
held to an allow-list by `TestUnscopedImportersAreCountable`: device token
resolution, Backoffice login by email, tenant provisioning, the scheduled-report
scan, the worker's merchant listing and partition maintenance, and the platform
panel (Fase 8), which is cross-merchant by definition. Adding a package to that
list is a security review, not a test fix.

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

**One panel, one door.** A browser cookie ignores the port, so `localhost:8443`
and `localhost:9000` share one jar under the same host name — a CSRF token
minted behind TLS is sent to the plain-HTTP door, where the scheme no longer
matches and every POST is refused as `origin invalid`. `HTTP_ADDR` and
`METRICS_ADDR` therefore default to `127.0.0.1` outside Compose, and
`TRUST_PROXY` is documented in `.env.example` with what happens when it is
wrong: unset behind TLS, the browser sends an https Origin while the server
compares it against http, and the panel refuses its own login.

**`Referrer-Policy` on a panel is a functional decision, not only a privacy
one.** gorilla/csrf falls back to the Referer header when a browser sends no
Origin on a form POST, and the platform panel shipped with `no-referrer` —
instructing browsers to withhold exactly that fallback. It refused its own
sign-in with "referer not supplied" for six days. `same-origin` keeps the
property that mattered (no other site learns these URLs, and several pages here
show a credential once) and leaves the panel able to identify itself.

**A CSRF refusal must say what decided it.** `web.CSRFFailure` logs the reason,
`Origin`, `Referer`, `Host`, `X-Forwarded-Proto` and the scheme the server
concluded — the last of which no browser can show you — and renders a page a
person can act on. Four very different causes used to share one bare line of
text: a real cross-site POST, an expired token, a browser told to withhold both
headers, and a proxy misconfiguration.

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

Not built for Fase 9's observability: an Alertmanager (rules fire in Prometheus
and are visible there and nowhere else), a backup-age metric (pgBackRest is not
deployed) and a certificate-expiry probe (Caddy exports none; blackbox_exporter
is the intended shape). Not measured: a run on the pilot VPS with the generator
on a separate box, and a 30-million-order history — it needs about 36 GB, and
this machine has 34 GB free.

Platform admin (Fase 8), reporting (Fase 7) and the stock ledger (Fase 5) are
built; each has its section below. Not built for the platform panel: QR codes at
TOTP enrolment (the secret is typed), admin management in the panel (CLI only),
an IP allow-list for `/platform` at Caddy, a default-tariff seed at onboarding
(`business_settings` exists since Fase 3 but is written only when the owner saves), and module switches that reach the till's feeds. `POST /sync/push`, partitioned order/details, UUID reservations, durable
ingest audit and River maintenance are implemented, and the Flutter v2 client
(Fase 4) consumes them: batched push with per-row results, a local dead-letter
table, the `/sync/changes` fast path and `X-Schema-Version` on every sync call.
The till pulls all 27 current feeds (18 before Fase 3), including brands, customers, modifier joins, promos and
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

## Platform admin (Fase 8) — what must stay true

`internal/domain/platform` owns super admins, onboarding, suspension, limits,
module switches, impersonation, the audit trail and the ops report;
`internal/platform` is its panel at `/platform`; `internal/domain/entitlements`
is the leaf package every merchant-side writer consults. See
`docs/PHASE_8_VERIFICATION.md` for what was checked.

**The boundary is the GRANT.** Migration 001's default privileges hand every new
table to `justclick_app`, so migration 018 revokes `super_admins`, recovery
codes, `platform_sessions`, `platform_audit_log` and `password_setup_tokens`
from it outright, and grants them to `justclick_unscoped` only.
`tenant_limits`, `tenant_feature_flags` and `impersonation_sessions` are
readable by their own merchant (RLS `FOR SELECT`) and writable only by the
platform. `platform_audit_log` is `SELECT, INSERT` — not even the platform
credential can edit it. `TestTheMerchantCredentialCannotReachPlatformTables`
and `TestThePlatformAuditLogIsAppendOnly` guard this; `rls_test.go` inverts its
check for the two platform tables that carry `tenant_id`. Platform sessions use
their own table through the unscoped credential and their own cookie
(`justclick_platform`, `Path=/platform`, `SameSite=Strict`, 30 min idle).

**Every platform action writes its audit row in the same transaction**
(`platform.Record` takes a `pgx.Tx`, never a pool). A function that closes
something and then reports an error must return nil from the transaction and
report after it: returning the error inside rolls the close back.
`ActiveImpersonation` shipped with exactly that bug for one test run.

**Sign-in is password, then TOTP or a recovery code.** A password alone moves
the session to `verify` or `enroll`; only a code moves it to `in`, and
`requireAdmin` reloads the admin every request. TOTP is RFC 6238 on the
standard library (SHA-1, 6 digits, 30 s, ±1 step), tested against the RFC
vectors. **A code is accepted only for a step later than the last accepted** —
one `UPDATE … WHERE totp_last_step < $step`, so two requests with one observed
code cannot both get in (`TestTheSameCodeSignsInExactlyOnceUnderConcurrency`);
the enrolment code counts as used. Recovery codes are SHA-256, claimed by CAS.
The first admin, a reset after a lost phone, and deactivation are CLI only.
The TOTP secret is stored readable — it must be, to verify — and is not
encrypted with `APP_KEY`, which must never key anything durable.

**Onboarding is one transaction**: `tenancy.ProvisionTx` + three numbered
starter categories + limits + a setup token + the audit row. The owner has no
password until they use the link (72 h, SHA-256, single use by CAS), so nobody
— the admin included — ever knows it; with no SMTP the link is shown once on the
panel. Reissuing cancels older links and leaves the current password working
until the new link is used, which is how support recovers a locked-out owner.

**Suspension stops tills, not just the panel** (product decision, 2026-09-15).
The predicates already existed (`t.status = 'active'` in device auth,
activation, sign-in, `ByID`, the worker); what makes it immediate is
`Bump("tenant", id)` **after** the commit. The till answers 401 by returning to
its activation screen and keeps its outbox; reactivation restores the same
token. The status UPDATE takes `FOR NO KEY UPDATE` on the tenant row, which does
not conflict with the `FOR KEY SHARE` of order foreign keys — never read the
tenant row with `FOR UPDATE` to "check first". Suspending ends open
impersonations. `tenants.status` has a CHECK: an unknown status would pass every
`= 'active'` predicate as locked out with no screen that says why.

**Impersonation is write-capable and audited, by design.** A handoff token
(32 bytes, SHA-256, one minute, CAS) is posted — never put in a URL — from the
platform page to `POST /backoffice/impersonate`, which sits outside the CSRF
group (it cannot hold the Backoffice token) but refuses a cross-site `Origin`.
The session carries `impersonation_id`; `requireEmployee` re-checks it every
request (expired, ended, admin deactivated, merchant suspended → signed out).
`auditImpersonatedWrites` writes the audit row **before** a non-GET runs and
answers 503 without running it when the row cannot be written. Password and PIN
routes refuse under impersonation. The banner is rendered in `Shell` and cannot
be dismissed. Rows changed under impersonation are attributed to the owner; the
audit trail is what ties them to the admin.

**Limits are count-then-insert under a transaction advisory lock**, taken only
by a bounded merchant and only for the rare writes that add a counted row
(outlet or till switched on or created, code issued, device activated). An
unlimited merchant reads one row and takes no lock
(`TestOnlyABoundedMerchantTakesTheLimitLock`). Order: after the row claim,
before any sync counter. Activation is the authority: a refusal rolls the claim
back so the code stays usable, the installation being re-activated is not
counted, and the API answers **422 `device_limit_reached`** (OpenAPI 2.3.0,
additive; the till reads any 422 as "get another code"). Issuing a code
pre-checks so the owner sees why in the panel. Lowering a limit switches
nothing off.

**Module switches close Backoffice sections, never till data.** A missing row
means the default in code (all on), so a new flag reaches existing merchants
without a backfill; setting a switch back to its default deletes the row.
`requireFeature` answers 404 and `sessionView` folds the same switch into the
nav. Export polling is hidden with the module, or it would toast a 404 every
five seconds. Scheduled reports of a merchant with exports off are skipped and
stay due.

**Last seen is advisory and must not move the device revision.**
`CachedAuthenticator.Touch` writes `devices.last_seen_at` at most once per
device per five minutes (Redis `SET NX`; no Redis, no write) and never touches
`updated_at` — that feeds `RevisionMs`, and moving it would send every till to
`/devices/me` on each touch. `TestTouchingLastSeenMovesNeitherTheRevisionNorTheAuthGeneration`.

**Usage reads devices and `daily_sales_rollup`, never `orders`.** The ops page
reads `goose_db_version` (granted to the unscoped role), River's job table,
`report_dirty_slices` and `jobs.DefaultPartitions`.

`TestUnscopedImportersAreCountable` holds the list of packages that import
`internal/store/unscoped`; adding one is a security review.

## Coordinated tills — what must stay true

`internal/domain/ingest/till.go` owns the online half: cashier sign-in, claiming
a drawer, handover, current status and receipt history. `sale.go` owns the money
half. Migration 020 holds `till_access`, `till_claims` and `till_operators`.
`scripts/verify-till` drives all of it over HTTP.

**Online coordination is deliberately separate from offline ingest, and there is
no heartbeat.** A till keeps its drawer through a network outage; nothing
expires a claim because the holder went quiet. The first device may still be
selling, and handing its drawer to a second device because a ping stopped is how
one shift becomes two sets of books.

**One active selling assignment per cashier, and it follows the ASSIGNMENT, not
the opener.** `till_one_active_cashier` is a partial unique index on
`(tenant_id, active_employee_id)`. Handover moves the assignment; closing clears
it. Keying it on whoever opened the session would forbid the handover the
product already supports.

**Lock order is register, then session/claim — and never the tenant row.** Open,
handover and close all take `pos_registers … FOR UPDATE` first, so two devices
racing one till serialise on the register they are both claiming.

**The session UUID is the idempotency key, and the client stores it before it
asks.** A replay with the same id and the same opening snapshot returns the same
claim; a replay whose snapshot differs is `idempotency_conflict`. A lost reply
therefore costs a retry, never a second drawer.

**`pos_registers.coordinated_sessions` is a one-way gate.** Once a register has
been claimed online, a session arriving through the legacy push path is refused
with `register_busy`. Without it a downgraded client would quietly reopen the
very hole this closes.

**Closing waits for the receipts.** A claimed session closes only when its
`order_count` matches the receipts the server actually holds; otherwise the
device is told `dependency_pending` and keeps them. Closing is also what clears
the cashier assignment, so a cashier who never closes can never sell elsewhere —
that is the intent, not an oversight.

**A receipt and its stock effects commit in ONE transaction** (`ingestSale`).
Effects bind to `ref_id = the order's id`, never to the human-readable receipt
number, which repeats across installations. A later revision may not omit an
effect that already committed, and quantities are bounded by the receipt's own
lines.

**History is newest-first, and its scope comes from the token.** The cursor
carries `placed_at_ms:uuid` because a v4 UUID sorts at random — paging by id
alone was stable and meaningless. A cashier sees their own receipts; anything
wider is resolved from the employee the cashier token names, never from a query
parameter. `TestHistoryIsNewestFirstAndPagesInThatOrder` guards both halves.

**A cashier token carries the PIN hash it was minted against**, so changing a
PIN revokes every till sign-in that used the old one. The rows are pruned by the
hourly maintenance job; nothing else deletes them.

**Receipt numbers come from a server-allocated block of 100,000 per claim.** A
device numbers offline from its own block, and exhausting it falls back to a
UUID label rather than reusing a number. Two installations can no longer print
the same receipt number.

## Till recovery (Fase 0 paritas) — what must stay true

Coordination above has no heartbeat, on purpose. That leaves exactly one way a
lost tablet's drawer can be closed: **a human decides, and the decision is
audited.** `internal/domain/ingest/recovery.go` owns it, migration 021 holds
`till_recoveries`, `till_recovery_items` and `till_recovery_events`, the manager
reaches it from `/backoffice/devices`, and `scripts/verify-recovery` drives the
whole path through the browser. Evidence and the gaps that remain are in
`../docs/FASE_0_VERIFICATION.md`.

**Nothing is ever repaired automatically, and no evidence is deleted.** There is
no database reset, no bulk requeue of a conflict, no takeover triggered by a
missed ping, and no late receipt accepted without a manager. The quarantined
payload is the byte-for-byte one the till sent, kept permanently even after the
`ingest_log` partition it was received in has been retired — which is why
`till_recovery_items` keeps `source_ingest_date` / `source_ingest_id` as
coordinates without a foreign key.

**The typed register name is the confirmation, and it is the only thing between
a mistyped click and someone else's open drawer.** `ForceTakeover` refuses with
`register_confirmation_mismatch` before it touches anything. `operation_id` is
generated per page render, so resubmitting the same rendered form is one
takeover, not two.

**One transaction closes the drawer, revokes the tablet and opens the case.**
Close as `close_kind='forced'` with `forced_recovery_id`, clear the active
cashier, drop `till_access`, null the device token, cancel live activation codes,
write the `takeover` event. The cache is told afterwards through
`CachedAuthenticator.InvalidateRevoked`, because the revocation was committed by
another domain's transaction.

**The closed session's `till_claims` row is deliberately KEPT.** `ingestSale`
only enforces the session guards when the session is *claimed*; deleting the
claim would let every late receipt through with no guard at all instead of
holding it. Only `active_employee_id` is nulled — `till_one_active_cashier`
forbids one cashier holding two claims, and that cashier has to be able to open
the replacement drawer.

**The manager's cash count sits BESIDE the snapshot, never instead of it.** The
case stores `expected_cash_at_takeover` (opening cash plus the session's cash
sales) and `order_count_at_takeover` as the server computed them, plus
`counted_cash` if the manager entered one. A closed shift's own numbers stay
immutable.

**`recovery_id` is the only key that passes the `session_closed` refusal, and it
passes nothing else.** `ingestSaleForRecovery` skips that one guard when the
caller holds the matching case; tenant, device ownership, cashier assignment,
amounts, idempotency and stock validation all still run on the same code path as
a normal sale. A late receipt with no decision behind it is refused with
`recovery_required` and its case id, so the till can explain itself.

**An exact retry is one quarantined item.** The unique key is
`(recovery_id, entity, entity_id, revision)`, while `ingest_log` stays an audit
of every received attempt. Approval writes exactly one order, one set of stock
effects and one dirty report slice; the till's own retry afterwards is a plain
duplicate. Discarding writes no order and no stock movement at all.

**A case cannot be closed while an item is pending**, so nothing is decided by
omission, and closing twice does not restate the first close's basis. Re-opening
an already-decided item is refused with `recovery_already_decided`.

**`DiagnoseTill` is read-only and shared** by the Backoffice card and
`justclick diagnostics till`. One caveat worth knowing before trusting it as
coverage: `cashier_has_multiple_claims` cannot fire while
`till_one_active_cashier` exists. It is defence in depth for the day that index
is dropped, not a tested path.

## Load testing and observability (Fase 9) — what must stay true

`scripts/loadtest` is the harness, `internal/infra/metrics` is what it reads
back, and `ops/` holds the Prometheus rules and the Grafana dashboard. See
`docs/PHASE_9_VERIFICATION.md` for the measured numbers and the findings.

**A load test that drops arrivals is telling you something; a load test that
delays them is lying.** The driver is an open model: each arrival is due at its
own time, and one that finds every worker busy is counted as dropped. A closed
loop reports healthy latency for a server nobody could use, because the
generator politely slows down with it. `fanout` is the one closed-loop
scenario, and only because its question is "what did the database do" — every
till must pull exactly once there.

**The harness may take shortcuts in provisioning, never in the measured path.**
Device rows are written directly with their token hashes, because activating
15,000 tablets would measure the activation limiter. Every measured request
carries a real bearer token through the real middleware, auth cache and
per-device limiter. Activation itself is covered by `loadtest smoke` and
`verify-activation`.

**`startupSpread` is a port of the till's own function and must stay
byte-identical.** The morning-rush scenario's claim — that the spread flattens
the burst — is a claim about the distribution
`mobile/lib/data/sync/sync_scheduler.dart` produces. Both sides pin the same
vectors (`TestTheStartupSpreadMatchesTheFlutterTill` in Go, "startup spread
matches the load harness on fixed vectors" in Dart); if one moves, the other
fails, because a harness that spread devices some other way would prove nothing.

**"No lock on the tenant row" cannot be checked by mode alone.** An INSERT into
`orders` takes a RowShareLock on `tenants` while PostgreSQL checks the foreign
key, and always will; a deliberate `SELECT … FOR UPDATE` takes the same mode.
What separates them is the consequence, so the gate is **ungranted** locks
(a transaction waiting for another) and anything RowExclusiveLock or stronger
(something writing the table). The static half of the proof is the
`no-tenant-lock` CI job over the source.

**Metrics live on their own listener (`METRICS_ADDR`), never a route on the
public server.** `/metrics` names every internal queue, and a route on :9000
would be one Caddy rule away from being readable by anyone. Compose does not
publish the port. Labels use chi's **routing pattern**, never the URL — a label
a caller chooses grows a series per request until the process runs out of
memory, and `page.Entity` rather than `?entity=` on the pull path is the same
rule.

**The fleet-wide gauges belong to the worker.** River queue depth, dead jobs,
rollup staleness, devices seen and DEFAULT partition occupancy are
cross-merchant reads; `internal/infra/jobs` is already on the `unscoped`
allow-list and there is exactly one worker, so the gauges mean one thing.
Publishing them from the API would add a package to that list, which is a
security review.

**A nil `*metrics.Metrics` instruments nothing and panics at nothing.** Every
test, script and one-shot command builds the server's dependencies without a
registry; making instrumentation optional is what keeps that true.

**postgres_exporter connects as `justclick_metrics`** — `pg_monitor` and not one
table grant (migration 019, guarded by
`TestTheMetricsCredentialCanReadStatisticsAndNoMerchantData`). Its per-table
collectors are switched off because they were measured at 78–100 ms per scrape
on 86 relations, and this schema adds partitions every month.

**An alert rule that cannot fire is worse than a missing one** — it looks like
cover. `alerts.yml` therefore carries the two the plan asks for and nothing
publishes yet (backup age, certificate expiry) as comments with the expression
to use once pgBackRest and blackbox_exporter exist.

**`synchronous_commit` is not configurable in Compose, on purpose.** Everything
else in the PostgreSQL tuning block is an environment variable; this one is
money, and a benchmark is exactly the situation where someone would loosen it.

**Pool ceilings are sized against PostgreSQL's `max_connections`, not the
container's CPU count.** pgx defaults to `max(4, NumCPU)`, which on a two-vCPU
box is four connections for the whole API; the symptom is request latency with
no slow query behind it, and `justclick_pgxpool_empty_acquires_total` is the
only place it shows.

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

## Reporting F1 (paritas) — what must stay true

Migration `20260922000022_reporting_f1` is additive; `internal/domain/history`
is new and read-only; `internal/httpapi/v2/reports.go` serves the till. See
`../docs/FASE_1_VERIFICATION.md`, and `scripts/verify-history` alongside the
extended `scripts/verify-reports`.

**Net sales = gross sales − discounts − sales returns, and gross profit = NET
SALES − COGS.** The old definition used revenue − COGS, so PB1 and service
charge — money collected on somebody else's behalf — inflated every margin by
whatever the tariff was. Gross sales deliberately keep a receipt that was later
refunded IN, and the return line takes it out again: a refund is then visible
instead of the day quietly shrinking. Identically, gross − discounts − returns
== subtotal − discount over the orders `revenue` already counts, which is why
both are asserted on every slice.

**"Refunded amount" and "sales returns" are two different numbers, and neither
substitutes for the other.** The return is the sale that came back
(subtotal − discount); the refunded amount is the money handed over, tax
included. A full refund of a 15.000 sale with 1.500 PB1 returns 16.500 and
reverses 15.000. `verify-history`'s Bintaro case exists for exactly this.

**`anomaly_count` flags arithmetic that does not close, never an honest partial
refund.** The first cut used `refunded_amount IS DISTINCT FROM total`, which
flagged every ordinary full refund, because a NULL there MEANS "the whole
total". It is now: total ≠ subtotal − discount + tax + service charge, or a
refund larger than the sale. Flagged, listed by
`justclick diagnostics reports`, and never repaired — F1 does not rewrite a
receipt to make a report tidy.

**The category split and the product-inside-category split share ONE read and
ONE allocation** (`writeCategoryAndProduct`). The order's discount goes to its
categories, then each category's share to the products inside it. Two separate
queries land a rupiah apart on any order whose split has a remainder, and a
month of those is a breakdown that does not add up to its own total.
`verify-reports` checks the invariant — that every dimension sums to net sales
— rather than recomputing the largest-remainder split a second time, which
would only prove the script agrees with itself.

**The weekday comes from the BUSINESS date, in SQL, with no timezone applied.**
The business date is already the merchant's trading day; converting it again
moves a Saturday's late sales into Sunday. The `days` column says how many of
each weekday actually traded, so a range that is not a whole number of weeks
can be read honestly.

**Cost and profit are removed from the RESULT, never hidden by a template.**
`Report.WithoutCostData` clones its slices before zeroing — a `Report` value
copies slice HEADERS, so blanking in place would also blank the caller's copy.
The till's `/till/reports/summary` goes further: the cost keys are ABSENT from
the body, not zeroed, so nothing downstream can read a zero as a figure.
`/till/reports/sales` is the only place they exist, behind
`viewFinancialReports`.

**History paging is keyset and the cursor is bound to its filter.** A list
people scroll while tills are still selling would repeat and skip rows under
OFFSET. The cursor carries the full sort key — business date, the millisecond,
then the UUID, because a v4 UUID orders at random — and the business date leads
it now that a page can span days. A cursor minted by the old single-day
contract has no date in it and is refused with `invalid_cursor` rather than
guessed at.

**A scope a cashier may not have is REFUSED, not narrowed.** `resolveHistory`
answers `forbidden_scope`, `forbidden_range` or `forbidden_cashier`; handing
back a narrower list unlabelled makes a colleague look like they sold nothing.
`day` combined with `from`/`to` is `ambiguous_range` for the same reason. The
response echoes the scope and range the server actually applied, so a till can
say which list it is showing.

**`internal/domain/history` never writes.** A receipt is immutable once printed
and a closed session keeps its snapshot; correcting either happens on the till,
where the person and the drawer are. The Backoffice screens over it offer no
void and no refund, and that is a product decision, not a stage of work.

**A session's receipts are read WITHOUT a date range.** A shift can run past
midnight and own receipts on two business dates; bounding by one drops half of
them. Receipts whose timestamp is later than the closing snapshot are listed
separately (`AfterClose`) — a counted drawer is not rewritten.

**The backfill is the durable markers, and nothing else.** `QueuePending`
drains `report_dirty_slices` a hundred slices per merchant per minute; progress
lives only in those markers, so an interrupted backfill resumes rather than
restarting, and an overlapping sweep enqueues nothing new (the slice job key is
unique). There is deliberately no active-outlet predicate: a closed branch
still has years of sales, and leaving them at calculation version 1 would make
every whole-chain report permanently incomplete. A report counts the version-1
slices in range and says the waterfall is not final yet.

**The Device API was 2.7.0 here** (Fase 1), additive: `/till/orders` keeps `day` and
`before`, and the master-data feed schema is unchanged at version 1. Fase 3 made
it 2.8.0 — see the pricing section below.

## Pricing, roles and business settings (Fase 3 paritas) — what must stay true

Plan: `../docs/RENCANA_IMPLEMENTASI_FASE_3.md`; evidence:
`../docs/FASE_3_VERIFICATION.md`.

**One pricing engine, written twice, held together by shared vectors.**
`internal/domain/pricing` (Go, no DB) and `mobile/lib/core/pricing/pricing.dart`
compute the same thing from the same `Input`. `testdata/pricing/*.json` at the
REPOSITORY ROOT is the contract: both `vectors_test` files read every file and
fail when a file is added that the other side does not know. Change the engine
on one side only and CI goes red on the other; both workflows watch
`testdata/**`. Money is integer rupiah, rates are basis points, products use
`big.Int` / `BigInt` so nothing rounds through a float. Version 1 is an EXACT
port of the old Flutter cart math (share floors, no remainder, no rounding) and
exists so one vector format covers both; the server never recomputes a v1
receipt. Allocation is Hamilton largest-remainder (`pricing.Allocate`) — NOT
"whole remainder to the largest line", which can hand a line more than its own
weight.

**Ingest refuses only arithmetic that does not close; it FLAGS what does not
reproduce.** The header equation is
`total = subtotal − discount + tax − tax_included + service_charge + rounding`
with `0 ≤ tax_included ≤ tax`; a pre-F3 till sends neither new term, so its
check is the old one. A version 1 receipt carrying a snapshot, included tax or
rounding is refused. A version 2 receipt needs its snapshot and a full line
breakdown; each line must satisfy `net = unit_price·qty − line_discount −
bill_share − tax_included`, and the lines must sum to the header. Then
`pricing.Compute(snapshot)` is run: a different answer sets
`orders.pricing_mismatch` (written at insert only, part of the immutable
revision) and counts as a report anomaly. **Never turn that into a refusal** —
the customer paid what the receipt says, and an offline till cannot re-price.

**Device capabilities gate what an old app cannot read.**
`X-Device-Capabilities` (`pricing-v2`, `roles-v1`; unknown tokens dropped) is
recorded on `devices.capabilities` only when the set CHANGES, and never touches
`updated_at` (that is the device revision a till polls). An absent header on a
`/sync/*` route is an old build and records the empty set; other routes leave
it alone. `devices.IncompatibleDevices` is the one query behind every gate:
`settings.SetPricingModel` (per outlet, locks the outlet row) and custom-role
assignment (`staff`, tenant-wide, because the employee feed is company-wide and
an old till reads an unknown role as a cashier who may sell). Activation of an
old build is refused while either model is on. The Backoffice devices page
marks active devices that lack a capability ("perlu update").

**Roles: a row for identity, code for system permissions.** `roles` is seeded
with the three system rows by a trigger on `tenants` (every fixture and
`tenancy.Provision` get them for free). System roles take their permissions
from `auth/permission.go`, so a permission added later reaches the owner
without a reseed; custom roles store a list and unknown names are dropped when
read, never granted. `employees.role` is DERIVED from `role_id` by trigger
(`custom` for a custom role), so every existing `role = 'owner'` lookup still
works. An editor may grant only what they hold plus the till set; only an owner
makes owners; nobody edits their own role. The Backoffice staff form posts a
role row id, and still accepts a system role key.

**Business and outlet settings.** `business_settings` has one row per merchant
and it exists only once the owner has SAVED it — a till treats "no row" as "not
configured" and keeps its own preferences (D8). `outlet_settings` overrides it
field by field: NULL inherits, 0 is a real override. The outlet's sales-type
and payment-group assignment ride on `outlet_settings` as arrays instead of two
join feeds (no rows = everything active). Nine feeds were added — `roles`,
`business_settings`, `sales_types`, `payment_methods`, `payment_groups`,
`discounts`, `outlet_settings`, `product_sales_type_prices`,
`outlet_product_sales_type_prices` — for **27** in all. `Entity.Singleton` and
`Entity.SystemRows` tell `syncfixture` and `verify-sync` what a merchant starts
with.

**`payment_method` on the wire stays the KIND** (`cash`, `card`, `qris`,
`ewallet`, `transfer`, `other`), so every drawer expectation that compares to
`'cash'` is unchanged. The method's own id and name travel beside it, and
`reporting.PaymentLabel` prefers the name.

**Timezone is per merchant, limited to WIB/WITA/WIT.** `tenants.legacy_timezone`
froze the zone every pre-F3 order was dated in; `hourlySQL` uses an order's own
`tz_offset_minutes` and falls back to that frozen zone, so recomputing an old
slice never moves its hours. A change marks today's slices dirty.

**Reports.** Net sales are `subtotal − discount − tax_included` everywhere
(waterfall, anomalies, history, sessions); a version 2 order's category,
product and brand net read each line's `net_amount`, because item discounts
are not proportional. Rounding is revenue, never sales. Migration 035 added
`tax_included`/`rounding` to the daily rollup plus sales-type and payment-method
rollups, and marked every historical slice dirty; `calculation_version` did not
move (only v2 receipts, which did not exist before, read differently).

**The Device API is 2.8.0**, additive. `scripts/verify-pricing` is the live
gate: capability recording, the v2 refusal and release, v2 receipts accepted /
flagged / refused, and a report whose waterfall closes with included tax and
rounding.

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
