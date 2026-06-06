# Yve — iOS build & ship guide

End-to-end iOS pipeline: from "code is prepped" (where we are now) to
"app is in TestFlight". You only need to do most of this once.

Total time: **~3-4 hours** including Apple Developer portal work,
Xcode signing, first TestFlight upload. Subsequent builds: ~5 min.

---

## Prerequisites

| | What |
|---|---|
| Apple Developer Program membership | $99/year. Pending in your case (~2 business days). Without this, no TestFlight, no App Store, no Apple Sign In, no Universal Links. |
| Mac | Required. Xcode is macOS-only. |
| Xcode | Latest stable. Open Mac App Store → Xcode → Install. ~12GB download. |
| CocoaPods | `sudo gem install cocoapods` on Mac. Used to install iOS plugin dependencies. |
| Real iPhone | For testing camera, mic, push, App Links. Simulator handles most other things. |

---

## 1. Open the project on your Mac

```bash
# On your Mac, in the repo root:
cd mobile
flutter pub get
cd ios
pod install
cd ..
open ios/Runner.xcworkspace   # NOTE: .xcworkspace, NOT .xcodeproj
```

Xcode opens with the Yve project loaded.

---

## 2. Apple Developer portal setup (one-time)

Once your Developer membership activates, do these in
[developer.apple.com](https://developer.apple.com):

### 2a. Register the App ID

**Identifiers → + → App IDs → App → Continue:**

| Field | Value |
|---|---|
| Description | `Yve` |
| Bundle ID | `io.getyve.yve` (explicit, matches Android exactly) |

**Capabilities to enable:**
- ✅ Sign In with Apple
- ✅ Associated Domains (for Universal Links — `auth/callback` deep linking)
- ✅ Push Notifications (optional, only if you wire FCM/APNS later)

**Save**.

### 2b. Create the "Sign in with Apple" Service ID

Sign in with Apple on Android/web needs a *Service ID* (separate from
the App ID). Skip this if you only need Apple Sign In on iPhone.

**Identifiers → + → Services IDs → Continue:**

| Field | Value |
|---|---|
| Description | `Yve Web Sign In` |
| Identifier | `io.getyve.yve.web` (matches `clientId` we hardcoded in `auth_service.dart`) |

**Configure → Enable "Sign In with Apple"**:
- **Primary App ID**: `io.getyve.yve`
- **Domains**: `ftekdhcomxxhbihvsyyw.supabase.co`
- **Return URLs**: `https://ftekdhcomxxhbihvsyyw.supabase.co/auth/v1/callback`

**Save**.

### 2c. Create a "Sign in with Apple" key

**Keys → + → Sign in with Apple → Configure → primary App ID = `io.getyve.yve` → Save → Continue → Register**.

Apple shows a **Key ID** + a **`.p8` private key file** that downloads
ONCE. Save both somewhere durable; you cannot re-download.

These go into **Supabase Dashboard → Authentication → Providers → Apple**:
- Service ID (Client ID): `io.getyve.yve.web`
- Team ID: shown at top-right of Apple Developer portal
- Key ID: from above
- Private key: paste the contents of the `.p8` file

Toggle **Enable Sign in with Apple** on. Save.

---

## 3. Xcode signing config (one-time)

In Xcode → click **Runner** in the file navigator → **Signing & Capabilities**:

1. **Team**: pick your Apple Developer team from the dropdown
2. **Bundle Identifier**: `io.getyve.yve` (should already be set from our code prep)
3. **Automatically manage signing**: ✅ ON
4. **+ Capability** → add:
   - **Sign In with Apple**
   - **Associated Domains** → add entry: `applinks:app.getyve.com` and `webcredentials:app.getyve.com`

Xcode will say *"Provisioning profile created"* once your dev team is
picked and capabilities are added. If it complains about certificates,
click the **"Fix issue"** button — Xcode handles it.

---

## 4. Update `apple-app-site-association`

The file at `mobile/web/.well-known/apple-app-site-association` has a
placeholder `TEAMID`. Replace it with your real Apple Team ID (a
10-char alphanumeric like `A1B2C3D4E5`) shown at top-right of the
Apple Developer portal.

```json
"appIDs": ["A1B2C3D4E5.io.getyve.yve"]
```

Then redeploy the web:

```powershell
& C:\Apps\StudyBuddy\mobile\scripts\build-web.ps1
cd C:\Apps\StudyBuddy\mobile\build\web
vercel --prod
```

Verify: `curl https://app.getyve.com/.well-known/apple-app-site-association`
should return the JSON.

Apple will fetch this file when iOS verifies Universal Links — usually
within minutes of first install.

---

## 5. First build to your iPhone (Mac)

Plug your iPhone into the Mac. In Xcode:

1. **Trust the device**: a dialog appears on the iPhone — tap Trust → enter passcode
2. **Top toolbar**: pick your iPhone from the device dropdown (not Simulator)
3. **▶ Run** (Cmd+R)

First build takes ~5 min. App installs on the iPhone but **won't launch**
the first time — you need to trust the developer cert:

**On iPhone**: Settings → General → VPN & Device Management →
"Apple Development: [your name]" → **Trust**.

Re-tap Yve from the home screen. Should launch.

If you see *"Could not launch Runner"*: Xcode → Product → Clean Build
Folder (Shift+Cmd+K), then Run again.

---

## 6. TestFlight upload

To send the build to anyone other than the Mac you're on, upload to
TestFlight:

1. Xcode → top device dropdown → pick **"Any iOS Device (arm64)"**
2. **Product → Archive**. Takes ~3 min. The Organizer window opens with
   your archive.
3. **Distribute App → App Store Connect → Upload → Next** (accept all
   defaults — automatic signing, include bitcode if asked, etc.)
4. Wait ~5-10 min. Apple processes the upload.
5. Open [App Store Connect](https://appstoreconnect.apple.com) →
   **My Apps → Yve → TestFlight**. Build appears after processing.
6. **Internal Testing** → add yourself + any teammates by Apple ID
   email → they get an email + the TestFlight app sends them a push.

---

## 7. App Store submission (when ready for public)

1. App Store Connect → **App Store** tab → fill in:
   - **Name**: Yve
   - **Subtitle**: e.g. "Your calm AI learning workspace"
   - **Description**: 4000 char limit; pitch
   - **Keywords**: 100 char limit; comma-separated (nursing student, study, ai, tutor, …)
   - **Support URL**: `https://app.getyve.com/legal/privacy` (or a real support page)
   - **Marketing URL**: optional
   - **Privacy Policy URL**: `https://app.getyve.com/legal/privacy` (required)
2. **Screenshots**: 3-10 per device size. Required sizes:
   - 6.7" iPhone (Pro Max): 1290 × 2796
   - 6.5" iPhone (XS Max / 11): 1242 × 2688
   - 5.5" iPhone (8 Plus): 1242 × 2208 (only required if you support iOS < 13)
3. **Age rating questionnaire**: Yve has no objectionable content → 4+
4. **Pricing**: Free (with in-app purchases)
5. **In-App Purchases**: Stripe subscriptions don't get listed here
   because they're not Apple IAP. Apple may flag this — see Section 8.
6. **Submit for Review**. ~24-48h response time.

---

## 8. ⚠️ Apple IAP vs Stripe — important

Apple's App Store rules **require digital subscriptions to use Apple
In-App Purchase** (with Apple taking 15-30% cut), **EXCEPT**:

- **External link entitlement** (granted to "reader" apps): allows
  linking out to web for subscription management
- **Apps under the EU DMA / US Epic v Apple ruling**: external link
  allowed in some jurisdictions

For Yve specifically — a "reader" app (learning content) — you can
apply for the **External Link Account entitlement** which lets you
keep Stripe billing on iOS. Without it, Apple may reject the listing
for "guiding users to purchase outside the app".

Two options:

| Option | Pros | Cons |
|---|---|---|
| **A) Stripe + external link entitlement** | Keep your 96% margin, same backend as Android/web | Need to apply for entitlement; some risk of rejection |
| **B) Apple IAP** | Guaranteed approval, no external link | Apple takes 15-30%, separate backend code, separate subscription model from Android |

