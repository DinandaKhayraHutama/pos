# JustClick POS — Monorepo

Restaurant Point of Sale platform for FnB clients. One Git repository, two projects:

| Path | What it is | Status |
|---|---|---|
| [`mobile/`](mobile/) | Flutter POS app (iOS, Android, web, desktop) — offline-first on local SQLite | Active |
| [`backend/`](backend/) | Laravel API + web Backoffice — multi-tenant, PostgreSQL | Active |

## Running the till app

```bash
cd mobile
fvm flutter pub get
fvm flutter run
```

The Flutter project root is `mobile/`, not the repository root: `pubspec.yaml`,
`l10n.yaml`, `analysis_options.yaml` and the platform folders all live there, and
every Flutter command has to be run from inside it. Details in
[`mobile/README.md`](mobile/README.md).

## Running the backend

Needs PHP 8.4 (with `ext-intl`), Composer, and PostgreSQL 18.

```bash
cd backend
composer install
cp .env.example .env && php artisan key:generate
createdb justclick_pos && createdb justclick_pos_test
php artisan migrate --seed
php artisan serve
```

Backoffice at <http://localhost:8000/backoffice>, API at `/api/v1`. Seeded demo
Owner: `farhan@nti.test` / `password`. Details in
[`backend/CLAUDE.md`](backend/CLAUDE.md).

## The two are independent

They share a repository, not a toolchain: no shared build, no shared
dependencies, and the Flutter app still runs entirely offline against its own
SQLite database. The backend is being introduced gradually behind that, so the
till keeps working at every step.
