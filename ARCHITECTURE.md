# Perch architecture

## Invariants

1. Source items are never modified.
2. The main actor never performs a potentially blocking copy or cloud download.
3. A shelf item becomes visible only after its staged representation exists.
4. A manifest never contains an absolute source path.
5. Every exported dragging session advertises copy only.
6. Display topology is replaceable without touching storage or import logic.
7. No sender on the App Group mailbox — the `perch` command line tool, or
   anything else that speaks it — persists a source URL, and none copies a byte
   before the containing app has persisted an admission response.

## Boundaries

```text
NSDraggingDestination                 paired iPhone / iPad
        │                                     │  Bonjour + encrypted wire
        ▼                                     ▼
ShelfDropHandler                      MobileReceiver ── pairing, Keychain,
        │  distinguishes promises /           │         spool + digest verify
        │  file URLs / images / links /       │         (PerchWire/)
        │  text                               │
        ▼                                     ▼
ShelfStore ─────── main-actor state, pending/completed/error transitions
        │           admission (a slot reserved before any bytes are copied)
        │           is granted here — mobile offers and mailbox senders alike
        │
        ├── TransferPipeline ── bounded background work, iCloud + coordination
        │
        └── StagingRepository ─ UUID containers, atomic manifest, recovery
                                (shared source with the iOS shelf — PerchWire/)

NSScreen[] ──► ShelfWindowSystem ──► ShelfPanelController per display
                                           │
                                           ▼
                                     ShelfPanelView
                                           │
                                           ▼
                                    NSDraggingSource
                                      copy-only group
```

Shortcuts / Spotlight (App Intents) are a third door onto the shelf, in both
directions:

- **In** — `AddToShelfIntent` (`Perch/Importing/AddToShelfIntent.swift`)
  resolves each `IntentFile` to a URL or raw data and hands it to the same
  `ShelfStore.importFileURLs` / `importData` path `ShelfDropHandler` uses — no
  separate staging logic.
