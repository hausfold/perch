# ADR 0005: A phone-side shelf and a hand-rolled local wire, not a cloud

Status: accepted

## Context

Perch's product sentence gains a second clause: *put it on Perch from anywhere;
it'll be waiting on your Mac.* An iPhone/iPad companion (`PerchIOS` + a Share
extension) stages copies on the phone and hands them to the paired Mac's shelf.

The constraints are inherited, not invented:

- **No account, no relay.** The Mac's only network call today is the update
  poll (ADR 0003). (This also cited ADR 0004's offline licensing; there is no
  licensing at all since [ADR 0009](0009-perch-stays-free-and-mit.md), which
  only makes the constraint easier to keep.) A Hausfold sync server would spend
  that trust for a v1 no one asked to be cloudy.
- **Copies only, admission before bytes, atomic commits** — the shelf's
  invariants (ADR 0001) don't bend because the source is a phone.
- **The Share extension must work while the Mac is asleep, away, or unpaired.**
  "On Perch" has to be a promise the phone alone can keep.

## Decision

**The phone is a real shelf; the Mac is a destination.** The iOS app stages
into the same `StagingRepository` layout (shared source, App Group container)
and keeps an outbox of `waiting → delivered` states. A share always succeeds
locally first; delivery is opportunistic — immediate when the Mac is visible,
retried when the app next runs otherwise. Honest states, no fake "sent".

**Transport is Bonjour + TCP + ChaChaPoly frames, hand-framed in `PerchWire/`**
(compiled into all three apps — no framework, no SPM package):

- The Mac advertises `_perch._tcp` with a stable `macid` TXT record; phones
  match on that ID, never an address. This costs the Mac one new entitlement,
  `network.server` — the listener, and nothing else, is why it exists.
- Pairing: the Mac shows a QR (`perch-pair:` + one-shot 32-byte secret, also
  pasteable for camera-less pairing). Both sides prove possession with HMACs
  over the handshake transcript, run X25519, and derive a long-term per-device
  key; a six-digit code derived from the transcript is shown on both screens
  for a human to compare, and approved on the Mac. The secret dies with the pairing window; the device key IS the
  relationship — revoking = deleting a Keychain row. On the phone, identity and
  pairing live in the *same* keychain store deliberately: splitting them across
  keychain and App Group produced a reinstall that looked paired but presented
  a fresh deviceID (found in testing, the hard way).
- Sessions: fresh directional keys via HKDF(deviceKey, both nonces); frames are
  ChaChaPoly boxes over a strict nonce counter, so replay, reorder, and
  truncation all fail decryption rather than needing protocol police. File
  bytes travel as binary chunks behind a one-byte tag — never through JSON.
- Transfers mirror the drag-in pipeline: `offer` (names, sizes, SHA-256s) →
  admission on the main actor *before any bytes* →
  chunks spooled to a dot-dir on the shelf's volume → digest verified → atomic
  move into a UUID container → `stored`. The phone deletes its copy only on
  `stored`, and keeps a dated receipt.

**The shelf is shared, and the phone is the one who asks.** A phone that can
only deliver is a one-way pocket, and the first thing testing on a real iPhone
produced was "I dropped this on the Mac — where is it?" So the same session
carries the reverse direction: `shelfListRequest → shelfList`, `fetchItem →
offer + chunks + itemDone`, `removeItem → removeAck`. All three are
phone-initiated, and that is a decision, not a limitation:

- The Mac cannot usefully dial a phone. It is asleep, off the network, or
  locked most of the time; a Mac that pushed would need a wake path, which
  means a relay or a notification service — the exact dependency this ADR
  exists to avoid.
- So "in sync" is a poll: every few seconds while the app is in the foreground
  and the Mac is visible, plus pull-to-refresh. Cheap on a LAN, invisible when
  the Mac is away (no endpoint, no connection, no error), and nothing to keep
  alive in the background.
- A fetch is a **copy**, not a move — the shelf is shared, so taking a copy to
  the phone leaves the Mac's tile alone. Removal is explicit from either end,
  and a phone's removal is the shelf's ordinary `remove`.
- A fetch is narrated like an arrival: progressive while the bytes move, past
  tense only once they are all there. The Mac describes the item, streams it,
  and is then told how that ended (`itemServed` / `serveFailed`), because "your
  iPhone took this" is a claim it cannot make before the last chunk lands.
- Fetched bytes land in a `MacInbox` container, never the phone's shelf root:
  the shelf root *is* the outbox, so staging an arrival there would deliver it
  straight back to the Mac it came from. From the inbox they go to the system
  share sheet, because iOS has no shelf of its own to drop them on.
- Folders are refused with a stated reason. The wire carries one file per item,
  and inventing a tar format for a v1 is not the trade.

Why not TLS-PSK (`sec_protocol_options_add_pre_shared_key`)? It buys the same
confidentiality from a C API with worse testability, and still needs the
pairing layer built by hand. The hand-rolled frame layer is ~150 lines, fully
unit- and loopback-tested (`WireLoopbackTests` runs the real server and client
over localhost TCP).

Why not AirDrop, iCloud Drive, or a CloudKit queue? No public receiver API, a
folder Perch would have to police, and an Apple account dependency,
respectively. A relay for "arrives while both are away" remains open as a
later, opt-in layer — the wire's `queued → stored` states were shaped so a
relay slots in without a model rewrite.

## Consequences

- ADR 0003's "the update poll is the only network call" sentence narrows to
  *outbound internet*: the listener speaks only to explicitly paired devices on
  the local network, end-to-end encrypted, off by a Settings toggle.
- The Mac approval sheet is load-bearing — it is the MITM defense, and it is
  the *only* approval control. The phone shows the same six digits and returns
  immediately (`MobileAppModel.swift:20`): possession of the QR secret already
  authenticated both ends, so the digits exist for a human to compare, not to
  tap. Don't document a phone-side confirm that isn't there.
  `PERCH_AUTOPAIR=1` bypasses the Mac sheet in DEBUG builds only, for automated
  end-to-end runs.
- A phone can delete from the Mac's shelf. That is the point of a shared shelf,
  and the pairing ceremony is what gates it: a device key is the relationship,
  and revoking it in Settings ends the ability.
- One share is one item, however many representations the host offers. Safari
  hands over a page as both `public.url` and `public.plain-text`, and staging
  every attachment put the page on the Mac twice; loose text alongside a link is
  that link's title, so it is dropped (files and images never are).
- The iOS targets ship nothing yet — App Store distribution and icons are
  deliberately out of this ADR. (This once also deferred "the
  free-companion/paid-Mac story"; both halves are free since
  [ADR 0009](0009-perch-stays-free-and-mit.md), so there is no story left to
  defer.)
