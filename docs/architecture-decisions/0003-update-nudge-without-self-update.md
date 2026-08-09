# ADR 0003: Nudge about releases, never install them

Status: accepted

## Context

Perch has four install routes and no way to mention a new release. The rice pins
it through the flake, a Homebrew cask carries it, the release ZIP is a drag into
`/Applications`, and a bare `nix run` is a store path — so "how do I update?"
has four different answers and perch, the one program that knows which install
it is, was silent about all of them. Pounce solved this first, with a palette
row.

The full-strength version of that nudge does two things: it names the right next
step per cohort, and for the two cohorts that own their bytes — a cask and a
drag-install — it *performs* the update, replacing its own bundle from the
release ZIP or handing off to `brew`, then reopening itself.

Perch cannot do the second half. It is sandboxed (`ENABLE_APP_SANDBOX = YES`,
plus exactly one read-only exception, ADR 0002). `/Applications` is outside the
container, every child process inherits the sandbox, and a `brew` spawned from
inside it would fail in ways nothing would be left running to report. A
self-update would have to be bought by dropping the sandbox — for a
drag-and-drop target that accepts arbitrary files from every app on the machine,
that is the wrong trade in the wrong direction.

## Decision

Perch ports pounce's `UpdateNudge` — the hourly poll, the CalVer ordering, the
per-version dismissal, the cohort detection — and stops before the install.

- **Every cohort gets advice, not an action.** The button copies this install's
  command (`haus update`, `brew upgrade --cask perch`, `nix flake update perch`)
  or opens the release page. Nothing in the update path writes outside the
  container or spawns a process.
- **The surfaces are passive.** A strip along the bottom of the expanded shelf,
  and a row in the menu bar menu. The obvious surface is a notification banner;
  perch asks the system for no permission it can avoid — the same reason it polls
  `pressedMouseButtons` instead of installing a `CGEventTap` — so the nudge
  waits until you look at it. It also yields to a drag in progress and to an
  error banner: the shelf's job during a drag is to catch the file.
- **Dismissal is per version.** `✕` silences 2026.08.05 and says nothing about
  2026.08.06, so "dismiss" never quietly becomes "never tell me again".
- **One entitlement.** `com.apple.security.network.client`, for one hourly
  unauthenticated GET to `api.github.com` for the latest tag, off by a Settings
  toggle, never in DEBUG builds. Perch uploads nothing and downloads no file.

Cohort detection is the inherited one, with one addition. Both of its receipts —
the rice's `/Library/Application Support/nebelhaus/perch.installed-from` and
`<brew prefix>/Caskroom/perch` — are outside the container, so a denial would
read as "not installed that way" rather than as an error. Both turn out to be
readable under the sandbox today, but the failure is silent if that ever
changes, so `~/.config/perch/config.json` — the rice's theme drop, the one
outside path the entitlements already grant — is a third signal: consulted only
when neither receipt was seen, and only able to promote an ambiguous
`/Applications` install to `.rice`.

## Consequences

A cask or drag-install user gets one more step than an unsandboxed app's
equivalent user would: run the command, or download and drag. That is the
visible cost of the sandbox, and it is paid by the cohorts perch's own author is
not in — the rice cohort's answer (`haus update`) is a copied command either
way, so on a nebelhaus machine nothing is lost.

Perch talks to the network, which it never did before. It is one host, one
hourly GET, one tag string parsed, and a toggle that stops it. The entitlement
is documented at its declaration for the same reason ADR 0002's exception is:
the next person to read `Perch.entitlements` should not have to guess why.

The nudge cannot nag. It has no banner to post and no window it can raise; the
worst it can do is occupy 30 points at the bottom of a shelf you opened
yourself.
