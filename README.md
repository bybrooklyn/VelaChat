# VelaChat

A focused native macOS chat client for OpenAI-compatible endpoints (and Anthropic's own Messages API), written in SwiftUI.

It connects directly to the providers you already use:

- **OpenAI** — standard `https://api.openai.com/v1` preset, and the format every "OpenAI Compatible" endpoint below implements
- **Anthropic** — Claude, over Anthropic's native Messages API (its own auth headers and streaming shape, not OpenAI's)
- **Google Gemini** — via Google's OpenAI-compatible endpoint on the Generative Language API
- **DeepSeek** — built-in `https://api.deepseek.com` preset
- **OpenRouter** — built-in endpoint with attribution headers; `:online` routing for web-connected answers
- **Groq** — very fast inference on open models
- **Mistral** — hosted API, including the Large and Codestral families
- **xAI** — Grok models
- **Perplexity** — Sonar models that search the live web on every request
- **Codex** — discover `~/.codex/auth.json` or launch `codex login`
- **Ollama** — local models at `http://127.0.0.1:11434/v1`
- **LM Studio** — local models at `http://127.0.0.1:1234/v1`
- **OpenAI Compatible** — any other custom endpoint: vLLM, llama.cpp server, LiteLLM, Jan, and similar

The app is intentionally not a model runtime or training studio. There is no Python process, model downloader, HuggingFace dependency, training job, image pipeline, or local inference engine bundled with it.

## Interface

The UI follows standard macOS conventions:

- `NavigationSplitView` for the workspace sidebar and detail area, with a titlebar-merged sidebar and a floating glass header over the transcript
- Native `List`, `Form`, toolbar menus, grouped settings, and system buttons
- Dark presentation with semantic AppKit colors so the interface follows macOS contrast and accent settings
- Material used only for functional layers: the composer, compact controls, and the sidebar/header chrome
- Persistent, searchable conversations in the sidebar (ranked results with matched-excerpt highlighting, not just a title filter)
- A ⌘K command palette for jumping to any conversation or action
- Automatic model discovery with the last exact model remembered per provider and conversation
- A searchable composer model palette generated from live provider catalogs
- Model metadata such as context size, local status, vision, tools, and reasoning support
- Provider-accurate thinking controls instead of a universal fake ladder, including Anthropic's extended-thinking token budget
- A circular context inspector showing the selected model's context window and an estimated conversation usage
- Markdown that renders live as it streams in, text selection, copy, retry, edit-and-regenerate with viewable alternates, stop generation, and reasoning/search activity sections
- Free, keyless web search via a self-hosted or public SearXNG instance, or a provider's own built-in search (Perplexity, OpenRouter) with no setup at all
- Read Aloud (system speech synthesis) and a real macOS share sheet per message
- A menu-bar quick composer and a global, user-remappable summon shortcut

## Build

Only the macOS Command Line Tools and [Just](https://github.com/casey/just) are needed:

```bash
just build          # debug compile
just check          # compile/typecheck
just app            # release build + assemble build/VelaChat.app
just open-app       # open the packaged app
just setup-signing  # one-time: stable local code-signing identity (see below)
just clean          # remove build artifacts
```

Or directly:

```bash
swift build -c release
./Scripts/build-app.sh --release
open "build/VelaChat.app"
```

The SwiftPM executable target is `VelaChat`, and source lives in `Sources/VelaChat/`.

### Stable code signing

`build-app.sh` ad-hoc signs by default, which gives the app bundle a different signing identity on every rebuild — and since a Keychain item's access control is tied to the exact identity that created it, that means macOS re-prompts for a password after every single build. Run `just setup-signing` once to create a stable, locally-trusted self-signed certificate; `build-app.sh` automatically signs with it afterward instead, so Keychain access stays granted across rebuilds.

## Connecting providers

Open **Settings** in the sidebar — provider management lives there now, not in a separate screen. Providers discover their model catalog automatically; the model field is an optional fallback only for servers that do not expose a model-listing endpoint. API keys stay in Keychain and requests go directly to the provider — nothing is relayed through an app-owned server.

### OpenAI, Groq, Mistral, xAI, Perplexity, OpenRouter, DeepSeek, Google Gemini

All of these speak the same `POST /chat/completions` shape OpenAI defined, so they share one HTTP/SSE client. Get a key from the provider's console (linked directly in each provider's editor), save, and test. Explicit thinking effort maps to `reasoning_effort` (OpenAI/Groq/Mistral/xAI/Google/compatible), DeepSeek's `thinking` + effort controls, OpenRouter's `reasoning.effort`, or Ollama/LM Studio's `think` parameter. The exact model choice is never replaced after you select it. Catalogs are cached locally for a fast picker on the next launch and refreshed periodically.

