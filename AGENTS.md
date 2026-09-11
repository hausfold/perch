# AGENTS.md

Perch is the hausfold family's macOS notch file shelf. Family rules and routing
are the workshop's `AGENTS.md`; harness wiring is
[`.agents/README.md`](./.agents/README.md).

## Non-negotiable invariants

- Never move, rename, edit, or delete a source URL.
- All blocking file coordination, cloud waiting, and copies stay off main.
- File promises are handled before ordinary URLs.
- Outgoing drags advertise copy only.
- Persist relative staged paths only; never persist or log original paths.
- A visible `ShelfItem` must point at a completed staged representation.
- Keep display/window code out of importing and persistence.
- A sender that isn't the app (`perch` tool, paired phone) gets its admission
  receipt before it copies a byte.
- `PerchUpdater` replaces the one bundle it is nested inside, only after the
  download satisfies `PerchSigning.payloadRequirement`. It is the only
  un-sandboxed code we ship that writes outside a container; it takes no
  arguments and no path from anyone.

Read `PRD.md` and `ARCHITECTURE.md` before changing transfer semantics; update
them when a product boundary moves. **A decision is stated once, where it
binds**; the user-facing half lives in the perch tree on hausfold.co, another
repo — change both in the same round.

## Build

**Xcode 26 or newer, macOS 14 or newer, Apple Silicon.**

```sh
# macOS app + the whole test suite (includes the wire loopback tests)
xcodebuild -project Perch.xcodeproj -scheme Perch \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test

# iOS companion + Share extension (simulator)
xcodebuild -project Perch.xcodeproj -scheme PerchIOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData build
```

Targets: `Perch` · `PerchCLI` (the `perch` tool, in the bundle) · `PerchUpdater`
(`Contents/Helpers/PerchUpdater.app`) · `PerchIOS` · `PerchShare` · `PerchTests`.
`PerchWire/`, `PerchMobileCore/`, `PerchDiagnostics/` and `PerchFinderBridge/`
compile straight into their consumers; `PerchDiagnostics/` (`InstallKind`,
`SystemProfile`) is quoted by the bug form and `perch doctor` alike. The Mac
ships no app extension: the Finder door is the `NSServices` entry in
`Perch/Config/Info.plist` (`ShelfServicesProvider`). Keep the `FinderAction*`
names and the `FinderActionRequests` directory — an installed `perch` writes
there.

What bites:

- **One perch owns the notch**: a second copy exits at launch. Quit the
  installed app first, or set `PERCH_ALLOW_MULTIPLE=1` — it reaches only a
  process inheriting your shell (`.../Contents/MacOS/Perch`, `open --env`, an
  Xcode scheme), never `open -a`. `xcodebuild test` starts no shelf.
- Every `xcodebuild` registers its `Perch.app` with LaunchServices, forever, so
  this Mac is a bad instrument for Finder-menu questions — duplicate Service
  rows have been misread as perch bugs. `pbs -dump_pboard` names the bundle
  behind each row; `pluginkit -r` clears nothing; the `lsregister -kill` recipe
  is in [`docs/feel-testing.md`](./docs/feel-testing.md), the hands-on runbook.
  A hand-built bundle may need `xattr -dr com.apple.quarantine
  /Applications/Perch.app`.
- Never pass `CODE_SIGNING_ALLOWED=NO` to an **iOS** build you intend to run —
  it strips the App Group entitlement and the app aborts at launch.
- **`arch=arm64` on the destination is load-bearing**, and every invocation in
  `build.yml` and `release.yml` carries it. A bare `platform=macOS` matches two
  destinations on an Apple Silicon Mac — `arch:arm64` and `arch:x86_64`, the
  same "My Mac" id twice — and xcodebuild takes the first, so the slice is a
  property of the machine rather than a decision. The project declares no
  `ARCHS`, so `-showBuildSettings` resolves the universal `ARCHS_STANDARD` and
  *confirms* the wrong answer; only the command line disagrees. Release builds
  add `ARCHS=arm64` on top, and `scripts/assert-arm64-only.sh` walks the bundle
  for Mach-Os and fails before signing — nothing downstream would notice, since
  signing, notarization, stapling and `PerchSigning.payloadRequirement` are all
  indifferent to arch.
- `ENABLE_CODE_COVERAGE = NO` is set project-wide, both configurations — an
  instrumented `perch` litters `default.profraw` wherever the shell sits.
  Coverage needs both `ENABLE_CODE_COVERAGE=YES -enableCodeCoverage YES … test`.
  `scripts/assert-no-instrumentation.sh` guards it: CI runs it on every macOS
  Release build, before signing, and those build steps pass no
  `ENABLE_CODE_COVERAGE=NO` on purpose — the guard proves the project setting
  holds on a stock `build`. Run it on any bundle you install.
