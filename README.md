# BridgeChat

A small, original SwiftUI chat client for any OpenAI-compatible endpoint
(Ollama, OpenAI, z.ai, LM Studio, vLLM...). No accounts, no telemetry, no
middleman: your phone talks straight to the endpoint you configure.

## Features

- **Settings you own**: provider preset, base URL, API key, system prompt.
- **Model dropdown** with live auto-discovery (`GET /models`), or type any id.
- **Streaming chat** with a per-conversation history.
- **Photos** → attached as vision parts (downscaled on-device; use a
  vision-capable model).
- **Location** and **next-7-days calendar** can be included as context
  (iOS permission prompts; nothing is shared unless you enable it).
- **grok-bridge integration (optional)**: point it at your
  [grok-bridge](..) server to include your iPhone-backup message history
  (`/messages/transcript`) in the context.

This is deliberately NOT a reimplementation of any proprietary app — it is a
lean, original client.

## Building

CI (GitHub Actions, macOS runner) builds an **unsigned IPA** on every push to
`main`: see the *Actions* tab → artifact `BridgeChat-unsigned-ipa`. Sign it
with Sideloadly / AltStore / ESign (free Apple ID works) and install.

Locally (needs macOS + Xcode):

```bash
brew install xcodegen && xcodegen generate
xcodebuild -scheme BridgeChat -destination 'generic/platform=iOS' build
```

## Notes

- For a **fully local** setup: Ollama on your LAN + this app = no message or
  chat data leaves your hardware.
- Vision (photos) requires a multimodal model (qwen-vl / llava / gpt-4o /
  glm-4v class).
