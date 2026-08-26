# Listing the companion — the App Store runbook

The Mac app ships as a Developer-ID-signed, notarized ZIP through the cask and
the flake (`release.yml`). The **iPhone/iPad companion can only ship through the
App Store**, which is a different animal: a store record with copy and
screenshots, a privacy label, an export-compliance answer, and a human review.

This file is that path. `.github/workflows/testflight.yml` does the machine half;
everything here is the half only a person with the account can do. It's ordered
by how often you'll need it — the release loop first, the standing facts in the
middle, and the once-per-decade Apple setup as an appendix at the bottom.

The companion is **free**, and stays free — so is the Mac app it belongs to
(free of charge and MIT since 2026-08-15; the `README.md` licence section has
what happened to the ten-day fair-source experiment before it). The phone
is the second half of perch, so it carries no purchase, no IAP, and no account.
That keeps the review simple: nothing to restore, no subscription screens, no
receipts.

## The shipping loop

```
bench release perch          # from the workshop — cuts the v<VERSION> tag
  ├─ release.yml    → notarized Mac ZIP, cask bump, flake pin bump
  └─ testflight.yml → PerchIOS archive → .ipa → App Store Connect
                      ↓
              TestFlight (automatic, ~10 min of Apple processing)
                      ↓
              you, in App Store Connect: attach the build to a version,
              then Submit for Review
```

Nothing auto-submits. The workflow's job ends at "the build is in TestFlight",
which means a Mac-only release can ride the same tag harmlessly — it just leaves
a build sitting in TestFlight that nobody promotes.

Version mapping is mechanical: `VERSION` `2026.08.06` becomes marketing version
`2026.8.6` (App Store Connect refuses leading zeros), and the build number is
`run_number × 10 + (attempt − 1)` — the attempt is folded in because a *re-run*
keeps the same run number, and Apple rejects a build number it has already seen
for that marketing version. So a failed upload is retryable with the Re-run
button; you don't have to cut a new tag. A same-day re-cut (`2026.08.06-2`)
uploads as the *same* marketing version with a higher build — fine for
TestFlight, but a store release of it needs a new VERSION day.

Phone-only builds don't need a tag at all: `gh workflow run testflight.yml`
(add `--ref <branch>` to test the pipeline from a branch). Every run's summary
page prints the version, the build number, and the two clicks still owed.

## After you submit

The first submission is the slow one; everything after it is the loop below.

- **Waiting.** "Waiting for Review" → "In Review" is typically hours to a day.
  Nothing to do; the build in TestFlight is already installable on your own
  devices while you wait.
- **A reviewer question** arrives in **Resolution Center**, not by email thread —
  reply there. The seven review-note answers below cover the likely ones; the
  offer to arrange a paired Mac is genuine, so honor it if they take it.
- **Rejection is not a re-upload.** Most rejections are metadata or explanation,
  fixed in App Store Connect and resubmitted with the same build. Only rebuild
  (new tag or `gh workflow run`) when the *binary* has to change.
- **Editing copy mid-review.** Description, keywords, and screenshots are frozen
  while a version is In Review — changing them means pulling the submission and
  going back into the queue. **Promotional text** (170 chars) is the exception:
  it changes any time, no review. Prefer it for anything urgent.
- **Approved.** Release manually rather than automatically the first time, so the
  listing goes live when you're watching it. Phased release (7-day ramp) is worth
  keeping on for later versions and pointless for the first one.

