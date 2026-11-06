# Generated captions: implementation gate

The caption menu must not offer a nonworking “Auto-generated” choice. The current iOS player renders HLS/AVPlayer audio but does not expose PCM audio to the app; the Windows player uses `<video>` plus hls.js. Neither player has a tested transcription feed today.

## iOS 26+

Apple's `AVPlayerItemSampleBufferOutput` can deliver decoded PCM from HLS `AVPlayerItem`s. A production implementation should attach it to the active item, time-align output sample presentation timestamps to the player timebase, and feed bounded samples to the Speech framework. It must cancel/restart on source change and seek, preserve caption choice on background/foreground, and check protected or inaccessible streams. Speech recognizers are locale-specific, so language must be established from trusted audio metadata or a validated detection pass before offering original-language and translated-English choices. Punctuation is supported by `SFSpeechRecognitionRequest.addsPunctuation`; numbers still require output validation. Japanese-to-English translation can use Apple's Translation framework where its language assets are available.

## iOS 17–25 and Windows

`whisper.cpp` supports multilingual speech recognition, automatic language selection, timestamps, and translation into English; its SwiftUI example shows an on-device integration. A local model still needs decoded, synchronized audio. Apple's AVPlayer audio mix is unavailable for HLS, and the iOS 26 sample output is unavailable on older iOS. For each supported source format, prove a separate audio extraction or capture path before integrating the model. Measure model download size, storage, CPU, battery, latency, and memory on target phones and Windows PCs. Offer the local model as an optional download after those checks, with clear deletion and unavailable-source behavior.

## Verification needed before shipping

1. On an iOS 26 device, prove PCM output and timestamp alignment from an actual Vela HLS source, including pause, seek, 2× hold, and source change.
2. On iOS 17–25 and Windows, prove a capturable audio path for each stream format selected for local transcription.
3. Compare English and Japanese clips against real speech, punctuation, spoken numbers, original Japanese, and translated English. Check whether the model produces captions soon enough for playback.
4. Compile with Xcode 26 and run device tests. This Windows workspace has no Xcode/iPhone test target, so this gate cannot be closed locally.

## Primary references

- [Apple AVPlayerItemSampleBufferOutput](https://developer.apple.com/documentation/avfoundation/avplayeritemsamplebufferoutput)
- [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [Apple speech punctuation](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest)
- [Apple Translation](https://developer.apple.com/documentation/translation)
- [Apple AVPlayer audio mix HLS limitation](https://developer.apple.com/documentation/avfoundation/avplayeritem/audiomix)
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
