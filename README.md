# JustClick POS — Monorepo

Restaurant Point of Sale platform. One Git repository, two projects:

| Path | What it is |
|---|---|
| [`mobile/`](mobile/) | Flutter POS till — offline-first on local SQLite |
| [`backend-go/`](backend-go/) | Go API + web Backoffice + platform admin — multi-tenant, PostgreSQL, Redis |

They share a repository, not a toolchain: no shared build, no shared
dependencies. Flutter commands run from `mobile/`, `go` from `backend-go/`, and
neither directory's guidance applies to the other.

## Running the till app

```bash
cd mobile
fvm flutter pub get
fvm flutter run
```

**The Flutter project root is `mobile/`, not the repository root**: `pubspec.yaml`,
`l10n.yaml`, `analysis_options.yaml` and every platform folder live there, so a
Flutter command run at the repository root finds no `pubspec.yaml` and fails.
Details in [`mobile/README.md`](mobile/README.md).

With no `API_BASE_URL` the app runs in demo mode against its own seeded SQLite
database — no server needed. Point it at a backend with
`--dart-define=API_BASE_URL=https://your-host/api/v2`; the till refuses plain
`http` for anything but loopback.

## Running the backend

Needs Docker. From `backend-go/`:

```bash
cp .env.example .env          # then fill in the passwords
docker compose up -d --build api worker caddy
go run ./cmd/justclick migrate up
go run ./cmd/justclick roles set-password
```

| Surface | Address | Who |
|---|---|---|
| Device API | `https://localhost:8443/api/v2` | the till |
| Backoffice | `https://localhost:8443/backoffice` | Owner, Manager, cashiers |
| Platform admin | `https://localhost:8443/platform` | super admins |

Create a merchant with
`docker compose exec api /justclick tenant create --name … --slug … --owner-name … --owner-email …`,
and a super admin with `… /justclick platform admin create --name … --email …`.
Details, and every invariant worth knowing before changing anything, in
[`backend-go/CLAUDE.md`](backend-go/CLAUDE.md).

## Walking the whole thing end to end

[`docs/MANUAL_TEST_LOKAL.md`](docs/MANUAL_TEST_LOKAL.md) is the script that
proves Backoffice, platform admin and till are wired to each other: create a
merchant, issue an activation code in the browser, activate a till with it,
sell, and watch the sale appear in the reports.

## History

The first backend was Laravel 12 + Filament. It was replaced by `backend-go/`
before either reached production, for four scale defects that were verified in
its code — chiefly that every pushed order took `SELECT … FOR UPDATE` on the
*tenant row*, so all of a company's outlets serialised behind one lock. The
Laravel tree has been deleted; [`plan.md`](plan.md) records the reasoning, and
the invariants it taught are written into `backend-go/CLAUDE.md` where the code
that keeps them lives.