- **Out** — `ExportFromShelfIntent` (same file's neighbor) returns staged
  items as `[IntentFile]` through the exact `liftForExport` + `handOff`
  transaction a drag-out to a terminal or editor already goes through: the
  shelf detaches the bytes rather than deleting them, because a Shortcut
  holding a file URL is no different from an app that read a dropped file's
  path instead of asking for the promise.
- `ShelfItemEntity` (`Perch/Importing/ShelfItemEntity.swift`) is the
  `AppEntity` both intents and Spotlight resolve shelf items through — a
  thin, live view onto `ShelfStore.items`, not a stored copy.

**Finder's right-click menu** is the fourth door, and it is a *classic
Service* — `Perch/Config/Info.plist` declares it under `NSServices`, the one
key with no `INFOPLIST_KEY_` build setting, which is why that partial plist
exists at all.

Its title comes from `PERCH_SERVICE_TITLE`, and Debug builds say "Add to Perch
Shelf (Debug)" while Release says "Add to Perch Shelf". macOS draws one
Services row per registered bundle id and never forgets a build, so a Mac that
has run `bench try` (Debug, `com.hausfold.perch.dev`) shows two rows for one
command; without the suffix both read "(Perch.app)" and the dev app's row is
indistinguishable from the shipped one. The suffix tracks the configuration
rather than the id, so a lane's ordinary Debug build wears it too — under the
release id, where it can take over the one row. Only the shipped, notarized
Release app claims the plain title. `docs/feel-testing.md` has the reading.

Perch used to ship a second Finder door beside it: a non-UI Action Extension,
`PerchFinderAction`, on the understanding that an extension is always nested
inside the menu's "Quick Actions" submenu while an `NSServices` entry reaches
the menu's top level. On macOS 26 **neither half of that is true**, and the
extension did not work. Measured 2026-08-23: both doors drew under "Services" — so the menu
read "Add to Perch Shelf (Perch.app)" twice — the extension never rendered
under "Quick Actions" despite being listed and enabled there, and clicking its
row shelved nothing, its App Group mailbox never written. The extension was
removed on that product call rather than on a measurement that could
discriminate: the Mac it was taken on carried 40 registered copies of the app,
which cannot tell the two doors apart. `docs/feel-testing.md` has the caveat
and the clean-machine test to run before reinstating anything.

The handler that remains is trivial by design. A Service is delivered to the
*running* app, not to an extension, so `ShelfServicesProvider`
(`Perch/Importing/ShelfServicesProvider.swift`) hands the pasteboard straight
to `ShelfDropHandler.accept(_:)` — the same call a drop onto the shelf makes.
No mailbox, no second staging path, and promises, file URLs, images, links and
plain text all behave exactly as they do on a drag, because it is the same
code. `NSUpdateDynamicServices()` at launch is what makes a newly installed
build's menu item appear without a logout.

A **command line tool** is the fifth door, and the only sender left on the Mac
App Group mailbox that `PerchFinderBridge/` defines. `perch add <path>...`
(`PerchCLI/`, shipped inside the bundle as `Contents/MacOS/perch-cli`) runs a
four-step transaction against it; the sender half is
`PerchFinderBridge/HandoffClient.swift`, and the app's half is
`FinderActionReceiver`. Both keep their names — `FinderActionRequests` is a
directory an *installed* CLI writes to, so renaming it would strand requests
from a copy of the tool the app was not shipped with.

1. The sender writes UUIDs, safe display names, and in-memory attachment
   indexes — never source URLs.
2. The running app's `FinderActionReceiver` asks `ShelfStore` to reserve slots
   and atomically writes the accepted IDs. This response is also the relaunch
   recovery receipt for pending reservations.
3. Only then does the sender load accepted providers and coordinate/copy their
   bytes off-main into its request directory. A completion file exposes only
   paths relative to that directory.
4. The app adopts each completed representation through `TransferPipeline`,
   commits the visible `ShelfItem`, and removes the request. Ten-minute stale
   transactions release reservations and are discarded.

`perch list` and `perch rm` are the same transaction with steps 3 and 4 cut
out: the request names a verb, the app answers in one turn with the entries —
the whole shelf, or exactly the items it removed — and the sender acknowledges,
which is what lets the app drop the directory rather than racing the reader of
its own answer. They are second clients of semantics the paired phone already
has over the wire (`shelfListRequest`/`removeItem`), not new shelf behaviour,
and `rm` performs the identical `ShelfStore.remove` the panel's own menu does.
A request naming no verb is an `add`, because that is what every request
written before them is; a request naming a verb this build doesn't know is *answered*,
with no entries, rather than thrown on — that is how a newer sender learns to
say so, and it keeps an unknown verb from stalling the transactions queued
behind it. `list` deliberately does not read the staging manifest
directly, though an unsandboxed tool could: an answer assembled anywhere but
the running app can disagree with the tiles on the notch.

The shared group is `88M28542LQ.com.hausfold.perch`, the Team-ID-prefixed form
for a directly distributed macOS app. It is deliberately separate from the iOS
companion's App Store group.

The tool has to exist because the app is sandboxed: a URL scheme or Apple Event
could name a path, but Perch may not open one it was merely told about. The
tool is unsandboxed and runs as you, so it does the reading — and reaches the
group container by its documented path, since
`containerURL(forSecurityApplicationGroupIdentifier:)` answers nil without the
entitlement. It treats the mailbox, not a process list, as the liveness test: a
dev build owns the notch under its own bundle identifier and would fail a
bundle-id check while answering perfectly well. See
[docs/cli.md](docs/cli.md).

A **watched folder** is the sixth door, and the only one that opens without a
gesture: Settings keeps a list of user-picked folders (each one panel grant,
persisted as an app-scoped security bookmark), and new files that appear in
them are copied onto the shelf by `FolderWatchCenter` /
`Perch/Importing/FolderWatcher.swift`. An **FSEvents** stream triggers a
rescan; a candidate must pass name rules (no hidden files, no in-progress
browser suffixes), be a regular file, and hold its size still across two
probes before it is handed to the same `ShelfStore.importFileURLs` path a drop
uses. A per-folder ledger of hashed inode + birth + size + mtime identities —
never a name or a path — decides what is new, is seeded with the folder's
existing contents on add, and catches up at launch on arrivals perch missed. Copy only, always: the
original never leaves the folder, so retention expiry deletes perch's copy and
nothing of the user's.

FSEvents rather than a kqueue directory source for two reasons. It reports
`ItemModified`, so a file **rewritten in place** — same inode, same directory
entry, which is what `curl -o` over an existing path does — is seen at all; a
directory kqueue fires only on entries appearing, disappearing and being
renamed, so those downloads never landed (#6). And its event IDs are durable:
the stream position each folder was last scanned at is persisted alongside its
ledger (`WatchedFolder.lastEventID` — an opaque volume counter, not a path or a
time) and the next launch resumes there, replaying what happened while perch
was down (#8) instead of starting blind at `kFSEventStreamEventIdSinceNow`. The
launch rescan is still the primary catch-up; replay is the stream covering the
same gap itself. Every event batch answers with one full `scan()`, which is why
a coalesced, dropped or replayed batch costs a rescan and never a missed file.

The two Finder doors are complementary, not redundant. The extension runs
without waking Perch, but only inside the submenu and only while the app is up
to answer its mailbox. The Service is at the top level and macOS launches Perch
to deliver it, which costs that launch and puts the copy in the app's own
process rather than the extension's. Both are on with no user action; neither
supersedes the other.

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
and waits off-main with a bounded 120-second timeout. `NSFileCoordinator`
protects the subsequent read. A two-operation queue prevents a batch of huge
files from starving either the UI or storage.

**The cloud wait runs before that queue, not on it.** It is the one import
phase that can legitimately last two minutes, and the queue is two operations
wide — waiting inside an operation let two evicted iCloud files hold both slots
while every ordinary drop queued behind them. `CloudDownloadWaiter` polls with
`Task.sleep` on the cooperative pool instead; only the copy is queued.

Copy progress stays indeterminate because `FileManager.copyItem` does not
expose reliable byte progress for directories, packages, cloud providers, and
coordinated reads under one API. **The cloud wait shows elapsed seconds rather
than a percentage, and no percentage is available to show:**
`URLResourceKey.ubiquitousItemPercentDownloadedKey` is unavailable in Swift,
and `NSMetadataQuery`'s replacement reports only on the querying app's own
ubiquity container — the dragged file is in the user's, and perch ships with no
iCloud entitlement. A wait that can last two minutes must at least be bounded on
screen, so the tile counts up against the timeout and ends in a named error:
`.cloudDownloadNeverStarted` (iCloud never picked the request up),
`.cloudDownloadTimedOut`, or `.cloudDownloadFailed`. iCloud's own error is
never rethrown — it embeds the original path. The pending model separates
phases, so a later provider-specific progress source does not require a model
rewrite.

### Following the haus theme

The shelf paints from a `RicePalette` — one of four compiled-in nebelung
variants, or any `role → "#hex"` file in `~/.config/perch/themes/`, which shadows
a built-in of the same name. `~/.config/perch/config.json` names the palette per
polarity and the macOS appearance picks the half; `ShelfTheme` re-resolves on
launch, on the light/dark switch, and as the shelf opens, and publishes through
the environment so every panel and tile repaints together.

Colour is not the only thing that file carries. `fontFamily` names the
proportional family the shelf, Settings and the pairing window set their text
in — `AppFont` is the only place it becomes a `Font`, and absent, it is
SwiftUI's own `.system(…)`. It rides the same resolve as the palette but not
the same channel: the family is a `@MainActor` static on `AppFont` rather
than an environment value, because the alternative is an `@Environment`
property on every view struct that sets a font. `ShelfTheme` publishes it too,
which is what re-renders the panel when a rebuild changes it under a running
perch. Symbols keep `.system` (an SF Symbol handed a text face is scaled by
that face's metrics) and so does anything `.monospaced()`.

There is no picker for it, for the reason there is none for the accent: the
shelf is a five-second surface, and "follow haus" is the feature.

Both paths sit outside the app container, which costs one read-only
home-relative sandbox exception and forces two details: the real home comes from
`getpwuid` (inside the sandbox `NSHomeDirectory()` is the container), and
haus must drop **real files**, since the sandbox resolves a symlink into
`/nix/store` before it checks the path and denies it.

### Where a setting lives

Every switch in Perch Settings is read from a file and written back to one.
There is no copy in `UserDefaults` that could disagree, and nothing to "sync":
a toggle clicked in the window and a line typed into the file are the same act,
and an edit made while perch runs lands without a relaunch.

Two files, and the order between them is the design:

```text
compiled-in defaults
  ‹ …/Application Support/Perch/settings.json   ← Settings writes this
    ‹ ~/.config/perch/config.json                ← haus declares this
```

`ConfigFileStore` (`Perch/App/AppConfigFile.swift`) loads both, follows both,
and writes only the first — atomically, merging into whatever keys were already
there so a hand-written note or a newer build's key survives a toggle.
`AppSettings` is a thin `ObservableObject` face over it.

Settings writes the **container** file because that is the one perch can write
without asking anybody: the `~/.config/perch/` exception is read-only, and it
stays read-only. Widening it so both layers could be one file would trade a
narrow exception for a home-relative *write* grant — the kind App Review reads
as a sandbox that isn't one.

So haus's half is a **declaration**: any key it names wins, and Settings
renders that row read-only with a padlock and a line saying which file decided.
Refusal happens in the store, before anything in memory moves — a switch that
accepts a change and springs back on the next read is worse than one that never
moves. The store keeps the container layer separate from the composed answer and
writes only the former, so an unrelated toggle never copies the declaration into
the user's own file: remove haus's key and the setting the user chose comes
back, rather than staying frozen at whatever haus last said. The keys are perch's own (`showOnAllDisplays`, `retentionDays`,
`mobileEnabled`, `automaticUpdateChecks`, `launchAtLogin`); the theme keys
sharing that file declare nothing, or every haus desktop would open a greyed-out
Settings window.

`launchAtLogin` is the odd one: macOS holds the real answer
(`SMAppService.mainApp.status`), so perch never *writes* that key — a file perch
wrote saying "yes" would be a standing instruction to put itself back into Login
Items after someone removed it there. Declared, it is applied on every launch
and every edit, which is what declaring a machine's configuration means.

`UserDefaults` keeps what a settings file has no business holding: the pane
Settings was last on, the window frame, the update checker's cache of what
GitHub last said, and the one-shot marker for the retention opt-in migration.
Ephemera, not settings.

### Knowing the drop will not land

macOS's *"Drag windows to top of screen to enter Mission Control"* is on by
default and arms the Dock's top-edge monitor for the whole of **any** drag —
files included — in exactly the band the notch catch zone occupies. On a stock
Mac the first drag aimed at the shelf is taken into Mission Control before perch
sees a `draggingEntered:`, so the app looks broken by the only gesture it has.

`MissionControlCheck` reads the Dock's own answer and says so, on the two
passive surfaces perch already owns: a strip along the bottom of the expanded
shelf and a row in the menu bar menu. It never writes that key — the button
opens System Settings ▸ Desktop & Dock and leaves the decision where it belongs.

Two seams matter here. **An absent value means armed**: a Mac that has never had
the key written is precisely the stock Mac this exists for, and a denied read is
indistinguishable from an absent one, so both err toward a dismissible hint
rather than silently failing every drag. And the shelf's notice slot is
**shared** — this strip outranks the update strip below, because a pending
release is worth reading and a shelf that cannot catch anything is not.

Reading `com.apple.dock` needs
`com.apple.security.temporary-exception.shared-preference.read-only`, one domain,
read-only. Measured 2026-08-26 on macOS 26.6: without it every route to the value
answers nil; with it the preference reads answer and the *file* read stays
denied — the exception widens the sandbox by one domain's preferences and
nothing on disk.

### Knowing there is a new release

`UpdateCheck` asks GitHub for the latest tag hourly (and on wake), compares it to
this build's CalVer, and — if it is newer and not already dismissed — pins a
strip along the bottom of the expanded shelf plus a row in the menu bar menu.
Dismissal is per version, so waving one release away still surfaces the next.

What the button does comes from `InstallKind`. Three cohorts get a command
copied (`haus update`, `brew upgrade --cask perch`, `nix flake update perch`),
because the tool that installed them owns the bytes and would undo a swap done
behind its back. The fourth — a ZIP dragged into `/Applications` — installs in
one click: `SelfUpdate` downloads the release into the container, unzips it and
checks it is signed by us, then hands it to `PerchUpdater.app`, a nested
un-sandboxed helper (`Contents/Helpers/`, which is where codesign seals a
nested app as code rather than as a resource) that does the swap and the
relaunch. It installs only from perch's own staging directory in the
container. The split is the
sandbox's: `/Applications` is outside the container and a spawned child inherits
the sandbox, but an app launched through LaunchServices does not. The updater
replaces only the bundle it is nested inside, and only a notarized build of ours
that is newer than the one installed — the notarization clause is *its* check to
make, since the container cannot settle notarization at all (errSecCSReqFailed
from inside, a pass from outside, on the same bytes). A failure at any step
leaves the installed app alone and relaunches it.

Which cohort perch is in is resolved from the bundle path
plus two out-of-band receipts — haus's `perch.installed-from` marker and
brew's Caskroom directory — with haus's theme drop as a third signal if the
receipts ever stop being readable from inside the container. The poll — and the
release ZIP that one click downloads — are the app's only *outbound internet*
traffic and the only reason it holds `com.apple.security.network.client`; a
Settings toggle stops the poll, and DEBUG builds never run it. (The
mobile listener below is the app's other network surface — local-network only,
paired devices only, its own toggle, and the sole reason for
`network.server`.)

### Admission, and why it survived the free tier

Perch is free software (MIT) with no paid tier, no license file, and no ceiling
on what the shelf holds. It was briefly the other thing — an Ed25519-signed
offline licence and a two-tile cap, decided 2026-08-03 and reversed 2026-08-15.
Nothing shipped: the production key was never minted, so `canSell` was false in
every build and the cap never switched on. The `README.md` licence section has
the tag range. The runbook for the day that switch would be flipped — minting
the keypair, the signing contract a Worker would have to honour — was
`docs/going-paid.md`, deleted with the decision;
`git show v2026.08.14-1:docs/going-paid.md` still has it.

The **admission step** it left behind is not a leftover: a sender that is not
the app — the `perch` tool, a paired iPhone — asks for a slot
by name and waits for `ShelfStore` to persist a receipt *before* it copies a
byte. That ordering is what makes the app the single authority on what is on the
shelf: it can't adopt bytes it never reserved a pending tile for, and a sender
that finds perch not running fails cleanly instead of filling a container nobody
is watching. Admission now always says yes; the wire keeps a refusal channel
(`RefusedItem`) that the Mac no longer populates.

### One shelf, two windows onto it

The iOS companion (`PerchIOS/` + `PerchShare/`, sharing `PerchWire/` and the
staging layout via `PerchMobileCore/`) is a shelf of its own: a share stages a
local copy first, then delivery to the Mac is opportunistic and honestly
stated (`waiting` until the Mac says `stored`). On the Mac, `MobileReceiver`
listens on Bonjour `_perch._tcp` for devices paired via a one-shot QR secret +
X25519 + a human-confirmed six-digit code; every frame after the hello is
ChaChaPoly-sealed under per-session keys. Arriving bytes spool into a hidden
dot-directory on the shelf's volume, are digest-verified, and enter the shelf
through the same admission-first, atomic-commit path as a drag. Pairing lives
in the Keychain; revoking a device deletes its row.

Every wire path — listener, browser and connection alike — sets
`includePeerToPeer = true`, so a phone that cannot reach the Mac over Wi-Fi
finds it over AWDL, the same peer-to-peer link AirDrop uses. Delivery needs the
Wi-Fi radio up at both ends and nothing else: no router, no DHCP lease, no
shared SSID. What that costs a test is stated where users read it, [the phone half of the
install page](https://hausfold.co/docs/perch/install#5-the-phone-half) —
Control Center's Wi-Fi toggle deliberately leaves AWDL up, so "Wi-Fi off" is not
how you take the link down.

**No account, no relay, and TLS-PSK was considered and declined.** A hausfold
sync server would spend, for a v1 nobody asked to be cloudy, exactly the trust
that "your files never leave your network" buys. `sec_protocol_options_add_pre_shared_key`
buys the same confidentiality from a C API with worse testability and still
needs the pairing layer built by hand; the hand-rolled frame layer is ~150 lines
and fully loopback-tested. A relay for "arrives while both are away" stays open
as a later, opt-in layer — the wire's `queued → stored` states were shaped so
one slots in without a model rewrite. AirDrop, iCloud Drive and a CloudKit
queue were each considered and rejected: no public receiver API, a folder perch
would have to police, and an Apple-account dependency, respectively.

The same session runs the other way. The Mac never dials a phone — a phone is
asleep, off-network, or behind a lock screen most of the time — so "shared and
in sync" means the phone *asks*: `shelfListRequest` → `shelfList`, `fetchItem`
→ an offer followed by the same chunk stream a delivery uses, `removeItem` →
`removeAck`. `MobileReceiver` answers all three from `ShelfStore` (digesting
off the main actor; folders are refused with a stated reason, because the wire
carries one file per item). The phone polls every few seconds while it is in
the foreground and the Mac is visible, on top of pull-to-refresh — no push, no
background wake, nothing to keep alive. A fetch is a **copy**: the item stays
on the shelf until someone removes it from either end, and removals from the
phone go through the shelf's ordinary `remove`. Pulled files land in a
`MacInbox` container, deliberately *not* the phone's shelf root — anything in
there is an outbox entry and would be delivered straight back — and are handed
to the system share sheet, which is what "save this" means on iOS.

### Watching a folder without shelving its half-written files

A watcher sees files before they are whole — Chrome's `.crdownload`, Safari's
`.download`, a `curl -o` growing in place — and invariant 3 forbids a tile
over a truncated copy. So a watched arrival is imported only after it passes
name rules, is a regular file, and holds size and modification date still
across consecutive probes; a file that never settles is probed cheaply forever
and imported never. What counts as *new* is a per-folder ledger of
SHA-256(inode + birth date + size + mtime) tokens, so renaming a shelved file
never re-imports it while **replacing its contents does** — a rewritten file is
a new arrival wearing the old one's name, which is what `curl -o` over an
existing download is. Nothing about a source's name or path is persisted or
logged. The tokens carry a format tag, and a ledger written by an older perch is
adopted wholesale on the next launch rather than compared and found empty, which
would re-import the entire folder; that one launch does no catch-up.

Marking is on **success**, not on hand-off: a failed staging takes its token
back out, so the next FSEvents batch tries again rather than the file being
invisible forever.

The same identity rule turns a drag-out into a watched folder against itself:
an export is a copy, so it lands as a brand-new inode that no ledger has seen,
and `~/Downloads` and `~/Desktop` are both what people watch and what people
drag onto. `ExportLedger` is the book that keeps the two apart — the promise
reserves its destination *before* `copyItem` writes a byte, because that write
is the directory event that starts the scan, and the watcher adopts what perch
wrote instead of shelving it. A receiver that takes the plain `public.file-url`
copies the file itself and never tells us where, so that one is out of reach;
it is the promise path — Finder's — that this covers.

### Name collisions

Every logical import owns a UUID directory. The user-visible filename remains
unchanged, while two `photo.jpg` files never share a filesystem namespace.

**The container is the identity; the filename is not.** A tile's
`relativePath` is a durable hint, not the link to its bytes — because
**Show in Finder** hands the user a real file in a real folder, and renaming
it there is a reasonable thing to do. `StagingRepository.resolvedURL(for:)` is
the one way to ask where an item's bytes are: the recorded path if it still
exists, otherwise the container's single visible child, which after a rename
is unambiguously the same item. The shelf follows the rename — same id, same
pin, same slot, new `displayName` — at the moment the panel next opens
(`ShelfPanelController.expand`) and again on the next launch.

Three answers are deliberately refused rather than guessed, and all return
nil — a real answer every caller honours, because handing a destination the
wrong file is worse than refusing the drag:

- a container holding more than one visible child;
- a container another live item still claims. A promised **batch** shares one
  container between several items, so the single child left after a sibling's
  file is deleted is as likely to be the sibling. Callers pass their
  neighbours (`alongside:`) — the shelf's items plus anything lifted mid-drag
  — so this case is answerable at all;
- a *detached* container, whose bytes belong to whatever took an earlier drop
  and must never be re-resolved back onto the shelf.

`StagingRepository.remove` resolves the same way and for the same reason:
deleting is the one place where guessing wrong destroys something.

### Termination and recovery

Only completed imports enter the atomic manifest. Ordinary copies use a hidden
partial name and atomically move to their final staged name only after the copy
finishes. Startup discards interrupted containers, filters missing manifest
entries, and scans two-level UUID containers for completed but uncommitted
files. Promise callbacks and ordinary copies converge on the same `ShelfItem`
commit path.

Startup prunes **only when retention is explicitly enabled**, and the default is
never. Deleting a staged copy is final — perch is sandboxed, so a delete has
nowhere recoverable to go, and its Trash sits inside its own container where
Finder will not show it — while for a dragged-in promise, a link, typed text or
an iPhone delivery the staged copy is the only copy. So a timer that deletes is
something the user switches on, not something they must notice and switch off,
and pinned items are exempt even then. The other destructive path, Clear, asks
first: in place on the shelf header, and as an alert from the menu bar. Nothing
in perch deletes a staged copy without either a confirmation or a setting the
user turned on themselves — `ShelfStore.confirmCopied` excepted, which deletes
only after the destination has reported that it holds its own copy.

Recovery is a fallback, never an overwrite. It invents a fresh UUID, a fresh
`addedAt` and an unpinned item for every file it adopts, so a manifest that
*exists but could not be read* must never be written back over — "unreadable"
and "absent" are separate outcomes in `load()`, and only the absent one lets
recovery persist. The manifest is written
`.completeFileProtectionUntilFirstUserAuthentication`: encrypted at rest, but
guaranteed readable for the whole login session. It was previously
`.completeFileProtectionUnlessOpen`, which is unreadable once closed until the
Mac is next unlocked — so a shelf reloaded after a lock read as empty, recovered
every file under a new identity, and wrote that over the real manifest, silently
losing what was pinned.

### Copy versus move

Imports copy; exports advertise `.copy`. Dragging an item (or the whole stack)
out removes it from the shelf the moment a destination accepts the drop —
letting go is the gesture, and a shelf still counting the item reads as stuck.
The item is *lifted*, not deleted: its staged bytes stay put, and a destination
that then refuses it or fails its copy puts the item back in its old slot.

Two rules keep that transaction from losing a tile. `liftForExport` never
removes an item whose bytes it cannot resolve — nothing can have copied them,
so nothing earned the removal, and the refusal surfaces as an error instead of
a silently shorter shelf. And the verdicts are **unordered by construction**:
`.accepted` is reported inline from `draggingSession(_:endedAt:)` — the last
moment the drag source is guaranteed alive, so it may not wait on a hop — while
`.copied` / `.failed` hop to the main actor from the promise queue. Either
hopped verdict can therefore land *first*, and both are held: `returnToShelf`
records a refusal that arrives before its lift so `liftForExport` can decline to
remove the tile, and `confirmCopied` records an early copy so `liftForExport`
can settle the bytes instead of leaving them to be re-adopted as a stranger at
the next launch. A verdict is scoped to the drag that produced it —
`beginExport` clears both sets, and every export path calls it, the Shortcuts
one included.

**Save to…** is the non-destructive way out, and deliberately not an export at
all: it copies the staged bytes to a location the user picks in an `NSSavePanel`
and touches no shelf state — nothing lifted, nothing deleted, no manifest write.
The same contract as Show in Finder, which is why it sits with it in the context
menu. The panel is also the permission: it is what grants a sandboxed app a
destination outside its container, so a fixed folder would mean a new
entitlement and a path no drag or picker handed us. The copy runs on
`TransferPipeline`'s bounded queue, never main.

A pinned item is the explicit exception: it never enters the lifted export
transaction, so every destination receives a copy while the tile and staged
bytes stay available for another drag. Pin state lives in the manifest and
older manifests decode missing pin state as unpinned.

Deleting those bytes is a separate step, and waits for the destination to
confirm it holds its own copy: exports are vended as **file promises**
(`NSFilePromiseProvider`), so the receiver asks Perch to write the file into the
location it chose, and the promise's completion handler is what records
destination completion before the staged source is deleted. This is the
`ExportTransaction` boundary — deleting on the raw drag-end instead raced the
receiver's in-flight copy (Finder error -8058) and could drop the item even when
its copy failed. The promise copy runs on a background queue, never main.

The same pasteboard item also carries the staged `public.file-url`, after the
promise types. Promise-blind receivers — terminals, most editors — otherwise see
a drag with nothing they can take and refuse it outright (no drop cursor at
all). They read the URL directly and report nothing, so a `.copy` where no
destination engaged the promise within a short grace period is a **hand-off**:
the item is already off the shelf, and its container is *detached* rather than
deleted — the receiver is holding a path into it. A detached container is never
re-adopted as an item and is swept once its grace (10 minutes, so a pasted path
stays live) has passed and a launch scans the root. Engaging the promise cancels the hand-off for that item, however long its
copy runs, so a slow copy is never raced.

True move-original semantics are still not inferred from modifier keys.

## Planned extensions that fit existing seams

- Quick Look preview: UI-only coordinator over staged URLs.
- Byte progress: transfer event stream updating `PendingTransfer`.
- Multiple named shelves: replace `ActiveShelf` with repository IDs.
- Expiration while running: scheduler calling the existing prune operation.
- Explicit move workflow: extend the promise `ExportTransaction`, never a change to importing.
- Additional share actions: commands over completed staged URLs.
- Push from the Mac (a phone that learns of a new tile without asking): needs a
  wake path — a relay or a notification — not a change to the wire.
- An opt-in encrypted relay for delivery while both devices are away: slots
  into the outbox's `waiting → delivered` states without a model rewrite.
