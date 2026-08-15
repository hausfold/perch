# ADR 0009: Perch stays free, and MIT

Status: accepted — supersedes [ADR 0004](0004-offline-license-and-a-capacity-cap.md)

## Context

[ADR 0004](0004-offline-license-and-a-capacity-cap.md) took perch paid: an
Ed25519-signed `.perchlicense` verified offline, a free tier capped at two
tiles, and a repo relicensed MIT → FSL-1.1-ALv2 to stop someone reselling the
builds. It was carefully built and it never sold anything — the production
public key was never minted, so `canSell` was false in every shipped build, the
cap never switched on, and the License pane never appeared.

Since then the bet changed. The family is going free and open source — the
platform and the apps together — and a paid shelf is the wrong shape for that:
it makes perch the one hausfold app you can't hand to someone, it puts a
fair-source licence on a repo whose siblings are MIT, and it costs the codebase
a licence subsystem, a capacity cap threaded through every import path, and a
purchase strip in the UI to run a business nobody is running yet.

Selling perch stays possible later. It just stops being something the code
carries in the meantime.

## Decision

**Perch is free of charge and MIT-licensed. There is no paid tier, no licence
file, and no ceiling on what the shelf holds.**

- **MIT, retroactively.** The FSL experiment covered `v2026.08.04` through
  `v2026.08.14-1`. hausfold holds the whole copyright, so those tags are
  relicensed MIT along with everything since: every release of perch, past and
  future, is MIT. `nix/package.nix` can now declare `meta.license` (FSL is
  unfree to nixpkgs, which is why it declared none — that constraint is gone).
- **The licence subsystem is deleted, not disabled.** `License.swift`,
  `LicenseStore.swift`, their tests, the Settings pane, the purchase strip on
  the shelf, the update nudge's renewal hint, and the `.perchlicense` drop path
  in `ShelfDropHandler` are all gone. Nothing dormant is left behind to
  half-work later; the git history is the record, and this ADR is the pointer
  into it.
- **The cap is gone from every import path.** `ShelfStore.admit` /
  `admissible` are deleted rather than made to return everything, so there is
  one fewer hop between a drop and staging.
- **Admission itself stays.** ADR 0007 and [ADR 0008](0008-command-line-joins-the-handoff-mailbox.md)
  are unaffected. Their two-phase handshake was *used* by the cap but is not
  about it: a sender outside the app asks for a slot by name and waits for the
  app to persist a receipt before it copies a byte, which is what keeps the
  running app the single authority on the shelf and makes "Perch isn't running"
  a clean failure instead of an unwatched inbox. The app now always says yes.
- **The wire keeps its refusal channel.** `RefusedItem` and the `accept`
  message's `refused` array stay in `PerchWire/`: the phone already knows how
  to hear a refusal, the two halves ship on one tag but run on independently
  updated devices, and a protocol that can only say yes has nowhere to grow. The
  Mac simply never populates it — `perch add`'s exit code 2 is likewise
  unreachable today and kept for the same reason.

## Consequences

- The README's privacy sentence gets simpler, not weaker: with licensing gone,
  the hourly release-tag poll and the paired-device listener are the only
  network surfaces left, exactly as ADR 0003 and ADR 0005 describe them.
- [ADR 0006](0006-companion-ships-free-on-the-mac-release-tag.md) is unchanged
  in substance — the companion was already free with no IAP — but its premise
  ("the second half of a Mac app you already bought") is now just "the second
  half of perch". `docs/app-store.md`'s review notes lose the paid-Mac framing.
- `docs/going-paid.md`, the runbook for minting the keypair and standing up the
  signing Worker, is deleted. If perch ever goes paid, ADR 0004 and that file
  are both recoverable from git — and both would want rewriting anyway.
- Anyone who built from an FSL tag is retroactively better off. Nobody paid, so
  there is no customer to make whole.
