# AGENTS.md

Index for the JustClick POS monorepo. Longer-form project memory lives with each
project, not here.

## Layout

| Path | Project | Its own memory |
|---|---|---|
| `mobile/` | Flutter POS app | [`mobile/AGENTS.md`](mobile/AGENTS.md) (file map, common tasks, backend migration path) and [`mobile/CLAUDE.md`](mobile/CLAUDE.md) (condensed operating guide) |
| `backend/` | Laravel API + Backoffice | [`backend/CLAUDE.md`](backend/CLAUDE.md) (multi-tenancy rules, identity model, testing) |

## The one thing to know before running anything

**The Flutter project root is `mobile/`, not the repository root.** All Flutter
tooling — `fvm flutter pub get`, `analyze`, `test`, `gen-l10n`, `build` — must be
run from inside `mobile/`. Paths inside `mobile/AGENTS.md` and
`mobile/CLAUDE.md` are relative to `mobile/`.

The Dart package name (`nti_pos`), the Android `applicationId`
(`com.example.nti_pos`) and the iOS bundle id (`com.example.ntiPos`) were not
changed by the move to `mobile/`, so imports and installed-app identity are
unaffected.
