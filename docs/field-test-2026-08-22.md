# Field test punch list — 2026-08-22

Thirteen findings from one hands-on pass over the shelf, the Finder doors, the
watched folders and the phone. This file is the **work queue**: each *Run* below
is sized for one agent session on its own `worktree-*` branch and its own PR.
Runs are independent — take any of them in any order, in parallel.

**Delete this file when the board is empty.** It is a dated snapshot by
construction; a second `docs/field-test-*.md` living beside a finished one is
the stale-doc failure AGENTS.md warns about.

**Not a decisions document.** Where a fix changes a product boundary, the
decision moves into `PRD.md` / `ARCHITECTURE.md` / the relevant `docs/` page in
the same PR, and the row here is struck out — including the two open calls at
the bottom, whose answers land there and are **not** copied back here.

Every root cause below was read out of the source, not observed under a
debugger. Confidence is stated per item. **Reproduce before you fix** — a
"confirmed" here means the code path provably does the wrong thing, not that it
is provably the only thing going wrong.

---

## The board

| # | Symptom | Area | Verdict | Run |
|---|---|---|---|---|
| ~~1~~ | ~~Shelf hover-opens ~1 notch-width either side of the notch~~ | Platform | **Fixed** — hit-test the pointer, don't trust the tracking area | ~~**A**~~ |
| ~~13~~ | ~~Secondary display never shows a drop target~~ | Platform | **Fixed** — `screen: nil`; the frames were already global | ~~**A**~~ |
| ~~10~~ | ~~Open/close animation janks at ~250 items (scrolling is fine)~~ | UI | **Fixed** — lazy strip + cached icons; feel-tested 2026-08-23 | ~~**B**~~ |
| ~~9~~ | ~~50 folders dropped into Finder land in a diagonal line~~ | UI | **Fixed** — the frames were the pile Finder untangled; feel-tested 2026-08-23 | ~~**B**~~ |
| ~~7~~ | ~~Rename a staged file in Finder → tile can never be dragged out, and vanishes~~ | Store | **Fixed** — re-resolve; decision in `ARCHITECTURE.md` | ~~**C**~~ |
| ~~6~~ | ~~`curl -o ~/Downloads/slow.bin` never lands~~ | Watch | **Fixed** — dedupe gone, FSEvents sees the rewrite; feel-tested 2026-08-23 | ~~**D**~~ |
| 8 | Quit → drop into `~/Downloads` → relaunch → no catch-up | Watch | **Addressed, still unreproduced** — the stream now resumes from a persisted position | **D** |
| ~~2~~ | ~~Non-downloaded iCloud file sticks on "Downloading" forever~~ | Import | **Fixed** — the poll read a cached status; re-tested 2026-08-23 | ~~**E**~~ |
| ~~4~~ | ~~Quick Action absent from Quick Actions; Service listed twice~~ | Finder | **Fixed** — the extension was the dead door; removed | ~~**F**~~ |
| ~~5~~ | ~~No top-level "Add to Perch Shelf" in the Finder context menu~~ | Finder | **Premise dead** — a classic Service does not reach the top level; docs corrected | ~~**F**~~ |
| ~~12~~ | ~~Settings ▸ Devices says "No devices paired" while the phone still delivers~~ | Mobile | **Fixed** — by #82, a day before the pass that reported it; verified on 2026.08.24, both surfaces, 2026-08-24 | ~~**G**~~ |
| 3 | 3 GB file "lands immediately" instead of showing progress | — | **Not a bug** — bad expectation | — |
| ~~11~~ | ~~Phone Wi-Fi off, Mac still receives~~ | — | **Not a bug** — documented in `docs/reference.md` | — |

### Where it stands — 2026-08-23

**Feel-tested on the dev build (`2026.08.23-dev`) and all four passed:** #10
(open/close at 250 items, and a cold scroll end to end), #9 (50 folders land in
a grid), #6 (`curl -o` twice over one path gives two tiles), #2 (an evicted
iCloud file lands instead of counting to 120). Run F is closed by the deletion
below — **by decision, not by the measurement it cites**; the caveat is stated
in Run F and changes nothing that shipped. **#12 is the only thing left on this
board.**

