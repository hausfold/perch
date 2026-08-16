---
name: perch
description: Put files on the Mac's notch shelf — the tray that lives in the screen's notch and holds things you're about to drag somewhere. Use when the user says "put this in my shelf", "add this to perch", "shelf this", "hold onto this file", "stick that on the notch", "park these screenshots somewhere I can drag them", or hands you a file and asks you to keep it handy. Load it for "what's on my shelf", "clear my shelf" and "take that off the shelf" too — perch cannot do those, and this is what stops you inventing a command that would.
---

# Perch — the notch file shelf

Perch is a macOS app that turns the notch into a shelf. Files land there as
tiles; the user drags them out into whatever app wants them. It's the halfway
house between "I have this file" and "this file needs to go over there" —
especially across apps that don't share a file picker.

You reach it with the `perch` command. It puts files on the shelf and nothing
else: **there is no verb that reads the shelf back**, so you can add and then
cannot list, remove, or say what's on it. Say so plainly rather than guessing.

Perch must be running to accept anything. If it isn't, `perch add` launches it
and keeps waiting — you don't have to start it yourself.

## Verbs

| do this | run this |
|---|---|
| put files on the shelf | `perch add report.pdf shot.png` |
| shelf a whole pipe of paths | `find . -name '*.png' -newermt '1 hour ago' \| perch add -` |
| shelf something and read the result | `perch add --json build/app.zip` |
| shelf quietly (scripts) | `perch add -q <path>...` |
| refuse to auto-launch Perch | `perch add --no-launch <path>...` |
| wait longer than 15s for a slow launch | `perch add --wait 30 <path>...` |
| everything, exhaustively | `perch --help` (**not** `perch add --help` — that's a usage error) |

Paths after `--` are always treated as paths, however they're spelled. `-` on
its own reads newline-separated paths from stdin.

`--json` prints `{"added":[…],"refused":[…],"failed":[…]}`, each entry
`{name, path}` (plus `reason` on the last two). `path` is your own argument
resolved — tilde expanded, standardized — and echoed back on your own stdout;
it is never sent to Perch, which only ever learns the display name.

## Exit codes — check these, they mean different recoveries

| | meaning | what to do |
|---|---|---|
| 0 | every path landed | say what's on the shelf now |
| 1 | usage error, or a path that doesn't exist | fix the path; **nothing was submitted** |
| 2 | Perch turned items away | report it; don't retry the same batch. Nothing refuses today — if you see this, something new is happening |
| 3 | no Perch answered in time, **or** Perch has never been opened on this Mac | retry with `--wait 30`; if it repeats, the user must launch Perch once by hand |
| 4 | admitted, but a copy failed | check the source is readable; partial batch |

A batch containing one bad path is refused **whole**, before anything is
submitted. So a `1` never means "some of them made it".

## When to reach for this

- "put this in my shelf" / "shelf these" / "add this to perch" → `perch add`
- "hold onto this for a sec" / "I want to drag this into Slack in a minute" →
  `perch add`, and say the tile is on the notch
- "put all the screenshots from this morning on my shelf" → pipe `find` into
  `perch add -`
- "the shelf isn't taking anything" → run `perch add --no-launch` on one file
  and read the exit code out loud

## When NOT to

- **The user wants the file somewhere permanent.** The shelf is a staging tray,
  not a folder. Copy or move it instead.
- **The user wants to see or clear the shelf.** There is no read or remove verb.
  Tell them to use the panel on the notch — don't invent `perch list`.
- **The user wants a notification.** That's `trill send`.
- **The user wants to change how Perch behaves** (whether it's installed, where
  it sits) — that's a haus setting, `haus.shelf.*`, not this command.
- **You are on Linux or in a container.** Perch is macOS-only and needs a
  logged-in GUI session; there is no headless mode.

## Traps

- **`perch` may not be on PATH at all, and that is expected right now.** The
  command landed after the current release, so an installed Perch has no CLI in
  its bundle and nothing creates `bin/perch`. `command -v perch` first; if it's
  missing, say the shelf is there but its command line ships in the next
  release — don't tell the user their install is broken.
- **Adding is one-way.** Nothing here can list or remove. If you told the user
  you'd "clean up the shelf afterwards", you can't.
- **Perch never touches the original.** It reads and copies. So "shelf this and
  delete the original" is two steps, and the second one is yours — do it only
  if asked, and only after exit 0.
- **Never pass a path Perch itself has to open.** The command reads the bytes
  and hands them over; there is no URL scheme, and `perch://add?path=…` does
  not exist. Perch is sandboxed and could not open such a path anyway.
- **Exit 0 with `--quiet` prints nothing.** That's success, not a hang.
