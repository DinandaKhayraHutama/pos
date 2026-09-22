# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

This is a monorepo holding two projects. **This file is only an index —
no project's real guidance lives here.**

| Path | Project | Its own guidance |
|---|---|---|
| `mobile/` | Flutter POS till | [`mobile/CLAUDE.md`](mobile/CLAUDE.md) — the substantial one, read it before touching anything under `mobile/` |
| `backend-go/` | Go API + Backoffice + platform admin | [`backend-go/CLAUDE.md`](backend-go/CLAUDE.md) — the invariant record, read it before touching anything under `backend-go/` |

The projects share no code and no toolchain. Flutter commands run from
`mobile/` and `go` from `backend-go/`; no directory's guidance applies to the
other.

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

## There is no Laravel here

The first backend was Laravel 12 + Filament. It was replaced by `backend-go/`
before either reached production and the tree has been **deleted** — there is no
`backend/` directory, no PHP, and no `php artisan` in this repository.

Comments in the Go code still say "the Laravel original", and they are worth
keeping: they record *why* an invariant exists, not where to go and read it. The
four scale defects that caused the rewrite, and the invariants inherited from
it — the lost-update proof behind `SyncCursor`, the three money guarantees of
`OrderIngest`, the largest-remainder discount split — are written up in
[`plan.md`](plan.md) and, where the code that keeps them lives, in
[`backend-go/CLAUDE.md`](backend-go/CLAUDE.md).

## Commits

Conventional Commits — `<type>(<scope>): <subject>`. Scope by project where the
change is project-specific (`feat(pos):`, `feat(api):`); omit or use a shared
scope for repo-wide changes. Types: `feat`, `fix`, `refactor`, `chore`, `docs`,
`test`, `style`, `perf`.
