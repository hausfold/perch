# Perch architecture

## Invariants

1. Source items are never modified.
2. The main actor never performs a potentially blocking copy or cloud download.
3. A shelf item becomes visible only after its staged representation exists.
4. A manifest never contains an absolute source path.
5. Every exported dragging session advertises copy only.
6. Display topology is replaceable without touching storage or import logic.

## Boundaries

```text
NSDraggingDestination
        │
        ▼
ShelfDropHandler ── distinguishes promises / file URLs / images / links / text
        │
        ▼
ShelfStore ─────── main-actor state, pending/completed/error transitions
        │
        ├── TransferPipeline ── bounded background work, iCloud + coordination
        │
        └── StagingRepository ─ UUID containers, atomic manifest, recovery

NSScreen[] ──► ShelfWindowSystem ──► ShelfPanelController per display
                                           │
                                           ▼
                                     ShelfPanelView
                                           │
                                           ▼
                                    NSDraggingSource
                                      copy-only group
```

## The hard cases

### Multiple displays and fullscreen Spaces

`ShelfWindowSystem` owns a panel per eligible screen and rebuilds on
`didChangeScreenParametersNotification`. Panels join all Spaces and are
fullscreen auxiliaries. Geometry consumes a pure `ScreenDescriptor`, which
makes notch and non-notch placement unit-testable without an attached display.

### File promises

Promises are handled before file URLs. All receivers from one drag share one
destination directory, as AppKit requires, and fulfill on a bounded operation
queue. Each fulfilled file is immediately moved into its own UUID container,
so deleting one item cannot delete a sibling from the same promise batch. A
receiving sentinel makes an interrupted batch distinguishable from completed
data. The UI shows pending items until each callback produces a real file.

### iCloud placeholders and huge files

`TransferPipeline` detects ubiquitous items, explicitly starts their download,
and waits off-main with a bounded timeout. `NSFileCoordinator` protects the
subsequent read. A two-operation queue prevents a batch of huge files from
starving either the UI or storage.

The current UI intentionally shows indeterminate progress because
`FileManager.copyItem` does not expose reliable byte progress for directories,
packages, cloud providers, and coordinated reads under one API. The pending
model already separates phases, so a later provider-specific progress source
does not require a model rewrite.

### Name collisions

Every logical import owns a UUID directory. The user-visible filename remains
unchanged, while two `photo.jpg` files never share a filesystem namespace.

### Termination and recovery

Only completed imports enter the atomic manifest. Ordinary copies use a hidden
partial name and atomically move to their final staged name only after the copy
finishes. Startup discards interrupted containers, filters missing manifest
entries, and scans two-level UUID containers for completed but uncommitted
files. Promise callbacks and ordinary copies converge on the same `ShelfItem`
commit path.

### Copy versus move

Imports copy; exports advertise `.copy`. Dragging an item (or the whole stack)
out removes it from the shelf, but only once the destination confirms it holds
its own copy: exports are vended as **file promises** (`NSFilePromiseProvider`),
so the receiver asks Perch to write the file into the location it chose, and the
promise's completion handler is what records destination completion before the
staged source is deleted. This is the `ExportTransaction` boundary — deleting on
the raw drag-end instead raced the receiver's in-flight copy (Finder error
-8058) and could drop the item even when its copy failed. A failed or refused
drop keeps the item. The promise copy runs on a background queue, never main.

True move-original semantics are still not inferred from modifier keys.

## Planned extensions that fit existing seams

- Quick Look preview: UI-only coordinator over staged URLs.
- Byte progress: transfer event stream updating `PendingTransfer`.
- Multiple named shelves: replace `ActiveShelf` with repository IDs.
- Expiration while running: scheduler calling the existing prune operation.
- Explicit move workflow: extend the promise `ExportTransaction`, never a change to importing.
- Finder actions and share actions: commands over completed staged URLs.
