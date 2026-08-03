# AGENTS.md

Perch is the native macOS notch file shelf in the nebelhaus family.

**This file is the one set of instructions, for every agent.** Claude Code,
Codex, OpenCode, Cursor, Copilot — TUI or GUI — all read *this*, directly or
through a one-line pointer. Nothing harness-specific belongs here; when a flow
needs per-client wiring (a hook, a slash command), the wiring lives in that
client's own file and the *content* stays here or in `.agents/`. The map of
which tool reads which file is [`.agents/README.md`](./.agents/README.md).

## Non-negotiable invariants

- Never move, rename, edit, or delete a source URL.
- All blocking file coordination, cloud waiting, and copies stay off main.
- File promises are handled before ordinary URLs.
- Outgoing drags advertise copy only.
- Persist relative staged paths only; never persist or log original paths.
- A visible `ShelfItem` must point at a completed staged representation.
- Keep display/window code out of importing and persistence.
- Licensing is offline: no network call, no entitlement, no file outside the
  container. The free-tier cap is decided before staging, never mid-drag.

## Build

```sh
xcodebuild -project Perch.xcodeproj -scheme Perch \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

Read `PRD.md`, `ARCHITECTURE.md`, and the ADRs before changing transfer
semantics. Update them when a product boundary changes.

## Release & downstream (like trill)

Perch is a native Xcode app that macOS 26 won't let Nix build from source (the
`_nixbld` user can't apply SwiftPM's manifest sandbox), so — exactly like
trill — the family consumes a **CI-built, Developer-ID-signed, Apple-notarized
release ZIP**, not a from-source build:

- `VERSION` is the single source of truth (CalVer, `YYYY.MM.DD[-N]`); it names
  the tag and is injected as `MARKETING_VERSION`. Cut releases with
  `bench release perch` from the workshop — never hand-type a version.
- `.github/workflows/release.yml` (on a `v*` tag) signs + notarizes + staples,
  publishes the GitHub release, and rewrites the CI-owned pins in two places at
  once: `Casks/perch.rb` (homebrew-tap) and `nix/release.nix` here.
- `flake.nix` exposes `overlays.default` (puts `perch` in pkgs) + `packages`,
  wrapping the release ZIP pinned in `nix/release.nix` (`nix/package.nix`). The
  rice adds this input and installs `pkgs.perch` at a fixed `/Applications`
  path, so perch rides the flake-lock chain like the rest of the family.
- `nix/dev-app/` is the `prebuilt` injection point: `bench try` builds a signed
  dev `Perch.app` from a source branch in your login session and overrides
  `prebuilt` at it, so a branch feel-tests without waiting on a release.

Released: `nix/release.nix` pins a real notarized release (CI rewrites it on
every `bench release perch` tag) and the rice enables `nebelhaus.perch.enable`
by default, like trill.
