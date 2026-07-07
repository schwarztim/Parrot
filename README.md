# Parrot

Push-to-talk voice dictation for macOS: hold a hotkey, speak, release, and the transcribed (optionally AI-refined) text is pasted at your cursor and left on the clipboard. Works fully offline out of the box.

## How It Works

Two independent layers, each local or cloud:

1. **Transcription (speech-to-text)**
   - **Parakeet V3 (default)**: on-device via [FluidAudio](https://github.com/FluidInference/FluidAudio), no network, no API key.
   - **OpenAI**: `POST /v1/audio/transcriptions` (whisper-1, gpt-4o-transcribe, gpt-4o-mini-transcribe).
   - **Azure Whisper**: `POST {endpoint}/openai/deployments/{deployment}/audio/transcriptions`.
   - Cloud failures fall back to on-device Parakeet with a non-blocking error toast.

2. **Refinement (raw transcript to clean text, optional)**
   The transcript is sent to an LLM that fixes dictation errors (homophones, run-ons, punctuation, capitalization, fillers) and formats it, while preserving meaning. Providers:
   - **Local (Ollama / LM Studio / llama.cpp / vLLM)**: any OpenAI-compatible server via configurable base URL (default `http://localhost:11434/v1`), no key required. Installed Ollama models are listed via `/api/tags`.
   - **OpenAI**: `https://api.openai.com/v1/chat/completions`, Bearer auth.
   - **Azure OpenAI**: deployment URL with `api-key` header (API version `2024-10-21`).
   - **Anthropic Claude**: `https://api.anthropic.com/v1/messages` (`x-api-key`, `anthropic-version: 2023-06-01`); models `claude-haiku-4-5`, `claude-sonnet-5`, `claude-opus-4-8`.
   - Refinement off (the default) pastes the raw transcript, so the app works unconfigured and local-only.
   - On any provider error the raw transcript is pasted instead; dictation is never lost.

## Prerequisites

- macOS 14+ on Apple Silicon
- Xcode command line tools (`swift` 5.9+)
- Optional: [Ollama](https://ollama.com) with a pulled model, for local refinement

## Setup

```bash
git clone https://github.com/schwarztim/Parrot.git
cd Parrot
./build.sh
```

`build.sh` builds, assembles `/Applications/Parrot.app`, signs it (self-signed "Parrot Dev Signing" certificate if present, ad-hoc otherwise), and launches it. Grant Microphone, Accessibility, and Input Monitoring permissions when prompted.

The Parakeet model (~800 MB) downloads on first launch to `~/Library/Application Support/FluidAudio/Models`.

## Usage

- Hold the hotkey (default: Right Option), speak, release. Text is pasted into the frontmost app and stays on the clipboard.
- **Configuration tab**: hotkeys, recording window style, and AI Refinement (enable toggle, provider, endpoint/model/key, Test Connection).
- **Models tab**: transcription provider (on-device Parakeet, OpenAI, or Azure Whisper).
- **Modes tab**: per-mode refinement directive (e.g. "Format as a professional email"). Empty uses the default cleanup directive.

API keys are stored in the macOS Keychain, one service per provider (`com.parrot.openai`, `com.parrot.azure-openai`, `com.parrot.anthropic`, `com.parrot.local-server`). They are never written to UserDefaults or logs.

## Project Structure

```
Parrot/
  Core/
    AudioRecorder.swift          16kHz mono capture (AVAudioEngine)
    TranscriptionEngine.swift    On-device Parakeet V3 (FluidAudio)
    CloudTranscribers.swift      TranscriptionProvider protocol, OpenAI/Azure Whisper, WAV encoder
    RefinementService.swift      RefinementClient protocol, provider selection, prompt scaffold
    OpenAICompatibleClient.swift OpenAI + local servers (Ollama /api/tags listing)
    AzureOpenAIClient.swift      Azure chat completions (api-key header)
    AnthropicClient.swift        Claude Messages API (content block array)
    HotkeyManager.swift          Global CGEventTap hotkeys
    TextInserter.swift           Clipboard + Cmd+V paste
    KeychainHelper.swift         Keychain storage for API keys
    ModeManager.swift            Persisted dictation modes
  Models/
    AppState.swift               Pipeline coordinator (record, transcribe, refine, paste)
    AppSettings.swift            @Observable settings, UserDefaults + Keychain
    Mode.swift                   Mode with per-mode refinement prompt
  Views/                         SwiftUI: main window, configuration, modes, models, overlays
ParrotTests/                     Unit + local integration tests (Ollama, Parakeet)
build.sh                         Build, bundle, sign, launch
```

## Testing

```bash
swift test
```

Integration tests self-skip when their backend is unavailable: Ollama tests need a running server with at least one model, the Parakeet test needs the cached model. Everything else runs offline.