- Bundle ids derive from `PERCH_BUNDLE_ID` (`$(PERCH_BUNDLE_ID)`, `.cli`,
  `.tests`, `.ios`, `.ios.share`). Rename with that override, never
  `PRODUCT_BUNDLE_IDENTIFIER=` on the command line — it collapses every target
  onto one id. [`nix/dev-app/README.md`](./nix/dev-app/README.md)
- The CLI product is `perch-cli`, never `perch`: case-insensitively
  `Contents/MacOS/perch` replaces the app's executable, and `perch.swiftmodule`
  collides with `Perch.swiftmodule`, hence `PRODUCT_MODULE_NAME = PerchCLI`.
  Installers put it on `PATH` as a symlink named `perch`, never a copy —
  `nix/package.nix`, homebrew-tap's `Casks/perch.rb`, haus's Shelf room.
  Protocol and exit codes: [`docs/cli.md`](./docs/cli.md).
- `PerchUpdater`'s three refusals are pinned by `PerchTests/SelfUpdateTests.swift`:
  only the bundle it is nested in, only a notarized payload signed by our team,
  only a newer build of the same bundle id. `PerchUpdater/UpdateHandoff.swift`
  compiles into both targets. Only the `.direct` cohort reaches it — `haus` or
  `brew` would undo the swap. Feel-test it in a VM with
  `PERCH_UPDATE_ON_LAUNCH=1`.

## The agent surface (`ai/SKILL.md`)

[`ai/SKILL.md`](./ai/SKILL.md) is for an agent *using* perch with no checkout,
to the workshop's `docs/agent-surface.md`. It ships three times,
byte-identical: the committed file, `pkgs.perch-skill` (`nix/skill.nix`), and
a Swift string `perch skill` prints and `perch skill install` writes. CI's
`skills` and macOS jobs (`.github/workflows/build.yml`) hold that:

- `scripts/check-skills.sh ai perch` — frontmatter, `name:`, a one-line
  `description` ≥80 characters, ≤150 lines, one trailing newline.
- `scripts/embed-skills.sh` — regenerates `PerchCLI/GeneratedSkills.swift`;
  `--check` fails when stale. **Run it in the same commit as any `ai/SKILL.md`
  edit**, and edit `ai/SKILL.md` in the same PR as any verb, flag or exit code.
- `scripts/check-cli-surface.sh <perch-cli>` — the only test that exercises
  `PerchCLI`. It never runs a bare `skill install`, which writes the real
  `$HOME`.

`perch doctor` (`--json` for callers) runs with no app and never launches one.
Its first two lines are the block `.github/ISSUE_TEMPLATE/bug.yml` asks for;
that template is generated from hausfold/workshop, so edit it there. The app's
*Report a Bug…* row (`Perch/App/PerchApp.swift`) opens the same form.

## Release & downstream

Nix can't build the app from source on macOS 26 (`_nixbld` can't apply
SwiftPM's sandbox), so the family consumes a CI-built, Developer-ID-signed,
notarized release ZIP.

- `VERSION` (CalVer `YYYY.MM.DD[-N]`) names the tag and is injected as
  `MARKETING_VERSION`. Cut releases with `bench release perch` from the
  workshop; never hand-type a version or hand-bump a pin.
- `.github/workflows/release.yml` (on a `v*` tag) signs, notarizes, publishes,
  and rewrites the two CI-owned pins: homebrew-tap's `Casks/perch.rb` and
  `nix/release.nix` here.
- `flake.nix` wraps the pinned ZIP (`nix/package.nix`); haus installs
  `pkgs.perch` and enables `haus.shelf.enable` by default.
- `nix/dev-app/` is the `prebuilt` injection point: `bench try` builds a signed
  dev `Perch.app` from a branch and overrides `prebuilt` at it.

## The companion's own path (App Store)

The iOS half ships through the App Store, free, on the same `v*` tag:
`.github/workflows/testflight.yml` archives `PerchIOS` and uploads the `.ipa` to
TestFlight. Submitting for review is a human act — runbook:
[`docs/app-store.md`](./docs/app-store.md). It **stays here, not in
hausfold/ops**: the shipping loop reruns on every `bench release perch` carrying
a phone change, so it is a live reference rather than a record, and `ops/log/`
takes only the latter.

- `PerchIOS/` and `PerchShare/` each carry a `PrivacyInfo.xcprivacy` over the
  same shared sources — a new required-reason API is a two-file change.
- `VERSION` reaches App Store Connect with leading zeros stripped (`2026.08.06`
  → `2026.8.6`); build number = `run_number × 10 + (attempt − 1)`.

## Before you open a PR

A `worktree-*` PR gets a **What / Why / Verify / Watch-out** body and the
clean-context assurance pass (workshop ship skill, Steps 3 and 2.5), which here
hunts a broken invariant, a hand-bumped pin, and user-visible behaviour with no
doc edit. Advisory, never a gate; spawning that subagent is user-requested by
this line.
