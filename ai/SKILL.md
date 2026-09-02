---
name: perch
description: Put files on the Mac's notch shelf — the tray that lives in the screen's notch and holds things you're about to drag somewhere — and read or prune what's already there. Use when the user says "put this in my shelf", "add this to perch", "shelf this", "hold onto this file", "stick that on the notch", "park these screenshots somewhere I can drag them", "what's on my shelf", "take that off the shelf", "clear my shelf", or hands you a file and asks you to keep it handy.
---

# Perch — the notch file shelf

Perch is a macOS app that turns the notch into a shelf. Files land there as
tiles; the user drags them out into whatever app wants them. It's the halfway
house between "I have this file" and "this file needs to go over there" —
especially across apps that don't share a file picker.

You reach it with the `perch` command: `add` puts files on the shelf, `list`
says what's on it, `rm` takes things off.

Perch must be running to answer anything. If it isn't, every verb launches it
and keeps waiting — you don't have to start it yourself.

## Verbs

| do this | run this |
|---|---|
| put files on the shelf | `perch add report.pdf shot.png` |
| shelf a whole pipe of paths | `find . -name '*.png' -newermt '1 hour ago' \| perch add -` |
| see what's on the shelf | `perch list` |
| read the shelf as data | `perch list --json` |
| take one item off | `perch rm <item-id>` |
| clear the shelf | `perch list --json \| jq -r '.items[].id' \| perch rm -` |
| shelf something and read the result | `perch add --json build/app.zip` |
| shelf quietly (scripts) | `perch add -q <path>...` |
| refuse to auto-launch Perch | `perch add --no-launch <path>...` |
| wait longer than 15s for a slow launch | `perch add --wait 30 <path>...` |
| everything, exhaustively | `perch --help` (**not** `perch add --help` — that's a usage error) |

Paths after `--` are always treated as paths, however they're spelled. `-` on
its own reads newline-separated operands from stdin — paths for `add`, ids for
`rm`.

`perch list` prints one line per tile, **id first**, because the id is what `rm`
takes. `rm` never takes a name: two tiles can share one, and it won't guess.

## Reading the JSON

`add` prints `{"added":[…],"refused":[…],"failed":[…]}`, each entry
`{name, path}` (plus `reason` on the last two). `path` is your own argument
resolved and echoed back on your own stdout; it is never sent to Perch, which
only ever learns the display name.

`list` prints `{"items":[…]}` and `rm` prints `{"removed":[…],"missing":[…]}`,
where an item is `{id, name, kind, contentType, bytes, addedAt, pinned}` —
every key always present, `contentType` and `bytes` null when Perch doesn't
know them. `missing` holds the ids you named that weren't on the shelf. There
is no path in any of it: where the bytes live is the app's business.

## Exit codes — check these, they mean different recoveries

| | meaning | what to do |
|---|---|---|
| 0 | it worked: paths landed / the shelf was printed / the items are off it | say what's on the shelf now |
| 1 | usage error, a path that doesn't exist, or an id the shelf doesn't have | fix it; for `add` **nothing was submitted**, for `rm` the *other* ids were still removed |
| 2 | Perch turned items away | report it; don't retry the same batch. Nothing refuses today — if you see this, something new is happening |
| 3 | no Perch answered in time, **or** Perch has never been opened on this Mac | retry with `--wait 30`; if it repeats, the user must launch Perch once by hand |
| 4 | the exchange broke after Perch answered — for `add`, a copy failed | check the source is readable; partial batch |

An `add` batch containing one bad path is refused **whole**, before anything is
submitted. So a `1` from `add` never means "some of them made it". An `rm`
batch is refused whole only if an argument isn't a UUID at all.

## When to reach for this

- "put this in my shelf" / "shelf these" / "add this to perch" → `perch add`
- "hold onto this for a sec" / "I want to drag this into Slack in a minute" →
  `perch add`, and say the tile is on the notch
- "put all the screenshots from this morning on my shelf" → pipe `find` into
  `perch add -`
- "what's on my shelf" / "is that still there" → `perch list`
- "take that off" / "clear the shelf" → `perch list --json` to find the id,
  then `perch rm`
- "the shelf isn't taking anything" → run `perch add --no-launch` on one file
  and read the exit code out loud

## When NOT to

- **The user wants the file somewhere permanent.** The shelf is a staging tray,
  not a folder. Copy or move it instead.
- **The user wants a notification.** That's `trill send`.
- **The user wants to change how Perch behaves** (whether it's installed, where
  it sits) — that's a haus setting, `haus.shelf.*`, not this command.
- **You are on Linux or in a container.** Perch is macOS-only and needs a
  logged-in GUI session; there is no headless mode.

## Traps

- **`rm` is not undo.** It deletes the copy Perch staged, and there's no
  putting it back from here. Confirm before clearing a shelf you didn't fill.
- **A pinned tile is pinned for a reason** — it stays put through a drag so the
  user can drop it again. `perch list` marks it; `rm` will still remove one if
  you name its id, so don't sweep pins into a "clear the shelf".
- **Perch never touches the original.** It reads and copies — and `rm` only
  ever removes its own copy. So "shelf this and delete the original" is two
  steps, and the second one is yours: do it only if asked, and only after exit 0.
- **Never pass a path Perch itself has to open.** The command reads the bytes
  and hands them over; there is no URL scheme, and `perch://add?path=…` does
  not exist. Perch is sandboxed and could not open such a path anyway.
- **Exit 0 with `--quiet` prints nothing.** That's success, not a hang.
