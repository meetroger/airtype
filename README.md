# Airtype

Local and privacy first voice-to-text MacOS app that transcribes your voice and inserts text at your cursor — in any application. Hold a shortcut, speak, and Airtype inserts the transcription at your cursor in any application.

## Local by default

Airtype can transcribe entirely on your Mac with Apple MLX. No account or API key is required, and your recordings do not need to be sent to a transcription service. Download a model once, then use it for on-device transcription.

### Supported local models

| Model | Best for |
|---|---|
| `Qwen3-ASR-0.6B-4bit` | Faster transcription with lower memory use; the default choice |
| `Qwen3-ASR-1.7B-4bit` | A larger model when transcription quality is the priority |

Local transcription currently supports automatic language detection, English, and Chinese.

## Download

Get the latest release from [GitHub Releases](https://github.com/sugarforever/airtype/releases/latest) or [airtype.space](https://www.airtype.space/download).

**Requires macOS 14 Sonoma or later.**

## Getting started

1. Open the downloaded `.dmg`, then drag Airtype to Applications.
2. Launch Airtype and grant Microphone and Accessibility permissions when prompted.
3. In Settings, select **MLX Local**, choose a model, and download it.
4. Hold **Option + Space**, speak, and release to transcribe and insert the text.

Airtype runs in the menu bar. Keyboard shortcuts can be changed in Settings.

## Direct BLE microphone

Airtype can receive audio directly from the ESP32-S3 AI Passport microphone
(service `666f6c6f-7061-7373-706f-727400000001`, protocol v1).
No BlackHole driver or separate PassportMic receiver app is needed.

1. Quit the standalone PassportMic receiver so Airtype owns the audio subscription.
2. Pair the device as a Bluetooth keyboard in macOS, as required by its firmware.
3. Open Airtype's menu bar **Microphone** menu and allow Bluetooth access.
   Traditional microphones appear first, followed by a separator and all discovered
   **BLE Microphones** in the same menu. Select a device directly; the current
   input has a checkmark. The name and short device ID distinguish same-name
   microphones. **Search again** refreshes discovery, including devices already
   connected to macOS as keyboards. Discovery remains available while a traditional
   microphone is selected, without subscribing to BLE audio.
   Your BLE choice is remembered across restarts and stays selected while offline;
   Airtype waits for that device instead of switching to a different microphone.
   Stop recording before switching. Airtype unsubscribes the old microphone
   before connecting the new one and discards all old-session audio.
4. Use the device's MIC/UP button as before. Its HID shortcut must match
   Airtype's configured shortcut. Mac keyboard shortcuts also work, but the
   device must be recording to transmit audio; Airtype cannot remotely start it.

The receiver reassembles BLE fragments, validates sessions and sequence numbers,
and decodes mono 20 ms Opus frames directly to 16 kHz PCM16 using the bundled,
source-built libopus dependency. Short packet losses use Opus concealment;
large gaps reset the decoder. Startup transient suppression is currently disabled
to allow testing microphone firmware changes: decoded PCM reaches buffering,
transcription, and archival without startup muting or fade-in.
A bounded one-second buffer preserves audio while
Airtype prepares capture. Disconnects and stalls stop the current recording and
trigger reconnection. BLE unavailability produces an error instead of recording
from another microphone.

PCM goes directly to Doubao streaming. Completed recordings are encoded as M4A,
including BLE recordings, for storage and the existing file-based ASR providers.
WAV is used during capture and kept as a recovery copy only if encoding fails.
Raw Opus packets are not passed to ASR. Normal system microphone capture remains
available through the same menu; switching away stops BLE reception.

Build in Xcode as usual: Swift Package Manager builds the pinned `Copus` product
from `alta/swift-opus` 0.0.2, with no Homebrew runtime dependency. For standalone
protocol and real codec checks, install development libopus (`brew install opus`)
and run `scripts/check-ble-mic.sh` (`OPUS_ROOT` can override its install prefix).
Hardware testing should cover tap/toggle, hold/release, cancellation, Bluetooth
reconnect, and both local and streaming ASR with the actual device.

## Features

- Fully local transcription with no API key required
- Push-to-talk and toggle-recording shortcuts
- Optional preview and editing before text is inserted
- A floating panel for recording and transcription status
- Up to 50 recent transcriptions stored locally
- Optional AI cleanup for grammar, punctuation, and formatting
- Automatic update checks

| Action | Default shortcut |
|---|---|
| Push to talk | **Option + Space** |
| Toggle recording | **Option + Shift + Space** |

## Cloud transcription and enhancement

Local transcription is the simplest private setup, but Airtype also supports cloud transcription through **OpenAI**, **ElevenLabs**, **Mistral**, and **Doubao**. These providers require their own credentials and send audio to the selected service.

Optional AI enhancement can clean up a completed transcription without changing its intent. It supports OpenAI-compatible providers including OpenAI, OpenRouter, Together AI, Groq, DeepSeek, Moonshot AI, z.ai, Azure OpenAI, Cloudflare Workers AI, custom endpoints, and LM Studio for local enhancement.

## Development

Requirements:

- Xcode 16.4 or later
- macOS 14 or later

```bash
open Airtype.xcodeproj
```

Run the `Airtype` scheme with **Command + R**. Swift Package Manager resolves the project dependencies.

## License

MIT
