<div align="center">

<!-- identity banner — green wordmark on graphite (assets/perch-banner.png) -->
<img src="./assets/perch-banner.png" alt="perch" width="460">

**drop it in the notch, drag it out anywhere**

the shelf — files, folders, images, links, and text, caught at the top of your
screen until you know where they're going.

![part of nebelhaus](https://img.shields.io/badge/part_of-nebelhaus-f2c4e5?labelColor=202020)
![themed by nebelung](https://img.shields.io/badge/themed_by-nebelung-c9a8f1?labelColor=202020)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-b9a8e0?labelColor=202020)
![license](https://img.shields.io/badge/license-FSL--1.1--ALv2-d7d7d7?labelColor=202020)

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
- **minimal permissions, no surveillance** — no Accessibility, no input taps, no screen reading, no Dock icon, no telemetry. nothing about your files is ever written to a log. the only network call it makes is an hourly look at perch's own release tag, and Settings turns that off.
- **native and calm** — one sandbox-friendly menu-bar app in the [nebelung](https://github.com/nebelhaus/nebelung) fog-grey palette, which follows your rice's flavor and contrast and swaps with macOS Light/Dark.

## install

```sh
brew install --cask nebelhaus/tap/perch
```

Signed with our Apple Developer ID and notarized, so it opens straight away — no
Gatekeeper prompt, no quarantine hack.

Perch installs by default in the [nebelhaus](https://github.com/nebelhaus) rice,
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
- **it stays responsive** — imports run off the main thread with a two-at-a-time limit, and iCloud placeholders are downloaded explicitly. drop a multi-gigabyte file and the shelf keeps animating.
- **it survives a relaunch** — completed items are written to an atomic manifest. quit and reopen and your pile is still there; startup even recovers files whose manifest write got interrupted.
- **pin it for repeat drops** — pin a tile and it stays on the shelf after a successful drag, ready to drop into several destinations in quick succession. the pin survives relaunch; unpinning restores the usual one-and-done behavior.
- **it drags out as a group, and clears the shelf** — grab any tile and every completed item comes with it, advertised as a copy. Once a destination accepts the drop, the item leaves the shelf; a refused or cancelled drag springs the tiles back. Your original files are never touched — only Perch's staged copies move.
- **it tells you when there's a newer perch** — a quiet strip along the bottom of the open shelf, and a row in the menu bar menu. it knows how *you* installed perch, so the button copies the right command (`haus update`, `brew upgrade --cask perch`, `nix flake update perch`) or opens the release page — perch is sandboxed and never swaps its own bytes behind your back. dismissing a version dismisses that version, not the feature.
- **it follows you around** — one panel per display, tracking Space, fullscreen, and Stage Manager changes with public AppKit behavior. on Tahoe it wears `NSGlassEffectView`; older systems get an AppKit material fallback.

> "Perch" is a working title. Product naming is deliberately kept separate from
> the storage and drag/drop architecture.

## more

- [hausfold.co/perch](https://hausfold.co/perch) — the product page
- [Reference](docs/reference.md) — building, where your staged files live, and the v1 product boundary
- [Architecture](ARCHITECTURE.md) · [Architecture decisions](docs/architecture-decisions/)

## the family

- 🏠 [**nebelhaus**](https://github.com/nebelhaus/nebelhaus) — the house. the whole rice, one Nix flake. start here.
- 🐾 [**pounce**](https://github.com/nebelhaus/pounce) — the palette. keyboard-first launcher; every command a file.
- 🐦 [**trill**](https://github.com/nebelhaus/trill) — the messages. native iMessage/SMS/RCS, read from `chat.db`.
- 🪺 [**perch**](https://github.com/nebelhaus/perch) — the shelf. files, caught in the notch. *(you are here)*
- 🌫️ [**nebelung**](https://github.com/nebelhaus/nebelung) — the theme. the silver-mist palette.
- 🧰 [**workshop**](https://github.com/nebelhaus/workshop) — the bench. where the family is built.

Each one stands alone. Together they're a house.

## license

Perch is **fair source**, not open source: [FSL-1.1-ALv2](LICENSE) © nebelhaus —
the Functional Source License 1.1 with an Apache-2.0 future license.

In practice:

- the source stays public, right here, and always will.
- read it, hack on it, build it yourself, run your build on your own machines —
  all fine, no strings.
- what you can't do is turn it into a competing product or hand out your own
  builds of it. that's the one thing MIT couldn't stop.
- **every release converts to Apache-2.0 two years after that release ships** —
  the restriction has an expiry date baked in, not a promise.
- **every tag cut before this change stays MIT, forever.** relicensing is not
  retroactive; those releases are already out under MIT and stay that way.
