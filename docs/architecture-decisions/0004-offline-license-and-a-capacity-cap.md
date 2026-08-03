# ADR 0004: An offline license file and a capacity cap, never a download gate

Status: accepted

## Context

Perch is going paid: a one-time purchase, one year of updates, a license that
keeps working forever on the builds it covered. The source stays public (ADR-
adjacent: the repo relicensed MIT → FSL-1.1-ALv2 in the same phase).

Perch ships through four doors — a Homebrew cask, the release ZIP, the rice's
Nix copy, and a bare `nix run` store path — and all four are fed by public
GitHub release artifacts, with a CI-owned tap bump and a blocking release watch.
Gating the *download* would break all four at once: the cask URL, the web
`/download/perch` route, the rice's ZIP wrap, and the update nudge's cohort
hints (ADR 0003) all assume a public artifact.

So the paywall has to live in the binary. That leaves two questions: how the app
knows you paid, and what it withholds if you haven't.

The obvious answer to the first — a key-activation endpoint, which every
merchant-of-record SDK offers out of the box — is the one thing perch cannot
do. ADR 0003 bought exactly one entitlement, `network.client`, for one hourly
GET, and the README's load-bearing sentence says so out loud: *"the only network
call it makes is an hourly look at perch's own release tag."* That sentence is
a contract with the people who chose a shelf app that asks for no Accessibility,
no input taps, and no screen reading. A licensing phone-home would spend it.

## Decision

**An Ed25519-signed license file, verified offline, and a capacity cap.**

- **The license is a file, not an account.** `.nebelhauslicense` is a small JSON
  blob — `product`, `email`, `purchased`, `seats`, `sig` — signed with Ed25519
  over a canonical fixed-order `key=value` payload (not the JSON: canonicalizing
  JSON is a well-known source of signature drift, and we own both ends). The app
  carries the public half as a constant and verifies with CryptoKit. No
  activation server, no sign-in, nothing to revoke, and it works on an
  air-gapped Mac. It is product-scoped so trill reuses the format, the signer,
  and the mail template untouched.
- **Importing it is a file picker — or a drop on the shelf.** A `.nebelhauslicense`
  dropped on perch is consumed as a key rather than staged as cargo, which is
  both sandbox-legal (a dropped file is a file the user handed us) and the most
  perch way imaginable to activate perch.
- **CalVer is the entitlement.** A purchase covers every build dated on or
  before `purchased + 1 year`, compared against the app's own
  `MARKETING_VERSION`. No version bookkeeping, no server opinion, and `bench
  release` is untouched end-to-end. A build a license covered keeps working
  forever — coverage is a fact about two dates.
- **The free tier is a working shelf capped at three tiles**, not a trial timer.
  Perch's value is habitual, so a cap lets light use stay free forever and
  converts exactly the people who have just felt the ceiling. It is also the
  only honest shape under the sandbox: trial state lives in a container the user
  can delete in one Finder move, so a timer would be theatre.
- **The cap is decided before staging, never during a drag.** Admission is
  computed against `items + pendingTransfers` in `ShelfStore` and the excess is
  simply not taken — nothing is copied and then thrown away, no drag is
  interrupted mid-flight, and the originals are untouched (perch only ever
  copies). A batch is trimmed, not refused: five files onto an empty free shelf
  fills it rather than doing nothing.
- **The ask appears only after a drop actually hit the ceiling.** An unlicensed
  shelf under three tiles never sees a word about buying. The strip reuses ADR
  0003's surface at the bottom of the open shelf and outranks the release nudge
  when both are live, because it answers something the user just did.
- **The cap and the ability to honour a license are one switch.** Until the
  public key constant is filled in, `LicenseStore.canSell` is false and there is
  no cap and no License pane at all. A capped shelf with no purchasable license
  would be a paywall with no door: it would take the free shelf away from
  everyone already using perch and offer them nothing to do about it.

## Consequences

Seats are an honour-system number printed in Settings. An offline license cannot
count installs, and the feature that would need to is the network call this ADR
exists to refuse. That is the deliberate trade: perch is easier to over-share
than a phone-home product, and in exchange nobody's shelf ever stops working
because a server was down, a company folded, or a key was revoked by mistake.

The signature covers every field including `purchased`, so the update year
cannot be extended in a text editor. It cannot stop someone rebuilding the app
from source without the gate — FSL permits exactly that for personal use, and
someone determined not to pay was never a customer.

The README's privacy sentence survives intact: licensing adds no network call,
no entitlement, and no file outside the container. The one new dependency is
CryptoKit, which is part of the OS.

Rice installs hit the same in-app gate as everyone else. One code path, and no
"why do nix users get it free" resentment.
