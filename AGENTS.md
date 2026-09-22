# AGENTS.md

Index for the JustClick POS monorepo. Longer-form project memory lives with each
project, not here.

## Layout

| Path | Project | Its own memory |
|---|---|---|
| `mobile/` | Flutter POS till | [`mobile/AGENTS.md`](mobile/AGENTS.md) (file map, common tasks) and [`mobile/CLAUDE.md`](mobile/CLAUDE.md) (condensed operating guide) |
| `backend-go/` | Go API + Backoffice + platform admin | [`backend-go/CLAUDE.md`](backend-go/CLAUDE.md) — the invariant record; read it before touching anything under `backend-go/` |

## The one thing to know before running anything

**The Flutter project root is `mobile/`, not the repository root.** All Flutter
tooling — `fvm flutter pub get`, `analyze`, `test`, `gen-l10n`, `build` — must be
run from inside `mobile/`. Paths inside `mobile/AGENTS.md` and
`mobile/CLAUDE.md` are relative to `mobile/`. Go commands run from
`backend-go/`, and its paths are relative to that.

The Dart package name (`nti_pos`), the Android `applicationId`
(`com.example.nti_pos`) and the iOS bundle id (`com.example.ntiPos`) were not
changed by the move to `mobile/`, so imports and installed-app identity are
unaffected.

## Commits

Conventional Commits — `<type>(<scope>): <subject>`. Scope by project where the
change is project-specific (`feat(pos):`, `feat(api):`); omit or use a shared
scope for repo-wide changes. Types: `feat`, `fix`, `refactor`, `chore`, `docs`,
`test`, `style`, `perf`.
