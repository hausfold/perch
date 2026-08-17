# `perch` — the command line

`perch add` puts files on the shelf from a script, a Makefile, a shell pipe, or
an agent. It is the same road a drag takes: the same admission handshake (so
nothing is copied that no shelf is there to adopt), the same staging pipeline,
the same "never touch the original" guarantee.

```sh
perch add report.pdf shot.png
find . -name '*.png' -newermt '1 hour ago' | perch add -
perch add --json build/app.zip
```

## Where the binary is

The tool ships **inside** `Perch.app`, at
`Perch.app/Contents/MacOS/perch-cli`, so it is signed and notarized with the
app and can never drift from the shelf it talks to.

| Install | What puts it on your PATH |
|---|---|
| haus | the Shelf room links it out of the copy it placed in `/Applications` (`haus.shelf.enable = true`) |
| Nix, on its own | `pkgs.perch` exposes `bin/perch` |
| Homebrew cask | ⚠️ nothing yet — the cask places the app and stops there. Take the row below until it carries a `binary` stanza |
| Neither | `ln -s /Applications/Perch.app/Contents/MacOS/perch-cli /usr/local/bin/perch` |

Every one of those is a **symlink** into the bundle, never a copy: the tool is
notarized as part of the app, so a copy outside it is nested code torn out of
that seal. `perch` resolves the link to find the `.app` it belongs to, which is
how `--version` knows what it is and how a dev build finds itself.

It is `perch-cli` inside the bundle and `perch` on your PATH for one blunt
reason: macOS filesystems are case-insensitive by default, so a second
executable named `perch` in `Contents/MacOS` *is* `Perch` — it overwrites the
app's own binary, and the "app" you launch is then the CLI printing its usage.

## Usage

```
perch add [options] <path>...

  --wait <seconds>  how long to wait for Perch to answer (default 15)
  --no-launch       fail instead of launching Perch when it isn't running
  --json            report the result as JSON on stdout
  --quiet, -q       don't print a line per added file
  -                 read newline-separated paths from stdin
  --                treat every remaining argument as a path

perch --version     print the installed release
perch help          usage
```

| Exit | Meaning |
|---|---|
| 0 | every path landed on the shelf |
| 1 | usage error, or a path that isn't there — nothing was submitted |
| 2 | Perch turned items away (nothing refuses an offer today — the code stays because the receipt can say no) |
| 3 | no Perch answered in time |
| 4 | Perch admitted the items but a copy failed |

A batch with a bad path is refused whole, before anything is submitted — a
half-typo'd batch should not spend shelf slots deciding that.

## How it works, and why it isn't a URL scheme

Perch is sandboxed. It holds `files.user-selected.read-write` and nothing more,
so it cannot read a path you merely *name* — `perch://add?path=…` would hand it
a path it isn't allowed to open. The tool is unsandboxed and runs as you, so it
does the reading, and the two halves meet in the App Group container the Finder
Action already uses ([ADR 0007](architecture-decisions/0007-finder-action-admission-before-copy.md),
[ADR 0008](architecture-decisions/0008-command-line-joins-the-handoff-mailbox.md)):

1. `perch add` writes a request — **display names only**, no paths — into a
   fresh transaction directory in
   `~/Library/Group Containers/88M28542LQ.com.hausfold.perch/FinderActionRequests`.
2. The running app reserves shelf slots and answers with the item IDs it
   admitted.
3. Only then does the tool copy those items' bytes into the transaction
   directory, each through a hidden `.partial` that is moved into place when the
   copy is complete.
4. It publishes the relative staged paths; the app validates them, adopts the
   bytes into its own staging root, and the tiles appear.

The originals are opened read-only and never moved, renamed, or written to. No
original path is ever written into the container, into the manifest, or into a
log — the names are all Perch learns. A refused item is never copied at all.

If nothing answers within two seconds the tool launches Perch (the installed
copy if Launch Services knows one, otherwise the bundle it is sitting in) and
keeps waiting until `--wait` runs out. It never gives up without writing an
empty completion, which is what releases the slots the app reserved.

## Speaking the protocol yourself

The mailbox is plain JSON in a documented directory, so anything unsandboxed and
running as you can be a second `perch add` — that is the whole SDK.
`PerchFinderBridge/HandoffClient.swift` is the reference implementation and
`PerchFinderBridge/FinderActionProtocol.swift` is the wire format. Two rules are
not negotiable if you write your own: **wait for the response before you copy
anything**, and **never put a source path in the JSON**.

## Teaching an agent to use it

[`ai/SKILL.md`](../ai/SKILL.md) is this page's counterpart for a coding agent on
a machine with no checkout — the routing document that makes *"put this in my
shelf"* work first try. It quotes the verbs, flags and exit codes above, so
**change it in the same PR that changes any of them.** It is bound by the
family standard, the workshop's `notes/agent-surface.md`.
