# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

This is a monorepo holding three separate projects. **This file is only an index —
no project's real guidance lives here.**

| Path | Project | Its own guidance |
|---|---|---|
| `mobile/` | Flutter POS app | [`mobile/CLAUDE.md`](mobile/CLAUDE.md) — the substantial one, read it before touching anything under `mobile/` |
| `backend-go/` | Go API + Backoffice — **the backend being built** | [`backend-go/CLAUDE.md`](backend-go/CLAUDE.md) — read it before touching anything under `backend-go/` |
| `backend/` | Laravel API + Backoffice — **superseded** | [`backend/CLAUDE.md`](backend/CLAUDE.md) |

**`backend/` is being replaced by `backend-go/`.** It is kept only as a
reference for the invariants it documents — the lost-update proof in
`SyncCursor`, the three money guarantees in `OrderIngest`, the largest-remainder
discount split in `CategorySalesAggregator` — and it will be deleted once the Go
backend passes the pilot gate. Do not add features to it. `backend-go/CLAUDE.md`
is the successor to `backend/CLAUDE.md` as the invariant record.

The projects share no code and no toolchain. Flutter commands run from
`mobile/`, `go` from `backend-go/`, `php artisan` from `backend/`, and no
directory's guidance applies to another.

**The Flutter project root is `mobile/`, not the repository root.** `pubspec.yaml`,
`l10n.yaml`, `analysis_options.yaml`, `test/`, `integration_test/` and every
platform folder live inside `mobile/`, so `fvm flutter <command>` has to be run
from there — running it at the repository root finds no `pubspec.yaml` and fails.
Every path in `mobile/CLAUDE.md` and `mobile/AGENTS.md` is written relative to
`mobile/`, so a reference to `lib/data/...` there means `mobile/lib/data/...`
from here.

The Dart package is still named `nti_pos` (`name:` in `mobile/pubspec.yaml`), so
imports stay `package:nti_pos/...` regardless of the folder rename. Android
`applicationId` (`com.example.nti_pos`) and the iOS bundle id
(`com.example.ntiPos`) are likewise unchanged.

## Commits

Conventional Commits — `<type>(<scope>): <subject>`. Scope by project where the
change is project-specific (`feat(pos):`, `feat(api):`); omit or use a shared
scope for repo-wide changes. Types: `feat`, `fix`, `refactor`, `chore`, `docs`,
`test`, `style`, `perf`.
