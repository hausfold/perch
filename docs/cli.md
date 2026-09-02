# `perch` — the command line

`perch add` puts files on the shelf from a script, a Makefile, a shell pipe, or
an agent. It is the same road a drag takes: the same admission handshake (so
nothing is copied that no shelf is there to adopt), the same staging pipeline,
the same "never touch the original" guarantee. `perch list` and `perch rm` are
the other direction: what is on the shelf, and taking something off it. Two more
verbs never touch the shelf at all — `perch doctor` reports on this Mac, and
`perch skill` hands a coding agent the routing document for all of it.

```sh
perch add report.pdf shot.png
find . -name '*.png' -newermt '1 hour ago' | perch add -
perch add --json build/app.zip

perch list
perch rm 6B0F2C7E-4C1D-4D8E-9E39-6E9F6F7B4A21
perch list --json | jq -r '.items[] | select(.pinned | not) | .id' | perch rm -

perch doctor
perch skill install
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
perch doctor [--json] [--wait <seconds>]
perch skill [--json] [<name>]
perch skill install [--json] [--client <name>] [--dir <path>]

  --wait <seconds>  how long to wait for Perch to answer (default 15; doctor 2)
  --no-launch       fail instead of launching Perch when it isn't running
  --json            report the result as JSON on stdout
  --quiet, -q       don't print a line per item (add, rm)
  -                 read newline-separated operands from stdin (add, rm)
  --                treat every remaining argument as an operand
  --client <name>   write into one client's skills dir (skill install)
  --dir <path>      write into this directory instead (skill install)

perch --version     print the installed release
perch help          usage
```

Every *shelf* verb — `add`, `list`, `rm` — reaches the running app, and each of
them will launch it and wait if it isn't running; `--no-launch` is how a script
says it would rather fail. `doctor` and `skill` are the two that don't, and
`doctor` will not launch anything even when asked.

`list` prints one line per tile, id first, because the id is what `rm` takes; an
empty shelf prints nothing on stdout and says so on stderr, so a pipe reads as
empty and a person still gets an answer.

`rm` takes ids, never names: two tiles can share a display name, and no removal
should have to guess which one was meant. It removes pinned items too — naming
an id is as deliberate as picking the tile — and, like everything else here, it
only ever deletes the copy Perch staged. The original was never Perch's.

| Exit | Meaning |
|---|---|
| 0 | every path landed / the shelf was printed / every named item is off it |
| 1 | usage error, a path that isn't there, or an id that didn't come off the shelf |
| 2 | Perch turned items away (nothing refuses an offer today — the code stays because the receipt can say no) |
| 3 | no Perch answered in time, or the one that did is older than the verb; from `doctor`, at least one blocking finding |
| 4 | the exchange broke — the container couldn't be written, or, for `add`, a copy failed after admission, or, for `skill install`, a file couldn't be written |

`skill` uses 1 for a name perch doesn't ship or a machine with no agent client
on it, 2 for a `SKILL.md` that exists with different bytes and was left alone,
and 4 when a write it *did* attempt failed.

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

## `perch doctor`

The one verb that answers with no Perch running — and it never starts one, on
purpose: a doctor that starts the patient cannot report on the patient.

```
$ perch doctor
perch 2026.08.31 (Homebrew cask)
macOS 26.0.1 (25A354) on Mac16,10

✓ app        /Applications/Perch.app
✓ launches   /Applications/Perch.app
✓ install    Installed with Homebrew — updates come from brew upgrade --cask perch.
✓ container  /Users/you/Library/Group Containers/88M28542LQ.com.hausfold.perch
✓ shelf      answering — 3 items on it

doctor: ready
```

`✓` fine, `!` worth knowing, `✗` blocking; exit 3 if anything is `✗`. The first
two lines are what the bug form's `perch doctor` field asks for — version,
cohort, macOS build, Mac model — from the same `PerchDiagnostics/` the app
quotes into that form, so a pasted `doctor` and a filed issue can't disagree
about which Mac this is. Not the same bytes: `BugReport` lays those four facts
out over three lines for the form, this lays them over two for a terminal.

