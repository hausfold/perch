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
like, then grab any tile and drag the whole group to its real home in one
motion. Copies in, copies out: your originals are never moved, renamed, or
touched, nothing leaves the shelf on its own, and there's no Accessibility
grant, no telemetry, and no Dock icon.

```sh
brew install --cask hausfold/tap/perch
```

The phone half is free on the App Store:
[**Perch Companion**](https://apps.apple.com/app/id6799443735) — pair it once by
scanning the Mac's code, then send over your own network — or with no
network at all, peer-to-peer.

The drag is the front door; Finder's right-click menu, the `perch` command
line, watched folders, and a paired iPhone are the others. The manual lives at
[hausfold.co/docs/perch](https://hausfold.co/docs/perch): the Nix flake, the
one macOS setting that steals the drop if you leave it on, every way onto the
shelf, and how updates arrive.

## more

- [the manual](https://hausfold.co/docs/perch): install, using the shelf, and what stays when you walk away — the one page about perch on hausfold.co
- [privacy](https://hausfold.co/perch/privacy): the whole policy, and shorter than the manual
- [Reference](docs/reference.md): storage, watched folders, theming, permissions, the deep detail
- [The `perch` command line](docs/cli.md): `perch add`, its exit codes, and the mailbox protocol behind it
- [`ai/SKILL.md`](ai/SKILL.md): the agent surface, so *"put this in my shelf"* works first try
- [Architecture](ARCHITECTURE.md): the invariants, and the seams that hold them

---

<div align="center">

<sub>**pre-release** · built so the paths that could lose your files don't exist: copies in, copies out, clearing asks first. that's the intent, not a warranty; [tell us what breaks](https://github.com/hausfold/perch/issues).</sub>

<a href="https://hausfold.co">⌂ hausfold</a>

</div>
