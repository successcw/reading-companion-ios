# Changelog

## Unreleased

- Add push-to-talk interaction: tap to record, tap again to send.
- Add stop button to cancel an in-flight LLM response and TTS.
- Show cat state frames: side-profile listening pose and talking mouth.
- Keep silent Tencent recognition results quiet instead of showing a parse error.
- Add Tencent Cloud one-sentence ASR, configurable in Settings and stored in the Keychain.
- Rebuild the audio graph after microphone interruptions, route changes, and media-service resets.
- Ignore errors from cancelled/stale speech recognition tasks.
- Treat `No speech detected` as a normal reset instead of showing an error.
- Require several above-threshold frames before starting VAD to avoid noise-triggered requests.
- Fall back to the last partial transcript when Apple Speech does not emit a final callback.
- Give sentences more room before ending (3s silence, 30s maximum) to avoid premature sends.
- Rename the app display name and in-app title to 橘猫陪读.

## 0.1.0

- Native iPhone reading companion.
- Local HTTP bridge for KOReader page context.
- Apple Speech automatic VAD and Chinese recognition.
- OpenCode Go streaming chat.
- Edge TTS with sentence prefetch and Apple system fallback.
- AirPods playback routing.
- Custom cat icon and background.
