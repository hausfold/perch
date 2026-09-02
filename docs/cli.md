# `perch` — the command line

`perch add` puts files on the shelf from a script, a Makefile, a shell pipe, or
an agent. It is the same road a drag takes: the same admission handshake (so
nothing is copied that no shelf is there to adopt), the same staging pipeline,
the same "never touch the original" guarantee. `perch list` and `perch rm` are
the other direction: what is on the shelf, and taking something off it.

```sh
perch add report.pdf shot.png
find . -name '*.png' -newermt '1 hour ago' | perch add -
perch add --json build/app.zip

perch list
perch rm 6B0F2C7E-4C1D-4D8E-9E39-6E9F6F7B4A21
perch list --json | jq -r '.items[] | select(.pinned | not) | .id' | perch rm -
```

## Where the binary is

The tool ships **inside** `Perch.app`, at
`Perch.app/Contents/MacOS/perch-cli`, so it is signed and notarized with the
app and can never drift from the shelf it talks to.

| Install | What puts it on your PATH |
|---|---|
| haus | the Shelf room links it out of the copy it placed in `/Applications` (`haus.shelf.enable = true`) |
| Nix, on its own | `pkgs.perch` exposes `bin/perch` |
| Homebrew cask | `Casks/perch.rb`'s `binary … target: "perch"` (hausfold/homebrew-tap) |
| Neither | nothing does — `ln -s /Applications/Perch.app/Contents/MacOS/perch-cli /usr/local/bin/perch`, once |

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
perch list [options]
perch rm [options] <item-id>...

  --wait <seconds>  how long to wait for Perch to answer (default 15)
  --no-launch       fail instead of launching Perch when it isn't running
  --json            report the result as JSON on stdout
  --quiet, -q       don't print a line per item (add, rm)
  -                 read newline-separated operands from stdin (add, rm)
  --                treat every remaining argument as an operand

perch --version     print the installed release
perch help          usage
```

Every verb reaches the *running* app, and every one of them will launch it and
wait if it isn't running — `--no-launch` is how a script says it would rather
fail. `list` prints one line per tile, id first, because the id is what `rm`
takes; an empty shelf prints nothing on stdout and says so on stderr, so a pipe
reads as empty and a person still gets an answer.

`rm` takes ids, never names: two tiles can share a display name, and no removal
should have to guess which one was meant. It removes pinned items too — naming
an id is as deliberate as picking the tile — and, like everything else here, it
only ever deletes the copy Perch staged. The original was never Perch's.

| Exit | Meaning |
|---|---|
| 0 | every path landed / the shelf was printed / every named item is off it |
| 1 | usage error, a path that isn't there, or an id that didn't come off the shelf |
| 2 | Perch turned items away (nothing refuses an offer today — the code stays because the receipt can say no) |
| 3 | no Perch answered in time, or the one that did is older than the verb |
| 4 | the exchange broke — the container couldn't be written, or, for `add`, a copy failed after admission |

An `add` batch with a bad path, or an `rm` batch with something that isn't a
UUID, is refused whole before anything is submitted — a half-typo'd batch should
not spend shelf slots, or removals, deciding that. An id that is well-formed but
didn't come off the shelf is different: `rm` removes the rest, names that one on
stderr — or in `--json`'s `missing` — and exits 1, the way `rm(1)` does.

`--json` answers with the whole result, one object:

| Verb | Shape |
|---|---|
| `add` | `{"added":[…],"refused":[…],"failed":[…]}`, each entry `{name, path}` (`reason` on the last two) |
| `list` | `{"items":[…]}` |
| `rm` | `{"removed":[…],"missing":["<id>"]}` |

An item is `{id, name, kind, contentType, bytes, addedAt, pinned}` — every key
always present, `contentType` and `bytes` null when Perch doesn't know them,
`addedAt` an ISO-8601 stamp. There is no path in it: staged or original, where
the bytes live is the app's business, and `add`'s `path` is only your own
argument echoed back on your own stdout.

## How it works, and why it isn't a URL scheme

Perch is sandboxed. It holds `files.user-selected.read-write` and nothing more,
so it cannot read a path you merely *name* — `perch://add?path=…` would hand it
a path it isn't allowed to open. The tool is unsandboxed and runs as you, so it
does the reading, and the two halves meet in the App Group container the Finder
Action already uses — admission is granted before anything reads source bytes,
and the command line is a second client of that same mailbox rather than a new
door:

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

`list` and `rm` are that transaction with its middle removed. The request names
a verb and, for `rm`, the ids to take off; the app answers in one turn with the
entries — the whole shelf, or exactly what it removed — and the tool
acknowledges, which is what lets the app drop the directory. Nothing is copied,
so nothing is reserved, and the answer carries names and ids and no path of any
kind.

A request that names no verb at all is an `add`: the mailbox had only that one
until the read verbs, and an installed `perch` writes here whether or not it is
the copy this app shipped with. The mirror case is answered rather than
ignored — a verb this app has never heard of gets a reply with no entries,
which is how a newer tool learns to say so instead of waiting out its timeout,
and is why one strange request can't stall the transactions queued behind it.

`rm` goes through this door rather than deleting anything itself for the same
reason `add` does: the shelf is the app's, the panel is drawn from it, and a
second writer would be a second opinion. `list` could have read the app's
manifest directly — the tool is unsandboxed and could answer with Perch closed —
and doesn't, for the other half of that reason: an answer assembled anywhere but
the running app can disagree with the tiles on the notch, and "what's on my
shelf?" has one right answer.

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
`PerchFinderBridge/FinderActionProtocol.swift` is the wire format. Three rules
are not negotiable if you write your own: **wait for the response before you
copy anything**, **never put a source path in the JSON**, and **close every
transaction you open** — the empty completion is what releases a reservation
after an `add` and what lets the app drop a read verb's directory.

## Teaching an agent to use it

[`ai/SKILL.md`](../ai/SKILL.md) is this page's counterpart for a coding agent on
a machine with no checkout — the routing document that makes *"put this in my
shelf"* work first try. It quotes the verbs, flags and exit codes above, so
**change it in the same PR that changes any of them.** It is bound by the
family standard, the workshop's `docs/agent-surface.md`.
