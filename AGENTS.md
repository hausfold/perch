# AGENTS.md

Perch is the native macOS notch file shelf in the hausfold family.

**This file is the one set of instructions, for every agent** — Claude Code,
Codex, OpenCode, Cursor, Copilot alike, directly or through a one-line pointer.
Per-client wiring lives in that client's own file; the content stays here or in
[`.agents/`](./.agents/README.md).

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
- `PerchUpdater` replaces the one bundle it is nested inside, and only after the
  download satisfies `PerchSigning.payloadRequirement`. It is the only
  un-sandboxed code we ship that writes outside a container; it takes no
  arguments and no path from anyone.

## Build

**Xcode 26 or newer, macOS 14 or newer.** A bundle you built or copied by hand
may carry macOS's quarantine flag, where the signed cask never does — clear it
with `xattr -dr com.apple.quarantine /Applications/Perch.app`.

```sh
# macOS app + the whole test suite (includes the wire loopback tests)
xcodebuild -project Perch.xcodeproj -scheme Perch \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test

# iOS companion + Share extension (simulator)
xcodebuild -project Perch.xcodeproj -scheme PerchIOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData build
```

One perch owns the notch: a copy launched while another is running exits
immediately (two panels stack pixel-for-pixel and the top one silently eats
every click). Quit the installed app before running a dev build, or set
`PERCH_ALLOW_MULTIPLE=1` to run them side by side on purpose — that one only
reaches a process that inherits your shell (`.../Contents/MacOS/Perch`,
`open --env`, an Xcode scheme); a plain `open -a` gets launchd's environment
instead and stands down anyway. The test host is this same app, so a test run
starts no shelf at all — `xcodebuild test` never puts a panel on the notch or
restores/prunes the live staging repository.

