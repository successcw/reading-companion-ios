# Reading Companion iOS

**English** | [简体中文](README.zh-CN.md)

A native iPhone AI reading companion for Kindle + KOReader. The iPhone hosts a small local HTTP server, receives the current page from a KOReader plugin, listens with Apple Speech, streams answers from OpenCode Go, and reads them aloud with Edge TTS (falling back to Apple's system voice).

> This repository contains the **iPhone app only**.
> The Kindle/KOReader side lives at [successcw/koreader-ai-reading](https://github.com/successcw/koreader-ai-reading).

## Features

- **Automatic VAD**: no press-to-talk; starts and stops on speech/silence.
- **Apple Speech**: Chinese on-device recognition when available.
- **Local HTTP bridge**: receives book, chapter, page, progress, and page text from KOReader.
- **OpenCode Go streaming**: `https://opencode.ai/zen/go/v1`, default model `deepseek-v4.1-flash`.
- **Edge TTS**: sentence-by-sentence synthesis, so the first sentence starts before the full answer is written.
- **AirPods output**: keeps the iPhone microphone for ASR and routes playback to AirPods when connected.
- **Smooth text reveal**: buffered text updates, no per-token jitter.
- **Cat UI**: custom app icon and background.

## Tested

| Item | Value |
|---|---|
| iPhone | **iPhone 13 Pro Max** |
| iOS | 27.2 |
| Xcode | 27.0 |
| KOReader | 2026.07.1 (optional Kindle side) |

Requires iOS 17+. The simulator builds without signing; a real device needs an Apple ID/team.

## Build and run

```bash
cd reading-companion-ios
xcodegen generate        # optional; project is also committed
open ReadingCompanion.xcodeproj
```

In Xcode:

1. Select your Team under Signing & Capabilities.
2. Pick your iPhone.
3. Run.

Simulator build:

```bash
xcodebuild -project ReadingCompanion.xcodeproj \
  -scheme ReadingCompanion \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
```

Free Apple ID signing expires after 7 days. TestFlight/App Store requires the paid Apple Developer Program.

## App settings

- **API Key**: OpenCode Go key, stored in the iOS Keychain.
- **Model**: default `deepseek-v4.1-flash`.
- **Port**: default `8790`.
- **Token**: default `change-me`; must match the Kindle plugin config.
- **TTS**: Edge voice selector (Xiaoxiao, Yunxi, Xiaoyi, Yunjian, Xiaobei) plus system fallback.

Base URL is fixed to:

```text
https://opencode.ai/zen/go/v1
```

The app uses `/chat/completions` and sends the required `x-opencode-session` header.

## Kindle connection

1. iPhone opens Personal Hotspot.
2. Kindle joins that hotspot.
3. The app shows an address like `http://172.20.10.1:8790/context`.
4. Put that address and token into the KOReader plugin's `config.lua`.

## Privacy

- The app receives the current page text from your Kindle and sends it to OpenCode Go for inference.
- Edge TTS sends the answer text to Microsoft's Edge TTS service.
- API keys live in the Keychain; no key is committed to this repository.
- No books, personal images, or account credentials are included in the repo.

## Known limitations

- iOS may suspend the local server when the app is backgrounded; keep the app in the foreground.
- iPhone Personal Hotspot does not broadcast continuously; Kindle must connect while it is discoverable.
- Edge TTS is an unofficial endpoint and can change; the app falls back to Apple's system TTS.
- Apple Speech accuracy depends on language pack, microphone distance, and noise.
- This is a prototype, not an App Store-ready product.

## License

MIT for the app code (see `LICENSE`).
`Vendor/SwiftEdgeTTS` is MIT; see its own license and `THIRD_PARTY.md`.
