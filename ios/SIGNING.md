# Signing the iOS build in CI

You have two ways to get VixScr onto your iPhone without owning a Mac. Both
run entirely on GitHub's macOS runners.

## Option A — Unsigned .ipa + AltStore/Sideloadly (easiest, no secrets needed)

Every push to `main` that touches `ios/**` automatically builds an
**unsigned** `.ipa` via the `unsigned-ipa` job and uploads it as a workflow
artifact.

1. Push to `main` (or open a PR) so the `iOS Build` workflow runs.
2. Go to the Actions tab -> the completed run -> download the
   `VixScr-unsigned-ipa` artifact, unzip it to get `VixScr-unsigned.ipa`.
3. Install [AltStore](https://altstore.io) or
   [Sideloadly](https://sideloadly.io) on a Windows/Mac computer, plug in
   your iPhone, and "sideload" the `.ipa`. Either tool signs the app with
   your free Apple ID at install time — no paid developer account, no
   GitHub secrets required.
4. Re-sign (re-open AltStore/Sideloadly and reinstall) every 7 days, which
   is Apple's limit for apps signed with a free Apple ID. A paid Apple
   Developer account ($99/yr) extends that to 1 year and unlocks Option B.

This is the recommended path if you just want the app on your own phone.

## Option B — Properly signed .ipa (requires a paid Apple Developer account)

Trigger the `signed-build` job manually (Actions tab -> "iOS Build" ->
"Run workflow") once these 5 repository secrets are set
(Settings -> Secrets and variables -> Actions -> New repository secret):

| Secret | What it is |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Your Distribution/Development `.p12` certificate, base64-encoded |
| `P12_PASSWORD` | Password you set when exporting the `.p12` |
| `BUILD_PROVISION_PROFILE_BASE64` | A matching `.mobileprovision` (ad-hoc/development/App Store), base64-encoded |
| `KEYCHAIN_PASSWORD` | Any password — used only to create a throwaway CI keychain |
| `DEVELOPMENT_TEAM` | Your 10-character Apple Developer Team ID |

### Getting the certificate and profile (from a Mac, or borrowed access to one)

You do need brief access to a Mac (or Xcode Cloud / a friend's machine)
once, to generate these — after that, CI reuses them on every build:

1. In Xcode: Settings -> Accounts -> add your Apple ID -> Manage
   Certificates -> create an "Apple Distribution" or "Apple Development"
   certificate.
2. In Keychain Access, find the certificate, right-click -> Export -> save
   as `.p12`, set a password (this becomes `P12_PASSWORD`).
3. Base64-encode it: `base64 -i Certificate.p12 | pbcopy` -> paste as
   `BUILD_CERTIFICATE_BASE64`.
4. In the [Apple Developer portal](https://developer.apple.com/account/resources/profiles/list),
   create a provisioning profile (Ad Hoc for testing on registered device
   UDIDs, or App Store for TestFlight) matching bundle id `com.vixscr.app`.
5. Download the `.mobileprovision`, base64-encode it the same way ->
   `BUILD_PROVISION_PROFILE_BASE64`.
6. Your Team ID is visible at the top of the Apple Developer "Membership"
   page.

Once these are set, `workflow_dispatch` -> choose `ad-hoc` (install on
specific registered devices) or `app-store` (upload to TestFlight/App
Store) as the export method, and run it. The signed `.ipa` shows up as the
`VixScr-ipa` artifact.

## Why two jobs exist

- `simulator-build` always runs first on every push — it's the fast
  "does this even compile" check and needs no signing at all.
- `unsigned-ipa` also runs on every push automatically, since it needs no
  secrets and gets you an installable `.ipa` immediately.
- `signed-build` only runs when you explicitly trigger it, since it needs
  your real signing secrets and produces a proper App Store/TestFlight/
  ad-hoc distributable.
