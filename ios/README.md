# VixScr for iOS (SwiftUI)

A native SwiftUI port of the VixScr Electron desktop app. Same TMDB catalogue,
same fuzzy search, same movie/TV streaming player, same redirect/popup
blocking policy — rebuilt for iOS with real Liquid Glass surfaces.

## No Mac? Use GitHub Actions

`.github/workflows/ios-build.yml` builds this project on GitHub's hosted
macOS runners on every push to `main` under `ios/**`, and uploads a
ready-to-sideload `.ipa` as a downloadable artifact — no Mac required on
your end. See **[ios/SIGNING.md](SIGNING.md)** for the full walkthrough
(there's a no-secrets, no-paid-account path using AltStore/Sideloadly).

## Setup (macOS + Xcode, only if you want to build locally)

This project was authored without access to Xcode/macOS, so instead of a
hand-written (and unverifiable) `.pbxproj`, it ships as an
[XcodeGen](https://github.com/yonaskolb/XcodeGen) spec (`project.yml`) that
generates a real, valid `.xcodeproj` deterministically from the source tree.

1. Install XcodeGen (one-time):
   ```bash
   brew install xcodegen
   ```
2. Generate the project:
   ```bash
   cd ios/VixScr
   xcodegen generate
   ```
3. Open `VixScr.xcodeproj` in Xcode 16+ and run on an iPhone simulator or
   device (iOS 17+).

If you'd rather not install XcodeGen, you can also create a new Xcode
"App" project named `VixScr` with bundle id `com.vixscr.app`, delete its
generated `ContentView.swift`/`App.swift`, and drag the `VixScr/` source
folder (everything under `ios/VixScr/VixScr`) into it, making sure "Copy
items if needed" is OFF and the app target is checked.

## What was ported 1:1

- **TMDB catalogue** — trending, popular movies/TV, top rated, all fetched
  live from `api.themoviedb.org/3` exactly like `tmdbFetch()` in the
  Electron app, with the same v3 api_key / v4 bearer-token auto-detection.
- **Fuzzy search** — `Services/FuzzySearch.swift` is a line-by-line port of
  the Levenshtein/n-gram/token scoring in `index.html`, including year
  detection ("Batman 2022") and the typo-correction fallback path.
- **Streaming player** — a `WKWebView` loads the same configurable
  streaming servers (`vixsrc.to` by default) at `/movie/{id}` or
  `/tv/{id}/{season}/{episode}`, exactly like `buildMoviePlayerUrl` /
  `buildTvPlayerUrl`.
- **Redirect/popup blocking** — see `Views/Player/StreamWebView.swift` for
  the full mapping from Electron's `setWindowOpenHandler` /
  `will-attach-webview` block / header stripping to WKWebView's
  `WKNavigationDelegate` / `WKUIDelegate` equivalents. TMDB links still open
  externally; everything else is denied, same allowlist as before.
- **Favourites, continue watching, recent searches, performance mode,
  ultra performance mode, card size, custom streaming servers** — all
  persisted via `UserDefaults` in `Services/AppStore.swift` (the direct
  iOS analogue of the app's `localStorage` usage), using the *same* storage
  key names as the JS app for continuity if you ever want to migrate data.
- **Cast row** — tapping an actor opens their TMDB person page, same as the
  Electron cast-card click handler.
- **Deep links** — `vixscr://<id>` opens a title directly, same as the
  desktop app's custom protocol handler (`app.setAsDefaultProtocolClient`).
- **Liquid Glass** — `Theme/GlassStyle.swift` uses Apple's real
  `glassEffect()` / `GlassEffectContainer` API (iOS 26+) for every card,
  nav bar, sheet, and chip, with a `.ultraThinMaterial` fallback for
  iOS 17–25 so the project still builds/runs on older simulators and
  devices.

## What was intentionally NOT ported

- **Auto-update from GitHub** (`main.js`'s portable-exe swap-and-relaunch
  flow). There's no equivalent action available to a sandboxed iOS app —
  updates on iOS go through the App Store / TestFlight instead.
- **Ad-blocking via `@ghostery/adblocker-electron`**. `WKWebView` has no
  direct equivalent to Electron's session-wide network request blocker.
  If you want ad-blocking on iOS, the standard approach is a
  `WKContentRuleList` compiled from an EasyList-style JSON ruleset — that's
  a separate, sizeable addition and out of scope for this 1:1 UI/behaviour
  port. Redirect/popup blocking (the thing you asked to keep) IS ported.
- **Header stripping** (`onHeadersReceived` removing X-Frame-Options/CSP).
  `WKWebView` doesn't intercept/rewrite response headers the way Electron's
  `session.webRequest` can. In practice this hasn't been an issue because
  the streaming servers already serve embeddable pages designed for
  iframe/webview use; if a specific server's page refuses to render, that's
  the first thing to check.

## Verification status

I could not compile or run this project — there's no macOS/Xcode available
in this environment. Every file was written by hand against the Swift 6 /
SwiftUI / WebKit APIs as I know them, and each screen was cross-checked
against the corresponding markup/JS in the original `index.html`, but you
should build it in Xcode and fix any compiler errors it surfaces before
relying on it. Likely first build errors to watch for, given no compiler
was available:
- Exact `glassEffect()` modifier signature/parameter names on iOS 26 SDKs
  (Apple's Liquid Glass API is very new; double-check against the iOS 26
  SDK docs in Xcode if it doesn't compile as written).
- `@Bindable` / `@Observable` usage requires the Observation framework
  (iOS 17+), which the deployment target already assumes.
