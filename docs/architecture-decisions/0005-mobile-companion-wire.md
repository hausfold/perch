# ADR 0005: A phone-side shelf and a hand-rolled local wire, not a cloud

Status: accepted

## Context

Perch's product sentence gains a second clause: *put it on Perch from anywhere;
it'll be waiting on your Mac.* An iPhone/iPad companion (`PerchIOS` + a Share
extension) stages copies on the phone and hands them to the paired Mac's shelf.

The constraints are inherited, not invented:

- **No account, no relay.** The Mac's only network call today is the update
  poll (ADR 0003), and licensing is offline by contract (ADR 0004). A Hausfold
  sync server would spend that trust for a v1 no one asked to be cloudy.
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
  key; a six-digit code derived from the transcript is confirmed by a human on
  both screens. The secret dies with the pairing window; the device key IS the
  relationship — revoking = deleting a Keychain row. On the phone, identity and
  pairing live in the *same* keychain store deliberately: splitting them across
  keychain and App Group produced a reinstall that looked paired but presented
  a fresh deviceID (found in testing, the hard way).
- Sessions: fresh directional keys via HKDF(deviceKey, both nonces); frames are
  ChaChaPoly boxes over a strict nonce counter, so replay, reorder, and
  truncation all fail decryption rather than needing protocol police. File
  bytes travel as binary chunks behind a one-byte tag — never through JSON.
- Transfers mirror the drag-in pipeline: `offer` (names, sizes, SHA-256s) →
  admission on the main actor *before any bytes* (free-tier cap included) →
  chunks spooled to a dot-dir on the shelf's volume → digest verified → atomic
  move into a UUID container → `stored`. The phone deletes its copy only on
  `stored`, and keeps a dated receipt.

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
- The Mac approval sheet and the phone's six-digit confirm are load-bearing
  (they are the MITM defense); `PERCH_AUTOPAIR=1` bypasses both in DEBUG
  builds only, for automated end-to-end runs.
- The iOS targets ship nothing yet — App Store distribution, icons, and the
  free-companion/paid-Mac story are deliberately out of this ADR.
