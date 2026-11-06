# Plan: SkipDB and iOS player improvements

## Scope and current state

The current checkout contains both `desktop/` (Windows Electron) and `ios/` (SwiftUI). It is on `main` with unrelated working-tree changes, which implementation has preserved. The next-episode overlay originally started at 90 seconds on both platforms. iOS already checked GitHub releases on cold launch, but used an alert rather than a bottom sheet. The iOS native player has separate inline/fullscreen surfaces, double-tap feedback, a 2× hold badge, AVPlayerLayer, and existing embedded/external subtitle choices. Tasks 1–6 and 8 now have code changes; iOS device verification and generated captions remain open.

## Decisions

- Query SkipDB first on both platforms. If it has no usable segment for an episode/type, fall back to TheIntroDB for TMDB TV or AniSkip for anime; preserve stream-provided timestamps as a final fallback. Keep user-set intro overrides above provider data.
- Query SkipDB by verified IMDb ID, season, episode, and actual playback duration. Support intro, recap, outro, and preview as manual skip actions. Convert milliseconds to seconds; reject 0/0 sentinels, invalid ranges, and uncertain out-of-range matches. Cache successful hits and misses within SkipDB's read rate limit. Keep playback usable if lookup fails.
- Treat next-episode timing as five minutes (300 seconds) for the in-player overlay on both platforms. Existing episode actions outside the overlay stay available.
- Use a native SwiftUI bottom sheet for iOS release notices, with a dismiss gesture and install/release actions. Keep the existing release check and AltStore/SideStore handoff.
- Scope seek feedback, zoom, and 2× badge fixes to the iOS native player. Preserve explicit caption selections across source reload and app background/foreground on both platforms. Generated captions are an opt-in choice alongside existing caption tracks: Apple speech on iOS 26+, a local model on older iOS and Windows where audio can be captured. Do not claim support for a stream whose audio cannot be accessed for transcription.

## Tasks in dependency order

1. **SkipDB identity and response contract.** Add reliable TMDB-to-IMDb lookup for movies and TV on both platforms and establish how anime titles map to an IMDb episode identity. Map all four SkipDB segment types into the player model. Apply duration adjustment and match validation. Verify known movie/TV examples, no-data, 0/0, and out-of-range responses. If anime has no trustworthy IMDb mapping, keep playback and manual override available without inventing timestamps.
2. **Add SkipDB to both skip services.** Try SkipDB first and use TheIntroDB/AniSkip for missing or unusable results, with per-type precedence so valid SkipDB results win. Retain cache/error behavior. Verify intro UI, auto-skip, custom overrides, and provider fallback in both apps. Run `npm run test:intro`, `npm run typecheck`, and the desktop build; run the iOS CI build.
3. **Next Episode at five minutes.** Change the Windows and iOS in-player thresholds to 300 seconds, with a guard for unknown/invalid duration and no next episode. Verify just before/at the boundary, seeking across it, short episodes, inline/fullscreen iOS, and Windows player.
3a. **Manual skip actions and transitions.** Show one Skip Intro/Recap/Outro/Preview control at a time. Skip Intro and Recap stay visible without the HUD. Skip Outro and Preview appear only with the HUD, dimmed above the primary Next Episode button. When segments meet or overlap, seek to the next segment and animate the button's label/content change. Verify recap → intro and outro → preview transitions in both apps.
4. **iOS update bottom sheet.** Present the existing `UpdateChecker` result in a native SwiftUI sheet after launch. Verify swipe dismissal, Later, Install, View Release, repeated launch behavior, and no prompt when already current or offline.
5. **iOS 2× badge and seek flash.** Reproduce the first-hold failure after rotation/fullscreen, then tie badge visibility and cleanup to the active player surface and hold lifecycle. Size seek feedback against the full visible video bounds/safe areas. Verify first and repeated holds and both double-tap edges in portrait and landscape.
6. **iOS pinch zoom.** Add three clear display states: full picture (aspect-fit), zoom-to-fill, and temporary further pinch zoom. Releasing beyond fill returns to fill; pinching outward returns to full picture. Keep video clipped to the player, preserve captions/controls, and reset appropriately on episode/surface changes. Verify gesture coexistence with taps, holds, scrubbing, rotation, and fullscreen.
7. **Generated captions feasibility and implementation.** First prove synchronized, permitted audio access from actual HLS/native streams on each platform. On iOS 26+, use Apple's player audio sample output and Speech framework where available. On older iOS and Windows, package or download an on-device multilingual speech model only for sources whose audio can be captured; account for model size, CPU/battery, and licensing. Add language detection, timestamped speech recognition with punctuation and spoken-number formatting, and English translation for non-English speech. Offer English for English audio; offer original-language and translated-English choices for Japanese audio. Preserve existing tracks and Off. If audio cannot be obtained, mark the option unavailable for that source instead of showing inaccurate captions. Verify sync after pause/seek/rate changes and resource impact.
8. **Caption selection persistence.** Keep the viewer's chosen track or Off through minimizing, app switching, foregrounding, and source reload on both platforms. Match tracks by stable label/language when their order changes. Verify embedded, external, and HLS tracks.

## Checkpoints

- After tasks 1–2: SkipDB-backed timestamps work on both platforms, older providers fill gaps, and playback/manual overrides still work.
- After tasks 3–6: Windows timing and iOS sheet/gesture/zoom behavior pass device checks, including first rotation and first fullscreen entry.
- Before task 7 UI: an end-to-end caption proof works on a real target stream. Then verify English/Japanese detection, punctuation, numbers, translation, timing, permission handling, and fallback on unavailable audio.

## Key risks and open decisions

- SkipDB reads require IMDb IDs; the anime catalogue currently identifies titles through Kitsu/MAL. Establish a reliable mapping before promising SkipDB coverage for anime.
- SkipDB data is ODbL with attribution requirements; add attribution in app documentation/UI as appropriate and avoid building a private derivative skip database.
- Speech recognition accepts audio samples. Apple's newer HLS player sample output is iOS 26+; older iOS and some Windows streams need a separate, validated audio capture path before a local transcription model can work.
- The request says “both branches,” while this checkout has iOS and Windows directories on `main`. Confirm branch/release targets when implementation begins; do not assume the local feature branches represent the two apps.

## Sources

- [SkipDB API](https://skipdb.tv/docs)
- [SkipDB license](https://skipdb.tv/license)
- [Apple Speech audio-buffer request](https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest)
- [Apple speech punctuation](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest)
- [Apple Translation](https://developer.apple.com/documentation/translation)
- [Apple AVPlayerItem audio mix limitation](https://developer.apple.com/documentation/avfoundation/avplayeritem/audiomix)
