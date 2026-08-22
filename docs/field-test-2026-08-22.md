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
| 1 | Shelf hover-opens ~1 notch-width either side of the notch | Platform | Confirmed cause | **A** |
| 13 | Secondary display never shows a drop target | Platform | Strong hypothesis | **A** |
| 10 | Open/close animation janks at ~250 items (scrolling is fine) | UI | Confirmed cause | **B** |
| 9 | 50 folders dropped into Finder land in a diagonal line | UI | **Open** — first theory disproved | **B** |
| 7 | Rename a staged file in Finder → tile can never be dragged out, and vanishes | Store | Confirmed + a second race | **C** |
| 6 | `curl -o ~/Downloads/slow.bin` never lands | Watch | Leading hypothesis + 1 confirmed adjacent bug | **D** |
| 8 | Quit → drop into `~/Downloads` → relaunch → no catch-up | Watch | Unresolved by reading | **D** |
| 2 | Non-downloaded iCloud file sticks on "Downloading" forever | Import | Two candidates | **E** |
| 4 | Quick Action absent from Quick Actions; Service listed twice | Finder | Needs a clean-machine check first | **F** |
| 5 | No top-level "Add to Perch Shelf" in the Finder context menu | Finder | Probably an obsolete claim | **F** |
| 12 | Settings ▸ Devices says "No devices paired" while the phone still delivers | Mobile | **Regression** — #82's fix didn't hold | **G** |
| 3 | 3 GB file "lands immediately" instead of showing progress | — | **Not a bug** — bad expectation | — |
| 11 | Phone Wi-Fi off, Mac still receives | — | **Not a bug** — bad expectation | — |

---

## Run A — Notch geometry (`Perch/Platform/`)

Two independent bugs, one file each, one PR.

### A1 · Passive hover opens a band ~3× the notch (#1)

**Symptom.** With items on the shelf and nothing being dragged, moving the
pointer along the menu bar pops the shelf open roughly one notch-width to the
left and right of the notch. It should only open over the housing itself.

**Repro.** Put one item on the shelf. Move the pointer along the menu bar from
the far left toward the notch. Note where it opens.

