<div align="center">

# Morsel

**A native, dependable temporary file shelf that grows out of your MacBook notch.**

</div>

Morsel lets you collect files, folders, Photos exports, Safari images, links,
and text at the top of any display, then drag the whole group somewhere else in
one motion. It is a menu-bar utility with no Dock icon and requires no
Accessibility, Input Monitoring, or Screen Recording permission.

> Morsel is a working title. Product naming is deliberately isolated from the
> storage and drag/drop architecture.

## v1 behavior

- A compact drop target follows the physical camera housing when a display has
  one, and becomes a small top-center tray on notchless displays.
- Every accepted item is copied into a collision-proof app-owned session
  directory. Originals are never moved or modified.
- Finder URLs and AppKit file promises are separate import paths, so Photos,
  Safari, and other delayed producers work correctly.
- Imports run away from the main thread, with a two-transfer concurrency limit
  and explicit iCloud-placeholder download handling.
- Completed items are committed to an atomic manifest. Relaunch recovers them,
  and startup also finds completed files whose manifest write was interrupted.
- Dragging any tile exports all completed shelf items together with copy-only
  semantics.
- One panel is managed per display and follows display, Space, fullscreen, and
  Stage Manager changes using public AppKit behavior.
- Tahoe uses `NSGlassEffectView`; older supported versions use an AppKit
  material fallback.

## Build and test

Requirements: Xcode 26 or newer, macOS 14 or newer.

```sh
xcodebuild -project Morsel.xcodeproj -scheme Morsel \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

Open `Morsel.xcodeproj`, choose the Morsel scheme, and run **My Mac** for an
interactive build.

## Storage and privacy

The active shelf lives at:

```text
~/Library/Containers/com.nebelhaus.morsel/Data/Library/Application Support/
  Morsel/ActiveShelf/
```

Each import gets a UUID directory, which prevents collisions without renaming
the displayed file. The manifest contains only staged relative paths and file
metadata; original source paths are not persisted. Clearing an item removes its
entire import directory.

## Current product boundary

v1 deliberately stages copies and exports copies. True move semantics conflict
with a resilient temporary shelf: a move can delete the only staged file before
the app knows whether the destination finished consuming it. A future explicit
“Move originals” action can be added behind a separate transactional export
service without changing the importer, repository, or UI model.
