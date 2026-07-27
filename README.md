<div align="center">

<!-- identity banner — green wordmark on graphite (assets/perch-banner.png) -->
<img src="./assets/perch-banner.png" alt="perch" width="460">

**drop it in the notch, drag it out anywhere**

a native macOS file shelf that grows out of your MacBook camera notch — collect
files, folders, images, links, and text at the top of the screen, then fling the
whole pile somewhere in one drag.

![part of nebelhaus](https://img.shields.io/badge/part_of-nebelhaus-f2c4e5?labelColor=202020)
![themed by nebelung](https://img.shields.io/badge/themed_by-nebelung-c9a8f1?labelColor=202020)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-b9a8e0?labelColor=202020)
![license](https://img.shields.io/badge/license-MIT-d7d7d7?labelColor=202020)

</div>

---

You know the dance: drag a file, realise the destination window is buried, let go,
dig it out, drag again. Perch kills that. Start dragging *anything*, flick up to
the notch, and a little shelf drops down to catch it. Pile in as much as you like
from as many places as you like — then grab any tile and drag the whole group to
its real home in a single motion.

It's a menu-bar utility with **no Dock icon**, and it asks for **no Accessibility,
Input Monitoring, or Screen Recording** permission — it only ever sees what you
choose to drop on it.

## what it does

- **A target that finds the notch.** The drop zone hugs the physical camera
  housing when a display has one, and falls back to a tidy top-center tray on
  notchless screens.
- **It never touches your originals.** Every dropped item is *copied* into a
  private, collision-proof staging area — drop two files with the same name from
  different folders and both survive. Nothing on disk is moved, renamed, or
  modified, ever.
- **It handles the awkward producers.** Photos exports, Safari images, and other
  apps that hand over files lazily (AppKit "file promises") go down their own
  import path, so they land correctly instead of arriving empty.
- **It stays responsive.** Imports run off the main thread with a two-at-a-time
  limit, and iCloud placeholders are downloaded explicitly — drop a
  multi-gigabyte file or a not-yet-downloaded iCloud item and the shelf keeps
  animating.
- **It survives a relaunch.** Completed items are written to an atomic manifest;
  quit and reopen and your pile is still there. Startup even recovers files whose
  manifest write got interrupted.
- **It drags out as a group, copy-only.** Grab any tile and every completed item
  comes with it — advertised as a copy, so the destination decides what to keep.
- **It follows you around.** One panel per display, tracking Space, fullscreen,
  and Stage Manager changes with public AppKit behavior. On Tahoe it wears
  `NSGlassEffectView`; older systems get an AppKit material fallback.

## why a shelf, and why this one

Shelf apps aren't new — Yoink, Dropover, and friends have carried the idea for
years. Perch's angle is **dependability and restraint**:

- **Copies, not moves.** A temporary shelf that *moves* your only copy can delete
  it before the destination finished reading it. Perch stages copies and exports
  copies, so an interrupted drag never loses data. (A future explicit "move
  originals" action can layer on without changing any of this.)
- **Minimal permissions, no surveillance.** No Accessibility, no input taps, no
  screen reading, no Dock icon, no telemetry. Nothing about your files is ever
  written to a log.
- **Native and calm.** A single sandbox-friendly menu-bar app dressed in the
  [nebelung](https://github.com/nebelhaus/nebelung) fog-grey palette, at home
  next to the rest of the family.

Perch is part of the [nebelhaus](https://github.com/nebelhaus) family — the native
macOS rice — but it stands alone: it's a plain menu-bar app on any Mac.

> "Perch" is a working title. Product naming is deliberately kept separate from
> the storage and drag/drop architecture.

## install

```sh
# Homebrew (nebelhaus tap)
brew install --cask nebelhaus/tap/perch
```

The app is signed with our Apple Developer ID and notarized by Apple, so the cask
installs it and it opens straight away — no Gatekeeper prompt, no quarantine hack.
(If you build or copy the app by hand instead of installing the cask, macOS may
quarantine your copy; clear it with
`xattr -dr com.apple.quarantine /Applications/Perch.app`.)

Perch installs by default in the [nebelhaus](https://github.com/nebelhaus) rice
too, but it stands alone — the cask above works on any Mac.

## build and run

Requirements: **Xcode 26+**, **macOS 14+**.

```sh
xcodebuild -project Perch.xcodeproj -scheme Perch \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

Or open `Perch.xcodeproj`, pick the **Perch** scheme, and run **My Mac** for an
interactive build.

## where your stuff lives

The active shelf is stored under the app's own container:

```text
~/Library/Containers/com.nebelhaus.perch/Data/Library/Application Support/
  Perch/ActiveShelf/
```

Each import gets its own UUID directory — that's what prevents name collisions
without renaming your file. The manifest records only **staged relative paths**
and file metadata; original source paths are never persisted (or logged).
Clearing an item deletes its whole import directory.

## the product boundary (v1)

v1 deliberately stages copies and exports copies. True move semantics fight a
resilient temporary shelf: a move can delete the only staged file before the app
knows whether the destination finished consuming it. A future explicit "move
originals" action can be added behind a separate transactional export service —
without changing the importer, repository, or UI model.

## documentation

- [Product requirements](PRD.md)
- [Architecture](ARCHITECTURE.md)
- [Architecture decisions](docs/architecture-decisions/)

## license

MIT © nebelhaus
