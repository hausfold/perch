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
- A Finder door: "Add to Perch Shelf" under Services for any selection of files
  and folders, on by default and needing no setup, and in any app's Services
  menu for text and links. (An Action Extension shipped alongside it through
  2026-08-23 and was removed — measured on macOS 26, it drew in the same
  submenu rather than under Quick Actions, and shelved nothing when clicked.)
- A `perch add` command line tool, shipped inside the app bundle and put on
  `PATH` by whatever installed it, so a script or an agent can stage files
  without a human present — same admission, same staging, same untouched
  originals, with an exit status a pipeline can branch on.
- Watched folders: user-picked folders (Downloads, the screenshot folder)
  whose new files are copied onto the shelf automatically — existing contents
  seeded silently, half-written downloads held until they settle, originals
  never moved.
- Background staging with visible pending state.
- Explicit iCloud placeholder handling and a bounded failure.
- Collision-proof staging and atomic completed-item persistence.
- Relaunch recovery and configurable age pruning.
- Copy-only grouped export; optional clear after confirmed copy.
- Per-item pinning for repeated drag-out copies without removing the staged item.
- Reduced-motion support, keyboard-readable labels, and no content in logs.
- Settings for login, display behavior, hover behavior, retention, and clearing —
  every one of them stored in a config file the user can edit, not in `defaults`,
  and any of them declarable by the machine's own drop, which renders that row
  read-only rather than fighting it.
- A palette that follows haus's nebelung variant and macOS Light/Dark, read
  from `~/.config/perch/` and never written.
- A passive release nudge that names the right next step for *this* install
  (haus, Homebrew, Nix, drag-install), is dismissible per version, and never
  installs anything itself.

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
9. With a newer release published, the open shelf offers this install's own
   update step — a command to copy, or, for a copy dragged into
   `/Applications`, **Update Now**, which installs it and reopens perch with
   the shelf intact; dismissing it silences that version and no other.
10. Right-click three files and invoke **Add to Perch Shelf** under *Services*
    — exactly one row offers it — and verify three tiles land while every
    original remains unchanged, proving the Service shares the drag path's
    admission rather than its own. If the row is missing it is switched off in
    System Settings ▸ Keyboard ▸ Keyboard Shortcuts… ▸ Services ▸ Files and
    Folders; there is no extension to enable.
11. Run `perch add` on those three files: it exits 0 and three tiles land. Quit
    Perch and run it again: it launches the shelf and the file still lands.
12. Watch a folder holding two files; neither lands. Download into it and one
    tile appears only after the download completes; the original stays put.
    Quit perch, drop a file in, relaunch — that file lands too, exactly once.

## Deferred without refactor

- Accurate byte progress for every file-provider implementation.
- Named or persistent shelves.
- Explicit transactional move of originals.
- Additional Share extensions and archive/compress actions.
- User-configurable global keyboard shortcut.
