# VelaChat — ideas parked for later

Things considered and deliberately deferred, with enough context to pick
them up cold. Nothing here is a commitment.

## Tools

- **`notify_user` + timers** — post a native notification now or after a
  delay ("remind me in 20 minutes") via `UNUserNotificationCenter`.
  Cut from round 5 to keep scope tight; `create_schedule_item` covers
  the durable case, so this is only for short, throwaway timers.
  Open question: scheduled notification (survives quit, needs a
  management UI) vs. in-app timer (dies with the app).
- **`define_word`** — real dictionary/thesaurus entries via
  `DCSCopyTextDefinition`, offline and instant.
- **`translate_text`** — Apple's Translation framework, on-device.
  Verify it's usable from a SwiftPM (non-Xcode) app before planning it;
  it may require entitlements the ad-hoc-signed build can't carry.
- **`search_contacts`** — read-only Contacts lookup, permission-gated
  like the schedule tools.
- **`run_shortcut`** — list and run the user's own Shortcuts. Big
  capability surface that the *user* curates, which is appealing; needs
  a trust story of its own.
- **`read_browser_tabs`** — Safari/Chrome tab titles + URLs via Apple
  events, so "summarize what I'm reading" works. Permission-heavy.

## Agentic

- **Background autonomy** — long tasks continuing with the window
  closed (the app is already menu-bar resident), a task list of what's
  in flight, and a notification when each finishes.
- **Background shells** — long-running processes (dev servers, watch
  builds) with output streaming into the transcript, instead of
  `run_command`'s single bounded run.
- **Subagent transcripts in the UI** — today a subagent's work returns
  as text; expanding its activity line into the sub-conversation's own
  live transcript would be better.
- **Sandboxed command runner** — a real restricted execution profile
  (no network, workspace-only filesystem) so more commands could run
  without asking. `sandbox-exec` is deprecated and fragile, so this
  needs research before it's worth building.

## ChatGPT Web provider

- **Work / Deep Research surfaces** — the runtime discovers `work` and
  `codex` inventories too; VelaChat currently exposes standard chat
  only.
- **Shared WebSocket delivery** — the reference supports ChatGPT's
  `shared_websocket` entitlement path; VelaChat uses HTTP SSE only.
- **Native ChatGPT tools** — web search with citation normalization,
  code interpreter, image generation (the conduit flow), Projects and
  custom GPTs as scoped conversations.
- **File uploads** — the private upload negotiation, so image
  attachments work in ChatGPT conversations.

## Other

- Provider logos sourced from real brand assets (rather than the
  hand-traced SVG paths).
- `@`-references in the composer (files, past conversations).
- Artifact version history and diffing.
- Attachments v2: ZIP, audio, video.
- A real test suite + CI.
- Import from ChatGPT/Claude data exports.
