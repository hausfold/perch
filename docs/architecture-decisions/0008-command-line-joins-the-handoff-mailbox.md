# ADR 0008: The command line is a second client of the handoff mailbox

Status: accepted

## Context

Perch could be driven programmatically only through App Intents — Shortcuts,
Spotlight, `shortcuts run` against a shortcut a human built first. Nothing in
that path is reachable from a shell script, a Makefile, or an agent, which is
where "put this build artifact on the shelf" actually comes from.

The obvious shape — a URL scheme, `perch://add?path=…`, or an Apple Event
carrying a path — cannot work. Perch is sandboxed with
`files.user-selected.read-write` and nothing else, so a path it is merely
*told* about is a path it may not open. Whatever reads the bytes has to be
something that is allowed to: the user's own unsandboxed process.

That is exactly the problem [ADR 0007](0007-finder-action-admission-before-copy.md)
already solved for Finder, and its solution is not Finder-specific. The Action
Extension is simply the first *sender*: it asks by name, waits for the app's
admission receipt, copies only what was reserved into the shared App Group
container, and publishes relative paths.

## Decision

**Ship a `perch` command line tool that is a second sender on the same
mailbox.** `perch add <path>...` runs the identical four-step transaction the
Finder Action runs, against the same directory, with the same JSON. The app
side gains nothing: `FinderActionReceiver` cannot tell the two apart, and must
not be able to — admission, path validation, and adoption are decided in one
place for every sender there will ever be. (This also said "and the free-tier
cap"; the cap is gone as of [ADR 0009](0009-perch-stays-free-and-mit.md), the
single admission point is not.)

The sender half of that protocol therefore moves into
`PerchFinderBridge/HandoffClient.swift`, shared verbatim by the extension and
the tool, so a change to the handshake cannot land in one and not the other.

**The tool ships inside `Perch.app`, as `Contents/MacOS/perch-cli`,** signed
and notarized with the app in the same inside-out pass as the extension. It is
placed on `PATH` as `perch` by whatever installed the app — a `bin/perch`
symlink from the Nix package, a `binary` stanza in the cask. It is named
`perch-cli` in the bundle because macOS filesystems are case-insensitive: a
`Contents/MacOS/perch` *is* `Contents/MacOS/Perch` and silently replaces the
app's own executable.

**The mailbox is the liveness test, not a process list.** The tool does not ask
whether a process with Perch's bundle identifier is running — a dev build has
its own identifier and would answer "no" while owning the notch. It opens the
request, waits ~2s for any shelf to answer, and only then launches one and
keeps waiting to the `--wait` deadline. A tool that gives up writes an empty
completion first, releasing whatever the app reserved.

**No new entitlement, no new permission.** The tool is unsandboxed, so it
addresses the group container by its documented path rather than through
`containerURL(forSecurityApplicationGroupIdentifier:)`, which answers nil
without the App Group entitlement. It refuses to *create* that container: an
absent one means Perch has never run, and the app makes its own.

## Consequences

- Every invariant of a drag holds for a script: originals are only read, the
  cap is decided before staging, no original path reaches the container or a
  log, and a tile appears only after a complete copy is adopted.
- The exit status carries the outcome a script needs — 2 for an item Perch
  turned away (nothing refuses one today — see ADR 0009), 3
  for no shelf listening, 4 for a copy that failed — so `perch add` is usable
  in a pipeline without parsing output. `--json` reports per item.
- The App Group directory keeps its `FinderActionRequests` name and JSON shape.
  Renaming it would buy accuracy and cost a migration for transactions in
  flight across an upgrade; the types are shared, so the code says what it is.
- The release workflow signs one more nested binary before the app.
- Documenting the mailbox makes it a public surface: anything unsandboxed can
  be a sender. That is deliberate — it is the same surface Finder uses, and the
  app remains the only authority over what is admitted.
- A reverse direction (`perch list`, `perch get`) is not part of this decision.
  It needs the app to write and the tool to read, which is a second protocol,
  not a second verb.
