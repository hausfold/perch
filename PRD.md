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
- A Finder Action extension that adds selected files and folders from Finder's
  Quick Actions menu, on by default, with a Settings shortcut to the pane that
  holds its checkbox — and a classic Service that puts the same command at the
  context menu's top level, and in any app's Services menu for text and links.
- A `perch add` command line tool, shipped inside the app bundle and put on
  `PATH` by whatever installed it, so a script or an agent can stage files
  without a human present — same admission, same staging, same untouched
  originals, with an exit status a pipeline can branch on.
- Background staging with visible pending state.
- Explicit iCloud placeholder handling and a bounded failure.
- Collision-proof staging and atomic completed-item persistence.
- Relaunch recovery and configurable age pruning.
- Copy-only grouped export; optional clear after confirmed copy.
- Per-item pinning for repeated drag-out copies without removing the staged item.
- Reduced-motion support, keyboard-readable labels, and no content in logs.
- Settings for login, display behavior, hover behavior, retention, and clearing.
- A palette that follows the rice's nebelung variant and macOS Light/Dark, read
  from `~/.config/perch/` and never written.
- A passive release nudge that names the right next step for *this* install
  (rice, Homebrew, Nix, drag-install), is dismissible per version, and never
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
   update step; dismissing it silences that version and no other.
10. Confirm **Add to Perch Shelf** is ticked under Login Items & Extensions ▸
    Extensions ▸ System Services, invoke it on three files while the free shelf
    has one open slot, and verify only one source is copied while every original
    remains unchanged.
11. Invoke the top-level **Add to Perch Shelf** on the same three files and get
    the same outcome — one copy admitted, three originals untouched — proving
    the Service shares the drag path's admission rather than its own.
12. Run `perch add` on those three files with one free slot left: it exits 2,
    one tile lands, and the two refused sources were never read. Quit Perch and
    run it again: it launches the shelf and the file still lands.

## Deferred without refactor

- Accurate byte progress for every file-provider implementation.
- Named or persistent shelves.
- Explicit transactional move of originals.
- Additional Share extensions and archive/compress actions.
- User-configurable global keyboard shortcut.