**History — read this before you "fix the width".** This has been narrowed
twice already and still misbehaves: `65bc959` (#55) and `3413871` (#78). The
geometry is *already* correct; the trigger is not reading it.

**Root cause (high confidence).**
`ShelfGeometry.hoverTriggerWidth` computes ≈ notch width + 12pt and
`ShelfHostingView.updateTrackingAreas()` installs a correspondingly narrow
`NSTrackingArea` — `Perch/Platform/ShelfPanelController.swift:300` and the
`hoverRect` at `:321`. But `mouseEntered(with:)` / `mouseExited(with:)` at
`:339`/`:343` fire for **every** tracking area whose owner is this view, and
`NSHostingView` installs its own full-bounds tracking area with itself as owner.
So the wide hosting-view area calls our override and expands the shelf; the
narrow area we installed is irrelevant. That is exactly why narrowing the rect
twice changed nothing.

**Confirmed empirically.** A subclass of `NSHostingView` whose root view
contains `.onHover` ends up with **two** tracking areas, both owned by the
subclass: ours, and SwiftUI's at full bounds with options
`mouseEnteredAndExited | mouseMoved | activeAlways | inVisibleRect`. Remove the
`.onHover` and the second one is not installed at all. Ours is
`ShelfPanelView.swift:534`. Note the irony: the comment at
`ShelfPanelController.swift:302-306` warns against `.inVisibleRect` for exactly
this reason, and `super.updateTrackingAreas()` at `:315` then re-adds an area
that uses it.

**Fix sketch.** Stop trusting *which* area fired. Either:
- gate on identity — `guard event.trackingArea === trackingAreaReference`
  in both overrides (cheap, but relies on AppKit handing back our instance); or
- drop the tracking area for hover entirely and hit-test the pointer:
  convert `NSEvent.mouseLocation` into the panel's coordinate space and compare
  against `hoverRect` inside `onPointerEntered`, before `expand()`.

Prefer the second — it is testable without a window server and it also fixes the
symmetric exit case. Whichever you pick, the wide catch band for *drags* must
stay exactly as wide as it is now (that is `collapsedWidth`, and #13/#55/#78 all
depended on it).

**Verify.** Build, quit the installed copy, run `.../Contents/MacOS/Perch`.
One item on the shelf; sweep the menu bar left→right. Opens only over the
housing. Then drag a file along the same path — still caught in the wide band.

**Watch out.** `hide()` sets `hoverSuppressed`; keep that path working (menu-bar
/ sketchybar items beside the notch must stay clickable after "Hide").

### A2 · Secondary displays get a panel at the wrong coordinates (#13)

**Symptom.** With "Show a drop target on every display" **on**, only the main
display shows a shelf. (With it **off**, one panel on the main display is the
intended behaviour — see the second note below for why even that can misplace.)

**Root cause (strong hypothesis — the API contract is verbatim, the macOS 26
runtime behaviour is not yet observed. Land the test case first).**
`ShelfWindowSystem.rebuildPanels()` does build one controller per
`NSScreen.screens`, so the panels exist — they are just placed off-screen.
`ShelfPanelController` computes `geometry.collapsedFrame` in **global** screen
coordinates from `screen.frame` (`Perch/Platform/ScreenGeometry.swift`), then
passes that rect to
`NSPanel.init(contentRect:styleMask:backing:defer:screen:)` **with a non-nil
`screen:`** — `Perch/Platform/ShelfPanelController.swift:32-37`. That
initializer documents `contentRect` as relative to the given screen's
lower-left corner, so the origin is applied twice. On the main display
(origin 0,0) the double-offset is zero and it looks fine; on any secondary
display the panel lands one screen-origin away from where it belongs.

**Fix sketch.** Pass `screen: nil` and keep the global rect (simplest), or keep
`screen:` and subtract `screen.frame.origin` from the rect. Add a
`ScreenGeometryTests` case with a screen whose `frame.origin` is non-zero,
asserting the frame that reaches the panel.

**Verify.** Two displays, setting **on**: a catch band on each. Setting **off**:
one, on the main display. Drag a file to the notch/top edge of the secondary
display and confirm it catches. Then `⌘`-drag the menu bar between displays
(fires `didChangeScreenParametersNotification` → `rebuildPanels`) and re-check.

**Watch out — two more failure modes with the same symptom.**
- `panels` is keyed by `perchIdentifier`; two mirrored displays can report the
  same `NSScreenNumber`, and a duplicate key silently drops a panel.
- With the setting **off**, `rebuildPanels` uses `NSScreen.main`
  (`ShelfWindowSystem.swift:85-91`) — which is the **key-window** screen, not
  the zero-origin one. So the single-panel case is misplaced by the same
  double-offset whenever focus is on a secondary display.

---

## Run B — Shelf list rendering (`Perch/UI/`)

### B1 · Open/close janks at ~250 items (#10)

**Symptom.** Scrolling and hover stay smooth at ~250 staged items, but the
expand/collapse animation stutters.

**Root cause (high confidence).** `ShelfPanelView.swift:324-326` is
`ScrollView(.horizontal) { HStack { ForEach(store.items) … } }` — an **eager**
`HStack`. Every expand builds all 250 `FileTile`s, and each one:
- starts a `.task` in `FilePreview` (`Perch/UI/FilePreview.swift`), and
- calls `NSWorkspace.shared.icon(forFile:)` **synchronously in `body`**
  (`FilePreview.swift:30-32`, `fileIcon`) — a LaunchServices round trip per
  tile, on the main thread, during the animation.

That second cost is worse than "only files without a content preview": `@State
thumbnail` starts `nil` on every rebuild, so `fileIcon` renders — and hits
LaunchServices — for **all 250 tiles on every expand**, thumbnailed ones
included, until each `.task` resolves.

**Fix sketch.** `LazyHStack` for both `ForEach`es, and hoist the workspace icon
behind the same async/cached path the thumbnail uses. Key that cache **by path**
in an `NSCache`, exactly as `ThumbnailCache` already does — *not* by content
type: `icon(forFile:)` is per-file for `.app` bundles, Finder custom icons and
alias badges.

**Verify.** Stage ~250 items (`for i in $(seq 1 250); do …; done` into a watched
folder, or `perch add`). Open/close ten times. Then confirm the *reflow*
animations still work — `.animation(Self.reflow, value: store.items)` on a
lazy stack behaves differently for off-screen rows; a tile removed while
scrolled away must not pop.

**Watch out.** The `.padding(.top, 11)` overhang comment at `:352` exists so
pin/remove badges aren't clipped. Lazy stacks re-clip; re-check the badges.

### B2 · Multi-item drag-out lands in a diagonal line (#9)

**Symptom.** Drag 50 folders out into an empty Finder window → they are placed
along a top-left→bottom-right diagonal, and Finder's Clean Up keeps the
diagonal.

**First theory, and why it is dead.** `FileDragSourceView.swift:141-142` does
cascade the drag frames — `offset = min(index, 4) * 3` — but the `min(index, 4)`
clamp stops it after five items. For a 50-folder drag the offsets are
`0, 3, 6, 9, 12, 12, 12, …`: **46 of the 50 items already share an identical
frame**, so a 3pt cascade cannot be producing a 50-icon diagonal, and "make the
frames identical" would change nothing for 46 of them. (Confirmed this is the
live path: the drag-all handle at `ShelfPanelView.swift:240` hands `store.items`
to a single `FileDragSourceView`.)

