# Agent notes for VelaChat

Operational lessons this project has already cost real time to learn.
Read this before touching launch/build/verification workflow or provider
wiring — the mistakes below are easy to repeat blind.

## Launching and verifying the app

- **Always launch the built `.app` bundle with `open`, never run the raw
  Mach-O directly** (`.../VelaChat.app/Contents/MacOS/VelaChat`). Running the
  binary directly frequently produces a live process that creates only the
  `MenuBarExtra` scene and no main window at all — 0% CPU, no crash, no
  window. It looks exactly like an app bug and isn't one.
  - `just app` builds a release `.app` bundle to `build/VelaChat.app`.
  - `just open-app` (or `open "build/VelaChat.app"`) launches it correctly.
- **GUI automation does not work in a sandboxed agent session on this
  machine** — there's no Accessibility permission, so `osascript`/System
  Events reports "0 windows" or hangs, and synthetic `CGEventPost` clicks do
  nothing. Don't try to drive the UI this way; don't spend time debugging why
  a click "didn't work."
- To verify a screen visually, screenshot by window ID via Quartz instead of
  clicking:
  ```
  /usr/bin/python3 -c "import Quartz; ..."   # filter kCGWindowOwnerName == 'VelaChat',
                                              # Width>900 and Height>400 for the main window
  screencapture -x -o -l <windowID> out.png
  ```
  To check a non-default screen (e.g. Settings), temporarily change
  `AppModel.section`'s default, rebuild, launch, capture, then revert.
- **Even a correctly-launched `.app` can come up with zero onscreen windows**
  in this sandbox — process alive at 0% CPU, no crash, but
  `CGWindowListCopyWindowInfo(.onScreenOnly)` shows nothing. This is
  reproducible on a clean launch, not just rapid-relaunch corruption. When it
  happens: don't chase it, and never "fix" it with an AppKit launch-time
  fallback like `newWindowForTab:` — that creates a second, raw window that
  bypasses every SwiftUI scene modifier (no titlebar setup, no environment
  objects), producing a broken window with a solid black titlebar and no
  traffic lights. Instead: verify the code change is principled and correct,
  note that live visual confirmation wasn't possible, and move on.

## Provider integrations

- **"OpenAI-compatible" is a claim, not a guarantee — verify the actual wire
  shape before writing structs for it.** Anthropic's `/v1/messages` uses
  `x-api-key`/`anthropic-version` headers (not `Authorization: Bearer`), a
  top-level `system` field (not a system-role message), and its own SSE event
  shape — nothing like the OpenAI chat-completions format its name might
  suggest. Codex's Responses API needed its own request/response path too.
  Confirm the real shape (curl the endpoint, or fetch the provider's own API
  docs) before assuming a new provider fits the shared `ModelListResponse`/
  `StreamChunk` path.
- Same discipline applies to "the model supports X": don't infer a
  capability from a model name if the provider's API actually reports it.
  Ollama's `/api/show` returns a real `capabilities` array (`"thinking"`,
  `"vision"`, `"tools"`) — use it there instead of guessing from the ID, the
  way every other provider without such a field has to.
- The cached model catalog (`velachat.model-catalogs` in `UserDefaults`,
  `RemoteModel` arrays) is disposable and decoded with `try?` on purpose —
  a decode failure just means a live refetch on next launch. Don't tighten
  this into a hard failure; adding a new non-optional `RemoteModel` field is
  expected to silently invalidate old cached entries, not crash on them.

## App lifecycle

- `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` must stay
  `false`. The global summon hotkey depends on the app staying resident in
  the menu bar after the main window closes — returning `true` here kills
  the whole process, hotkey listener included, the instant the window shuts.
- `role: "notice"` messages (`ChatMessage`) are synthetic, local-only UI
  cards (errors, status) — never real conversation content. Always read
  `conversation.realMessages` (which filters them out) rather than
  `conversation.messages` directly when the question is "what actually
  happened in this conversation," including anything built from it that gets
  sent to a provider.

## Build commands

- `just build` / `swift build` — debug build, fast iteration.
- `just app` — release `.app` bundle at `build/VelaChat.app`.
- `just run` — `swift run VelaChat`; can hit the zero-window issue above just
  like the bundled build can.
- `just smoke` — builds the release bundle and opens it.
