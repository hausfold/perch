<div align="center">

<!-- identity banner — green wordmark on graphite (assets/perch-banner.png) -->
<img src="./assets/perch-banner.png" alt="perch" width="480">

**drop it in the notch, drag it out anywhere**

files, folders, images, links, and text, caught at the top of your screen until you know where they're going

</div>

---

You know the dance: drag a file, realise the destination window is buried, let
go, dig it out, drag again.

Perch ends it. Start dragging *anything*, flick up to the notch, and a shelf
drops down to catch it. Pile in as much as you like from as many places as you
like, then grab any tile and drag the whole group to its real home in one
motion. Copies in, copies out: your originals are never moved, renamed, or
touched, nothing leaves the shelf on its own, and there's no Accessibility
grant, no telemetry, and no Dock icon.

```sh
brew install --cask hausfold/tap/perch
perch skill install   # optional — teach this Mac's coding agents about the shelf
```

macOS 14 or newer, signed and notarized. The phone half is free on the App
Store — [**Perch Companion**](https://apps.apple.com/app/id6799443735) — and
pairs by scanning the Mac's code, over your own network or with no network at
all.

## the manual

📖 **[hausfold.co/docs/perch](https://hausfold.co/docs/perch)** — and it only
lives there: [install](https://hausfold.co/docs/perch/install) (which opens with
the one macOS setting that steals the drop if you leave it on),
[using the shelf](https://hausfold.co/docs/perch/using), and
[privacy](https://hausfold.co/perch/privacy), which is shorter than either.

Inside a haus machine it's [the Shelf
room](https://hausfold.co/docs/haus/rooms/shelf) — installed, themed and kept
current with the rest of the desktop.

## in this repo

- [`docs/cli.md`](docs/cli.md) — `perch add`, `list`, `rm`, their exit codes, and the mailbox protocol behind them
- [`ai/SKILL.md`](ai/SKILL.md) — the agent surface, so *"put this in my shelf"* works first try; `perch skill` prints it, `perch skill install` puts it where your agent will find it
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — the invariants, and the seams that hold them
- [`AGENTS.md`](AGENTS.md) — building it, testing it, shipping it

---

<div align="center">

<sub>**pre-release** · built so the paths that could lose your files don't exist: copies in, copies out, clearing asks first. that's the intent, not a warranty; [tell us what breaks](https://github.com/hausfold/perch/issues).</sub>

<a href="https://hausfold.co">⌂ hausfold</a>

</div>