### Anthropic

Claude goes over Anthropic's own Messages API (`/v1/messages`), not the OpenAI shape — separate `x-api-key`/`anthropic-version` auth headers, a top-level `system` field instead of a system-role message, and Anthropic's own SSE event stream (`content_block_delta` with `text_delta`/`thinking_delta`). Thinking levels map to an explicit extended-thinking token budget rather than a named effort string.

### Ollama and LM Studio

Start either one and load a chat model, e.g.:

```bash
ollama pull gpt-oss:20b
# or: ollama pull qwen3:8b
```

Ollama models are discovered through its native `/api/tags` endpoint; LM Studio exposes an OpenAI-compatible `/v1/models` listing. Both run entirely on this Mac — no key, nothing leaves the machine. Chat requests to Ollama use a short keep-alive so an already-loaded model responds faster.

### Codex login

Install the Codex CLI and complete its official login flow:

```bash
codex login
```

The Codex provider can launch that command and watches for the resulting `~/.codex/auth.json`. ChatGPT OAuth sessions use the Codex Responses endpoint; an API key entered manually uses standard OpenAI-compatible chat completions. Credentials stay local and are never uploaded by the app.

### OpenAI-compatible endpoints

Add a custom endpoint from Settings and provide a URL such as:

- `http://127.0.0.1:1234/v1` for LM Studio
- `http://127.0.0.1:8000/v1` for vLLM
- `http://127.0.0.1:8080/v1` for llama.cpp server
- any hosted service's `/v1` URL

### Web search

Perplexity and OpenRouter search the live web with no setup. Every other provider falls back to a SearXNG instance — free and keyless, no account needed — configured once in Settings and toggled per-message in the composer.

## Architecture

```text
Sources/VelaChat/
  VelaChatApp.swift        native app entry point, window chrome, menu-bar extra
  AppModel.swift            conversations, persistence, streaming state
  Models.swift               provider and chat models
  ProviderStore.swift       profiles, cached model catalogs, Keychain-backed key cache
  Credentials.swift         Keychain + Codex auth discovery
  ChatAPI.swift              HTTP/SSE clients: OpenAI-shaped, Anthropic Messages, Codex Responses
  Theme.swift                 semantic macOS colors
  Materials.swift            native material + Liquid Glass helpers
  MarkdownTheme.swift    swift-markdown-ui theme mapped onto Theme
  Views/
    RootView.swift             NavigationSplitView shell
    SidebarView.swift          conversation list, search, and Settings entry point
    ChatView.swift             conversation, composer, and per-message activity rows
    SettingsView.swift        grouped native settings, including inline provider list
    ProvidersView.swift      the per-provider editor, pushed from Settings
    ProviderLogo.swift        hand-drawn vector brand marks per provider
    CommandPaletteView.swift  ⌘K jump-to-conversation/action palette
    QuickComposerView.swift  menu-bar quick composer
    Components.swift            shared chat/composer controls
```

## Requirements

- macOS 15 or later
- Apple Silicon or Intel Mac supported by SwiftUI
- No Xcode required for command-line builds
- A provider account or local Ollama/LM Studio/compatible server for live responses

## License

MIT — see [LICENSE](LICENSE).
