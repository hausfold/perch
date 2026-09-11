# `perch` — the command line

What a contributor needs: the wire protocol behind the verbs, the exit codes, and
the JSON shapes. What the verbs *do* is the manual's, at
[hausfold.co/docs/perch/install](https://hausfold.co/docs/perch/install#the-perch-command),
and `ai/SKILL.md` is the same surface for an agent with no checkout.

`perch add` is the same road a drag takes: the same admission handshake (so
nothing is copied that no shelf is there to adopt), the same staging pipeline,
the same "never touch the original" guarantee. `list` and `rm` are that
transaction with its middle removed. `skill` never opens the mailbox at all, and
`doctor` opens it only to knock.

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
  --client <name>   claude|codex|opencode|pi (skill install)
  --dir <path>      write into this directory instead (skill install)

perch --version     print the installed release
perch help          usage
```

The three shelf verbs launch the app and wait if it isn't running; `doctor` and
`skill` don't, and `doctor` will not launch anything even when asked. `list`
prints one line per tile, id first, because the id is what `rm` takes; an empty
shelf prints nothing on stdout and says so on stderr, so a pipe reads as empty
and a person still gets an answer. `rm` takes ids and never names, because two
tiles can share a display name and no removal should have to guess.

## Exit codes

| Exit | Meaning |
|---|---|
| 0 | every path landed / the shelf was printed / every named item is off it |
| 1 | usage error, a path that isn't there, or an id that didn't come off the shelf |
| 2 | Perch turned items away (nothing refuses an offer today — the code stays because the receipt can say no) |
| 3 | no Perch answered in time, or the one that did is older than the verb; from `doctor`, at least one blocking finding |
| 4 | the exchange broke — the container couldn't be written, or, for `add`, a copy failed after admission, or, for `skill install`, a file couldn't be written |

`skill` uses 1 for a name perch doesn't ship, a machine with no agent client on
it, `--dir` and `--client` together, or either flag with a missing or empty
value (`--dir ""` is an unset variable, not a path); 2 for a `SKILL.md` that
exists with different bytes and was left alone; and 4 when a write it *did*
attempt failed. A symlink is none of those: something else installed it (on a
haus machine, `haus.ai.skill`), it is named and left alone, and the run exits 0.

An `add` batch with a bad path, or an `rm` batch with something that isn't a
UUID, is refused whole before anything is submitted — a half-typo'd batch should
not spend shelf slots, or removals, deciding that. An id that is well-formed but
didn't come off the shelf is different: `rm` removes the rest, names that one on
stderr — or in `--json`'s `missing` — and exits 1, the way `rm(1)` does.

## `--json`

One object per verb:

| Verb | Shape |
|---|---|
| `add` | `{"added":[…],"refused":[…],"failed":[…]}`, each entry `{name, path}` (`reason` on the last two) |
| `list` | `{"items":[…]}` |
| `rm` | `{"removed":[…],"missing":["<id>"]}` |
| `skill` | `{name, body}` |

An item is `{id, name, kind, contentType, bytes, addedAt, pinned}` — every key
always present, `contentType` and `bytes` null when Perch doesn't know them,
`addedAt` an ISO-8601 stamp. There is no path in it: staged or original, where
the bytes live is the app's business, and `add`'s `path` is only your own
argument echoed back on your own stdout.

`doctor --json` answers with every key always present:
`{version, bundleID, app, launchServicesApp, tool, install, installName,
updateCommand, os, model, container, containerPresent, running, shelfItems, ok,
checks}`, where `checks` is `[{name, status, detail}]` and `status` is
`ok`/`note`/`bad`. `install` is the machine token (`homebrew`, `direct`, `haus`,
`nix`, `unknown`); `installName` is the same thing written for a person.

## `perch doctor`

`✓` fine, `!` worth knowing, `✗` blocking; exit 3 if anything is `✗`. The first
two lines are what the bug form's `perch doctor` field asks for — version,
cohort, macOS build, Mac model — from the same `PerchDiagnostics/` the app
quotes into that form, so a pasted `doctor` and a filed issue can't disagree
about which Mac this is. Not the same bytes: `BugReport` lays those four facts
out over three lines for the form, this lays them over two for a terminal.

Three rows earn their place by naming a trap rather than a state. **`app` vs
`launches`** are the bundle this tool ships inside and the copy Launch Services
would open; on a Mac that has ever built perch they routinely differ, because
every `xcodebuild` registers the app it built and nothing unregisters it
(AGENTS.md). **`install`** is the update cohort, and it is the answer to "how do
I update this" — only the cohort knows which command. And **`shelf` tells three
answers apart** that all look like silence: nothing running, a mailbox that could
not be written, and a Perch that is running but predates the verb doctor knocks
with — that last one answers with no entries, and calling it "not running" would
send someone hunting for a process that is right there.

The check rows name **local paths**, which is the point of them and also why the
*whole* output is not the thing to paste into a public issue: the header pair is
(it carries no path), the check rows are yours.

The knock is one `list` through the mailbox with a 2-second deadline and no
launch — the tool's own documented liveness test, since only a running app can
answer it. `--wait` raises the deadline on a loaded Mac. The transaction is
closed either way; a doctor never leaves a request behind.

## `perch skill`

A3 of the family agent surface (the workshop's `docs/agent-surface.md`): the
tool teaches an agent about itself from a machine with no checkout. The skill is
baked into the binary, not read from beside it, because perch ships as a cask's
`.app`, a read-only Nix store path and a ZIP somebody drags, and the tool on
`PATH` is only ever a symlink into the bundle — every "read the file next to me"
scheme is right for exactly one of those doors. Embedded, the version that
answers `--version` answers `skill`. AGENTS.md § *The agent surface* has the
scripts that keep the three copies byte-identical.

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

## The protocol, and why it isn't a URL scheme

Perch is sandboxed. It holds `files.user-selected.read-write` and nothing more,
so it cannot read a path you merely *name* — `perch://add?path=…` would hand it
a path it isn't allowed to open. The tool is unsandboxed and runs as you, so it
does the reading, and the two halves meet in the App Group container the Finder
Action already uses: admission is granted before anything reads source bytes,
and the command line is a second client of that same mailbox rather than a new
door.

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

For `list` and `rm` the request names a verb and, for `rm`, the ids to take off;
the app answers in one turn with the entries — the whole shelf, or exactly what
it removed — and the tool acknowledges, which is what lets the app drop the
directory. Nothing is copied, so nothing is reserved, and the answer carries
names and ids and no path of any kind.

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

## Speaking it yourself

The mailbox is plain JSON in a documented directory, so anything unsandboxed and
running as you can be a second `perch add` — that is the whole SDK.
`PerchFinderBridge/HandoffClient.swift` is the reference implementation and
`PerchFinderBridge/FinderActionProtocol.swift` is the wire format. Three rules
are not negotiable if you write your own: **wait for the response before you
copy anything**, **never put a source path in the JSON**, and **close every
transaction you open** — the empty completion is what releases a reservation
after an `add` and what lets the app drop a read verb's directory.
