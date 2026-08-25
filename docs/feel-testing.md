# Feel-testing perch by hand

A hands-on pass over the shelf is worth more than any test suite for the
things a suite cannot see — but on this kind of app several of the obvious
recipes **produce a confident wrong answer on the first run**. Each section
below is one of those, written down because it already cost somebody a wrong
turn during the 2026-08-22 field test.

Everything here is about *measuring*. What perch does and why lives in
[`reference.md`](./reference.md), `PRD.md` and `ARCHITECTURE.md`. The punch list
itself is gone — it was empty — but the record of what each finding ruled out is
retrievable: `git show v2026.08.24:docs/field-test-2026-08-22.md`.

One of its findings outlived it, and the watched-folder section below is how to
test it honestly: **"quit → drop into `~/Downloads` → relaunch → no catch-up"
was never reproduced.** The stream now resumes from a persisted position, and
the launch rescan would find a missed arrival on its own; nothing is owed unless
it recurs.

## Reading perch's own log

```sh
/usr/bin/log stream --predicate 'subsystem == "com.hausfold.perch"' --level info --style compact &
killall Perch; open -g -a /Applications/Perch.app
```

Two traps in that one line. `log`, unqualified, is a **zsh builtin** — the full
path is not optional. And `--level info` is not optional either: most of the
lines worth reading (counts, "N paired device(s)", state at launch) are `info`,
which macOS does **not persist** — `log show` will never show them however far
back you ask, and their absence there means nothing. The reading only exists
live, on a relaunch.

## Before measuring any Finder door

Every `xcodebuild` registers the app it built with LaunchServices and nothing
ever unregisters it, so this Mac accumulates dozens of `Perch.app` records
across lanes, bench and scratchpads (measured 2026-08-23: 40 records, 6 of them
live bundles declaring the `addToShelf` Service, under two bundle ids).
Duplicate Service rows and a Quick Action whose provider is some lane's build
cache are both artifacts of that, and both were misread as perch bugs once.
`pluginkit -r` is **not** a substitute — it only knows appex providers.

Clean the instrument first, and take the reading **before the next lane
builds**:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -kill -r -domain local -domain system -domain user
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f /Applications/Perch.app
killall Finder
```

(`lsregister` is not on `PATH`; the full path above is the whole reason this
block exists.) One Services row after that means a duplicate was lane
pollution; two would mean two doors really render.

**That clean reading has never actually been taken**, which matters only if
anyone reconsiders the Finder extension deleted 2026-08-23. The evidence that
closed it was gathered on a Mac carrying 40 registered copies, so it cannot
distinguish "the appex is the dead row" from "the second row was another lane's
build" — both hypotheses predict what was seen. The extension is gone on a
**product call** (it bought only not-waking-an-app that owns the notch, and the
classic Service demonstrably works), not on a discriminating measurement. Run
the block above before treating the question as settled either way.

## Watched folders: prime the folder, or the first run lies

Testing *quit → drop a file in → relaunch → does it catch up* against a folder
that has never fired an event reproduces "no catch-up" **for a reason that is
not a bug**. A folder's FSEvents position (`WatchedFolder.lastEventID`) is only
written once the stream actually delivers something; absent, the next launch
falls back to `kFSEventStreamEventIdSinceNow`
(`Perch/Importing/FolderWatcher.swift`), which is no replay at all. Measured
2026-08-24 on this Mac: `~/Desktop` had a position (it takes every screenshot)
and `~/Downloads` — the folder that recipe always names — had **none**. A first
pass fails, a second passes, and the run reads as flaky.

1. Read the positions first, so there is a before to compare against (the ids
   are UUID prefixes, not folder names):

   ```sh
   python3 -c "import json;print([(f['id'][:8],f.get('lastEventID')) for f in json.load(open('$HOME/Library/Containers/com.hausfold.perch/Data/Library/Application Support/Perch/watched-folders.json'))])"
   ```

2. With perch running, `touch ~/Downloads/prime-$(date +%s).txt`. It fires the
   event and shelves a tile; bin the tile.
3. Wait past the 5 s position-report interval and run the same line again — the
   row that had no number now has one. That folder can replay.
4. *Now* ⌘Q, drop the test file, relaunch.

Two more things about that loop. **A re-dropped file is deduped by identity,
not by name**: the token is `SHA256(inode:birth:size:mtime)`
(`FolderWatcher.swift:42-57`) and encodes no path or name — except on a mount
reporting neither inode nor birth date, where it falls back to the hashed name.
So what is silently ignored is a file **moved** back in: `mv`, or a Finder drag
within one volume, keeps the inode and every other component, and that is
exactly the gesture a feel-tester reaches for. A **copy** gets a new inode and
imports fine (measured on this APFS volume: original `79906233`, `cp`
`79906234`, `cp -c` clone `79906235`), and so does a fresh `touch`. Renaming is
not the lever either — a rename changes nothing in the token, which
`testARenameStillDoesNotReimport` (`PerchTests/FolderWatchingTests.swift:507`)
pins deliberately. **Create a new file each pass**; don't move an old one back
in, and don't expect a rename to make it new.
And **don't count on ⌘Q to persist the position**: the
flush on stop is a `queue.async` that hops to the main actor and then to a
background write, so it races process exit. Losing it costs a slightly wider
replay and nothing else.

## Big files land instantly on one volume — that's APFS, not a missing progress bar

`TransferPipeline.stageFile` uses `FileManager.copyItem`, which **clones**
rather than copies when source and destination are on the same APFS volume —
and `~/Downloads` and the app container are. Measured: a 2 GB copy finishes in
**0.001 s** and consumes **zero** extra disk. So a 3 GB drop appearing at once
is correct behaviour, not a bug.

To feel-test progress at all, drag from an **external, network or disk-image
volume**; on the internal volume, assert instead that it lands instantly. `cp`
is **not** a valid stand-in when writing that test — the same 2 GB file takes
`cp` 1.34 s and the full 2 GB.

## Overlapping downloads to one path can only ever make one tile

Running `curl -o ~/Downloads/slow.bin <url>` twice *sequentially* gives two
tiles. Starting the second before the first finishes gives **one**, when the
last writer stops — and that is the only answer available: both curls write the
same path, so there is one file, and it doesn't hold still until the last
writer lets go. N overlapping writers to one path cannot produce N files.

The case that would be a bug is two *different* paths downloading at once, and
it works (`testTwoFilesGrowingAtOnceBothLand` overlaps two continuous writers in
both directions and asserts each lands exactly once). Worth knowing while
writing that kind of test: growing a file in bursts slower than
`probeInterval × requiredStableProbes` leaves a quiet window mid-download and
the probe promotes on each one — that is "replaced contents are a new arrival"
doing its job, not a double import.

## Taking the phone's link down needs Airplane Mode

Turning Wi-Fi off in **Control Center** disconnects from the network and
deliberately leaves AWDL up, so a paired phone still delivers over the
peer-to-peer link. Use Airplane Mode, or Settings ▸ Wi-Fi ▸ Off. Stated for
users, with the mechanism, in [`reference.md`](./reference.md) ▸ Permissions.
