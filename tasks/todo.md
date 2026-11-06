# SkipDB and iOS player improvements

Implementation status: tasks 1–6 and 8 have code changes in the working tree; iOS device verification is pending. Task 7 remains at the audio-capture feasibility gate; see `caption-feasibility.md`.

- [ ] 1. Establish IMDb identity and SkipDB parsing/validation contract on Windows and iOS; verify movie, TV, anime/no-ID, sentinel, and uncertain matches.
- [ ] 2. Add SkipDB before TheIntroDB/AniSkip on Windows and iOS; verify per-type precedence, fallback, overrides, auto-skip, cache/error behavior, and builds.
- [ ] Checkpoint: SkipDB works on both platforms and old providers fill gaps.
- [ ] 3. Show in-player Next Episode during the last 300 seconds on Windows and iOS; verify boundary, seeks, and no-next cases.
- [ ] 3a. Show Intro/Recap persistently; show dimmed Outro/Preview only with the HUD above primary Next Episode; verify smooth adjacent and overlapping transitions.
- [ ] 4. Present iOS updates in a native dismissible bottom sheet; verify launch, dismissal, and install actions.
- [ ] 5. Fix first-hold 2× badge after rotation/fullscreen and edge-to-edge double-tap feedback; verify on device.
- [ ] 6. Add iOS pinch fit/fill/temporary zoom behavior; verify gesture coexistence and orientation changes.
- [ ] Checkpoint: Windows timing and iOS update/player interactions pass device checks.
- [ ] 7a. Prove synchronized audio access for generated captions on actual streams: Apple output on iOS 26+, and a separate capturable path on older iOS/Windows.
- [ ] 7b. Add on-device transcription, detected-language choices, punctuation/numbers, original-language and English translation, timed rendering, model delivery, and resource checks.
- [ ] 8. Preserve explicit caption track/Off selection through app switching and source reload on iOS and Windows.
- [ ] Final checkpoint: targeted tests, Windows build, iOS CI/device checks, and user review.
