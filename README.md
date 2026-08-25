<div align="center">

# 🪺 perch

**drop it in the notch, drag it out anywhere**

files, folders, images, links, and text, caught at the top of your screen until you know where they're going

</div>

---

You know the dance: drag a file, realise the destination window is buried, let
go, dig it out, drag again.

Perch ends it. Start dragging *anything*, flick up to the notch, and a shelf
drops down to catch it. Pile in as much as you like from as many places as you
like. Then grab any tile and drag the whole group to its real home in one
motion. Pin a tile and it stays for repeat drops; right-click **Save to…** and
it writes a copy with no drag at all; quit and relaunch and the pile is still
there.

No Dock icon. No Accessibility, Input Monitoring, or Screen Recording
permission. It only ever sees what you choose to drop on it.

## install

```sh
brew install --cask hausfold/tap/perch
```

Or on Nix: add `github:hausfold/perch` as a flake input, and `overlays.default`
puts `perch` in your pkgs, wrapping the same notarized release ZIP the cask
installs. Either way it opens straight away: signed with our Apple Developer ID,
no Gatekeeper prompt. macOS 14+, notch optional; notchless displays get a
top-center catch band.

Then flip one system setting: turn **off** System Settings ▸ Desktop & Dock ▸
*"Drag windows to top of screen to enter Mission Control"*. macOS arms that
top-edge trigger during any drag, over the exact band the shelf lives in, so
without this the Dock steals the drop
([why](docs/reference.md#the-one-system-setting-perch-needs)). A
[haus](https://github.com/hausfold/haus) desktop installs perch and flips it
for you.

## every way in

The drag is the front door. The others matter just as much:

| | |
|---|---|
| **right-click** | **Add to Perch Shelf** sits under Finder's *Services* with no setup, and under the same menu for selected text and links in any app. Perch doesn't have to be running; the Service launches it. |
| **a script** | `perch add report.pdf` shelves from a shell, a Makefile, or an agent; `find . -name '*.png' \| perch add -` takes stdin. Exit codes tell a pipeline what happened, and [the CLI page](docs/cli.md) says how each install puts `perch` on your PATH (the cask doesn't, yet). |
| **a watched folder** | point Settings at Downloads or a scans folder and new arrivals shelf themselves, plus a one-switch **Shelf my screenshots**. ([how](docs/reference.md#watched-folders)) |
| **your iPhone** | the free companion app and its Share sheet send photos, links, and files to the Mac's shelf and pull items back: end-to-end encrypted, peer-to-peer, no server, no account. |

## the promise

Shelf apps aren't new; Yoink and Dropover have carried the idea for years.
Perch's angle is **dependability and restraint**:

1. **Your originals are never touched.** Every door stages a *copy* into a
   collision-proof private area, and drag-out exports copies too, so an
   interrupted drag can't lose data, and two same-named files from different
   folders both survive. Nothing on disk is moved, renamed, or modified, ever.
2. **Nothing leaves the shelf on its own.** Clearing asks first, the expiry
   timer ships off, and completed items are written to an atomic manifest that
   survives relaunch; startup even recovers files whose manifest write got
   interrupted.
3. **Nothing watches you.** No input taps, no telemetry, no logs of your
   files; original paths are never persisted anywhere. The only internet
   traffic is an hourly look at perch's own release tag, and Settings turns it
   off. ([the full permissions story](docs/reference.md#permissions))

When a newer perch exists, the open shelf says so quietly and hands you the
right command for how *you* installed it; it never swaps its own bytes behind
your back.

## more

- [hausfold.co/perch](https://hausfold.co/perch): the product page
- [Reference](docs/reference.md): the shelf in detail, storage, watched folders, theming, permissions, updating
- [The `perch` command line](docs/cli.md): `perch add`, its exit codes, and the mailbox protocol behind it
- [`ai/SKILL.md`](ai/SKILL.md): the agent surface, so *"put this in my shelf"* works first try
- [Architecture](ARCHITECTURE.md): the invariants, and the seams that hold them

---

<div align="center">

<sub>**pre-release** · built so the paths that could lose your files don't exist: copies in, copies out, clearing asks first. that's the intent, not a warranty; [tell us what breaks](https://github.com/hausfold/perch/issues).</sub>

<a href="https://hausfold.co">⌂ hausfold</a>

</div>