**So this one is open.** The likely answer is that Finder cascades a
multi-item drop *itself* when the drag gives it no distinct positions to work
from — i.e. the diagonal is Finder's own default and the fix is to stop letting
it decide. Investigate in this order:
1. Drop 6 items vs 50 into an empty icon-view window. If both cascade
   identically, it is Finder's placement, not our frames.
2. Try dropping onto a **list-view** or **column-view** window, and onto the
   Desktop. If those are fine, it is purely icon-view placement.
3. Compare against a 50-file drag out of another shelf app (Dropover, Yoink) —
   if theirs land in a grid, diff what they put on the pasteboard.

**Only then** decide the fix. Candidates: set no dragging frames at all and let
Finder place; or set frames on a real grid so Finder's honouring of them
produces the layout you want.

**Verify.** 5 folders and 50 folders, dropped into (a) an empty Finder window in
icon view, (b) a list-view window, (c) the Desktop. Icons arrive in Finder's
normal grid. Also drop onto a terminal and confirm 50 paths still paste.

---

## Run C — A staged file the user can rename out from under the shelf (#7)

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

### D1 · A failed import is ledgered anyway, so it never retries (confirmed, fix regardless)

`FolderWatcher.promote` (`Perch/Importing/FolderWatcher.swift:223`) inserts the
identity token into the ledger and *then* calls `onImport`;
`FolderWatchCenter.attachWatcher`'s `onImport` closure calls
`folderStore.markImported(token, …)` **before** `shelf.importFileURLs([fileURL])`
and never learns whether staging succeeded. One transient failure and that file
is permanently invisible to the watcher. Ledger on success, not on attempt.

### D2 · `curl -o` arrivals never land (#6)

**Symptom.** `curl -o ~/Downloads/slow.bin …` — nothing appears mid-write
(correct) and nothing appears when it finishes (wrong). Repeated with and
without `--limit-rate`. A browser download to the same folder lands fine, so
the watcher itself is alive.

**Leading hypothesis (medium-high confidence).**
`FolderWatchRules.identityToken` (`FolderWatcher.swift:21`) hashes **inode +
birth date**, deliberately, so a rename or edit-in-place does not re-import.
`curl -o` on an existing path *truncates and rewrites* — same inode, same birth
date, same token. Once `slow.bin` has been ledgered once, **every later
`curl -o ~/Downloads/slow.bin` is deduped forever**, which is precisely the
"even this one shows nothing" report. A browser avoids it by writing
`…​.crdownload` and renaming to a fresh name each time.

Combined with D1, one silently-failed first import would also produce
"never again" with no successful import having ever happened.

**Diagnose first, in this order.**
1. `rm ~/Downloads/slow.bin` then curl to that name → does it land? (isolates
   inode reuse from everything else)
2. `curl -o ~/Downloads/$(uuidgen).bin …` → does it land? (same)
3. `log stream --predicate 'subsystem == "com.hausfold.perch"'` while curling —
   `Shelf`/`WatchedFolders` categories.

If (1)/(2) land, the bug is the dedupe rule, not the watcher.

**Fix sketch (if confirmed).** The token must change when the *content* is
replaced. Add the size and modification date to the hashed identity, or store
the last-seen `(size, mtime)` beside the token and treat a change as a new
arrival. Keep the property the token exists for: a pure rename, and an
edit-in-place that the shelf already holds, must still not re-import. Extend
`FolderWatchingTests` with a truncate-and-rewrite case.

### D3 · No catch-up on relaunch (#8)

**Symptom.** Quit Perch → drop a file into `~/Downloads` → relaunch → the file
never lands.