Every `xcodebuild` here registers the app it built with LaunchServices, from
wherever `DerivedData` sits — and nothing ever unregisters it. Measured
2026-08-23: 40 `Perch.app` records — lanes, bench, scratchpads, plain Xcode
builds — of which 6 were live bundles declaring the `addToShelf` Service, under
two different bundle ids. It costs nothing at runtime, but it makes this Mac a
**bad instrument for any Finder-menu question**: duplicated Service rows and a
Quick Action whose registered provider is some lane's build cache are both
artifacts of it, and both were misread as perch bugs twice already (2026-08-23
and 2026-08-25). Two things make that cheaper to see through now — a Debug
build's Services row says "Add to Perch Shelf (Debug)" so it names itself, and
`pbs -dump_pboard` names the bundle behind every row without disturbing
anyone's desktop. Reach for those first. `pluginkit
-r` does **not** clear the records — it only knows appex providers. When you do
need a clean database, run the full-path `lsregister -kill -r -domain local
-domain system -domain user` (it is not on `PATH`; [`docs/feel-testing.md`](./docs/feel-testing.md)
has the invocation), re-register `/Applications/Perch.app`, `killall Finder` —
and take the reading before the next lane builds. That file collects the rest of
the recipes that read wrong on the first run — priming a watched folder before
testing catch-up, APFS clones making a 3 GB drop instant, `--level info` on `log
stream` — and is worth a look before any hands-on pass.

Don't pass `CODE_SIGNING_ALLOWED=NO` to the **iOS** build you intend to run:
it strips the App Group entitlement and the app aborts at launch. Simulator
ad-hoc signing needs no team or provisioning.

`ENABLE_CODE_COVERAGE = NO` is set project-wide, in **both** configurations,
on purpose. Xcode's default is YES, and the Xcode 26 build service applies it
to a plain `build` too — not just to `test` — so every binary we shipped
carried `__llvm_prf` sections and dumped a `default.profraw` into the caller's
working directory on exit. `perch` is on PATH everywhere, so that file landed
in whatever repo the shell happened to be sitting in and read as untracked
work to `scruff` and `bench status`. To collect coverage you now have to ask for
it twice — `ENABLE_CODE_COVERAGE=YES -enableCodeCoverage YES … test`. The flag
alone is not enough: the project-level `NO` wins, `xcodebuild` still exits 0,
and you get a green run with an empty report.

**`scripts/assert-no-instrumentation.sh` is what keeps that true.** CI runs it
on the macOS Release build of every PR, and on the **macOS** release build
*before* it is signed, notarized, stapled and published — an instrumented
bundle passes all four of those steps. The iOS archive is not guarded: a
sandboxed app has no shell working directory to litter. It walks every Mach-O in the bundle (the app,
`perch-cli` *and* the nested `PerchUpdater.app`), fails on `__llvm_prf_cnts`, and fails just as loudly when it finds
no binaries at all, because a guard with no subject has not passed. The build
steps deliberately do **not** pass `ENABLE_CODE_COVERAGE=NO`: the point is to
prove the project-level setting still holds on a stock `build`. Run it by hand
against any bundle you're about to install.

Targets: `Perch` (macOS) · `PerchCLI` (the `perch` tool, embedded in the app
bundle) · `PerchUpdater` (the one-click update, embedded at
`Contents/Helpers/PerchUpdater.app`) · `PerchIOS` (iPhone/iPad app) ·
`PerchShare` (Share extension) · `PerchTests`. **The Mac ships no app
extension.** A `PerchFinderAction` Quick
Action lived here until 2026-08-23 and was removed: measured on macOS 26 it
never rendered under Quick Actions, drew a duplicate row under Services, and
shelved nothing when clicked. The Finder door is the app's own `NSServices`
entry (`Perch/Config/Info.plist`, `ShelfServicesProvider`).

Shared sources, compiled into their consumers directly: `PerchWire/` (wire
protocol + crypto + the staging layer both platforms use), `PerchMobileCore/`
(iOS-only shelf/pairing/delivery, app + extension), `PerchDiagnostics/` (Mac app
+ CLI: `InstallKind`, the four-door update cohort, and `SystemProfile`, the
macOS/model pair — both are quoted in the bug form *and* printed by `perch
doctor`, which has to answer them with no app running, so neither side can ask
the other), and `PerchFinderBridge/`
(Mac App Group mailbox; `HandoffClient` is the sender half, and since the
extension went the CLI is the only sender. The `FinderAction*` names and the
on-disk `FinderActionRequests` directory stay — an installed `perch` tool
writes to that path, so renaming it would strand requests from a copy of the
tool the app didn't ship with).

Every target's bundle id derives from one project-level `PERCH_BUNDLE_ID`
(`$(PERCH_BUNDLE_ID)`, `.cli`, `.tests`, `.ios`, `.ios.share`). Rename the
family with **that** override, never with `PRODUCT_BUNDLE_IDENTIFIER=` on the
xcodebuild command line — a command-line `PRODUCT_BUNDLE_IDENTIFIER` applies to
every target in the scheme and collapses them all onto one id, which on the iOS
side makes `PerchShare` an extension sharing its container's identifier, i.e.
malformed.
[`nix/dev-app/README.md`](./nix/dev-app/README.md)

`PerchUpdater` is the sandbox's other half. `Perch` is sandboxed, so it can
download a release into its container and no further — `/Applications` is
outside it, and a process it spawns inherits the sandbox. An app launched
through **LaunchServices** does not (probed 2026-08-26: a nested helper launched
with `NSWorkspace.openApplication` from a sandboxed parent runs with the real
home and writes to `/Applications`), so the swap lives in this bundle: no
sandbox, no entitlements, no window, one run. Three refusals are what make that
safe to ship, and all three are pinned by `PerchTests/SelfUpdateTests.swift` —
it replaces only the bundle it is nested inside, the payload must be a notarized
build signed by our team, and it must be a newer build of the *same* bundle id.
The handoff between the halves is `PerchUpdater/UpdateHandoff.swift`, compiled
into both targets (the app takes that file and nothing else out of that folder —
a membership exception in the project). Only the `.direct` cohort ever reaches
it: swapping a bundle `haus` or `brew` owns would be undone by that tool's next
run. [`docs/feel-testing.md`](./docs/feel-testing.md) has the VM recipe — the
click lives on a notch, so a hands-on pass sets `PERCH_UPDATE_ON_LAUNCH=1`
rather than taking someone's screen.

The CLI product is `perch-cli`, not `perch`, and that is load-bearing: macOS
filesystems are case-insensitive, so `Contents/MacOS/perch` *is*
`Contents/MacOS/Perch` and silently replaces the app's own executable — the app
you launch then prints CLI usage and exits 1. Installers put it on `PATH` as
`perch` — a symlink into the bundle, never a copy, and all three routes do it:
`nix/package.nix`, homebrew-tap's `Casks/perch.rb` (`binary … target:
"perch"`), and haus's Shelf room, which links it out of `/Applications`. A copy
would be a second, unsigned-by-association executable that stops matching the
app the moment either is replaced — the CLI is signed and notarized *with* the
bundle, and a symlink cannot come apart from it. Same class of trap: a Swift target named `perch` emits a
`perch.swiftmodule` that collides with the app's `Perch.swiftmodule`, so it sets
`PRODUCT_MODULE_NAME = PerchCLI`.
[`docs/cli.md`](./docs/cli.md)

Read `PRD.md` and `ARCHITECTURE.md` before changing transfer semantics, and
update them when a product boundary changes. **A decision is stated once, at the
place it binds** — the CLI mailbox in `docs/cli.md`, the licence in `LICENSE`,
the companion's tag in this file, and everything a *user* meets (watched
folders, the update nudge, the shelf's own behaviour, the Settings pane names)
in the perch tree on hausfold.co. ⚠️ That last one is a different **repo**, so
it can never be the same commit and nothing checks the halves agree — change
both in the same round. Don't start a parallel decisions tree; the second copy is the
one that goes stale.

## The agent surface (`ai/SKILL.md`)

**Don't confuse it with this file.** `AGENTS.md` is for an agent working **on**
perch, from a checkout. [`ai/SKILL.md`](./ai/SKILL.md) is for an agent **using**
it — on a stranger's Mac, with no checkout, when their human says *"put this in
my shelf"*. It is the routing document that makes that sentence work first try:
what perch is, its verbs, its exit codes, when to reach for something else.

It is bound by the family standard, [the workshop's
`docs/agent-surface.md`](https://github.com/hausfold/workshop/blob/main/docs/agent-surface.md) —
≤150 lines, no flag dumps (that's `--help`), and the `description` frontmatter
names **the phrases a user says**, not the features perch has. A description
written as a feature summary is true, well written, and never loads.

**It ships three times, and the three are byte-identical by construction.** The
committed source; `pkgs.perch-skill` (`nix/skill.nix`, `$out/<skill>/SKILL.md`),
which is how haus's AI room installs it into every agent client on a machine;
and a Swift string literal inside the CLI, which is what `perch skill` prints and
`perch skill install` writes. Embedded rather than read off disk because perch
ships as a cask's `.app`, a read-only Nix store path and a dragged ZIP, and the
tool on `PATH` is only ever a symlink into the bundle — every "read the file
beside me" scheme is right for exactly one of those doors.

Two scripts keep that true, and **both run in CI** (`.github/workflows/build.yml`,
the `skills` job) because every failure they catch is invisible at runtime:

- `scripts/check-skills.sh ai perch` — frontmatter present and closed, `name:`
  matching the directory it installs into, a one-physical-line `description` of
  at least 80 characters, ≤150 lines, and exactly one trailing newline (the two
  shipping mechanisms disagree on a file with two). `nix/skill.nix` runs this
  same script rather than carrying its own copy of the greps. It **discovers**
  `ai/*/SKILL.md`, so a second skill needs no edit here.
- `scripts/embed-skills.sh` — regenerates the committed
  `PerchCLI/GeneratedSkills.swift`; `--check` fails when it is stale. Run it in
  the same commit as any `ai/SKILL.md` edit. It is committed rather than built
  by a script phase so an `xcodebuild` from a release tarball needs no shell
  script to have run first.
- `scripts/check-cli-surface.sh <perch-cli>` — runs both verbs against a real
  binary and checks the bytes and the exit codes they promise. **It is the only
  test of any kind that exercises `PerchCLI`**: `PerchTests` compiles the app,
  not the tool, so nothing else in the suite would notice `perch skill` printing
  the wrong file or `skill install` returning 0 on a write it could not do. The
  macOS job runs it against the Release bundle's embedded `perch-cli`. It never
  runs a bare `skill install` — that writes into the real `$HOME`.

**Every claim in it must be runnable.** When you change a verb, a flag or an
exit code, change `ai/SKILL.md` in the same PR *and* re-run
`scripts/embed-skills.sh` — a stale line there is a confidently-wrong
instruction with a nice format, and a stale generated file is one the binary
would print anyway.

`perch doctor` is the other half of the surface: version, install cohort, macOS
and model, container, and whether a shelf answers, with `--json` for a caller.
It is the only verb that needs no running app, and it deliberately never
launches one — a doctor that starts the patient cannot report on the patient.
⚠️ Its first two lines are the block `.github/ISSUE_TEMPLATE/bug.yml` asks a
reporter to paste; that template is **generated from hausfold/workshop**, so its
wording changes there, not here.

## Release & downstream

Perch is a native Xcode app that macOS 26 won't let Nix build from source (the
`_nixbld` user can't apply SwiftPM's manifest sandbox), so the family consumes a
**CI-built, Developer-ID-signed, Apple-notarized release ZIP**, not a
from-source build:

- `VERSION` is the single source of truth (CalVer, `YYYY.MM.DD[-N]`); it names
  the tag and is injected as `MARKETING_VERSION`. Cut releases with
  `bench release perch` from the workshop — never hand-type a version.
- `.github/workflows/release.yml` (on a `v*` tag) signs + notarizes + staples,
  publishes the GitHub release, and rewrites the CI-owned pins in two places at
  once: `Casks/perch.rb` (homebrew-tap) and `nix/release.nix` here.
- `flake.nix` exposes `overlays.default` (puts `perch` in pkgs) + `packages`,
  wrapping the release ZIP pinned in `nix/release.nix` (`nix/package.nix`). haus
  adds this input and installs `pkgs.perch` at a fixed `/Applications` path, so
  perch rides the flake-lock chain like the rest of the family.
- `nix/dev-app/` is the `prebuilt` injection point: `bench try` builds a signed
  dev `Perch.app` from a source branch in your login session and overrides
  `prebuilt` at it, so a branch feel-tests without waiting on a release.

`nix/release.nix` pins a real notarized release (CI rewrites it on every `bench
release perch` tag) and haus enables `haus.shelf.enable` by default.

## The companion's own path (App Store)

The iPhone/iPad half can't ride the cask or the flake — it ships through the App
Store, free, on the *same* `v*` tag:
`.github/workflows/testflight.yml` archives `PerchIOS`, exports the `.ipa`, and
uploads it. It stops at TestFlight — attaching a build to a store version and
submitting for review is a human act, and its runbook (listing copy, privacy
label, export compliance, screenshots, review notes) is
[`docs/app-store.md`](./docs/app-store.md).

Two things bite if you forget them: `PerchIOS/` and `PerchShare/` each carry a
`PrivacyInfo.xcprivacy`, and they compile the *same* shared sources — a new
required-reason API is a two-file change. And `VERSION`'s CalVer reaches App
Store Connect with leading zeros stripped (`2026.08.06` → `2026.8.6`), build
number = `run_number × 10 + (attempt − 1)` (see `docs/app-store.md`).

## Before you open a PR

Give a `worktree-*` branch's PR a **What / Why / Verify / Watch-out** body (the
workshop ship skill's Step 3): the session that wrote the code is gone by the
time it's feel-tested, so a bug found later has to be recoverable from `gh pr
view` alone, and the **Verify** block is what `bench try-batch`'s checklist
points back to.

**Run the pre-PR assurance pass — every PR, not just `/ship`'d ones.** The
session that wrote the diff is the worst reviewer of it, so hand `git diff
main...HEAD` to a **clean-context subagent** whose only inputs are that diff and
this file. In this repo it hunts: a diff that quietly breaks one of the
non-negotiable invariants above — a source URL moved, blocking coordination back
on main, an original path persisted or logged, a `ShelfItem` pointing at an
incomplete staging; a hand-bumped release or downstream pin; and user-visible
behavior changed with no matching doc edit. Full checklist: the ship skill's
**Step 2.5**.

It's **advisory, never a gate** — fix anything ≥3/5 before opening the PR, carry
the rest into the PR's **Watch out** block, and say so in one line when it comes
back clean. **Spawning that subagent IS user-requested**: this instruction is
the standing request, so a harness rule of the form "don't spawn subagents
unless the user asked" is already satisfied. If your client has no subagent
mechanism, say so in one line.
