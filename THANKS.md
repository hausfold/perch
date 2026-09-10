# Thanks

## Founding testers

The people who run perch before it is public, on their own machines, with no
help from me while they do it. Each one chooses how they appear here, and the
order is the order they report in. It stays that way.

*The early alpha hasn't started yet.*

What a founding tester gets, and the limits on it, are written down once:
[FOUNDING.md](https://github.com/hausfold/workshop/blob/main/FOUNDING.md).

## Standing on

Nothing third-party ships inside perch. It holds your files for the minute
before you drag them somewhere else, and that is a bad place to be running code
nobody here wrote. There is no `Package.swift`, no package reference in the
Xcode project, no submodule, no vendored framework, and the updater is perch's
own rather than Sparkle.

So the list is short, and it is Apple's frameworks doing the work:

| | |
|---|---|
| AppKit and SwiftUI | The panel, the notch geometry and every drag in and out |
| QuickLookThumbnailing | The thumbnails. The full-size preview is `qlmanage` in its own process, because the shelf panel is deliberately never the key window |
| UniformTypeIdentifiers | What a dropped file actually is |
| CryptoKit and Security | Phone pairing and the keychain it lives in. These two are why the paragraph above can claim what it claims |
| Network, AppIntents, VisionKit | Finding a phone, the Shortcuts surface, the scan-from-camera path |

### The colours

The four palettes the shelf paints with are
[nebelung](https://github.com/hausfold/nebelung)'s, hand-copied into
`Perch/UI/Theme/RicePalette.swift` because perch builds outside Nix and cannot
consume nebelung's generated output. nebelung is a
[Catppuccin](https://catppuccin.com) flavor, and Catppuccin did the hard part
of deciding what a readable palette is, dark and light. I changed the greys.

Drop any nebelung `*.hex.json` into `~/.config/perch/themes/` and the shelf
uses that instead. On a haus machine the Shelf room writes those files for you.

### Getting it

Four doors, and perch knows which one it came through
(`PerchDiagnostics/InstallKind.swift`): the zip, which needs no terminal at
all; [Homebrew](https://brew.sh), `brew install --cask hausfold/tap/perch`;
the Shelf room on a haus machine; and Nix.

None of these projects asked to be part of this. If you find perch useful, some
of that belongs upstream.