**Reading did not explain this.** The catch-up path exists and looks right:
`AppRuntime.start()` → `FolderWatchCenter.start()` → `startWatching(seedExisting:
false)` → `FolderWatcher.initialScan` (`FolderWatcher.swift:153`) prunes the
ledger to what is present and then calls `scan()`, which probes and promotes any
unledgered file after ~0.5 s. **Instrument before changing anything.**

Things to rule out, cheapest first:
- Was the file's token already in the ledger? (moving a file *into* `~/Downloads`
  preserves inode + birth date — the same D2 mechanism, from a different angle)
- Does `startWatching`'s detached bookmark resolve at all on a cold launch?
  `attachWatcher` bails silently on a stale bookmark → `markUnavailable`, and
  the only trace is a log line. Check Settings ▸ Watched Folders for an orange
  (unavailable) row after relaunch.
- Is the kqueue racing app launch — does the file land if you *touch* it after
  the app is up?

Fix D1 and D2 first; re-test D3 afterwards. There is a fair chance it is the
same root cause seen from the other end.

---

## Run E — Non-downloaded iCloud file sticks on "Downloading" (#2)

**Symptom.** Right-click ▸ Remove Download on an iCloud file, then drag it to
the shelf. The tile appears and stays on "Downloading" with a spinner
indefinitely. The shelf itself stays responsive.

**Two candidates — establish which before fixing.**

1. **It is not stuck, it is queued.** `TransferPipeline`'s queue is
   `maxConcurrentOperationCount = 2` (`Perch/Importing/TransferPipeline.swift:28`)
   and `waitForCloudDownload` (`:234`) blocks its slot with `Thread.sleep` for up
   to **120 seconds**. Two cloud files in flight stall every other import behind
   them. The 120 s ceiling then throws `.cloudDownloadTimedOut`, which
   `finishTransfer` reports as an error and drops the tile — so "forever" and
   "two minutes then gone" look the same to a tester who walked away.
2. **The download was never actually started.** `startDownloadingUbiquitousItem`
   is called on the URL Finder handed over. If the drag delivered a
   `.icloud` placeholder or a file-promise URL rather than the real ubiquitous
   item, the status polled at `:234` never reaches `.current` and the loop runs
   its full deadline for nothing.

**Diagnose.** Drag one evicted iCloud file and watch for exactly 120 s. If the
tile dies at ~2 min with an error, it is (1) plus a missing progress signal. If
it truly never resolves, look at what URL arrives — log the
`ubiquitousItemDownloadingStatus` transitions (never the path).

**Fix sketch.** Regardless of which: get the blocking poll off the import queue.
Use `NSMetadataQuery` (or an `NSFileCoordinator` read with
`.withoutChanges` on the ubiquitous item, which triggers and waits for the
download natively) rather than a sleep loop holding one of two slots, and give
the tile a real percentage from
`ubiquitousItemPercentDownloadedKey` instead of an unbounded spinner. A phase
that can last two minutes needs to be honest about progress and needs a
user-visible failure when it gives up.

**Watch out.** Blocking coordination must stay off the main actor (it already
is). Don't let the fix make a *second* import wait on the first.

---

## Run F — The two Finder doors (#4, #5)

**Symptoms.**
- "Add to Perch Shelf" does **not** appear under Finder ▸ Quick Actions, even
  though it is ticked in the Quick Actions "Customize…" list.
- It **does** appear under Finder ▸ Services — **twice**.
- There is no top-level "Add to Perch Shelf" in the context menu.

