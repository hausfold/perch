# Perch architecture

## Invariants

1. Source items are never modified.
2. The main actor never performs a potentially blocking copy or cloud download.
3. A shelf item becomes visible only after its staged representation exists.
4. A manifest never contains an absolute source path.
5. Every exported dragging session advertises copy only.
6. Display topology is replaceable without touching storage or import logic.
7. Licensing is offline: it adds no network call, no entitlement, and no file
   outside the container.
8. The free-tier cap is decided before staging starts, so a refused item is
   never copied and no drag is interrupted.

## Boundaries

```text
NSDraggingDestination                 paired iPhone / iPad
        │                                     │  Bonjour + encrypted wire
        ▼                                     ▼
ShelfDropHandler                      MobileReceiver ── pairing, Keychain,
        │  distinguishes promises /           │         spool + digest verify
        │  file URLs / images / links /       │         (PerchWire/, ADR 0005)
        │  text (a .perchlicense is           │
        │  a key, not cargo — it goes to      │
        │  LicenseStore and is never staged)  │
        ▼                                     ▼
ShelfStore ─────── main-actor state, pending/completed/error transitions
        │           admission is checked here, before any bytes are copied
        │           (mobile offers included — a refused item is never sent)
        │
        ├── LicenseStore ────── offline Ed25519 verify, CalVer coverage, the cap
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

### Following the rice theme

The shelf paints from a `RicePalette` — one of four compiled-in nebelung
variants, or any `role → "#hex"` file in `~/.config/perch/themes/`, which shadows
a built-in of the same name. `~/.config/perch/config.json` names the palette per
polarity and the macOS appearance picks the half; `ShelfTheme` re-resolves on
launch, on the light/dark switch, and as the shelf opens, and publishes through
the environment so every panel and tile repaints together. Perch's own settings
stay in `UserDefaults` — the rice writes only the theme.

Both paths sit outside the app container, which costs one read-only
home-relative sandbox exception and forces two details: the real home comes from
`getpwuid` (inside the sandbox `NSHomeDirectory()` is the container), and the
rice must drop **real files**, since the sandbox resolves a symlink into
`/nix/store` before it checks the path and denies it. See ADR 0002.

### Knowing there is a new release

`UpdateCheck` asks GitHub for the latest tag hourly (and on wake), compares it to
this build's CalVer, and — if it is newer and not already dismissed — pins a
strip along the bottom of the expanded shelf plus a row in the menu bar menu.
Dismissal is per version, so waving one release away still surfaces the next.

It never installs anything. Perch is sandboxed, so it cannot replace its own
bundle in `/Applications` and a `brew` spawned from here would inherit the same
sandbox; instead the button copies this install's command (`haus update`,
`brew upgrade --cask perch`, `nix flake update perch`) or opens the release page.
Which of those it offers comes from `InstallKind`, resolved from the bundle path
plus two out-of-band receipts — the rice's `perch.installed-from` marker and
brew's Caskroom directory — with the rice's theme drop as a third signal if the
receipts ever stop being readable from inside the container. The poll is the
app's only *outbound internet* call and the only reason it holds
`com.apple.security.network.client`; a Settings toggle stops it, and DEBUG builds
never run it. See ADR 0003. (The mobile listener below is the app's other
network surface — local-network only, paired devices only, its own toggle, and
the sole reason for `network.server`. See ADR 0005.)

### Knowing whether this Mac paid

`LicenseStore` verifies a `.perchlicense` — a small signed JSON blob — with
CryptoKit against an Ed25519 public key baked into the app, and stores the file
verbatim in the container's defaults. There is no activation call, no sign-in,
and nothing to revoke: licensing adds no network traffic and no entitlement, so
the update poll above stays the app's only network call. The signature covers a
canonical fixed-order `key=value` payload rather than the JSON, because the
signer (a Worker) and the verifier (this app) share no code and JSON
canonicalization is where that kind of pair silently drifts apart.

Entitlement is a date comparison: a license covers builds stamped on or before
`purchased + 1 year`, so `bench release` needs no version bookkeeping and a
build a license covered keeps working forever. A build with no CalVer date — an
Xcode build, or a `bench try` branch build — stays covered rather than reading
as lapsed.

Unlicensed, the shelf holds two tiles. Admission is computed in `ShelfStore`
against `items + pendingTransfers` **before** staging begins, so an item that
doesn't fit is never copied and no drag is interrupted; a batch is trimmed
rather than refused wholesale. The ask appears only once a drop has actually hit
the ceiling, on the same bottom strip the release nudge uses, and outranks it
while both are live. Until the public key constant is filled in, `canSell` is
false and there is no cap at all — a paywall with no purchasable door is worse
than no paywall. See ADR 0004.

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
in the Keychain; revoking a device deletes its row. The wire protocol, the
pairing ceremony, and the no-relay stance are ADR 0005.

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
- Finder actions and share actions: commands over completed staged URLs.
- Push from the Mac (a phone that learns of a new tile without asking): needs a
  wake path — a relay or a notification — not a change to the wire.
- An opt-in encrypted relay for delivery while both devices are away: slots
  into the outbox's `waiting → delivered` states without a model rewrite.