> ✅ **1.0 is live — approved 2026-08-25**, after a resubmission on 08-19.
> `Perch Companion`, Apple ID **`6799443735`**, bundle id `com.hausfold.perch.ios`,
> free, iOS 18+ —
> [apps.apple.com/app/id6799443735](https://apps.apple.com/app/id6799443735).
> That id is the durable handle: the short `/app/id<id>` URL redirects to the
> right localized listing forever, while the slug in the URL App Store Connect
> shows you changes with the app's name. Turn **phased release** on from the
> next version. It also unblocks the deletions in
> [Re-identifying an already-submitted app](#re-identifying-an-already-submitted-app)
> step 6.

Then each later release is: tag → build lands in TestFlight → **new version
record** in App Store Connect (`+` next to iOS App) → attach the build → one
honest What's New line → Submit. A Mac-only release skips all of that and just
leaves an unpromoted build behind.

## The listing

The copy of record. What's in App Store Connect should match what's here; when
they disagree, fix it here first and paste. Keep it honest about what the app is:
a companion, not a standalone.

- **Name**: `Perch Companion` (plain `Perch` is taken by another developer; in-app branding stays `Perch`). Was `Perch for Mac` until 2026-08-08 — bundle ID, SKU and name all changed together in the hausfold re-identification, see [Re-identifying an already-submitted app](#re-identifying-an-already-submitted-app). Bundle ID `com.hausfold.perch.ios`, SKU `perch-ios-hausfold`
- **Subtitle** (30 max): `Send it to your desktop shelf`
  Was `Send it to your Mac's shelf` until 2026-08-19, when App Review rejected
  1.0 (240) under **5.2.5** for an Apple trademark in the subtitle. Name,
  subtitle and icon carry **no Apple product names** — "desktop" instead of
  "Mac". The description and the review notes keep theirs — there it is a
  referential compatibility statement, which the trademark guidelines allow.
  **Keywords deliberately keep `mac`** (not displayed on the product page, and
  it is how people search for this); **promotional text dropped it** on the same
  day, because it renders on the page and carried the exact rejected phrase. If
  5.2.5 comes back anyway, the keyword is the next thing to strip.
- **Category**: Productivity (secondary: Utilities)
- **Age rating**: 4+ — no user content shown to other users, no web view, no ads
- **Support URL**: `https://hausfold.co/perch`
- **Marketing URL**: `https://hausfold.co/perch`
  hausfold is the seller, and perch's privacy policy — the one thing App Store
  Connect *requires* a URL for — lives at `https://hausfold.co/perch/privacy`;
  the support and marketing URLs belong beside it.
  [hausfold/hausfold.co#1](https://github.com/hausfold/hausfold.co/pull/1) is
  deployed and **both URLs return 200 as of 2026-08-15**, so they are safe to
  paste. (Support URL reachability is a routine App Review rejection — re-check
  with `curl -sIL` before a submission if the site has moved since.)
  ⚠️ **Editing a listing field in App Store Connect is a manual act.** A commit
  to this file changes the copy of record, not the listing.
- **Keywords** (100 chars, comma-separated, no spaces):
  `shelf,airdrop,transfer,mac,send,share,files,drop,handoff,local,offline,nearby`

**Promotional text** (170, changeable without review):

> Share anything to Perch and it's waiting on your desktop shelf — over your own
> network, with no account and no cloud in the middle.

**Description**:

> Perch is the pocket half of the Mac shelf that catches your drags at the notch.
>
> Share a file, a photo, a link, or a scrap of text to Perch from any app. It's
> on your shelf immediately — even if your Mac is asleep, out of range, or you
> haven't paired one yet. The moment your Mac is back on the network, Perch hands
> it over and the tile lands on the shelf at the top of its screen, ready to drag
> anywhere.
>
> • Sharing always works. Delivery happens when it can, and Perch tells you the
>   truth about which state you're in — nothing is ever marked "sent" when it
>   isn't.
> • Your network, nobody else's. Perch finds your Mac over Bonjour and talks to
>   it directly — across your local network, or peer-to-peer when there isn't
>   one — end-to-end encrypted with a key the two devices agreed on when you
>   paired them. There is no relay, no server, and no account.
> • Pairing is deliberate. Scan the QR your Mac shows, check that the same six
>   digits appear on both screens, and approve it on the Mac. Unpairing is one
>   tap, and it deletes the key.
> • Nothing is collected. No analytics, no ads, no tracking, and your file names
>   never appear in a log.
>
> The Mac half is a separate app, downloaded free from hausfold.co/perch. Both
> halves are free, and always will be.

The listing is *named* `Perch Companion`, so never write "the companion" as if it
were something else — inside this listing that points at itself. Say "the Mac
half" or "the Perch desktop app" for the other end, and let the URL do the work.
(This warning previously read the same way about `Perch for Mac`, which had the
sharper version of the problem: it named the *other* app.)

**What's New** (per release): one honest line. If a release only touched the Mac
side, say so — a build with no phone-facing change is still a legitimate upload.

## Review notes — paste this into App Review Information

This is the part that decides whether a submission comes back. A reviewer opens
the app with no Mac on their desk; say so before they conclude it's broken.

**The 1.0 submission came back 2026-08-15 as Guideline 2.1 — Information
Needed**, not for a bug and not for anything in the binary: the Notes field held
only the four bullets this section used to carry, and Apple's standard 2.1
questionnaire asks seven specific things. Apple asked for all seven in Notes on
every future submission, so the copy of record below *is* those seven answers.
Paste it whole — shortening it back down is how the rejection happens again.
The screen recording Apple asks for as item 1 is
[its own section](#the-screen-recording-apple-asks-for); it is a human act and
cannot be pasted from here.

Four things to know before pasting it, three of them learned the annoying way:

- **The Notes field caps at 4,000 characters.** The block below is 3,950 — it
  fits with 50 to spare, so anything you add has to buy its space from
  something else. Check with
  `awk '/^## Review notes/{f=1} f&&/^>/{sub(/^> ?/,"");print} f&&/^Also fill in:/{exit}' docs/app-store.md | wc -m`.
- **It is a plain-text field**, which is why the block below carries no
  Markdown emphasis and uses ALL-CAPS headings. Keep it that way; `**bold**`
  pastes as literal asterisks in front of a reviewer.
- **Items 1 and 2 are the only two that go stale**, and both are statements of
  fact to Apple: item 1 promises an attached recording (attach it, or cut the
  word), and item 2 names the devices and OS versions *you actually ran*.
  Re-read those two every submission; paste 3–7 unchanged.
- **Everything else in the block was checked against the code** on 2026-08-15 —
  the UI strings, the framework list, the "no third-party SDK / no backend"
  claim, the crypto primitives. If you change what the app does, this text is
  part of the change.

**On saying "Simulator" out loud in item 2.** It is fine, and it is what the
answer says. Apple asks *what you tested on*, not that you own every device
they'll run it on; the "test on physical devices" line in the rejection is
about the platform you ship to, and the iPhone half covers that. The iPad half
is the same binary, the same universal SwiftUI layout, and the iPad screenshots
Apple requires come out of the Simulator anyway. What is *not* fine is naming a
device you never booted, which is why item 2 lists **one** iPad and not a
plausible-looking spread — every device in that answer is one that actually ran
the shelf. (Done 2026-08-16 on iPad Pro 13-inch (M5), iPadOS 26.5: empty state,
`On this iPad` section header, `22 bytes · waiting` row, presence row — all
correct.) If you add a device to the list, boot it first.

> Perch Companion is the iPhone/iPad half of Perch, a Mac shelf that lives at
> the notch. The Mac app is separate, distributed outside the App Store at
> https://hausfold.co/perch. This app does NOT need a Mac to be reviewed — see
> 4.
>
> 1. SCREEN RECORDING. Attached. Captured from a physical iPhone 15 Pro running
> iOS 27.0 mirrored to a Mac so both halves of the product are visible in one
> file. It begins at the Home Screen, launches the app, and shows the whole
> flow: the local-network and camera prompts, adding items with no Mac present,
> the Share extension, pairing, and delivery. It shows no registration, login,
> purchase or user-generated-content flow because the app has none; see the last
> paragraph.
>
> 2. TESTED ON. iPhone 15 Pro, iOS 27.0 (physical device) — every flow,
> including pairing and delivery over Wi-Fi. iPad Pro 13-inch (M5), iPadOS 26.5
> (Simulator) — layout and shelf behaviour. Mac side: macOS 26 running the
> Perch desktop app.
>
> 3. WHAT IT DOES, AND FOR WHOM. A shelf in your pocket. Share a file, photo,
> link or scrap of text to Perch from any app: it lands on the phone's shelf at
> once and waits until your Mac is reachable, then is handed over and appears on
> the Mac's shelf. For Mac owners who move small things between their own
> devices all day. AirDrop needs both devices awake and in range at once; cloud
> alternatives want an account and your file on a server. Perch decouples them —
> sharing always succeeds now, delivery happens when the Mac comes back — with
> no account and no server in the path.
>
> 4. SETUP AND ACCESS. No login, no credentials, no sample files, and no account
> of any kind, so there is no demo account to provide. On a clean install with
> no Mac at all: launch the app — the shelf reads "Nothing waiting", the correct
> empty state, not an error; tap Add (+) and choose From Photos, From Files or
> Paste, and the item appears under "On this iPhone" (or iPad) and survives
> relaunch; or share to Perch from Photos, Safari or Files and find it on the
> shelf. Each row reads "waiting" while no Mac is paired — nothing is ever
> labelled sent when it hasn't been. Swipe a row to remove it. Nothing is gated
> or paywalled. Pairing is optional, and the only part needing hardware we can't
> ship you: a Mac running Perch — on the same Wi-Fi, or simply nearby with Wi-Fi
> on, since the two can also talk peer-to-peer — shows a QR code, the phone
> scans it (or accepts the perch-pair:… string pasted as text), and both screens
> then display the same six digits, which you compare before approving on the
> Mac. Unpairing is one tap and deletes the key. We will gladly arrange a Mac
> running Perch for you to connect to — just ask and we'll respond same day.
>
> 5. EXTERNAL SERVICES, TOOLS AND PLATFORMS. None. No third-party SDKs, no
> analytics, no crash reporter, no ads, no authentication service, no payment
> processor, no AI service, no data provider, and no backend of ours. The only
> network peer is a Mac the user paired by hand, found over Bonjour
> (_perch._tcp) and connected directly over TCP — across the local network, or
> over Apple's peer-to-peer link when there is no network. Everything
> else is Apple's frameworks: SwiftUI, UIKit, PhotosUI, VisionKit for the QR
> scanner, Network.framework, and CryptoKit for the end-to-end encryption
> (X25519, HKDF, ChaCha20-Poly1305 — OS-provided standard algorithms, the basis
> of our export-compliance answer). No data leaves the two devices the user
> paired.
>
> 6. REGIONAL DIFFERENCES. None — the app behaves identically in every region
> and storefront. No geo-gating, no region-specific content or pricing, no
> remote configuration. English only.
>
> 7. REGULATED INDUSTRY OR PROTECTED THIRD-PARTY MATERIAL. Neither applies.
> Perch is a general-purpose productivity utility; all code, text and artwork
> are our own.
>
> FREE, AND PRIVATE. No in-app purchases, no subscriptions, nothing to restore.
> The Mac half is free too, and nothing is sold anywhere in Perch — there is no
> checkout to steer anyone towards. Nothing a user adds is ever visible to
> anyone else — no feed, no upload, no server, no other user — so there is no
> reporting or blocking mechanism.

Also fill in: no demo account needed, contact = `julien@hausfold.co`. (Not
`support@…` on either domain, and not the old `hi@` — the address moved
2026-08-22; the record of why is the workshop's `notes/go-to-market.md` §6,
which is the one place that owns it. **Send yourself a test message before you
type it in.** A review contact that bounces is the one field you cannot afford
to get wrong, and this doc cannot assert deliverability on your behalf —
verify, don't assume. ⚠️ App Store Connect is the one surface a commit cannot
move. The first submission (`v2026.08.07`) predates the address decision
entirely, so it never carried `hi@` — but if App Review Information has been
filled in at any point since, open it and check the field by hand.)

## The screen recording Apple asks for

Item 1 of the 2.1 questionnaire, and the only part of it a commit can't produce.
The rules Apple states: **a physical device** (not the Simulator), the **latest
OS**, and it must **start by launching the app** and show the typical flow
through the core features — including every permission prompt.

Perch has a problem no single-screen recording solves: half the product is a
Mac. Record both at once rather than filming a screen with another phone:

1. **Wire the iPhone to the Mac with a cable, unlock it, and tap Trust.** Then
   QuickTime Player → **File → New Movie Recording** → click the ⌄ next to the
   record button and pick the iPhone as the source. That mirrors the *device
   screen* into a window, camera preview and permission alerts included.

   ⚠️ **Check which iPhone entry you're picking.** Under *Camera* the menu
   lists **`Julien's iPhone 16 Camera`** — that is Continuity Camera, the
   phone's rear camera pointed at the room, and it is useless here. Screen
   mirroring is a *separate* entry with the bare device name and **no "Camera"
   suffix**, and it only appears while the phone is plugged in, awake, unlocked
   and trusted. If the only iPhone row says "Camera", the phone isn't actually
   connected — `xcrun xctrace list devices` will show it under **Devices
   Offline**, which is the same fact from the other side.
2. Put the Perch shelf and that QuickTime window on the same display, then
   record the **Mac's** screen (⇧⌘5). One file, both halves, the tile visibly
   landing at the notch.
3. Delete and reinstall the app on the phone first, and unpair it from the Mac.
   The permission prompts and the empty state only happen once, and they are
   precisely what Apple asked to see.

**If the cable route won't cooperate**, don't fight it — record the two halves
separately and attach both. iOS Control Center → Screen Recording gives an
unimpeachably "captured on a physical device" file (it lands in Photos; AirDrop
it over), and a plain ⇧⌘5 of the Mac during the same run covers the delivery
beat. Two files in Resolution Center is a weaker story than one, but a
Continuity-Camera video of a phone lying on a desk is a much weaker one.

The shot list, in order — this *is* the "typical user flow", and skipping the
permission prompts is what invites a second round:

| # | shot | why Apple wants it |
|---|---|---|
| 1 | Home Screen, tap the Perch icon | "must begin with launching the app" |
| 2 | The **local network** prompt → Allow | it fires here, at launch — see the warning below |
| 3 | Empty shelf: "Nothing waiting" | proves the app is usable with no Mac |
| 4 | ＋ → From Photos → pick one; ＋ → Paste (iOS asks "Allow Paste?") | core feature, standalone — and a third system alert to expect |
| 5 | Leave the app → Photos → Share → **Perch** → back to the shelf | the Share extension, the other core feature |
| 6 | Force-quit and relaunch; the items are still there | it's a shelf, not a send button |
| 7 | Tap **Pair a Mac** → Scan QR → the **camera** prompt → Allow → point at the Mac's QR | the second purpose string, in context |
| 8 | The same six digits on both screens; **approve on the Mac** | shows pairing is deliberate and mutually verified |
| 9 | The row leaves the phone's shelf, a **Delivered** receipt appears, and the tile lands on the Mac's shelf | the payoff, and the only shot that needs the Mac |
| 10 | **More → Unpair** | the teardown half, which reviewers look for |

⚠️ **The local-network prompt does not wait for "Pair a Mac".** Bonjour
browsing starts on every activation (`PerchMobileApp.swift:12` →
`MobileAppModel.becameActive()` → `startBrowsing()`), so on a fresh install the
alert lands over the launch, before the empty state is even legible. Film it
there; don't plan a later beat for it that will never come.

⚠️ **The phone has no confirm button.** Possession of the QR secret already
authenticated both ends, so the six digits exist to be *compared*, not tapped —
the phone displays them and waits, and the only approval control is on the Mac
(`MobileAppModel.swift:20`, `PairMacView.swift:51`). Say "compare, then approve
on the Mac"; a note promising a tap the reviewer can't find is worse than no
note.

There is no account registration, login, account deletion, purchase,
subscription, or user-generated-content flow to record — say that in the reply
rather than leaving Apple to wonder whether you skipped them.

Keep it under ~3 minutes and don't narrate; upload it in **Resolution Center**
(and attach the same file to App Review Information for the next submission, so
the question never gets asked twice).

## Known rejection risks, and the answer to each

| risk | answer |
|---|---|
| **2.1 Information Needed** — happened, 2026-08-15 | Apple's seven-question form. All seven are answered verbatim in [Review notes](#review-notes--paste-this-into-app-review-information); item 1 is the [screen recording](#the-screen-recording-apple-asks-for). Reply in Resolution Center *and* leave the same text in Notes — this build does not need rebuilding. |
| **5.2.5 Apple trademark in metadata** — happened, 2026-08-19 | "Mac" in the **subtitle**. Metadata-only fix: a subtitle with no Apple product name, same build, resubmit. Name, subtitle, icon **and promotional text** stay trademark-free; the description's referential compatibility line ("the Mac half is a separate app") and the `mac` keyword are a recorded decision to keep — see [The listing](#the-listing). |
| 2.1 "we couldn't test the core feature" | The review note above: the app stages and holds items with no Mac at all. |
| 4.2 "minimum functionality / it's a companion" | It is a functional shelf and a Share extension target on its own, not a remote control. Lead with that framing in the description too. |
| 5.1.1 local network permission | `NSLocalNetworkUsageDescription` and `NSBonjourServices` are declared. The prompt fires at first launch, not at Pair — browsing starts in `becameActive()` — so the purpose string has to make sense to someone who hasn't paired anything yet, and it does. |
| 5.1.1 camera permission | `NSCameraUsageDescription` is specific: it reads the pairing QR, nothing else. |
| 3.1.1 "steering to an outside purchase" | Nothing in the family is sold at all: no checkout exists to steer to. The description's one mention of the Mac app is a factual statement about a free companion product. Keep it that way. |
| Missing privacy manifest | Both bundles carry one; if you add a shared source file that touches a required-reason API, update **both**. |

## Screenshots

Required to submit: **6.9" iPhone** (1320×2868) and, since the app is universal
(`TARGETED_DEVICE_FAMILY = "1,2"`), **13" iPad** (2064×2752). Apple scales those
down for smaller devices.

Capture them from the simulator, from the states that actually sell it:

1. The shelf with three items waiting and the presence row showing a named Mac.
2. The pairing sheet mid-flow, with the six digits on screen.
3. The Share sheet, with Perch chosen and the "on your shelf" confirmation.
4. A delivered receipt list — the proof that it went somewhere.

```sh
xcodebuild -project Perch.xcodeproj -scheme PerchIOS -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -derivedDataPath DerivedData build
xcrun simctl boot 'iPhone 17 Pro Max'
xcrun simctl install booted DerivedData/Build/Products/Debug-iphonesimulator/PerchIOS.app
xcrun simctl launch booted com.hausfold.perch.ios
xcrun simctl io booted screenshot shot.png
```

`PERCH_AUTOSEND_TEXT` and `PERCH_PAIR_OFFER` (`PerchIOS/App/MobileAppModel.swift`)
populate a shelf without a real Mac, which is how you get a screenshot with
content in it. Don't ship a screenshot of an empty state.

⚠️ **`simctl launch` does not inherit your shell's environment.** Setting them
the obvious way silently does nothing and you get the empty state anyway —
they need the `SIMCTL_CHILD_` prefix, which is what passes a variable through
to the launched app:

```sh
SIMCTL_CHILD_PERCH_AUTOSEND_TEXT="Quarterly review notes" \
SIMCTL_CHILD_PERCH_PAIR_OFFER="Julien's MacBook Pro" \
  xcrun simctl launch booted com.hausfold.perch.ios
```

## Privacy label

App Store Connect → App Privacy → **Data Not Collected**. All of it. Perch has no
account, no analytics SDK, no crash reporter, and no network destination other
than a Mac the user paired by hand. The two required-reason API declarations live
in `PerchIOS/PrivacyInfo.xcprivacy` and `PerchShare/PrivacyInfo.xcprivacy`
(UserDefaults `1C8F.1`, file timestamps `C617.1`) — both are App Group container
access, and neither is data collection.

If you ever add a crash reporter, this section is a lie until you update it.

## Export compliance

The build declares `ITSAppUsesNonExemptEncryption = false` in
`PerchIOS/Config/Info.plist`, which is why uploads don't stop to ask.

The basis: every cryptographic operation on the wire — X25519, HKDF,
ChaCha20-Poly1305, SHA-256, HMAC — is CryptoKit's, i.e. standard algorithms
provided by the operating system. Perch implements no cryptography of its own;
`PerchWire/` is framing and key management over Apple's primitives. Nothing is
proprietary and nothing exceeds standard mass-market algorithms.

That is a legal statement, not a code comment. If you'd rather answer the
question per-build in App Store Connect, delete the key and Apple will ask on
every upload. If you ever hand-roll a cipher, this flips to `true` and you owe
Apple a compliance code.

## Re-identifying an already-submitted app

Written 2026-08-08, when the iOS half moved to `com.hausfold.perch.ios`. Keep
it: the ordering generalizes to any bundle-id change after a record exists, and
the trap it avoids is not obvious.

**Why it can't be an edit.** App Store Connect only offers the bundle-id
dropdown while *no build is associated with the record*. Perch's 1.0 has an
uploaded build and is Waiting for Review, so the id on that record is frozen. A
new record is the only path.

**The trap: the App Store name, not the bundle id.** Plain `Perch` was already
taken by someone else — which is why the original listing settled for `Perch for
Mac`. Two records cannot hold the same name at once, and a *deleted* app's name
does not reliably return to the pool on any schedule Apple documents. So the new
record has to be created while the old one still holds its name, and deleting
first to free it is a gamble on undocumented behaviour.

> **✅ How this was actually resolved, 2026-08-08 — and the lesson worth keeping.**
> The new record was created as **`Perch Companion`**, a name chosen to be kept
> rather than a placeholder to be traded back. That deletes the gamble outright:
> there is no name to reclaim, so the old record becomes ordinary cleanup that
> can happen whenever, and steps 6–7 below stop being load-bearing.
>
> **If you ever do this again, take the free name.** `Perch for Mac` was itself
> only a consolation prize for `Perch` being taken, and *for Mac* read oddly on
> an iPhone app. A forced rename is the cheapest moment to pick a better name —
> App Store names stay editable right up until release.

The ordering, as run. Steps 6–7 were kept because a future re-identification may
need the old name back:

1. 👤 **Remove the 1.0 submission from review.** The version page →
   *Remove from Review*. Free, reversible, and it stops Apple approving a build
   under the old id while you work. Do this before anything else.
2. 🤖 **Land the code change** — the four `PRODUCT_BUNDLE_IDENTIFIER` lines, both
   `.entitlements` files, and `MobileConfig.appGroupID`. Already done in the PR
   that added this section.
3. 👤 **Register the new identifiers** (Appendix steps 1–2): the two App IDs and
   App Group `group.com.hausfold.perch`. Xcode's automatic signing will register
   the App IDs on the first local archive, but it **will not invent the App
   Group** — create that by hand or every archive fails at signing.
4. 👤 **Create the new App Store Connect record.** ✅ Done — `Perch Companion`,
   bundle id `com.hausfold.perch.ios`, SKU `perch-ios-hausfold`. The name is
   permanent by choice, not temporary; see the box above.
5. 🤖 **Upload a build**: `gh workflow run testflight.yml`. No tag needed — the
   phone side ships on `workflow_dispatch`. Confirm it lands in TestFlight under
   the *new* record.
6. 👤 **Delete the old record** — `Perch for Mac`, Apple ID `6799010687`.
   Gated on the *new* record being **approved**, by decision, not merely on a
   green build; ✅ unblocked 2026-08-25. Not because the name was needed back —
   step 4 took a keeper name and settled that — but because deletion is
   permanent and a record you might still fall back to is worth keeping until
   the replacement is approved. Unreleased and free, it carries no
   purchases and — because step 4 took a keeper name — no name anyone is
   waiting on. Ordinary cleanup, no deadline. **Permanent**, so it only happens
   once and only after approval.

   The dead `com.nebelhaus.*` identifiers go with it, in this order: the record,
   then both `XC com nebelhaus perch ios*` App IDs, then `group.com.nebelhaus.perch`
   — the App Group refuses to delete while an App ID still enables it. No code,
   config or entitlement here references `nebelhaus` any more, so the only
   casualties are provisioning profiles for builds nobody can install. `perch-ios` stays a spent
   SKU either way; deleting the record does not free it.
7. 👤 *(only if you needed the old name back)* Rename the new record in App
   Information. Deleting the old record is what *allows* this but does not
   reliably free the name on any documented schedule, so expect to wait and
   retry. Not on the path taken here.
8. 👤 Re-enter the listing metadata against the new record, attach the build,
   and submit. **The metadata does not come with the bundle id** — description,
   keywords, screenshots, privacy label, export compliance and review notes are
   all per-record and start empty. [The listing](#the-listing) and
   [Review notes](#review-notes--paste-this-into-app-review-information) are the
   copy of record; paste from there.

**What this resets, and why that's fine.** Renaming the App Group changes
`kSecAttrAccessGroup`, so the phone's shelf, its outbox *and* its keychain
identity all become unreachable at once. That is exactly the invariant
`MobileConfig.deviceIdentity()` documents — *"identity and pairing survive
together or die together"* — and dying together is the safe half: the phone
mints a fresh `deviceID` and you re-pair, rather than presenting a new id while
holding an old key ("paired on screen, refused by the Mac"). No migration code
was warranted **then**: the app had never been released, so the only data at
risk was on your own test devices. ⚠️ **That escape hatch closed on
2026-08-25.** Moving the App Group or either side's Keychain *service* strings
now strands a real user's shelf, outbox and pairing, exactly as described above
— the same move today owes them a migration, or an honest release note saying
re-pair.

**The Mac app followed, separately.** It settled on `com.hausfold.perch` on
2026-08-08 — the bundle id *is* the sandbox container, so the sooner it settles
the less there is to strand. Same reasoning as above, same accepted cost —
empty shelf, Settings back to defaults, pairings broken, the local-network
prompt re-appears. What breaks pairing is the Keychain *service* strings moving
on both sides at once (`Perch/Mobile/PairedDeviceStore.swift` on the Mac,
`PerchMobileCore/MacPairingStore.swift` and `MobileConfig.swift` on the phone)
— not the container move; they die together, which is the safe half.

No migration shim, by decision. The Mac app *is* released (cask +
`nix/release.nix`, and the desktop enables it by default), so a live install's
shelf under the previous container was orphaned rather than migrated — the
upgrade came up empty, and the old container was the owner's to delete. It was
affordable because perch was days old and barely installed anywhere; the same
move today would want a migration, whatever the licensing story.

## Appendix: the one-time Apple side

Done once, by hand, in your login session — not in CI. They stay written down
because they come back: the Apple Distribution certificate expires annually, API
keys get rotated, and a new machine or a new app starts here again.

> ✅ **Steps 1–3 were re-run on 2026-08-08, under `com.hausfold.*`.** They had
> been completed once under the previous identifiers (first green upload
> `v2026.08.07`, submitted as *Perch for Mac* 1.0); the bundle-id move re-did
> them against new ones, and the listing is now **`Perch Companion`** —
> see [Re-identifying an already-submitted app](#re-identifying-an-already-submitted-app)
> for why the name changed with them. Steps 4–7 carried over untouched: **Team ID
> `88M28542LQ` and every certificate and API key are unchanged.**

1. **Register the two App IDs** (developer.apple.com → Identifiers), explicit,
   under team `88M28542LQ`:
   - `com.hausfold.perch.ios` — the app
   - `com.hausfold.perch.ios.share` — the Share extension
2. **Create the App Group** `group.com.hausfold.perch` and enable it on *both*
   IDs. This is the one capability the build genuinely needs; without it the app
   `fatalError`s on launch by design (`PerchMobileCore/MobileConfig.swift`).
   `-allowProvisioningUpdates` can mint profiles, but it will not invent this
   capability — get it right here or every archive fails at signing.
3. **Create the App Store Connect record**: New App → iOS, name `Perch
   Companion`, primary language English (U.S.), bundle ID
   `com.hausfold.perch.ios`, SKU `perch-ios-hausfold`.
   ⚠️ **If a record already holds the name you want, do not delete it to free
   the name** — take a name you'd keep instead, and see
   [Re-identifying an already-submitted app](#re-identifying-an-already-submitted-app).
   Taking a live record's name here simply
   fails, and deleting that record to free it is a bet on undocumented Apple
   behaviour.
   ⚠️ **A SKU can never be reused, even after the app that held it is deleted.**
   `perch-ios` is spent on the original record forever, which is why the hausfold
   one is `perch-ios-hausfold`. The SKU is private to your account and appears
   nowhere a user can see, so its ugliness is free.
4. **Mint an App Store Connect API key** (Users and Access → Integrations), role
   **Admin**, and download the `.p8` once — Apple will not show it twice. The
   notarization key already in the repo's secrets is scoped to notarization
   and *cannot* upload builds; this is a second key.

   Role picker is single-select, not a checkbox list. **App Manager** alone
   uploads builds but can't touch Certificates/Identifiers/Profiles, so
   `xcodebuild -allowProvisioningUpdates` fails on the first archive with
   `Cloud signing permission error` / `No profiles for '<bundle id>' were
   found` — it has nothing to create a provisioning profile with. **Developer**
   alone can manage profiles but its upload rights are unconfirmed. Admin
   covers both and is what this repo's key actually runs as; scoping it down
   further is unverified.
5. **Export the Apple Distribution certificate** as a `.p12` with a password.
6. **Add the five secrets** to this repo (Settings → Secrets → Actions):

   | secret | what |
   |---|---|
   | `IOS_DIST_CERT_P12` | `base64 -i AppleDistribution.p12` |
   | `IOS_DIST_CERT_PASSWORD` | the password on that `.p12` |
   | `ASC_KEY_P8` | `base64 -i AuthKey_XXXXXX.p8` |
   | `ASC_KEY_ID` | the key's Key ID |
   | `ASC_ISSUER_ID` | the team's issuer ID |

7. **Run the workflow once by hand** (Actions → testflight → Run workflow) before
   you ever depend on it during a release. The first run is where a missing
   capability or a mis-pasted key shows up.