**Step 0, before touching any plist: rule out two registered copies.**
The duplicate Services entry is exactly what you get with an installed
`/Applications/Perch.app` *and* a `DerivedData` dev build both registered with
LaunchServices. Check:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -dump | grep -i -B5 'perch' | grep -i 'path:'
pluginkit -mAvvv -p com.apple.services | grep -i perch
```

If two bundles show up, unregister the stale one and re-test before concluding
anything about #4 or #5. This alone may account for both.

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

## Run G — Settings ▸ Devices says "No devices paired" while the phone works (#12)

**Symptom.** Phone and Mac are paired and delivering. Settings ▸ Devices shows
"No devices paired yet." Revoke is therefore unreachable, so the revoke test could not be run at all.

**History — this was "fixed" one day ago and the fix did not work.**
`3b40264` (#82) diagnosed `all()` as `errSecParam` (-50) from asking the
file-based Keychain for `kSecMatchLimitAll` **together with** `kSecReturnData`,
and split it into the two-step read that is in the tree now. That PR shipped
**unbuilt and unrun** by its own admission, and its verify step 1 was "pair a
phone, it should appear in Settings". This field test *is* that step, and it
failed. So the two-step workaround either did not address the real cause or
introduced a second one — treat the `errSecParam` explanation as **disproved
until the log says otherwise**, exactly like #1's #55/#78.

**Fault localised; the cause itself is still open.** Two different Keychain
reads back the two behaviours:
- Delivery uses `PairedDeviceStore.peer(for:)` — a single-account lookup with
  `kSecReturnData`. It works, which proves the item is in the Keychain.
- The list uses `PairedDeviceStore.all()`
  (`Perch/Mobile/PairedDeviceStore.swift:22`) — `kSecMatchLimitAll` +
  `kSecReturnAttributes` against the **file-based** Keychain, then a second
  read per account. That enumeration is returning nothing.

`all()` already logs on failure. Get the status code first:

```sh
log stream --predicate 'subsystem == "com.hausfold.perch" && category == "PairedDevices"'
```

Three outcomes, three different bugs:
- `Keychain list failed: <status>` → the enumeration is still refused, and the
  status is not what #82 assumed. If it is `-50` again, the two-step read did
  not change anything that mattered.
- `Keychain list skipped N unreadable device(s)` → step one works and the
  per-account `peer(for:)` read is what dies. #82 added that line for exactly
  this case; it is the most informative outcome.
- **Silence with an empty list** → the enumeration succeeds and genuinely
  returns zero rows, meaning the item `peer(for:)` finds is not visible to a
  `kSecMatchLimitAll` query at all — an access-group or
  `kSecAttrSynchronizable` mismatch, not a limit-all problem.

**Fix sketch.** With the in-place workaround already tried and failed, the
durable fix is to move every query in this file — add, read,
list, delete — onto the data-protection Keychain
(`kSecUseDataProtectionKeychain: true`), which supports `kSecMatchLimitAll`
together with `kSecReturnData` and collapses the two-step hack in `all()` into
one query. **See the decision below — this is not a free change.**

**Verify.** Pair a phone → it appears in Settings ▸ Devices immediately (not
just after relaunch). Relaunch → still listed. Revoke → the phone can no longer
deliver (currently untestable) and re-pairing from scratch
works. `WireLoopbackTests` should cover revoke-then-deliver.

---

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

**#11 · "Wi-Fi off on the phone, Mac still received it."** Also correct.
Every wire path sets `includePeerToPeer = true` (`PerchWire/Wire/WireServer.swift:94`,
`WireBrowser.swift:62`, `WireConnection.swift:37`), so delivery can run over
AWDL — the same peer-to-peer link AirDrop uses. Turning Wi-Fi off in **Control
Center** disconnects from the network but deliberately leaves AWDL up, so the
phone finds the Mac anyway. **Rewrite the line** to use Airplane Mode, or
Settings ▸ Wi-Fi ▸ off (not the Control Center toggle), which is the only way to
actually take the link down. Worth a sentence in `docs/reference.md`: perch
reaches your Mac peer-to-peer, so it works with no network at all — that is a
feature, and the test was asserting the opposite.

---

## Needs a call from Julien

**G · Keychain migration — 4/5.**
Moving `PairedDeviceStore` to the data-protection Keychain fixes the enumeration
properly, but every phone paired against the current file-based Keychain
**stops being recognised** unless the change ships with a read-old/write-new
migration. The comment at `PairedDeviceStore.swift:16-21` already calls this out.

- **Option A — migrate.** Read from the file-based Keychain, write to the
  data-protection one, keep the fallback read for one release, then drop it.
  ~40 extra lines and one migration test.
- **Option B — patch `all()` in place, again.** Keep the file-based Keychain and
  fix whatever the logged status turns out to be. Smaller diff, but the two-step
  enumeration hack stays, and so does the class of bug. **This is what #82 was,
  one day ago, and it did not hold.**

**Recommendation: A**, with the fallback read — the current listing is already
lying to the user about a security-relevant fact ("no devices can reach this
Mac" when one can), and one in-place attempt has already failed. **Reversal cost:** if A ships without the fallback read, every
existing pairing must be redone by hand on both devices; with the fallback read,
reverting is a straight revert.

**C · Rename semantics — 3/5.** Fix (a) makes the staged filename user-editable
and the shelf follows it; fix (b) makes it immutable and errors loudly. (a) is
recommended, but it changes what "Show in Finder" implies about the shelf and so
wants a line in `ARCHITECTURE.md`.
