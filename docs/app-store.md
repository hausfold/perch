# Listing the companion — the App Store runbook

The Mac app ships as a Developer-ID-signed, notarized ZIP through the cask and
the flake (`release.yml`). The **iPhone/iPad companion can only ship through the
App Store**, which is a different animal: a store record with copy and
screenshots, a privacy label, an export-compliance answer, and a human review.

This file is that path, top to bottom. `.github/workflows/testflight.yml` does
the machine half; everything below is the half only a person with the account
can do. Do the one-time section once, then live in "the shipping loop".

The companion is **free**, and stays free. Perch's money is the Mac app
([`going-paid.md`](going-paid.md), ADR 0004); the phone is the second half of a
product you already bought, so it carries no purchase, no IAP, and no account.
That also keeps the review simple: nothing to restore, no subscription screens,
no receipts.

## One-time: the Apple side

Everything here is done once, by hand, in your login session — not in CI. **All
seven steps are already done** for `com.nebelhaus.perch.ios` (first green upload:
`v2026.08.07`); they stay written down for the next machine, the next key
rotation, and the next app.

1. **Register the two App IDs** (developer.apple.com → Identifiers), explicit,
   under team `88M28542LQ`:
   - `com.nebelhaus.perch.ios` — the app
   - `com.nebelhaus.perch.ios.share` — the Share extension
2. **Create the App Group** `group.com.nebelhaus.perch` and enable it on *both*
   IDs. This is the one capability the build genuinely needs; without it the app
   `fatalError`s on launch by design (`PerchMobileCore/MobileConfig.swift`).
   `-allowProvisioningUpdates` can mint profiles, but it will not invent this
   capability — get it right here or every archive fails at signing.
3. **Create the App Store Connect record**: New App → iOS, name `Perch for Mac`
   (plain `Perch` is taken — see the listing section), primary language English
   (U.S.), bundle ID `com.nebelhaus.perch.ios`, SKU `perch-ios`.
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

## The listing

Draft copy, ready to paste. Keep it honest about what the app is: a companion,
not a standalone.

- **Name**: `Perch for Mac` (App Store Connect rejected plain `Perch` as taken; bundle ID, SKU, and in-app branding stay `Perch`/`perch-ios`)
- **Subtitle** (30 max): `Send it to your Mac's shelf`
- **Category**: Productivity (secondary: Utilities)
- **Age rating**: 4+ — no user content shown to other users, no web view, no ads
- **Support URL**: `https://nebelhaus.com/perch`
- **Marketing URL**: `https://nebelhaus.com/perch`
- **Keywords** (100 chars, comma-separated, no spaces):
  `shelf,airdrop,transfer,mac,send,share,files,drop,handoff,local,offline,nearby`

**Promotional text** (170, changeable without review):

> Share anything to Perch and it's waiting on your Mac's shelf — over your own
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
> • Your network, nobody else's. Perch finds your Mac over Bonjour on the local
>   network and talks to it directly, end-to-end encrypted with a key the two
>   devices agreed on when you paired them. There is no relay, no server, and no
>   account.
> • Pairing is deliberate. Scan the QR your Mac shows, then confirm the same six
>   digits on both screens. Unpairing is one tap, and it deletes the key.
> • Nothing is collected. No analytics, no ads, no tracking, and your file names
>   never appear in a log.
>
> The Mac half is a separate app, downloaded from nebelhaus.com/perch. This
> companion is free and always will be.

The listing is *named* `Perch for Mac`, so never write "Perch for Mac is a
separate app" in the copy — inside this listing that sentence points at itself.
Say "the Mac half" or "the Perch desktop app" and let the URL do the work.

**What's New** (per release): one honest line. If a release only touched the Mac
side, say so — a build with no phone-facing change is still a legitimate upload.

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
xcrun simctl launch booted com.nebelhaus.perch.ios
xcrun simctl io booted screenshot shot.png
```

`PERCH_AUTOSEND_TEXT` and `PERCH_PAIR_OFFER` (`PerchIOS/App/MobileAppModel.swift`)
populate a shelf without a real Mac, which is how you get a screenshot with
content in it. Don't ship a screenshot of an empty state.

## Review notes — paste this into App Review Information

This is the part that decides whether the first submission comes back. A reviewer
opens the app with no Mac on their desk; say so before they conclude it's broken.

> This app is the iPhone/iPad companion to the Perch desktop app — a separate
> Mac application distributed outside the App Store at
> https://nebelhaus.com/perch. It does not require the Mac app to be reviewed:
>
> • The app is fully usable on its own. Tap + to add a file or a photo, or share
>   anything to Perch from another app: it is staged on the phone's shelf
>   immediately and stays there. "Waiting" is the honest, expected state when no
>   Mac is paired — no account or sign-in is involved at any point.
> • Pairing (optional) requires a Mac running Perch on the same Wi-Fi. The Mac
>   shows a QR code; the phone scans it or takes a pasted code, and both screens
>   confirm the same six digits. If you'd like to test this half, we're happy to
>   arrange it — please ask via Resolution Center.
> • Networking is local only: Bonjour discovery of `_perch._tcp` plus a direct
>   TCP connection to the paired Mac, end-to-end encrypted. The app contacts no
>   server of ours and no third party.
> • The app is free with no in-app purchases. The Mac app is paid, sold on our
>   website, and never mentioned as a purchase inside this app.

Also fill in: no demo account needed, contact = `support@nebelhaus.com`.

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
  reply there. The review-note bullets above are the answers to the likely ones;
  the offer to arrange a paired Mac is genuine, so honor it if they take it.
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

Then each later release is: tag → build lands in TestFlight → **new version
record** in App Store Connect (`+` next to iOS App) → attach the build → one
honest What's New line → Submit. A Mac-only release skips all of that and just
leaves an unpromoted build behind.

## Known rejection risks, and the answer to each

| risk | answer |
|---|---|
| 2.1 "we couldn't test the core feature" | The review note above: the app stages and holds items with no Mac at all. |
| 4.2 "minimum functionality / it's a companion" | It is a functional shelf and a Share extension target on its own, not a remote control. Lead with that framing in the description too. |
| 5.1.1 local network permission | `NSLocalNetworkUsageDescription` and `NSBonjourServices` are declared, and the prompt only appears when the user taps Pair. |
| 5.1.1 camera permission | `NSCameraUsageDescription` is specific: it reads the pairing QR, nothing else. |
| 3.1.1 "steering to an outside purchase" | The app never sells anything or links to a checkout. The description's one mention of the Mac app is a factual statement about a separate product, not a purchase link. Keep it that way. |
| Missing privacy manifest | Both bundles carry one; if you add a shared source file that touches a required-reason API, update **both**. |
