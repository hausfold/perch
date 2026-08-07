# ADR 0006: The companion ships free, through the App Store, on the Mac's tag

Status: accepted

## Context

[ADR 0005](0005-mobile-companion-wire.md) built the phone side and explicitly
left distribution out: *"the iOS targets ship nothing yet — App Store
distribution, icons, and the free-companion/paid-Mac story are deliberately out
of this ADR."* This is that ADR.

Three things are decided at once because they constrain each other: what the
companion costs, which tag builds it, and how far automation is allowed to go.

The inherited constraints are real. The Mac app is sold direct with an offline
license (ADR 0004, [`going-paid.md`](../going-paid.md)) and is distributed
outside the App Store as a notarized ZIP. The wire between the two halves is
versioned by the code on both ends, not negotiated — a phone far ahead of its
Mac is a support problem no one asked for.

## Decision

**The companion is free, with no purchase and no in-app purchase — ever.** It is
the second half of a Mac app you already bought, not a product. Consequences
that follow and are load-bearing:

- The app never mentions a price, never links to a checkout, and never shows a
  paywall. It states, once, in the store description, that Perch for Mac is a
  separate app on our site. That is a fact about a different product, not
  steering (App Store 3.1.1), and it is the whole reason a reviewer can make
  sense of the app.
- ADR 0004's capacity cap is a *Mac-side* mechanism. The phone's shelf is not
  capped by the licence; admission for a transfer is still decided by the Mac
  before any bytes move, which is where the cap already lives.

**The same `v<VERSION>` tag ships both halves.** `bench release perch` cuts one
tag; `release.yml` notarizes the Mac ZIP and `testflight.yml` archives, exports,
and uploads the iOS build. One version number, one ritual, and a phone build
whose wire is by construction the one its Mac shipped with.

The cost is a TestFlight build for every Mac-only release. That is deliberate and
cheap: uploading is not shipping.

**Automation stops at TestFlight.** Nothing auto-submits for review. Attaching a
build to a store version and pressing Submit stays a human act, because the copy,
the screenshots, and the review notes are the parts that actually get rejected,
and none of them belong in a YAML file. The runbook for that half is
[`app-store.md`](../app-store.md).

**`VERSION` remains the single source of truth**, adapted rather than forked:
App Store Connect refuses leading zeros, so `2026.08.06` is injected as
`2026.8.6`, with the workflow's run number as the build number. The build number
carries monotonicity; the marketing version carries meaning.

## Consequences

- Two more identities to keep alive: an Apple Distribution certificate and an
  App Store Connect API key with App Manager role. The notarization key cannot
  upload builds, so the repo now holds two App Store Connect keys with different
  scopes — label them.
- The App Group `group.com.nebelhaus.perch` becomes release infrastructure, not
  just a build detail: it must exist on both App IDs in the portal or every
  archive fails at signing.
- Privacy manifests are now a maintenance obligation. `PerchIOS/` and
  `PerchShare/` each carry one, and they must agree — the two bundles compile the
  *same* `PerchWire/` and `PerchMobileCore/` sources, so a new required-reason
  API in shared code is a two-file change.
- A same-day re-cut (`2026.08.06-2`) collapses to the same marketing version. It
  is fine for TestFlight; a store submission of it needs a fresh VERSION day.
- Export compliance is answered in the build
  (`ITSAppUsesNonExemptEncryption = false`) on the basis that all cryptography is
  CryptoKit's standard algorithms. Hand-rolling a cipher would invalidate that
  answer, which is one more reason not to.
