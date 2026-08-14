# ADR 0007: Finder Action admission precedes access to source bytes

Status: accepted

## Context

Perch's App Intents make files available to Shortcuts, but macOS does not place
an App Intent in Finder's right-click Quick Actions menu automatically. The
public Finder integration for that surface is a macOS Action Extension. It is
disabled until the user explicitly enables it in System Settings, and its
process cannot call the containing application directly.

The Finder entry point still inherits every shelf invariant: originals are
untouched, copies and file coordination stay off main, the free-tier decision
happens before staging, no original path is persisted or logged, and a visible
item always points at a completed private representation.

## Decision

**Ship a non-UI `com.apple.services` Action Extension named Add to Perch Shelf.**
It accepts Finder file selections, returns Finder's original providers
unchanged, and uses the supported Finder preview label/icon attributes. Perch
links Settings to the extensions pane, but the one-time enable remains a user
choice owned by macOS.

**Use a two-phase App Group mailbox, with the app as admission authority.** The
extension first atomically writes a request containing only transaction/item
UUIDs, safe display names, and attachment indexes that mean nothing outside the
live extension context. The running app polls this mailbox, reserves capacity
in `ShelfStore`, and atomically answers with the accepted UUIDs. Only after that
receipt exists may the extension ask the accepted item providers for URLs and
copy their data.

Completed copies land in UUID-scoped App Group directories. The extension then
publishes relative staged paths; `FinderActionReceiver` validates those paths,
and `TransferPipeline` moves or copies the complete representations into
Perch's ordinary staging root off main. `ShelfItem` is committed only after
that adoption succeeds. A persisted response restores its pending reservations
after an app relaunch, and transactions older than ten minutes are failed and
removed.

**Require the containing app to be running.** Perch is normally a login/menu-bar
app, and only it can evaluate current shelf capacity safely. The extension waits
up to five seconds for admission, then tells the user to open Perch and try
again. Launching or messaging the containing app through private mechanisms is
not worth the permission and lifecycle ambiguity.

The directly distributed Mac bundles share
`88M28542LQ.com.hausfold.perch`, a Team-ID-prefixed macOS App Group. The iOS
companion keeps its App Store group; the two stores carry unrelated data and do
not need a shared entitlement.

## Consequences

- Finder gains a native right-click/Quick Actions entry after one explicit
  enable; App Intents remain the Shortcuts and Spotlight integration.
- A refused free-tier item is never requested from Finder and never copied.
- App Group JSON cannot reveal an original source path, and completion paths are
  rejected unless they remain below their transaction directory.
- The release workflow must sign the nested extension before re-signing the app,
  preserving the same group entitlement in both.
- If Perch is not running, the action fails clearly instead of creating an
  unbounded inbox outside `ShelfStore` admission.
