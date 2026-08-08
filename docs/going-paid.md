# Going paid — the runbook for the day you flip the switch

Everything described in [ADR 0004](architecture-decisions/0004-offline-license-and-a-capacity-cap.md)
is already in the app and already shipping. It is **inert**, and it stays inert
until one constant changes.

This file is the checklist for the day that constant changes. Read it top to
bottom before touching anything; the steps are ordered so that nothing
user-visible happens until the last one.

## The switch

```swift
// Perch/Platform/License.swift
static let productionPublicKeyBase64 = ""
```

While that string is empty, `LicenseStore.canSell` is false and therefore:

- `capacity` is `nil` — the shelf holds as many tiles as you like,
- the License section in Settings is not rendered at all,
- the `LicenseStrip` can never appear, because nothing can ever hit a cap.

Filling it in turns on the free-tier ceiling (`freeTierCapacity`, currently 2),
the License pane, and the purchase strip, **in every build cut afterwards, for
everyone**. There is no staged rollout and no per-user flag. That is the whole
point of it being one switch — but it also means the commit that fills it in is
the commit that takes the uncapped shelf away from every existing user, so it
must not land before the store can take their money.

## Pre-flight — all of these before the switch

- [ ] **Paddle (or LemonSqueezy) is live**, out of test mode, and a real card
      has completed a real purchase end to end.
- [ ] **The Worker issues and emails a license file** that this app accepts.
      Verify by importing the emailed file into a `bench try` build — do not
      take "the signature verifies in Node" as proof; the Swift verifier is the
      one that matters.
- [ ] **hausfold.co/perch sells.** The strip's `Get Perch` button and the
      Settings `Buy Perch — $19` link both open
      `https://hausfold.co/perch`, so that page needs a checkout on it, not a
      README in consumer voice with no button.
      ✅ *The page itself exists* as of 2026-08-08 — consumer voice, install,
      no price — along with `hausfold.co/terms` and `hausfold.co/refunds`,
      which is what Paddle's account review asks for. What it still lacks is
      the price block and the overlay, and those land together, in one commit,
      on the day this runbook is executed. (Was `nebelhaus.com/perch`, which
      still resolves and 301s once the site consolidates; hausfold is the
      seller, so the page it sells from is hausfold's.)
- [ ] **The FAQ covers fair source, the update year, seats, and refunds.** The
      first support email you get will be one of those four.
      *Three of the four are already written*: fair source and the update year
      are on `hausfold.co/terms`, refunds are their own page. **Seats is the
      gap** — the terms say a seat is a person, and nothing says how a buyer
      picks a seat count at checkout.
- [ ] **`support@hausfold.co` exists** and you've decided what SLA you'll
      actually honour. Paying customers change the tone of the issue tracker.
      Until it does, every page on the site says `hi@hausfold.co`, which
      routes today — moving them is a find-and-replace, but do it *before* the
      first receipt goes out, not after. (Was `support@nebelhaus.com`; people
      buy a hausfold product, and hausfold is the name they'll have seen on the
      receipt — `notes/go-to-market.md` §6 in the workshop.)
- [ ] **The private key is backed up offline.** If it is lost, no new license
      can ever be issued and every existing one still works forever — a
      uniquely annoying failure mode.

## Minting the keypair

Do this once, on your own machine, not in CI and not in a PR.

```sh
# The private half. Guard this like a signing certificate.
openssl genpkey -algorithm ed25519 -out perch-license-signing.pem

# The public half, raw 32 bytes, base64 — this is what goes in the app.
# (An Ed25519 SPKI DER is 44 bytes; the last 32 are the raw key.)
openssl pkey -in perch-license-signing.pem -pubout -outform DER | tail -c 32 | base64
```

- The base64 from the second command goes into `productionPublicKeyBase64`.
  `LicenseTests.testTheProductionKeyIsEitherAbsentOrAValidEd25519Key` flips from
  "must be empty" to "must be 32 valid bytes" automatically — if you paste
  something malformed, the suite says so.
- The PEM goes into the Worker as a secret (`wrangler secret put`) **and** onto
  offline media. Two copies, neither of them in a repo.
- Rotating later is possible but ugly: every license already issued was signed
  by the old key, so a rotation means either re-issuing every license or
  carrying both keys. Prefer not to.

## The signing contract

The app verifies an Ed25519 signature over a **canonical fixed-order
`key=value` payload**, not over the JSON. Get this wrong by one byte and every
license you issue is rejected by an app that gives no useful error.

```
product=perch
email=buyer@example.com
purchased=2026-08-03
seats=3
```

- Exactly four lines, exactly that order, `\n` separators, **no trailing
  newline**.
- `purchased` is `YYYY-MM-DD`, resolved as midnight UTC by the app.
- `seats` is the bare integer, no quotes.
- The `sig` field is base64 of the raw 64-byte signature and is *not* part of
  what is signed.

`License.canonicalPayload` in `Perch/Platform/License.swift` is the definition,
and `LicenseTests.testCanonicalPayloadIsTheExactBytesBothEndsAgreeOn` pins it
literally. If you ever change the format, every license already sitting in a
customer's inbox stops working — so don't; add fields to the JSON that the
payload ignores instead.

Reference signer, in Workers' WebCrypto:

```js
const payload = new TextEncoder().encode(
  `product=perch\nemail=${email}\npurchased=${purchased}\nseats=${seats}`
)
const key = await crypto.subtle.importKey("pkcs8", pkcs8Bytes, { name: "Ed25519" }, false, ["sign"])
const sig = new Uint8Array(await crypto.subtle.sign("Ed25519", key, payload))

const license = {
  product: "perch",
  email,
  purchased,
  seats,
  sig: btoa(String.fromCharCode(...sig)),
}
// Email this as `<something>.nebelhauslicense` — the extension is what lets it
// be activated by dropping it on the shelf.
```

## The flip

1. Paste the public key into `productionPublicKeyBase64`.
2. Run the suite. Confirm the production-key test now asserts 32 valid bytes.
3. `bench try` the branch and actually feel it:
   - drop three files on an unlicensed shelf → two land, the strip appears,
   - `Get Perch` opens the store page,
   - drop the emailed `.nebelhauslicense` on the shelf → it activates and is
     not staged as a tile,
   - Settings shows the email, the seat count, and the covered-through month,
   - `Remove` returns you to the free tier.
4. PR, merge, then `bench release perch` as normal. **The release pipeline is
   not part of this change** — if you find yourself editing
   `.github/workflows/release.yml`, the paywall is leaking out of the binary.
   Stop and re-read the principle at the top of the plan.
5. Announce. The fair-source angle is the story for HN/lobste.rs; the notch
   angle is the story for the Mac press that covered NotchNook.

## After

- **Only ever loosen the free tier.** `freeTierCapacity` is a product knob;
  raising it is a gift, lowering it reads as a rug-pull to everyone who already
  organised their habits around the old number.
- **Old builds keep working forever.** Coverage is a comparison of two dates, so
  nothing the app does can expire a build a license already covered. Keep it
  that way.
- **The privacy sentence stays a contract.** Any future licensing feature that
  wants a network call loses to it. Offline, forever.
