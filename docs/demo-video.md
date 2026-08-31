# The 60-second demo

A shot list for the short internal video: what's on screen, what's said over it,
and the handful of things that quietly ruin a take. Every beat is something the
app does today, and the "how it works" paragraph is condensed from [the App
Store description](./app-store.md) and `ARCHITECTURE.md`'s wire section.

Record the **whole display**, never a window: the shelf hangs off the notch, so
a window-scoped capture cuts the subject out of frame.

## Shot list

| | On screen | Said over it |
|---|---|---|
| **0:00–0:07** | Drag a file off the Desktop, flick up to the notch. The shelf drops, the tile lands. | "Drag anything, flick up to the notch, and a shelf drops down to catch it." |
| **0:07–0:22** | Three more without stopping: select a paragraph in a browser and drag it up; drag a **folder** out of a Finder window; drag a file out of **Downloads**. Then grab the **Drag all 4** pill in the shelf header and drop the pile into one folder. | "Pile in as much as you like, from as many places as you like — a chunk of text, a folder, a download — then take the whole stack out in one motion." |
| **0:22–0:36** | Settings ▸ **Watched Folders**, "Shelf my screenshots" **off**. ⇧⌘4 a region — nothing lands. Flip the switch **on**, click **Watch** in the panel. ⇧⌘4 again — the tile appears on its own. | "Point it at your screenshots folder and it catches those too, the moment they're taken. The originals never move." |
| **0:36–0:44** | iPhone Mirroring window beside the shelf. In the phone: share a photo → **Perch** → the sheet turns to a green check, **On \<your Mac\>**, and the tile lands on the Mac's shelf. | "And your phone is a shelf as well. Share to Perch there, and it turns up here." |
| **0:44–0:57** | Hold on the phone-to-Mac beat; optionally cut to Settings ▸ **iPhone & iPad** showing the paired phone. | The paragraph below. |
| **0:57–1:00** | `brew install --cask hausfold/tap/perch` on screen. | "Mac half's a brew cask. Phone half's free on the App Store." |

## The how-it-works paragraph

> It finds your Mac over Bonjour and talks straight to it — your network,
> nobody else's — end-to-end encrypted with a key the two devices agreed on
> when you paired them. No relay, no server, no account. And if there's no
> network at all, it goes peer-to-peer over the same link AirDrop uses.

~50 words, about 13 seconds at demo pace. If you need a shorter cut, the last
sentence is the one to drop; "no relay, no server, no account" is the line the
team will repeat.

## Before you hit record

- **Pair the phone the day before.** The local-network prompt fires over the
  companion's *launch*, not when you tap "Pair a Mac" (`docs/app-store.md`), so
  on a fresh install it lands in the middle of your first shot. Pairing itself
  can go either way — scan the QR, or paste the `perch-pair:` code, which is the
  route that works under iPhone Mirroring, where there is no camera.
- **Quit every other Perch.** One perch owns the notch; a second copy exits at
  launch, so a dev build already running means the app on screen isn't the one
  you meant to demo.
- **Leave the Dock's top-edge trigger alone.** The shelf's bottom strip and its
  Mission Control menu row only render while that trigger is armed — and while
  it's armed, dragging to the notch *does not work at all*
  (`docs/feel-testing.md`). No take has both. Leave it off and skip the strip.
- **Rehearse the screenshots switch once.** Turning it *on* opens a folder
  panel, and it opens at what the desktop config named, else `~/Desktop` — the
  sandbox can't read where macOS actually puts your captures. If yours go
  somewhere else you'll be navigating a panel on camera. Know the click:
  pick the folder, then **Watch**.
- **Use fresh files in every take.** A watched folder dedupes by file identity,
  not name: a file *moved* back into Downloads keeps its inode and will not land
  a second time. Copy or create, don't move. (`docs/feel-testing.md`)
- **Don't wait for a progress bar.** Same-volume drops are APFS clones — a 3 GB
  file lands instantly. That's correct; just don't script a beat around it.
- **Tidy the frame.** The notch sits in the menu bar; a crowded one is the first
  thing anyone reads.