Three of the rows earn their place by naming a trap rather than a state. **`app`
vs `launches`** are the bundle this tool ships inside and the copy Launch
Services would open; on a Mac that has ever built perch they routinely differ,
because every `xcodebuild` registers the app it built and nothing unregisters it
(AGENTS.md). **`install`** is the update cohort, and it is the answer to "how do
I update this" — `brew upgrade --cask perch`, `haus update`, a flake bump, or
one click in the app, and only the cohort knows which. And **`shelf` tells three
answers apart** that all look like silence: nothing running, a mailbox that could
not be written, and a Perch that is running but predates the verb doctor knocks
with — that last one answers with no entries, and calling it "not running" would
send someone hunting for a process that is right there.

The check rows name **local paths** — which bundle, which container. That is the
point of those rows, and it is also why the *whole* output is not the thing to
paste into a public issue: the header pair is (it carries no path), the check
rows are yours.

`--json` answers with every key always present:
`{version, bundleID, app, launchServicesApp, tool, install, installName,
updateCommand, os, model, container, containerPresent, running, shelfItems, ok,
checks}`, where `checks` is `[{name, status, detail}]` and `status` is
`ok`/`note`/`bad`. `install` is the machine token (`homebrew`, `direct`, `haus`,
`nix`, `unknown`); `installName` is the same thing written for a person.

The knock is one `list` through the mailbox with a 2-second deadline and no
launch — the tool's own documented liveness test, since only a running app can
answer it. `--wait` raises the deadline on a loaded Mac. The transaction is
closed either way; a doctor never leaves a request behind.

## `perch skill`

A3 of the family agent surface (the workshop's `docs/agent-surface.md`): the
tool teaches an agent about itself, from a machine with no checkout.

```
perch skill                 print ai/SKILL.md, byte for byte
perch skill <name>          print one of perch's other skills (there is one today)
perch skill --json          the same, as {name, body}
perch skill install         write every skill into every agent client found here
perch skill install --client claude|codex|opencode|pi
perch skill install --dir PATH
```

**The skill is baked into the binary**, not read from beside it — perch ships as
a cask's `.app`, a read-only Nix store path and a ZIP somebody drags, and the
tool on `PATH` is only ever a symlink into the bundle, so every "read the file
next to me" scheme is right for exactly one of those doors. Embedded, the
version that answers `--version` is the version that answers `skill`.
`scripts/embed-skills.sh` does the baking into the committed
`PerchCLI/GeneratedSkills.swift`, and CI fails on a stale one.

`install` writes `<skills dir>/<skill name>/SKILL.md` — named for the skill, not
for the tool — into every client whose own config directory exists
(`~/.claude`, `~/.codex`, `~/.config/opencode`, `~/.pi/agent`; `$HOME` is
honoured, because that is the home the client will read at). It **refuses rather
than clobbers**, and says which kind of refusal it is:

| what it finds | what it does | exit |
|---|---|---|
| nothing there | writes it, prints `wrote <path>` | 0 |
| our bytes already | prints `current <path>` | 0 |
| a symlink | leaves it — on a haus machine `haus.ai.skill` owns that path, and the Nix store is read-only | 0 |
| a real file with different bytes | leaves it, names the path | 2 |
| a directory it cannot write | says why, on stderr | 4 |

The haus case is the happy path, not a failure: the skill is already installed
and current, from the same source. Saying so beats an `EPERM`.

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
**change it in the same PR that changes any of them**, and re-run
`scripts/embed-skills.sh` so `perch skill` prints what you wrote. It is bound by
the family standard, the workshop's `docs/agent-surface.md`.

Three copies of that file ship, and they are byte-identical by construction: the
committed source, `pkgs.perch-skill` (`nix/skill.nix`, which haus installs), and
the string literal inside the binary. `scripts/check-skills.sh` guards the
frontmatter and the shape; `scripts/embed-skills.sh --check` guards the literal.
Both run in CI, and the Nix build runs the first.
