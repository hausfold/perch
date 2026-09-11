# Listing the companion — the App Store runbook

The Mac app ships as a notarized ZIP through the cask and the flake. The
**iPhone/iPad companion can only ship through the App Store**: a store record
with copy and screenshots, a privacy label, an export-compliance answer, and a
human review. `.github/workflows/testflight.yml` does the machine half;
everything here is the half only a person with the account can do.

The record is `Perch Companion`, Apple ID **`6799443735`**, bundle id
`com.hausfold.perch.ios`, SKU `perch-ios-hausfold`, free, iOS 18+. The Apple ID
is the durable handle —
[apps.apple.com/app/id6799443735](https://apps.apple.com/app/id6799443735)
redirects forever, while the slug App Store Connect shows you changes with the
app's name. Both halves are free and carry no purchase, no IAP and no account,
which is what keeps the review simple: nothing to restore, no subscription
screens, no receipts.

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

Nothing auto-submits, so a Mac-only release rides the same tag harmlessly — it
just leaves a build in TestFlight that nobody promotes. Each phone release is:
tag → build lands → **new version record** (`+` next to iOS App) → attach the
build → one honest What's New line → Submit.

`VERSION` `2026.08.06` becomes marketing version `2026.8.6` (App Store Connect
refuses leading zeros); the build number is `run_number × 10 + (attempt − 1)`.
The attempt is folded in because a *re-run* keeps the run number and Apple
rejects a build number it has seen for that marketing version — so a failed
upload is retryable with the Re-run button, no new tag. A same-day re-cut
(`2026.08.06-2`) uploads as the *same* marketing version with a higher build:
fine for TestFlight, but a store release of it needs a new VERSION day.

Phone-only builds need no tag: `gh workflow run testflight.yml` (`--ref
<branch>` to run it off a branch). Every run's summary prints the version, the
build number, and the two clicks still owed.

## After you submit

- **Waiting for Review → In Review** is typically hours to a day, and the
  TestFlight build is installable on your own devices throughout.
- **A reviewer question** arrives in **Resolution Center**, not by email thread —
  reply there. The offer in item 4 to arrange a paired Mac is genuine, so honor
  it if they take it.
- **Rejection is not a re-upload.** Most rejections are metadata or explanation,
  fixed in App Store Connect and resubmitted with the same build. Only rebuild
  when the *binary* has to change.
- **Editing copy mid-review.** Description, keywords and screenshots are frozen
  while a version is In Review; changing them means pulling the submission and
  going back into the queue. **Promotional text** (170 chars) is the exception —
  it changes any time, no review, so prefer it for anything urgent.
- **Approved.** Release a listing manually the first time it goes live, so it
  happens while you're watching; after that, phased release (a 7-day ramp) is
  worth leaving on.

## The listing

The copy of record. What's in App Store Connect should match what's here; when
they disagree, fix it here first and paste. Keep it honest about what the app is:
a companion, not a standalone.

- **Name**: `Perch Companion` — plain `Perch` is taken by another developer, and
  in-app branding stays `Perch`
- **Subtitle** (30 max): `Send it to your desktop shelf`
  **Name, subtitle, icon and promotional text carry no Apple product names** —
  "desktop", not "Mac" — because **5.2.5** rejects an Apple trademark in metadata
  that renders on the product page, and it has here. The description keeps "the
  Mac half is a separate app": there it is a referential compatibility statement,
  which the trademark guidelines allow. **Keywords deliberately keep `mac`** —
  they aren't displayed, and it is how people search for this. If 5.2.5 comes
  back anyway, that keyword is the next to strip.
- **Category**: Productivity (secondary: Utilities)
- **Age rating**: 4+ — no user content shown to other users, no web view, no ads
- **Support URL** and **Marketing URL**: `https://hausfold.co/docs/perch/`
- **Privacy policy URL**: `https://hausfold.co/perch/privacy/` — the one URL App
  Store Connect *requires*, and the only one of the three still under
  `hausfold.co/perch`, which otherwise redirects to the docs tree. An unreachable
  support URL is a routine rejection: `curl -sIL` all three before a submission
  if the site has moved.
  **Paste the trailing slash** — into the two URL *fields*. The Description and
  the review notes name the URL in running prose, where bare reads better and
  the field is plain text anyway — the bare form there is deliberate.
  **Read the status code, not the hop count.** Slashless, each of the three
  answers exactly one hop, so the count separates nothing. A **307** is
  Cloudflare's `auto-trailing-slash` normalising a path — what `/docs/perch` and
  `/perch/privacy` answer, harmless, and what the slashed form skips. A **301**
  is a page that moved, and `/perch` and `/perch/` → `/docs/perch/` are the only
  two here. Privacy sits outside them on purpose: hausfold.co's `_redirects`
  matches those two paths exactly, above a ⚠️ never to widen them to `/perch/*`,
  which would swallow the one URL App Store Connect requires.
  ⚠️ **Editing a listing field is a manual act.** A commit here changes the copy
  of record, not the listing — and the two drift on *facts*, not just URLs, so
  the pre-submission check is a full diff of the live Description against this
  file, not a glance at the URL inside it. Three things a paraphrase loses,
  each load-bearing: that pairing needs someone to **approve it on the Mac**
  (`Perch/Mobile/MobilePairingWindow.swift` — no Mac window, no pairing), and
  dropping it leaves a reviewer scanning a QR and concluding the app is broken;
  that delivery also works **peer-to-peer with no network** (`includePeerToPeer`
  across `PerchWire/Wire/`), which the review notes claim and the listing should
  not undersell; and the closing line, where "the companion" reads as this
  listing rather than the Mac app — the rule below.
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
> The Mac half is a separate app, downloaded free from hausfold.co/docs/perch.
> Both halves are free, and always will be.

The listing is *named* `Perch Companion`, so never write "the companion" inside
it as if it were something else — there it points at itself. Say "the Mac half"
or "the Perch desktop app" for the other end, and let the URL do the work.

**What's New** (per release): one honest line. If a release only touched the Mac
side, say so — a build with no phone-facing change is still a legitimate upload.

## Review notes — paste this into App Review Information

This is the part that decides whether a submission comes back: a reviewer opens
the app with no Mac on their desk, so say so before they conclude it's broken.
Apple's 2.1 questionnaire asks seven specific things, in Notes, on every
submission — so the block below *is* those seven answers. Paste it whole;
shortening it to a summary is what earns a 2.1 Information Needed, and has.
Item 1's recording is [its own section](#the-screen-recording-apple-asks-for).

- **The Notes field caps at 4,000 characters** and the block below is 3,909, so
  anything you add has to buy its space from something else. Measure, don't
  assume — it has been over:
  `awk '/^## Review notes/{f=1} f&&/^>/{sub(/^> ?/,"");print} f&&/^Also fill in:/{exit}' docs/app-store.md | wc -m`.
- **It is a plain-text field**, which is why the block carries no Markdown
  emphasis and uses ALL-CAPS headings. `**bold**` pastes as literal asterisks in
  front of a reviewer.
- **Items 1 and 2 are the only two that go stale.** Item 1 promises an attached
  recording (attach it, or cut the word); item 2 names the devices and OS
  versions *you actually ran* — naming a device you never booted is the one way
  this block can lie. Saying "Simulator" out loud is fine, and item 2 lists
  **one** iPad rather than a plausible-looking spread because one is what was
  booted (iPad Pro 13-inch (M5), iPadOS 26.5, on 2026-08-16). Paste 3–7
  unchanged.
- **The rest is a claim about the code** — the UI strings, the framework list,
  the "no third-party SDK / no backend" claim, the crypto primitives. If you
  change what the app does, this text is part of the change.

> Perch Companion is the iPhone/iPad half of Perch, a Mac shelf that lives at
> the notch. The Mac app is separate, distributed outside the App Store at
> https://hausfold.co/docs/perch. This app does NOT need a Mac to be reviewed —
> see 4.
>
> 1. SCREEN RECORDING. Attached. Captured from a physical iPhone 15 Pro running
> iOS 27.0 mirrored to a Mac so both halves of the product are visible in one
> file. It begins at the Home Screen, launches the app, and shows the whole
> flow: the local-network and camera prompts, adding items with no Mac present,
> the Share extension, pairing, and delivery. It shows no registration, login,
> purchase or user-generated-content flow because the app has none; see 4.
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
> or paywalled, and nothing a user adds is ever visible to anyone else — no feed,
> no upload, no server, no other user — so there is no reporting or blocking
> mechanism. Pairing is optional, and the only part needing hardware we can't
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

Also fill in: no demo account needed, contact = `julien@hausfold.co` (not
`support@…` on either domain). **Send yourself a test message before you type it
in** — a review contact that bounces is the one field you cannot afford to get
wrong, and this doc cannot assert deliverability on your behalf.

## The screen recording Apple asks for

Item 1 of the 2.1 questionnaire, and the only part a commit can't produce.
Apple's rules: **a physical device** (not the Simulator), the **latest OS**, and
it must **start by launching the app** and show the typical flow through the core
features, every permission prompt included.

Half the product is a Mac, which no single-screen recording covers. Wire the
iPhone to the Mac, unlock it, tap Trust, then QuickTime Player → **File → New
Movie Recording** → the ⌄ next to the record button → the iPhone: that mirrors
the *device screen* into a window, camera preview and permission alerts
included. Put it beside the shelf on one display and ⇧⌘5 the **Mac's** screen —
one file, both halves, the tile visibly landing at the notch. Delete, reinstall
and unpair first; the permission prompts and the empty state happen once, and
they are precisely what Apple asked to see.

⚠️ **Check which iPhone entry you're picking.** The entry ending in **`Camera`**
is Continuity Camera, the rear camera pointed at the room. Screen mirroring is a
*separate* entry with the bare device name and **no "Camera" suffix**, and it
appears only while the phone is plugged in, awake, unlocked and trusted. If the
only iPhone row says "Camera", the phone isn't connected — `xcrun xctrace list
devices` shows it under **Devices Offline**, the same fact from the other side.

**If the cable won't cooperate**, record the halves separately and attach both:
iOS Control Center → Screen Recording is unimpeachably "captured on a physical
device", and a ⇧⌘5 of the Mac during the same run covers delivery. Two files is
a weaker story than one, but a Continuity-Camera video of a phone on a desk is a
much weaker one.

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
on the Mac"; a note promising a tap the reviewer can't find is worse than none.

There is no account registration, login, account deletion, purchase,
subscription or user-generated-content flow to record — say that in the reply
rather than leaving Apple to wonder whether you skipped them. Under ~3 minutes,
no narration, uploaded in **Resolution Center**, then attached to App Review
Information so the question isn't asked twice.

## Known rejection risks, and the answer to each

| risk | answer |
|---|---|
| **2.1 Information Needed** — has happened | All seven answers are in [Review notes](#review-notes--paste-this-into-app-review-information); item 1 is the [screen recording](#the-screen-recording-apple-asks-for). Reply in Resolution Center *and* leave the same text in Notes. No rebuild. |
| **5.2.5 Apple trademark in metadata** — has happened | "Mac" in the **subtitle**. Metadata-only fix, same build. Name, subtitle, icon and promotional text stay trademark-free; the description's referential line and the `mac` keyword are a recorded decision to keep — [The listing](#the-listing). |
| 2.1 "we couldn't test the core feature" | Item 4: the app stages and holds items with no Mac at all. |
| 4.2 "minimum functionality / it's a companion" | It is a functional shelf and a Share extension target on its own, not a remote control. Lead with that framing in the description too. |
| 5.1.1 local network permission | `NSLocalNetworkUsageDescription` and `NSBonjourServices` are declared. The prompt fires at first launch, not at Pair, so the purpose string has to make sense to someone who hasn't paired anything yet — and it does. |
| 5.1.1 camera permission | `NSCameraUsageDescription` is specific: it reads the pairing QR, nothing else. |
| 3.1.1 "steering to an outside purchase" | Nothing in the family is sold at all, so no checkout exists to steer to. The description's one mention of the Mac app is a factual statement about a free companion product. Keep it that way. |
| Missing privacy manifest | Both bundles carry one; if you add a shared source file that touches a required-reason API, update **both**. |

## Screenshots

Required to submit: **6.9" iPhone** (1320×2868) and, since the app is universal
(`TARGETED_DEVICE_FAMILY = "1,2"`), **13" iPad** (2064×2752). Apple scales those
down for smaller devices. Capture from the simulator, from the states that sell
it: the shelf with items waiting and a named Mac on the presence row; the
pairing sheet with the six digits up; the Share sheet with Perch chosen; a
delivered receipt list.

```sh
xcodebuild -project Perch.xcodeproj -scheme PerchIOS -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -derivedDataPath DerivedData build
xcrun simctl boot 'iPhone 17 Pro Max'
xcrun simctl install booted DerivedData/Build/Products/Debug-iphonesimulator/PerchIOS.app
```

`PERCH_AUTOSEND_TEXT` and `PERCH_PAIR_OFFER` (`PerchIOS/App/MobileAppModel.swift`)
populate a shelf without a real Mac — don't ship a screenshot of an empty state.
⚠️ **`simctl launch` does not inherit your shell's environment**, so setting them
the obvious way silently does nothing and you get the empty state anyway. They
need the `SIMCTL_CHILD_` prefix:

```sh
SIMCTL_CHILD_PERCH_AUTOSEND_TEXT="Quarterly review notes" \
SIMCTL_CHILD_PERCH_PAIR_OFFER="Julien's MacBook Pro" \
  xcrun simctl launch booted com.hausfold.perch.ios
xcrun simctl io booted screenshot shot.png
```

## Privacy label

App Store Connect → App Privacy → **Data Not Collected**. All of it. Perch has no
account, no analytics SDK, no crash reporter, and no network destination other
than a Mac the user paired by hand. The two required-reason API declarations live
in `PerchIOS/PrivacyInfo.xcprivacy` and `PerchShare/PrivacyInfo.xcprivacy`
(UserDefaults `1C8F.1`, file timestamps `C617.1`) — both are App Group container
access, and neither is data collection. If you ever add a crash reporter, this
section is a lie until you update it.

## Export compliance

The build declares `ITSAppUsesNonExemptEncryption = false` in
`PerchIOS/Config/Info.plist`, which is why uploads don't stop to ask. The basis:
every cryptographic operation on the wire — X25519, HKDF, ChaCha20-Poly1305,
SHA-256, HMAC — is CryptoKit's, i.e. standard algorithms provided by the
operating system. Perch implements no cryptography of its own; `PerchWire/` is
framing and key management over Apple's primitives.

That is a legal statement, not a code comment. Delete the key and Apple asks on
every upload instead; hand-roll a cipher and it flips to `true` and you owe Apple
a compliance code.

## Changing the bundle id, the name or the App Group

Three facts decide how this goes, and none of them is obvious from the UI.

- **A record's bundle id freezes the moment a build is attached to it.** App
  Store Connect offers the dropdown only while no build is associated, so a
  change after that means a *new record*, never an edit — and the metadata does
  not come with it. Description, keywords, screenshots, privacy label, export
  compliance and review notes are per-record and start empty; paste them from
  [The listing](#the-listing) and
  [Review notes](#review-notes--paste-this-into-app-review-information).
- **Take a name you'd keep.** Two records cannot hold the same name at once, and
  a deleted app's name does not reliably return to the pool on any schedule Apple
  documents — so never delete a record to free its name, and never plan on
  trading one back. App Store names stay editable right up until release, which
  makes a forced rename the cheapest moment to pick a better one.
- **A SKU can never be reused**, even after the record that held it is deleted.
  `perch-ios` is spent forever, which is why this one is `perch-ios-hausfold`.
  The SKU is private to your account and shows nowhere a user can see, so its
  ugliness is free.
- **A record Apple won't delete is an acceptable resting state.** Removal is
  refused in Ready for Review, Waiting for Review, In Review, Metadata Rejected
  and Rejected, and a Rejected version is read-only — its Build section renders
  with no remove control, so you cannot unstick it by dropping the build.
  Support (Contact Us → App Store Connect → App Management) is the only path,
  and naming the record that superseded it reads as tidy-up rather than a
  decision. Meanwhile a dead record and a dead App ID cost nothing, expire
  never, and cannot collide with the `com.hausfold.*` family. Teardown order is
  set by two dependencies: an **App ID** can't be removed while a record points
  at it, and an **App Group** can't be removed while an App ID enables it — but
  un-ticking App Groups on a stuck App ID is allowed, which frees the group
  without waiting. hausfold/ops' `todo/` tracks the one open case.

⚠️ **Moving the App Group, or either side's Keychain *service* strings, strands
a real user's shelf.** Renaming the App Group changes `kSecAttrAccessGroup`, so
the phone's shelf, its outbox *and* its keychain identity go unreachable at once
— exactly the invariant `MobileConfig.deviceIdentity()` documents, *"identity and
pairing survive together or die together"*. Dying together is the safe half: the
phone mints a fresh `deviceID` and you re-pair, rather than presenting a new id
while holding an old key ("paired on screen, refused by the Mac"). On the Mac the
bundle id *is* the sandbox container, but what breaks pairing is the Keychain
service strings moving on both sides at once
(`Perch/Mobile/PairedDeviceStore.swift`, `PerchMobileCore/MacPairingStore.swift`
and `MobileConfig.swift`). Both halves are released, so any of this now owes a
migration, or an honest release note saying re-pair.

The order, if you do it: pull any live submission from review first (the version
page → *Remove from Review*, free and reversible), land the code change — the
`PERCH_BUNDLE_ID` override (never `PRODUCT_BUNDLE_IDENTIFIER=`, per AGENTS.md §
Build, since all twelve lines derive from it), the App Group in all three
`.entitlements` files, and `MobileConfig.appGroupID`; the Mac's own id is
`com.hausfold.perch` — register the identifiers by hand (Appendix 1–2;
automatic signing registers App IDs on
the first local archive but **will not invent the App Group**), create the
record, then `gh workflow run testflight.yml` and confirm the build lands under
it.

## Appendix: the one-time Apple side

Done once, by hand, in your login session — not in CI. Written down because they
come back: the Apple Distribution certificate expires annually, API keys get
rotated, and a new machine or a new app starts here again. Team ID `88M28542LQ`.

1. **Register the two App IDs** (developer.apple.com → Identifiers), explicit:
   `com.hausfold.perch.ios` for the app, `com.hausfold.perch.ios.share` for the
   Share extension.
2. **Create the App Group** `group.com.hausfold.perch` and enable it on *both*
   IDs. It is the one capability the build genuinely needs — without it the app
   `fatalError`s on launch by design (`PerchMobileCore/MobileConfig.swift`) — and
   `-allowProvisioningUpdates` mints profiles but will not invent it. Get it
   right here or every archive fails at signing.
3. **Create the App Store Connect record**: New App → iOS, name `Perch
   Companion`, primary language English (U.S.), bundle ID
   `com.hausfold.perch.ios`, SKU `perch-ios-hausfold`. If a record already holds
   the name you want, see
   [Changing the bundle id, the name or the App Group](#changing-the-bundle-id-the-name-or-the-app-group).
4. **Mint an App Store Connect API key** (Users and Access → Integrations), role
   **Admin**, and download the `.p8` once — Apple will not show it twice. The
   notarization key already in this repo's secrets *cannot* upload builds; this
   is a second key. The role picker is single-select, and Admin is the only role
   verified to cover both halves: **App Manager** uploads builds but can't touch
   Certificates/Identifiers/Profiles, so `-allowProvisioningUpdates` fails on the
   first archive with `Cloud signing permission error` / `No profiles for
   '<bundle id>' were found`.
5. **Export the Apple Distribution certificate** as a `.p12` with a password.
6. **Add the five secrets** (Settings → Secrets → Actions):

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