| owed | which | needs |
|---|---|---|
| Measurement | G (#12) | the phone, the **release** build, and `log stream … category == "PairedDevices"`. Not the dev build: a different bundle id is a different Keychain access group, so "No devices paired" is the correct answer there and would reproduce the symptom for the wrong reason |
| Nothing | D3 (#8) | unreproduced; the resumed stream is in, and there is nothing further to write until it recurs |

The two loose ends this board handed to other sessions have both landed:
bounding concurrent cloud waiters (E3, #95) and drag-out into a *watched*
destination shelving the item straight back, with the export-ledger probe race
it uncovered (#96).

### Where it stands — 2026-08-24 — the board is clear

**#12 is fixed, and was already fixed when it was reported.** Three readings
on `/Applications/Perch.app` at 2026.08.24 — Developer-ID-signed, notarized,
sandboxed — against the pairing this Mac has had since 2026-08-21:

| surface | reads |
|---|---|
| `PairedDeviceStore.all()` at launch | `Keychain list: 1 paired device(s)` |
| Menu bar (`PairedDevicesSection`) | `iPhone — paired` |
| Settings ▸ iPhone & iPad (`DevicesPane`) | `iPhone · Paired Aug 21, 2026`, with a live **Revoke** |

The reported symptom does not exist on the shipped build. **#82** is what fixed
it — it landed 2026-08-21 00:47 and shipped in `v2026.08.21`, tagged 21:06 that
evening, about ten hours before this punch list was written (`00900ec`,
2026-08-22 07:36). The pairing itself was made 00:52 that morning, five minutes
after #82 was committed and long before any release carried it — so the pass
that filed #12 was almost certainly driving a build from before the fix, which
is exactly the shape a bug that "reproduces every time" and then evaporates
usually has. Everything Run G wrote about the Keychain after that was answering
a question that no longer had a bug behind it. The measurements it produced
stand and are worth keeping; the diagnosis they were chasing was of a corpse.

**How the reading was taken**, since it is not obvious and cost a wrong turn:

```sh
/usr/bin/log stream --predicate 'subsystem == "com.hausfold.perch"' --level info --style compact &
killall Perch; open -g -a /Applications/Perch.app
```

`log`, unqualified, is a zsh builtin — hence `/usr/bin/log`. And `--level info`
is not optional: the count line is `info`, which is **not persisted**, so
`log show` will never show it however far back you ask. Its absence means
nothing; the reading only exists live, on a relaunch. No phone was needed —
`security find-generic-password -s com.hausfold.perch.mobile-device` shows the
item already on disk (attributes only, no prompt).

**What this does *not* cover, stated so nobody reads more into it than it
says.** All three readings reach `pairedDevices` through `MobileReceiver.init`,
at launch — so neither the refresh inside `finishPairing` nor **revoke** (which
the original pass could not reach *because* of #12) was covered by them.

**Both were run at the machine, same day, and passed.** Revoke the iPhone,
watch the row leave without a relaunch, pair it again, watch it come back. The
store agrees: the pairing record is the same account UUID with its creation
date rewritten to 2026-08-25 02:53 UTC, which is `store(_:)`'s delete-then-add
replacing the record — the round trip really went through the Keychain and not
just the array. #12 and Run G are closed on all three paths.

**Only D3 (#8) outlives this board, unreproduced, and it is not a fix that is
owed — it is a test that cannot be run naively.** Prime the watched folder
first; D3 says how, and why a first pass without it reproduces #8's symptom for
a reason that is not #8.

---

## ~~Run A — Notch geometry (`Perch/Platform/`)~~

**Landed.**

- **A1 (#1)** — the hover trigger no longer trusts *which* tracking area fired.
  `ShelfHostingView` hit-tests the pointer against `ShelfHoverRegion`, and
  `ShelfHoverGate` turns those samples into edges: opening is edge-triggered on
  the hit test, while `mouseExited` is always forwarded, because it is the only
  signal that the pointer left the panel and `scheduleCollapse` is the only
  passive way back to a collapsed shelf. The wide drag-catch band is untouched.
  Covered by `ShelfHoverRegionTests`, which needs no window server — the reason
  #55 and #78 could only be judged by sweeping a real menu bar.
- **A2 (#13)** — the panel is created with `screen: nil`; `ShelfGeometry`'s
  frames were already global, so passing the screen applied its origin twice.
  Also: the single-panel case now uses the zero-origin display rather than
  `NSScreen.main` (the *key window's* screen), and a duplicate
  `perchIdentifier` from mirrored displays is skipped instead of silently
  displacing a live panel. Covered by
  `ScreenGeometryTests.testSecondaryDisplayFramesAreGlobalNotScreenRelative`.

## Run B — Shelf list rendering (`Perch/UI/`)

### ~~B1 · Open/close janks at ~250 items (#10)~~ — **fixed in code, needs a feel-test**

**Root cause, as diagnosed.** `ShelfPanelView.itemStrip` was an **eager**
`HStack`, so every expand built all 250 `FileTile`s — and each tile is not
cheap: a `FilePreview` with a QuickLook `.task`, a live `FileDragSourceView`
(an `NSViewRepresentable`, i.e. a real `NSView`), and a synchronous
`NSWorkspace.icon(forFile:)` **inside `body`**. `@State thumbnail` starts `nil`
on every rebuild, so that LaunchServices round trip ran for *all* 250 tiles on
every expand, thumbnailed ones included, until each `.task` resolved.

Measured, so the second half isn't taken on faith: 250 `icon(forFile:)` calls
cost **27 ms** for plain text files and **103 ms** for a mix of real `.app`
bundles (31 ms warm) — six dropped frames of main-thread work, spent during
the animation, on top of building 250 tiles and 250 `NSView`s.

**What landed.**
- `LazyHStack` for the strip, so an expand builds the tiles actually on screen.
- `IconCache`, an `NSCache` keyed **by path** (not content type — `.app`
  bundles, Finder custom icons and alias badges are per-file), and the icon
  lookup moved out of `body` into the same `.task` the thumbnail uses. It stays
  on the main actor — `NSWorkspace`'s lookup isn't documented thread-safe — but
  now lands after the layout pass instead of inside it.
- Both caches are read back **synchronously** while the view builds
  (`ThumbnailCache.cached(for:)`, `IconCache.cached(for:)`). A lazy strip
  rebuilds a tile every time it scrolls back into view, so without that seed
  the fix would have traded one stutter for a placeholder flash on every
  scroll.
- A tile with a *cached* thumbnail asks LaunchServices for nothing at all.
  A cold one still fetches its icon **first**, before awaiting QuickLook —
  skipping it would leave a generic `doc` glyph on every image tile for the
  length of the render, which is worse than what it replaced.

**Still to feel-test** (needs a screen; no unit test can see it):
1. Stage ~250 items, open/close ten times — smooth?
2. **Scroll a *cold* 250-item shelf end to end.** This is the regression the
   fix could plausibly introduce: the eager stack paid every icon lookup once
   at expand and scrolled free thereafter, so "scrolling is fine" was measured
   against a fully-built strip. A lazy one pays per tile as it mounts.
3. **The badges.** The pin/remove buttons overhang the tile's top corner by
   8pt into the strip's `.padding(.top, 11)`. `LazyHStack` computes its bounds
   from mounted children; confirm nothing is clipped.
4. **Reflow.** Remove a tile while scrolled away from it, and drag one out —
   the neighbours must still slide, and nothing may pop.

Drag-out is unaffected in the ordinary case, but the reason is worth stating
precisely, because the obvious one is wrong. The dragged tile is *not* under
the pointer once the drag leaves the notch, and the panel tears its views down
then anyway — that is pre-existing, and `draggingSession(_:endedAt:)` already
compensates by reporting inline. What laziness adds is a second unmount vector
("scrolled out of the lazy window") alongside "panel hid"; in both cases a
promise verdict arriving after unmount falls through to the 1 s grace timer,
which is the designed fallback. Drag-*all* doesn't use the tiles' drag sources
at all — `dragAllHandle` has its own `FileDragSourceView`
(`ShelfPanelView.swift:240`).

### ~~B2 · Multi-item drag-out lands in a diagonal line (#9)~~

**Fixed in code, still owed a feel-test.**

**Symptom.** Drag 50 folders out into an empty Finder window → they are placed
along a top-left→bottom-right diagonal, and Finder's Clean Up keeps the
diagonal.

**First theory, and why it was dead.** `FileDragSourceView` cascaded the drag
frames — `offset = min(index, 4) * 3` — but the `min(index, 4)` clamp stopped it
after five items. For a 50-folder drag the offsets were `0, 3, 6, 9, 12, 12,
12, …`, so **46 of the 50 items already shared an identical frame** and a 3 pt
cascade could not be drawing a 50-icon diagonal.

**The real cause, and the clamp is still where it lives — as a pile, not as a
cascade.** A dragging frame is not decoration. `setDraggingFrame` sets the
item's `NSDraggingFormationNone` position, and that layout is what a
destination places the arriving files by — `NSDragging.h` says so at
`animatesToDestination`: "if the final destination frames do not match the
current `NSDraggingFormationNone` frames, then enumerate through the
draggingItems … to set their `NSDraggingFormationNone` frames to the correct
destinations." So the drag was not asking Finder for a diagonal; it was asking
for **one position, forty-six times**. Finder resolved the pile-up the only way
an icon view can, by de-overlapping — and de-overlapping cascades. Hence a
diagonal that no 3 pt offset in perch is long enough to explain, and that Clean
Up preserves because by then the icons really are at those positions.

That the clamp existed for a good reason is the trap: it made the drag *look*
like a tidy five-deep pile. But the look of a drag is `NSDraggingFormation`'s
job, not the frames' — `.stack` is defined as "drag images are laid out
overlapping diagonally", applied to the visuals without moving the positions a
destination reads. Splitting the two is the entire point of the API, and it is
what Finder does dragging its own multi-selection: a stack under the pointer, a
grid on arrival.

**The fix.** `DragLayout.frames(count:center:)` lays the items out on a real
grid (8 columns, 128 pt cells, centred on the tile so the pointer stays in the
middle of the pile), and `session.draggingFormation = .stack` keeps the drag
looking like one object. A single-item drag is unchanged — its image still sits
exactly on the tile. `DragLayoutTests` pins the properties the old layout broke:
every item gets a distinct frame, no two frames intersect, and the grid wraps
into rows rather than running 50 wide.

**Honest about what this is.** The mechanism is read out of `NSDragging.h` and
the source, not off a debugger — same standard as the rest of this file. The
frames were provably wrong and are provably right now; whether that is the
*whole* of #9 is what the feel-test says.

**Watch out.** 50 items is a 128 pt grid eight wide and seven deep — about
900 × 820 pt of `.none` frames, centred on a tile that sits at the notch, so
roughly the top half of that block is above the edge of the display. `.stack` is
what keeps it from being seen; if the formation ever fails to take, the drag
sprays across the screen rather than merely looking untidy. The cell is
deliberately wider than a Finder icon-view cell at its largest — two frames that
overlap in the destination's grid are two frames it has to de-overlap, which is
the bug this replaces — so shrinking it to calm the visual trades the fix away.

**Verify.** 5 folders and 50 folders, dropped into (a) an empty Finder window in
icon view, (b) a list-view window, (c) the Desktop. Icons arrive in Finder's
normal grid, not a diagonal. Watch the drag itself on the way there — it must
still look like one pile under the pointer, not a spray of 50 icons; that is the
one thing `.stack` is carrying and the only way the fix can look wrong. Also
drop 50 onto a terminal and confirm 50 paths still paste.

**If it still cascades**, the next question is whether Finder is placing from
the `.stack` frames rather than the `.none` ones, in which case the answer is
`.none` formation plus a visually tighter grid — and the comparison worth having
first is a 50-file drag out of Finder itself, which lands correctly and is
therefore the working example to diff against.

---

## ~~Run C — A staged file the user can rename out from under the shelf (#7)~~

**Landed.** Fix (a) — re-resolve. The rename decision now lives in
`ARCHITECTURE.md` ("Name collisions" and "Copy versus move"), not here.

**This is the most serious item on the board — it loses a tile.**

**Symptom / repro (reproduced multiple times).**
1. Download an image in a browser → it appears on the shelf.
2. Tile menu ▸ **Show in Finder**.
3. Rename the file in Finder.
4. Drag the tile into any app → the drop never delivers,
   **and the tile disappears from the shelf** (unless it is pinned).
5. Quit and relaunch Perch → the "lost" files are all back on the shelf.

**Root cause (confirmed).** `ShelfItem.relativePath`
(`PerchWire/Shelf/ShelfItem.swift`) is the single link between a tile and its
bytes, and `reveal()` (`Perch/App/ShelfStore.swift`) points Finder straight at
that path inside `…/Application Support/Perch/ActiveShelf/<uuid>/`. Nothing
re-resolves it, so a rename orphans the item:

- `item.fileURL(inside:)` still returns a URL, it just no longer exists.
- The drag still starts (`ExportItem.url` is stale) and Finder still reports
  `.copy`, so `draggingSession(_:endedAt:operation:)` reports `.accepted` →
  `ShelfStore.liftForExport` removes the tile and rewrites the manifest.

**A second, independent bug decides whether the tile comes back — and it is an
ordering race.** `report(_:_:)` hops to the main actor through a `Task`
(`Perch/UI/FileDragSourceView.swift:229-233`), while `draggingSession(_:endedAt:)`
reports `.accepted` **inline**. A promise that fails fast therefore delivers
`.failed` *before* `.accepted`:

1. `.failed` → `returnToShelf(id)` finds nothing in `lifted` and no-ops
   (`ShelfStore.swift:370`), and `state.finishExport(of:)` clears
   `draggingOutIDs`.
2. `.accepted` → `liftForExport` then removes the tile **after** the only thing
   that could have put it back has already run.
3. `draggingOutIDs` is empty, so the 1 s grace timer hands nothing off — no
   `.detached` marker is written, the bytes survive, and the next launch
   re-adopts them via `StagingRepository.recoverUntrackedFiles`.

That is step 5 of the repro, exactly. (The other path — grace timer fires and
`handOff` → `detach` writes `.detached` — would *not* reproduce step 5:
`load()` and `recoverUntrackedFiles` both skip detached containers,
`StagingRepository.swift:74-76` and `:281`.)

**Fix sketch — pick one, they are different products.**
- **(a) Re-resolve.** Every import allocates its own `<uuid>` container holding
  exactly one visible entry, so the container is the durable identity and the
  filename is not. Resolve `fileURL` by reading the container's single
  non-dot child, falling back to `relativePath`. A rename then Just Works and
  the displayed name follows it.
- **(b) Refuse.** Validate existence before starting the drag; if the staged
  file is gone, surface it (`latestError`) and don't begin the session. Safe,
  but the tile is still dead.

(a) is the better product and is roughly the same amount of code. Two things are
worth fixing on their own, before either is chosen:
- `liftForExport` must not remove an item whose bytes it cannot find.
- The `.accepted` / `.failed` verdicts must be **ordered**. Either report
  `.accepted` through the same `Task` hop the promise verdicts use, or make
  `returnToShelf` tolerate arriving before the lift.

**Verify.** Run the 5-step repro. Then: rename → drag out → lands correctly and
leaves the shelf. Rename → drag out → press Escape → tile springs back. Rename →
delete the staged file entirely → drag out → tile stays put and an error shows.
Add regression tests in `ShelfStoreExportTests`.

**Watch out.** Do not break the invariant that a visible `ShelfItem` points at a
*completed* staged representation, and do not start persisting or logging
original paths while touching this. And fix (a)'s "read the container's single
non-dot child" must **not** resurrect a container carrying `.detached` — those
bytes belong to whatever took an earlier drop.

---

## Run D — Watched folders (`Perch/Importing/`)

### ~~D1 · A failed import is ledgered anyway, so it never retries~~ — **fixed**

`ShelfStore.importFileURLs` now takes a per-URL completion, and
`FolderWatchCenter` ledgers on success instead of on attempt; a failure calls
`FolderWatcher.forgetImport(_:)`, which takes the token back out so the next
event batch probes the file again — *the next event*, which since D2 includes a
write into the file itself. It also self-heals at relaunch,
since the persisted ledger never got the token. The token still goes into the *in-memory*
ledger at promote time, so a second event can't start a second import mid-flight.
`testAFailedImportIsRetriedOnTheNextEvent`.

### ~~D2 · `curl -o` arrivals never land (#6)~~ — **fixed, both halves**

Two independent faults wearing one symptom.

**The dedupe half** (fixed in #88): `identityToken` now hashes **size and
modification date** alongside inode and birth date, so truncating and rewriting a
path is a new arrival rather than a match against the first download forever. A
pure rename still does not re-import (`testARenameStillDoesNotReimport`), which is
the property the token exists for. Tokens carry a `v2:` format tag, and a ledger in
an older format is *adopted* on the next launch rather than pruned to nothing —
without that, upgrading would have re-imported everything in `~/Downloads` at once.
The product decision (replaced contents = new arrival) is in `docs/reference.md`.

**The event half, which was the real finding of Run D.** A directory kqueue fires on
entries appearing, disappearing and being renamed. It does **not** fire when
something writes into a file that is already in the directory — which is precisely
what `curl -o` does to an existing path (`O_TRUNC`, same inode, same entry). So no
event arrived, `scan()` never ran, and the fixed token never got a chance to differ.

`FolderWatcher` now runs an **FSEvents** stream instead
(`kFSEventStreamCreateFlagFileEvents | …NoDefer`), which reports the rewrite as
`ItemModified`. Only the event source changed: the stability probe, the ledger,
`forgetImport` and the `v2` re-seed are untouched, and every event batch still
answers with one full `scan()`, so a coalesced or dropped batch costs a rescan and
never a missed file. `testAFileRewrittenInPlaceLandsAgainWithNoOtherChangeInTheFolder`
is the old test with its crutch removed — it used to have to create a second file
purely to fire a directory event, and now nothing else in the folder changes.

**Still owed: the feel-test.** #6 has only ever been verified in the suite. Run
`curl -o ~/Downloads/slow.bin` twice over the same path with `~/Downloads` watched
and confirm two tiles.

**What this makes visible, and it is a probe question, not an event-source one.**
The probe promotes a file whose size and mtime hold still for `probeInterval ×
requiredStableProbes` ≈ 1 s. A single download that stalls longer than that and
then resumes was *already* being shelved early and truncated — the probe has
always been a net under the naming convention, not a proof of doneness. What the
kqueue did was hide the second half: no event for the resumed write, so the
truncated copy was the only thing you ever got and the finished file never landed.
FSEvents sees the resume, so you now get the truncated tile **and** the complete
one. Measured, not theorised: a 1000 B file promoted during a stall, then grown to
6000 B, lands as `["stall.bin", "stall.bin"]` at sizes `[1000, 6000]`.

Strictly more of the right bytes than before, and one extra tile to clear. Noted
in `docs/reference.md`. The lever, if the tile bothers more than the truncation
did, is `requiredStableProbes` — raising it widens the quiet window a stall has to
beat, at the cost of delaying every ordinary arrival by the same amount. Left
alone here on purpose: this run changed the event source and nothing else.

### D3 · No catch-up on relaunch (#8) — **addressed, still unreproduced**

Never reproduced, and nothing here claims it is closed. What changed is that the
stream no longer starts blind: `WatchedFolder.lastEventID` persists the FSEvents
position each folder has been scanned up to (an opaque volume counter — no path, no
time), and the next launch resumes there, replaying what happened while perch was
down. `testAResumedStreamReplaysHistoryAQuietFolderWouldNotProduce` isolates that
against a control started at `kFSEventStreamEventIdSinceNow`, which hears nothing.

Be honest about what that is worth: the launch path (`initialScan` → prune →
`scan`) is a full rescan and would find a missed *arrival* on its own — it is
covered by `testLaunchScanPrunesGoneFilesAndCatchesUpOnUnledgeredOnes` and does work
in a test. Replay is the stream covering the same gap itself, not a second detector.
If #8 reproduces after this, the suspicion still falls on the bookmark resolving at
launch rather than on the scan.

**Prime the folder before testing it, or the first run lies.** Measured
2026-08-24 on this Mac: `watched-folders.json` has `~/Desktop` at
`lastEventID: 1203891618` and **`~/Downloads` with no `lastEventID` at all**
(it is `UInt64?`, so the encoder omits it rather than writing null). A position
is only written when the stream actually delivers an event, and `~/Desktop`
takes every screenshot while `~/Downloads` has been quiet since the FSEvents
build landed — so the folder #8's recipe names is the one with nothing to
resume from. Absent falls back to `kFSEventStreamEventIdSinceNow`
(`FolderWatcher.swift:206-208`), which is no replay at all, so *quit → drop →
relaunch* would reproduce "no catch-up" on the first pass for a reason that has
nothing to do with #8. Its second pass would then pass, and the run would read
as flaky.

1. Read the positions **first**, so step 3 has something to compare against —
   the ids are UUID prefixes, not folder names, so "did it land" is only
   legible as a before/after:

   ```sh
   python3 -c "import json;print([(f['id'][:8],f.get('lastEventID')) for f in json.load(open('$HOME/Library/Containers/com.hausfold.perch/Data/Library/Application Support/Perch/watched-folders.json'))])"
   ```

2. With perch running, `touch ~/Downloads/prime-$(date +%s).txt`. It fires the
   event and shelves a tile; bin the tile.
3. Wait past `positionReportInterval` (5 s) and run the same line again: the
   row that had no number now has one. That folder can now replay.
4. Now ⌘Q, drop the test file, relaunch.

Two things about that loop worth knowing before it confuses you. **A
re-dropped file is deduped by identity, not by name** — `importedTokens` holds
`SHA256(inode:birth:size:mtime)` and encodes no name or path
(`FolderWatcher.swift:31-33`), so copying the *same* file back in is ignored
while a freshly created one with the same name imports fine. A fresh name each
pass is still the simplest way not to have to think about it. And **don't count
on ⌘Q to persist the position**: `stop()` does flush whatever the throttle was
holding (`FolderWatcher.swift:265-270`), but that flush is a `queue.async` that
hops to the main actor and then to a background write, so it races process
exit. Losing it costs a slightly wider replay and nothing else.

## Run E — Non-downloaded iCloud file sticks on "Downloading" (#2)

**Feel-tested 2026-08-23, and it found the actual cause — which was neither of
the two candidates below.** The tile counted up to 44 s and beyond while Finder
showed the file had long since arrived. Both candidates were real and both are
fixed; neither was what made it stick.

**The poll was reading a cached value.** `URL` caches resource values on its
underlying `NSURL` box, so `resourceValues(forKeys:)` on the *same* URL returns
what it read the **first** time, for the life of that URL. The wait therefore
sampled `.notDownloaded` once and re-read that same answer 480 times over two
minutes, whatever iCloud did in between. It could only ever end at its deadline.

The codebase already knew this trap — `FolderWatcher.probe` carries a comment
about it and samples through `FileManager` precisely to dodge it. The cloud path
did not, and the old `Thread.sleep` loop had the same bug, so this predates the
queue fix rather than being caused by it. `CloudDownloadWaiter`'s reads now go
through `uncachedResourceValues(of:forKeys:)`, and
`testTheProbeSeesValuesChangeRatherThanTheFirstReadForever` pins both halves:
that the helper sees a size change, and that the plain call really does not.

**Re-test owed:** evict a file, drag it, and confirm the tile lands rather than
counting to 120.

Below: the two queue/percentage findings, which stand.

**Symptom.** Right-click ▸ Remove Download on an iCloud file, then drag it to
the shelf. The tile appears and stays on "Downloading" with a spinner
indefinitely. The shelf itself stays responsive.

**Both candidates were real, and the second one is what made "forever" the
honest description.**

**(1) It was also blocking every other drop.** `waitForCloudDownload` ran
*inside* a `TransferPipeline` operation and slept up to 120 s on
`maxConcurrentOperationCount = 2`, so two cloud files held the whole queue and
ordinary drops queued behind them. The wait is now an `async` pre-step that runs
before any slot is taken — `CloudDownloadWaiter`, polled with `Task.sleep`, on
the cooperative pool and never the main actor.
`testACloudWaitDoesNotBlockOrdinaryImports` stages three ordinary files through
a pipeline with two cloud waits outstanding; before the change that deadlocked
until the timeout fired.

**(2) There was no way to tell a slow download from a wedged one, and no
percentage exists to fix that with.** The fix sketch here said to use
`ubiquitousItemPercentDownloadedKey`. That is not available:
`URLResourceKey.ubiquitousItemPercentDownloadedKey` is **unavailable in Swift**
(deprecated since 10.8 — `swiftc` refuses it outright), and its replacement,
`NSMetadataQuery` with `NSMetadataUbiquitousItemPercentDownloadedKey`, only
reports on the *querying app's own* ubiquity container. The dragged file lives
in the user's, and perch ships with no iCloud entitlement at all. So there is no
percentage for perch to read, and the pinned decision is in the type comment on
`CloudDownloadWaiter`.

What the tile shows instead is **elapsed seconds** — "Downloading 7s" — against
a stated 120 s deadline, so the phase is bounded on screen rather than
open-ended. And the two ways it can end are now different errors, because they
have different answers: `.cloudDownloadTimedOut` (a download ran and did not
finish — including one that started and then paused) and
`.cloudDownloadNeverStarted` (no probe ever saw one running — "open it in Finder
to download it, then drop it again"). A third, `.cloudDownloadFailed`, stands in
for iCloud's own error, which is deliberately **not** rethrown: it embeds the
original path and `ShelfStore.report` logs `localizedDescription` as `.public`.
All three surface through `report(_:)` as before.
`testCloudWaitDistinguishesNeverStartedFromTimedOut`.

### ~~E3 · The unbounded wait that leaving the queue left behind~~ — **fixed**

Leaving the operation queue removed the stall it was causing *and* the two-slot
cap on concurrent waiters. N evicted files dropped at once were N waiters each
making a synchronous `resourceValues` syscall every 250 ms **on the cooperative
pool**, which has one thread per core and cannot grow — a big drop could starve
every other async task in the app, the imports queued behind it included.
`ShelfStore.importFileURLs` spawns one unstructured `Task` per dropped URL with
no cap of its own, so nothing upstream was capping it either.

The fix bounds the *blocking work*, not the waiting: all three cloud syscalls —
the "is this evicted?" check on the path of every import, the
`startDownloadingUbiquitousItem` request, and the poll — go through
`CloudSyscallQueue`, one serial dispatch queue off the cooperative pool at
`.userInitiated`, while every waiter keeps its own clock, its own deadline and
its own download.
Bounding the waits was the obvious fix and the wrong one — iCloud fetches in
parallel, so a queued waiter would not ask for its download until an earlier one
finished and its 120 s deadline would start late, which is the bug E1 removed.
`testConcurrentCloudWaitsOverlapButTheirProbesDoNot` pins both halves, and the
second one is the point: no waiter may finish until all twelve have probed, so
anything that re-bounds the *waits* fails on the timeout instead of going green.
Cost, stated: serial means head-of-line, so a wedged syscall delays every other
cloud call behind it — it cannot move a deadline, that instant is wall-clock,
but the deadline is only *checked* after the probe returns, so it does delay
when a timeout fires.

**Still owed: the feel-test.** Evict a file (right-click ▸ Remove Download),
drag it to the shelf, and watch. Expect the counter to climb, the tile to land
when iCloud delivers, and — for a file iCloud will not fetch — a named error at
2 minutes rather than a spinner. Then drop two evicted files *and* an ordinary
one together: the ordinary one must land immediately.

**Watch out.** Blocking coordination is still off the main actor, and the
`NSFileCoordinator` read in `stageFile` is unchanged — only the wait moved. The
cloud seam (`isUndownloadedCloudItem` / `startDownload` / `probe`) exists to
make the path testable without an iCloud account; production defaults are the
real calls.

## ~~Run F — The two Finder doors (#4, #5)~~

**Closed 2026-08-23. The extension was the dead door, and it is gone.**

The click test the section below asks for was run: of the two identical
"Add to Perch Shelf" rows under Services, **only the top one shelved the file**.
Which door that was is settled by a durable artifact rather than by timing —
`PerchFinderAction` had exactly one delivery path (`ActionRequestHandler` →
`HandoffClient` → the App Group mailbox), and
`~/Library/Group Containers/88M28542LQ.com.hausfold.perch/FinderActionRequests`
was untouched across the whole session. One group container, both the app and
the appex entitled to it, so there was nowhere else the write could have gone.
The tile landed without the mailbox being written, which only the in-process
`ShelfDropHandler` path does. **The working row was the classic `NSServices`
entry; the extension delivered nothing.**

So the extension was 0-for-3 — never rendered under Quick Actions, never
delivered when clicked from Services, and was the sole cause of the duplicate
row — and the `PerchFinderAction` target was deleted. `PerchFinderBridge/`
stays: the `perch` CLI is still a sender on that mailbox. The decisions now
live where they bind (`Perch/Config/Info.plist`, `ARCHITECTURE.md`,
`AGENTS.md`, `PRD.md`, `README.md`, `nix/dev-app/README.md`), not here.

The investigation that got there is kept below, unedited, because it is the
record of what was ruled out.

### The proof above does not discriminate — read this before reinstating anything

Measured after the deletion landed, from a checkout, with nothing cleaned first:

| what | count |
|---|---|
| registered `Perch.app` records in `lsregister -dump` | **40** |
| of those, still on disk | 12 |
| live bundles declaring the `addToShelf` Service | **6** |
| distinct bundle ids among those six | **2** — `com.hausfold.perch` ×3, `com.hausfold.perch.dev` ×3 |
| registered appex providers (`pluginkit -mAvvv -p com.apple.services`) | 1, whose parent bundle is `~/.cache/bench/perch-dd/…/Debug/Perch.app` — **not** `/Applications/Perch.app` |

Two consequences, and they land on the reasoning above rather than on the
outcome:

- **"The mailbox was untouched" does not identify the dead row.** It proves the
  row that did nothing did not go through `HandoffClient`. It does not prove
  that row *was* the appex. Six live providers under two bundle ids produce two
  disambiguated `(Perch.app)` rows on their own — one being `/Applications`, the
  other a lane build whose Service would launch a second Perch that stands down
  at the single-instance guard (`AGENTS.md` ▸ Build). That predicts exactly what
  was seen: one row shelves, the other does nothing, no mailbox write. Both
  hypotheses fit the observation, so the observation cannot choose between them.
- **"Never rendered under Quick Actions" was measured on the wrong copy.** The
  only appex PluginKit had was the bench build cache's — same nested id as
  `/Applications`', so PluginKit keeps one record and the cache won it. A Quick
  Action whose container sits in a build cache is the unrepresentative case this
  file warned about in step 0.

**This does not reopen the deletion.** The extension bought one thing — running
without waking the app — which is worth little for an app that owns the notch,
and the classic Service demonstrably works. Removing it is defensible as a
product call and it is made. What is corrected here is the *record*: Run F is
closed by a decision, not by a measurement that could have gone the other way.

**If anyone ever wants the extension back**, the clean-machine test was never
run and `git revert` of #98's target deletion is the cheap half. The test is:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -kill -r -domain local -domain system -domain user
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f /Applications/Perch.app
killall Finder
```

…then right-click a selection **before any lane builds again**. One Services row
means the duplicate was lane pollution; two means both doors really render.
`pluginkit -r` is not a substitute — it only unregisters appex providers, which
is why the "clean machine" in the first feel-test pass was never clean.



### Original notes

**Symptoms.**
- "Add to Perch Shelf" does **not** appear under Finder ▸ Quick Actions, even
  though it is ticked in the Quick Actions "Customize…" list.
- It **does** appear under Finder ▸ Services — **twice**.
- There is no top-level "Add to Perch Shelf" in the context menu.

**Step 0 — done. The duplicate was this Mac, and the *absence* is the dev app.**

Two separate things were going on, and neither is in a plist.

**(i) The duplicates were stale registrations.** `pluginkit -mAvvv -p
com.apple.services` found **three** "Add to Perch Shelf" extensions, all on
disk: `/Applications/Perch.app`, `~/code/workshop/perch/DerivedData/…/Release`
and `~/.cache/bench/perch-dd/…/Debug`. `lsregister -dump` showed a dozen more
`Perch.app`s under `~/.cache/claude-worktrees/*/DerivedData` — every agent lane
that ever ran `xcodebuild` registered its build. Unregistering the two dev
copies took the count to 1.

**(ii) With one copy left it still doesn't appear — because `bench try`'s dev
app gives the extension the app's own bundle id.** Measured on the installed
`2026.08.23-dev` build:

| bundle | `CFBundleIdentifier` |
|---|---|
| `/Applications/Perch.app` | `com.hausfold.perch.dev` |
| `…/PlugIns/PerchFinderAction.appex` | `com.hausfold.perch.dev` — **the same** |

An app extension must carry its own identifier, prefixed by its container's.
Identical ids are a malformed pair, so PluginKit never surfaces it: no Quick
Action, and nothing to switch on in Settings ▸ Login Items & Extensions ▸
System Services Extensions.

The cause is one line in **bench**, not in perch:

```sh
xcodebuild -scheme Perch … PRODUCT_BUNDLE_IDENTIFIER=com.hausfold.perch.dev
```

A `PRODUCT_BUNDLE_IDENTIFIER` on the xcodebuild command line overrides the
setting for **every target in the scheme** — the app, `PerchFinderAction` and
`PerchCLI` alike — collapsing all three onto one id. The controlled experiment
is already in the `pluginkit` dump above: the same source built *normally*
registers correctly as `com.hausfold.perch.finder-action`; only bench's build
is broken.

**So #4 and #5 are, on current evidence, artifacts of the dev app and not of
shipped perch** — which also explains why they resisted a plist-shaped
diagnosis. Confirm by testing a real notarized release, and fix the dev path so
`bench try` can feel-test the Finder doors at all:

- **perch — done in this PR.** All six targets derive from a project-level
  `PERCH_BUNDLE_ID = com.hausfold.perch`: `$(PERCH_BUNDLE_ID)`,
  `.finder-action`, `.cli`, `.tests`, `.ios`, `.ios.share`. Verified both directions —
  a normal build's ids are unchanged (`com.hausfold.perch` /
  `com.hausfold.perch.finder-action` / `com.hausfold.perch.ios` /
  `com.hausfold.perch.ios.share`, diffed against a pre-change build), and
  `PERCH_BUNDLE_ID=com.hausfold.perch.dev` now yields a properly nested
  `com.hausfold.perch.dev` / `com.hausfold.perch.dev.finder-action`.
- **bench — the matching one-line change.** `ensure_perch_dev_app`
  (`bench:590`) passes `PERCH_BUNDLE_ID=…dev` instead of
  `PRODUCT_BUNDLE_IDENTIFIER=…dev`.

Until *both* land, `bench try` cannot feel-test #4, #5 or anything else that
depends on the extension being live. After they do, the check is: `bench try`,
then select 3 files in Finder — the Quick Action should appear, and Login Items
& Extensions ▸ System Services Extensions should have a Perch row to switch.

### Feel-tested 2026-08-23 — twice. What each pass ruled out.

The bundle-id fix landed and is live: `/Applications/Perch.app` is
`com.hausfold.perch.dev`, its `PerchFinderAction.appex` is
`com.hausfold.perch.dev.finder-action`, properly nested, and the extension now
appears — enabled — in both Login Items & Extensions ▸ System Services
Extensions and Quick Actions ▸ Customize….

**Pass one blamed stale registrations, and was wrong.** `pluginkit` did show two
providers (a stale record for the old release at `/Applications`, plus the bench
DerivedData copy). Clearing them with `pluginkit -r` + `lsregister -f` +
`killall Finder` left **exactly one** plug-in — and the menu was unchanged. Both
symptoms survived a clean machine, so neither is a registration artifact.

**What that proves, by elimination.** With one registered appex and two
`Add to Perch Shelf (Perch.app)` rows under **Services**, the two rows are the
appex *and* the app's classic `NSServices` entry. macOS only appends the app
name when it has two providers with one title to tell apart. So:

- **#4's duplicate is self-inflicted**, not a build or registration fault. Perch
  ships two doors and they land in the same submenu.
- **#5's premise is dead.** A classic `NSServices` entry does *not* reach the
  context menu's top level on macOS 26 — it is in Services, next to the
  extension. The comment at the head of `Perch/Config/Info.plist` and the
  matching paragraph in `ARCHITECTURE.md` said otherwise; both are corrected in
  this change, which is the fix #5 was always most likely to need.

**Also ruled out for the Quick Actions half**, so nobody re-checks them:
- *The activation rule.* It cannot be the reason. The extension **does** appear
  under Services for the same selection, so the rule matched — a rule that
  failed to match would hide it from both submenus, not one.
  `NSExtensionActivationSupportsFileWithMaxCount = 1000` is exonerated.
- *A missing preview icon.* `NSExtensionServiceFinderPreviewIconName` names
  `ActionIcon`, and `assetutil --info` on the shipped
  `PerchFinderAction.appex/Contents/Resources/Assets.car` finds it
  (`RenditionName: ActionIcon.svg`). It is there.

**What is left, and it needs one more measurement.** Every Quick Action that
*does* render on this Mac — Rotate Left, Markup, Create PDF, Convert Image,
Remove Background — is a Finder built-in: `pluginkit -mAvvv -p
com.apple.services` reports **one** plug-in on the whole system, perch's. There
are no Automator `.workflow` Quick Actions in `~/Library/Services` or
`/Library/Services` either. So this machine has no working third-party example
to diff against, and the open question is whether macOS 26 renders third-party
Action extensions under Quick Actions **at all**, or only built-ins and
Automator workflows.

The cheap experiment: drop a minimal Automator Quick Action into
`~/Library/Services` and look. If the workflow appears and perch's extension
still does not, #4's first half is macOS's placement and the fix is
documentation — the same answer #5 just got. If the workflow does not appear
either, the Quick Actions submenu on this Mac only ever shows built-ins and
there is nothing here for perch to fix.

**Which door to keep is a product call, and it needs one click first.** The two
rows are indistinguishable in the menu, so before deleting either, click each
and see which one shelves the file — if the extension is the broken one, the
classic Service is the door that works and deleting it would close the last one.

**Two doors with one name was deliberate, and the reason it was given no longer holds.** The app declares
a legacy `NSServices` entry titled "Add to Perch Shelf" *and* ships an appex
Services extension with the same display name — the decision is stated at the
head of `Perch/Config/Info.plist` and in `ARCHITECTURE.md`: the extension runs
without waking the app, the classic Service is eligible for the menu's top
level and is two clicks shorter. They land in different submenus, so they are
not the two rows #4 reported; the duplicates were the stale registrations in
(i).

**#4 · Quick Actions.** `PerchFinderAction/Info.plist` declares
`NSExtensionPointIdentifier = com.apple.services` with
`NSExtensionServiceRoleTypeEditor` and the Finder-preview keys, which is the
right shape for a Finder Quick Action. If it is enabled and still absent after
step 0, the next suspects are:
`NSExtensionActivationSupportsFileWithMaxCount = 1000` (try a small number —
oversized activation rules have been observed to disqualify an item), and
whether the extension is signed/registered at all from the build under test
(`pluginkit -m -p com.apple.services`). Note the enclosing app must be in a
LaunchServices-visible location; a Quick Action inside `DerivedData` is not a
representative test.

**#5 · Top-level Service.** Verify the premise before writing code. Modern macOS
Finder collects services under **Services** and Quick Actions under **Quick
Actions**; the "beside New Terminal Tab Here" placement described in the comment
at the head of `Perch/Config/Info.plist` may simply no longer exist on macOS 26.
If it doesn't, **the fix is documentation**: correct that comment, correct the
matching claim in `PRD.md`/`ai/SKILL.md` if present, and drop the test-script
line — a shipped claim that macOS does not honour is worse than no claim.

**Verify.** On a clean machine (or after `lsregister -kill -r -domain local
-domain system -domain user`), with only one Perch installed: 3 files selected →
Quick Actions shows it once, Services shows it once, and both land 3 tiles with
3 untouched originals.

---

## ~~Run G — Settings ▸ Devices says "No devices paired" while the phone works (#12)~~

**Symptom.** Phone and Mac are paired and delivering. Settings ▸ Devices shows
"No devices paired yet." Revoke is therefore unreachable, so the revoke test
could not be run at all.

**Closed 2026-08-24: #82 had already fixed it, ten hours before this pass ran.**
Both surfaces list the device on the shipped 2026.08.24 and Revoke is live —
the readings, and the two paths they still don't cover, are under *Where it
stands — 2026-08-24* above. **The rest of this run is kept as written**: it is
wrong about what was broken and right about everything it measured, and those
measurements are load-bearing — they are why `PairedDeviceStore` has the shape
it has, and why the data-protection Keychain is not available to perch. Read
what follows as findings about the Keychain, not as a diagnosis of #12.

**The Keychain theory is disproved by measurement, not by reading.** Both #82's
fix *and* the migration that was going to replace it are off the table. `PairedDeviceStore` was instrumented and put under test in a
signed, sandboxed Perch host (`xcodebuild test` *without*
`CODE_SIGNING_ALLOWED=NO`, which is what makes the app sandboxed and entitled
the way the shipped one is). What that host actually returns:

| call | status |
|---|---|
| `SecItemAdd` | `0` |
| single-account read (delivery's path) | `0` |
| `kSecMatchLimitAll` + `kSecReturnAttributes` (step one of `all()`) | `0`, **1 row** |
| the same plus `kSecReturnData` | `-50` — #82's `errSecParam`, confirmed |
| anything with `kSecUseDataProtectionKeychain` | `-34018` |

So **the enumeration works**, #82's two-step read is correct and is not a hack
to be tidied away, and #12 is *not* a Keychain-listing bug. `all()` now logs its
row count on success as well as its status on failure, which is what the next
pairing needs to say which of the three outcomes it is. The full round trip —
store, read, list, revoke, re-pair — is covered by `PairedDeviceStoreTests`,
which passes both signed and unsigned.

**Where to look next**, now that the store is exonerated: `MobileReceiver`'s
`@Published pairedDevices` is the only other thing between the Keychain and the
label. It is refreshed in exactly three places (`init`, `finishPairing`,
`revoke`), so the question is whether the instance Settings renders is the
instance that paired, and whether `finishPairing` ran at all for the pairing in
the room. Reproducing needs the phone and the installed Developer-ID build:

```sh
log stream --predicate 'subsystem == "com.hausfold.perch" && category == "PairedDevices"'
```

Pair, and read the count line. `Keychain list: 1 paired device(s)` with an empty
Settings list moves this to the UI; `no paired devices` moves it to whether the
pairing was ever stored.

**Taken 2026-08-24: `1 paired device(s)`, and the list was not empty** — so
neither branch this criterion offers was the answer. Both were written on the
assumption there was still a bug. *Where it stands — 2026-08-24* above.

**Watch out.** Do not "fix" this by moving to the data-protection Keychain. It
needs a Keychain access group; naming one needs a `keychain-access-groups`
entitlement, which is provisioning-profile-gated, and perch ships
Developer-ID-signed with **no** profile — a binary carrying that entitlement
without one is SIGKILLed at exec (measured). The App Group perch already has is
not accepted as a substitute (`-34018`). Both facts are pinned by tests, next to
the code that depends on them.

## Not bugs — fix the test script instead

**#3 · "3 GB file shows up immediately."** That is correct behaviour on APFS.
`TransferPipeline.stageFile` uses `FileManager.copyItem`, which clones rather
than copies when source and destination are on the same APFS volume — and
`~/Downloads` and the app container are. The copy really is instantaneous and
costs no disk. The test line ("tile shows indeterminate progress, lands
eventually") is only reachable across volumes. **Rewrite it**: drag a 3 GB file
from an external/USB or network volume, or from a disk image, and assert
progress there; on the internal volume assert that it lands instantly.

Measured, to save the next person the doubt: a 2 GB `FileManager.copyItem` on
one APFS volume finishes in **0.001 s** and consumes **zero** extra disk. `cp`
of the same file takes 1.34 s and the full 2 GB — so `cp` is **not** a valid
stand-in when writing the replacement test.

**#14 · "Overlapping `curl -o` downloads only add one tile."** Reported in the
2026-08-23 feel-test: run `curl -o ~/Downloads/slow.bin <url>` twice
sequentially and two tiles land; start the second before the first finishes and
only one lands, when the last one stops. That is the only answer available.
**Both curls write the same path, so there is one file**, and it does not hold
still until the last writer lets go — the stability probe promotes once, at the
end, with whatever bytes won. N overlapping writers to one path cannot produce N
files for perch to shelve.

Two *different* paths downloading at once is the case that would be a bug, and
it works: `testTwoFilesGrowingAtOnceBothLand` runs two continuous writers that
overlap in both directions and asserts each lands exactly once. Worth knowing
while writing that kind of test: growing a file in bursts slower than
`probeInterval × requiredStableProbes` leaves a quiet window in the middle, and
the probe promotes on each one — that is D2's "replaced contents are a new
arrival" doing its job, not a double import.

**#11 · "Wi-Fi off on the phone, Mac still received it."** Also correct.
Every wire path sets `includePeerToPeer = true` (`PerchWire/Wire/WireServer.swift:94`,
`WireBrowser.swift:62`, `WireConnection.swift:37`), so delivery can run over
AWDL — the same peer-to-peer link AirDrop uses. Turning Wi-Fi off in **Control
Center** disconnects from the network but deliberately leaves AWDL up, so the
phone finds the Mac anyway. **Rewrite the line** to use Airplane Mode, or
Settings ▸ Wi-Fi ▸ off (not the Control Center toggle), which is the only way to
actually take the link down. **Stated in `docs/reference.md` ▸ Permissions** —
which also had to be corrected while it was open: it claimed perch "makes
exactly one kind of network call" (the update check) and did not mention the
Bonjour listener the phone connects to, which ships **on**. Both halves are
there now, with the peer-to-peer note beside them, and the mechanism
(`includePeerToPeer` on all three wire paths) is stated once in
`ARCHITECTURE.md` beside the wire.

---

## Needs a call from Julien

~~**G · Keychain migration — 4/5.**~~ **Answered: neither option — the question
was wrong.** Julien chose Option A (migrate, no fallback, re-pair by hand). It
turns out not to be available: the data-protection Keychain refuses perch
outright, for a reason no amount of migration code changes. And Option B has
nothing left to fix — the file-based enumeration was measured working. The
decision that *did* land is stated where it binds, in the type comment on
`PairedDeviceStore` and in the two tests that pin it. The `MobileReceiver`/UI
side that Run G was left open on turned out to have nothing wrong with it —
closed 2026-08-24.

~~**C · Rename semantics — 3/5.**~~ **Answered: (a)**, re-resolve — the staged
filename is the user's to edit and the shelf follows it. Stated in
`ARCHITECTURE.md`; Run C is landed.
