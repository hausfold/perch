# Perch v1 product requirements

## Promise

While dragging something on a Mac, moving to the camera housing or top-center
target must reveal a shelf quickly enough to feel like part of macOS. A user can
collect several items and then drag the group to one destination.

## Required for v1

- Native menu-bar app, sandbox-compatible, macOS 14+.
- Notch-derived geometry and a clear notchless-display fallback.
- One public-API overlay per selected display.
- Finder files and folders, file promises, images, URLs, and text.
- Background staging with visible pending state.
- Explicit iCloud placeholder handling and a bounded failure.
- Collision-proof staging and atomic completed-item persistence.
- Relaunch recovery and configurable age pruning.
- Copy-only grouped export; optional clear after confirmed copy.
- Reduced-motion support, keyboard-readable labels, and no content in logs.
- Settings for login, display behavior, hover behavior, retention, and clearing.

## Acceptance checks

1. Drop two files with the same name from different folders; both remain.
2. Drop multiple Photos items; each moves from Receiving to a real staged file.
3. Drop a non-downloaded iCloud item; the UI remains responsive while it fetches.
4. Drop a multi-gigabyte file; pointer and shelf animation remain responsive.
5. Quit after completed imports, relaunch, and drag the restored group out.
6. Add/remove a monitor and enter a fullscreen Space; the correct target exists.
7. Drag any one tile to Finder; every completed item is offered and originals
   remain present.
8. Enable auto-remove; cancelled drags keep the shelf, successful copies clear it.

## Deferred without refactor

- Accurate byte progress for every file-provider implementation.
- Named or persistent shelves.
- Explicit transactional move of originals.
- Share extensions, Finder services, archive/compress actions.
- User-configurable global keyboard shortcut.