**Recommendation**: file the External Link Account entitlement (free,
~1 week processing) BEFORE submitting the App Store listing. The
entitlement form is in App Store Connect → your app → External Link
Account Entitlement.

---

## Troubleshooting

**"Provisioning profile doesn't include the Sign in with Apple entitlement"**
Add the capability in Xcode (Section 3 step 4). Xcode regenerates the profile.

**"Code signing failed — no signing certificate found"**
Xcode → Preferences → Accounts → + → sign in with Apple ID → pick your team.

**Universal Links don't open the app on iPhone**
- Check `apple-app-site-association` is reachable: `curl https://app.getyve.com/.well-known/apple-app-site-association` returns JSON.
- Check Associated Domains capability is on the App ID.
- Reinstall the app: iOS only fetches the AASA file on install.

**"Missing compliance" warning when uploading**
We set `ITSAppUsesNonExemptEncryption=false` in Info.plist — this should suppress it. If it still shows: Xcode → Organizer → your archive → Manage Compliance → "uses standard encryption" → exempt.

**App crashes on first launch on real device**
Settings → General → VPN & Device Management → Trust the developer cert.

---

## What's already prepped (Windows-side, done)

- ✅ `Info.plist` updated with permission strings + URL types + crypto declaration
- ✅ Bundle ID changed to `io.getyve.yve` in `Runner.xcodeproj`
- ✅ iOS launcher icons regenerated from Yve brand mark
- ✅ Native splash regenerated for iOS
- ✅ `sign_in_with_apple` package added; native sheet wired
- ✅ Apple Sign In button restored in both auth panels
- ✅ Apple-app-site-association file written to `web/.well-known/`
- ✅ Bundle id matches Android (`io.getyve.yve`) so user_id mapping is identical

## What you do on Mac (everything above sections 1-7)

- Run `pod install`
- Open in Xcode, set team
- Add Sign In with Apple + Associated Domains capabilities
- Test on real iPhone
- Archive + upload to TestFlight
- Submit to App Store

Good luck.
