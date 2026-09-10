# Thanks

## Founding testers

The people who ran perch before it was public, on their own machines, with no
help from me while they did it. Each one chose how they appear here, and the
order is the order they reported in. It stays that way.

*The early alpha hasn't started yet. This is where the list goes.*

What a founding tester gets, and the limits on it, are written down once:
[FOUNDING.md](https://github.com/hausfold/workshop/blob/main/FOUNDING.md).

## Standing on

perch has no third-party dependencies. It is a shelf that holds your files
before you drag them somewhere else, and a file-holding app is the last place
to widen the trust boundary for convenience. What it is built on instead:

| | |
|---|---|
| Apple's own frameworks | AppKit, SwiftUI, QuickLook, UniformTypeIdentifiers, VisionKit, AppIntents, Network. The notch, the drags and the thumbnails are all theirs |
| [Homebrew](https://brew.sh) | One of two doors: `brew install --cask hausfold/tap/perch`. The other is the zip, and it needs no terminal at all |
| [Swift](https://swift.org) | The language and its toolchain |

The shelf's colours come from [nebelung](https://github.com/hausfold/nebelung),
which is a [Catppuccin](https://catppuccin.com) flavor. Catppuccin did the hard
part of deciding what a readable dark theme is; we changed the greys.
