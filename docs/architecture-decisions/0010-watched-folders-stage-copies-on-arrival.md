# ADR 0010: A watched folder copies new arrivals and never touches them

Status: accepted

## Context

The shelf's doors so far all wait for a human gesture: a drag, a menu, a
Shortcut, a command line. The two folders people actually live out of —
`~/Downloads`, and wherever macOS drops screenshots — fill themselves, and the
gesture users want is "whatever lands there lands on the shelf".

Perch is sandboxed, which fixes most of the shape before any decision is made:

- It cannot read `com.apple.screencapture location` (another domain's
  preferences), and could not open the folder it names anyway. So the
  screenshot folder is not special: the user picks *every* watched folder in an
  `NSOpenPanel`, the same way "Save to…" picks a destination.
- A panel grant dies with the process. Watching across relaunches means
  persisting the grant as an **app-scoped security bookmark**, which costs one
  new entitlement: `com.apple.security.files.bookmarks.app-scope`.
- The bookmark blob encodes the folder's path, opaquely, because that is what a
  bookmark is. That is watch *configuration* — which folder to observe — not
  item provenance: the manifest still never learns where any shelf item came
  from, and nothing logs a watched path.

Two questions were genuinely open.

**Copy or move.** "Route downloads onto the shelf" reads like a move. But
invariant 1 says sources are never modified, and the shelf's own retention
setting (`AppSettings.retentionDays`) deletes staged copies outright — a moved
download that later expired would be the user's file, gone, from a timer they
enabled for shelf hygiene. PRD "Deferred without refactor" already lists
explicit transactional move of originals.

**Half-written files.** A watcher sees files before they are whole: Safari's
`.download` bundles, Chrome's `.crdownload`, Firefox's `.part`, a `curl -o`
growing in place, a screenshot that exists only after its floating thumbnail is
dismissed. Importing one of those stages a truncated copy behind a
completed-looking tile, which invariant "a visible ShelfItem points at a
completed staged representation" exists to forbid.

(The free-tier capacity cap would have made this feature self-defeating — a
watched Downloads folder keeps a two-tile shelf permanently full. ADR 0009
removed the cap before this was designed, so admission always says yes and the
watcher needs no rationing story.)

## Decision

**Copy, never move.** A watched arrival goes through the same
`ShelfStore.importFileURLs` → `TransferPipeline.stageFile` path as a drop: a
private staged copy, off main, behind a pending tile. The original never
leaves the folder, so retention expiry, Clear, and drag-out all keep their
existing meaning — they act on perch's copy only. Move-the-original stays
deferred behind the future transactional export service, per the PRD.

**One panel per folder; persist the grant as an app-scoped bookmark.** Settings
gains a Watched Folders list: add opens an `NSOpenPanel` restricted to
directories, remove forgets the bookmark. Config lives in
`Application Support/Perch/watched-folders.json` inside the container. A stale
bookmark is refreshed and re-persisted; an unresolvable one shows the row as
unavailable rather than silently vanishing.

**Watch with a kqueue directory source, not FSEvents.** A
`DispatchSourceFileSystemObject` on an `O_EVTONLY` descriptor fires whenever
the directory's entries change (create, rename, delete), and each firing
triggers a rescan on a background queue. FSEvents' per-file event stream buys
nothing here: a rescan is needed anyway for launch catch-up and ledger
pruning, and content writes to a growing file — which directory kqueues do not
report — are the stability probe's job, not the event stream's.

**A file earns its import three ways, in order:**

1. *Name rules.* Hidden files and the browsers' in-progress suffixes
   (`.download`, `.crdownload`, `.part`, `.partial`, `.tmp`) are ignored — the
   browser announces completion by renaming, and the rename is a directory
   event.
2. *Regular files only.* A directory appearing in a watched folder (an
   unzipped archive, a package) does not auto-land; folders still reach the
   shelf by every deliberate door.
3. *Stability.* The candidate's size and modification date must hold still for
   two consecutive probes 500 ms apart. A file still growing keeps being
   probed until it settles — a probe is one `stat`, so a slow multi-gigabyte
   download costs a poll every half-second, not a truncated import.

**A per-folder ledger of hashed identities decides what "new" means.** Each
imported file is remembered as a SHA-256 token of its inode and creation date
— no name, no path. Adding a folder seeds the ledger with everything already
present, so watching Downloads never floods the shelf with its history. At
launch the watcher rescans: unledgered stable files import (arrivals while
perch wasn't running), and tokens whose files are gone are pruned. A file is
marked when it is handed to import — at most once, so a failed staging shows
its error and stays failed instead of retrying forever — and identity by
inode+birth means renaming or editing a file in place never re-imports it.

## Consequences

- One new entitlement, `com.apple.security.files.bookmarks.app-scope`, and a
  truthful update to the reference's permissions story: every path perch
  opens is still one the user handed it — the bookmark just makes the handing
  survive a relaunch.
- The shelf tile is a copy. Dragging it out, clearing it, or letting retention
  expire it never touches the file in Downloads; conversely deleting the
  download does not empty the tile.
- The watcher holds each folder's security scope for its lifetime; removing a
  folder mid-import can fail that one staging, visibly, and nothing else.
- Directories that appear in watched folders are deliberately not imported —
  a v1 boundary to revisit only with evidence, since "unzip explodes twelve
  folders onto the shelf" is the default outcome otherwise.
- A file that never stops changing (a live log) is probed indefinitely and
  imported never — cheap, and the honest reading of "not finished".
- The ledger grows with the folder's population (32 bytes a file, hashed);
  pruning at launch keeps it bounded by what is actually there.
