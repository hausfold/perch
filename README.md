<div align="center">

<!-- identity banner — green wordmark on graphite (assets/perch-banner.png) -->
<img src="./assets/perch-banner.png" alt="perch" width="460">

**drop it in the notch, drag it out anywhere**

the shelf — files, folders, images, links, and text, caught at the top of your
screen until you know where they're going.

![part of hausfold](https://img.shields.io/badge/part_of-hausfold-f2c4e5?labelColor=202020)
![themed by nebelung](https://img.shields.io/badge/themed_by-nebelung-c9a8f1?labelColor=202020)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-b9a8e0?labelColor=202020)
![license](https://img.shields.io/badge/license-MIT-d7d7d7?labelColor=202020)

<sub>**pre-release** · your originals are never moved, renamed or touched, and nothing leaves the shelf on its own — clearing it asks first, and the expiry timer is off unless you turn it on. that's the intent, not a warranty — tell us what breaks.</sub>

</div>

---

You know the dance: drag a file, realise the destination window is buried, let
go, dig it out, drag again.

Perch kills that. Start dragging *anything*, flick up to the notch, and a little
shelf drops down to catch it. Pile in as much as you like from as many places as
you like — then grab any tile and drag the whole group to its real home in one
motion.

No Dock icon. No Accessibility, Input Monitoring, or Screen Recording
permission. It only ever sees what you choose to drop on it.

📖 **[hausfold.co/perch](https://hausfold.co/perch)**

## why perch

Shelf apps aren't new — Yoink, Dropover, and friends have carried the idea for
years. Perch's angle is **dependability and restraint**:

- **copies, not moves** — a shelf that *moves* your only copy can delete it before the destination finished reading it. Perch stages copies and exports copies, so an interrupted drag never loses data.
- **minimal permissions, no surveillance** — no Accessibility, no input taps, no screen reading, no Dock icon, no telemetry. nothing about your files is ever written to a log. the only thing it sends to the internet is an hourly look at perch's own release tag, and Settings turns that off; the only other traffic is to an iPhone you paired yourself, on your own network, encrypted end to end ([ADR 0005](docs/architecture-decisions/0005-mobile-companion-wire.md)).
- **native and calm** — one sandbox-friendly menu-bar app in the [nebelung](https://github.com/hausfold/nebelung) fog-grey palette, which follows your rice's flavor and contrast and swaps with macOS Light/Dark.

## install

```sh
brew install --cask hausfold/tap/perch
```

Signed with our Apple Developer ID and notarized, so it opens straight away — no
Gatekeeper prompt, no quarantine hack.

Perch installs by default in the [hausfold](https://github.com/hausfold) rice,
but it stands alone — the cask works on any Mac running macOS 14 or newer.

Then turn **off** System Settings ▸ Desktop & Dock ▸ *"Drag windows to top of
screen to enter Mission Control"*. macOS arms that top-edge trigger for the whole
of any drag — files included — and it fires over the same band the notch shelf
lives in, so without this the Dock steals the drop. The rice flips it for you;
standalone installs do it once, by hand. ([why](docs/reference.md#the-one-system-setting-perch-needs))

## what it does

- **a target that finds the notch** — the drop zone hugs the physical camera housing when a display has one, and falls back to a tidy top-center catch band on notchless screens. either way the collapsed shelf draws no chrome of its own — no synthetic notch, no tray.
- **you can see it's holding something** — a staged shelf lights a small sage ember under the camera housing, or under the menu bar on a notchless screen: a pip per item and a flare as each one lands. it tells you the shelf is holding something, not exactly how much — for that, open it.
- **it never touches your originals** — every dropped item is *copied* into a private, collision-proof staging area. drop two files with the same name from different folders and both survive. nothing on disk is moved, renamed, or modified, ever.
- **it handles the awkward producers** — Photos exports, Safari images, and other apps that hand over files lazily (AppKit "file promises") go down their own import path, so they land correctly instead of arriving empty.
- **it lives at the top of Finder's right-click menu** — **Add to Perch Shelf** sits in the context menu itself, beside *New Terminal Tab Here*, with no setup at all: right-click any selection and it's on the shelf. Select text or a link anywhere else and the same command is in that app's Services menu. The Quick Actions submenu carries it too, from the Finder extension — macOS turns that one on for you; if it ever goes missing it lives in System Settings ▸ General ▸ Login Items & Extensions ▸ Extensions ▸ ⓘ next to **System Services** — under that row, not under Perch. Perch must be running for the Quick Action so it can reserve shelf space before Finder copies anything; the top-level one launches Perch itself.
- **it takes files from a script** — `perch add report.pdf` puts something on the shelf from a shell, a Makefile, or an agent; `find . -name '*.png' | perch add -` takes a list on stdin. It's the same road a drag takes — same staging, originals only ever read — and the exit status says what happened, so a pipeline can tell an unopened shelf from a copy that failed. ([the CLI](docs/cli.md))
- **it stays responsive** — imports run off the main thread with a two-at-a-time limit, and iCloud placeholders are downloaded explicitly. drop a multi-gigabyte file and the shelf keeps animating.
- **it survives a relaunch** — completed items are written to an atomic manifest. quit and reopen and your pile is still there; startup even recovers files whose manifest write got interrupted.
- **pin it for repeat drops** — pin a tile and it stays on the shelf after a successful drag, ready to drop into several destinations in quick succession. the pin survives relaunch; unpinning restores the usual one-and-done behavior.
- **it drags out as a group, and clears the shelf** — grab any tile and every completed item comes with it, advertised as a copy. Once a destination accepts the drop, the item leaves the shelf; a refused or cancelled drag springs the tiles back. Your original files are never touched — only Perch's staged copies move.
- **or save it out without a drag** — right-click a tile and pick **Save to…** when the destination is a folder nothing has open. it writes a copy wherever you point the panel and leaves the tile where it was, replacing an existing file only once the new copy is whole.
- **it tells you when there's a newer perch** — a quiet strip along the bottom of the open shelf, and a row in the menu bar menu. it knows how *you* installed perch, so the button copies the right command (`haus update`, `brew upgrade --cask perch`, `nix flake update perch`) or opens the release page — perch is sandboxed and never swaps its own bytes behind your back. dismissing a version dismisses that version, not the feature.
- **it follows you around** — one panel per display, tracking Space, fullscreen, and Stage Manager changes with public AppKit behavior. on Tahoe it wears `NSGlassEffectView`; older systems get an AppKit material fallback.

> "Perch" is a working title. Product naming is deliberately kept separate from
> the storage and drag/drop architecture.

## more

- [hausfold.co/perch](https://hausfold.co/perch) — the product page
- [Reference](docs/reference.md) — building, where your staged files live, and the v1 product boundary
- [The `perch` command line](docs/cli.md) — `perch add`, its exit codes, and the mailbox protocol behind it
- [Architecture](ARCHITECTURE.md) · [Architecture decisions](docs/architecture-decisions/)

## the family

- 🏠 [**haus**](https://github.com/hausfold/haus) — the house: the nix-darwin layer and the desktops built on it, one Nix flake. start here.
- 🐾 [**pounce**](https://github.com/hausfold/pounce) — the palette. keyboard-first launcher; every command a file.
- 🪺 [**perch**](https://github.com/hausfold/perch) — the shelf. files, caught in the notch. *(you are here)*
- 🌫️ [**nebelung**](https://github.com/hausfold/nebelung) — the theme. the silver-mist palette.
- 🧰 [**workshop**](https://github.com/hausfold/workshop) — the bench. where the family is built.

Each one stands alone. Together they're a house.

## license

[MIT](LICENSE) © hausfold — free and open source, and free of charge. Read it,
hack on it, build it yourself, ship your own builds. No paid tier, no license
key, no cap on what the shelf holds.

Perch was briefly licensed FSL-1.1-ALv2 (`v2026.08.04` through `v2026.08.14-1`)
while a paid tier was on the table. That's off the table — those tags are
relicensed MIT along with everything since, so every release of perch, past and
future, is MIT.
