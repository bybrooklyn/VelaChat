# VelaChat — working notes

## 2026-08-19 — Round 3 (bc153a4..HEAD; GitHub: private bybrooklyn/VelaChat)

S1a instant titles (fired at send from the first message; fullscreen
top-clip fix); S1b Apple Intelligence (FoundationModels verified from the
SDK swiftinterface — on-device utility brain for titles/compaction/
handoff + full "Apple Intelligence" chat provider; image input deferred,
framework is text-only); S2a usage ledger (hourly per-provider buckets,
5h/day/week/month, $ only from real pricing, per-reply $ in token row);
S2b live quota headers → sidebar gauge popover + Statistics section;
S3a branch-from-message + Markdown/PDF export (CTFramesetter);
S3b ⌘F find-in-chat (sidebar search → ⇧⌘F); S3c model favorites/recents,
native scroll edge fades (toggleable), Settings glass cards; S3d quick
chat upgrade (model picker, attach, screenshot via screencapture -i);
S4 get_schedule (EventKit, SDK-verified full-access API) + read_clipboard
tools w/ toggles + Info.plist usage strings; S5 basic MCP (stdio JSON-RPC
client actor, mcpServers-JSON config + import, Settings card, tools
merged per-send as mcp_<server>_<tool>, activity lines, stopAll on quit).
Needs human verification: Apple Intelligence availability on this
machine (ad-hoc signing may report ineligible → falls back), calendar
permission prompt, an end-to-end MCP server, quick-chat screenshot.

## 2026-08-19 — Round 2 (R1–R9, one commit each; d1ddf37..2417520)

R1 quick fixes (send glyph regression, real scroll-to-bottom sentinel,
toolbar band removed + sidebar toggle relocated into sidebar header,
plus attach button, fetch_url browser headers, title thinking .off→.auto
fix — .off mapped to invalid Codex effort and silently 400'd every
auto-title/compaction/handoff, spinner sweep); R2 activity collapse
(finished replies fold their tool stack into one dim summary line,
4KB result cap); R3 inspector (markdown/code kinds rendered natively,
editable workspace files w/ Save, resizable panel, Open buttons on file
activities + big code/md blocks); R3b plus menu (gh CLI repo shallow-clone
into workspace w/ 200MB guard, clipboard, cloud coming-soon page);
R4 SystemPrompt.compose (app-context preamble); R5 chat visuals (no
provider label, persistent token+actions row, hover timestamps, grouping,
code header strip); R6 picker (hardcoded simple-icons brand glyphs + SVG
path parser, native bottom scroll edge fade); R7 Settings v2 (glass cards,
text jump rail, modern switches; per feedback: no icon tiles, General
first, Shortcut folded in); R8 onboarding + full reset; R9 glass buttons.
NOTE: final launch attempts hit the documented zero-window sandbox flake
3x — code verified by build + earlier captures; needs a human launch
check (especially onboarding gate + toolbar-hidden window chrome).

## 2026-08-18/19 — deep-audit overhaul round (13 phases, one commit each)

Full plan + audit findings: ~/.claude/plans/the-settings-screen-should-dapper-coral.md.
P1 correctness (retry/edit data-loss fix, debounced saves, endpoint honoring);
P2 tool awareness (system-prompt tool inventory, fetch_url/current_datetime/
calculator/read_attachment, honest gating, conversation-search toggle,
compaction at 95%); P3 Codex Responses function calling; P4+P5 interleaved
activity timeline (message segments, reveal-op queue, Claude-web dim lines,
no spinners, shimmer); P6 model-managed memory (save/search/edit_memory
tools, relevance injection, topics; remember-card flow removed); P7
streaming feel (adaptive drain, no end snap, reasoning calm); P8 ask-user
streaming fix (line-start fences, suffix kept, placeholder); P9 Settings/
providers rework (1000pt, ring context button, accentStrong chrome, draft
add sheet, no select-on-view, About rework); P10 remote provider logos
(RemoteLogoLoader, disk cache, hand-drawn fallback); P11 skills auto-import
removed (migration for active ones, capped injection); P12 new-chat sidebar
deferral (pendingConversation, spring insert on first message); P13 polish
(dead top inset gone, composer aligned, send-button crossfade, accent
propagation, notice kinds, faster typewriter).
Not yet live-verified: a real tool-calling chat (blockrun/Codex) — needs a
human to send a message and watch the activity lines.

Persistent tracking file for the ongoing build-out. Updated as we go instead
of re-deriving status each session. See also `AGENTS.md` (operational
lessons) and the original phased plan this grew out of (Phase 0 — the whole
punch list of immediate fixes — is complete as of 2026-08-18).

## Status

- **Phase 0** (global hotkey, errors-in-chat, context button placement, chat
  top bar removed, pinned conversations/messages, welcome screen, chat
  naming, right-click menus, sidebar resize, slash commands, Skills,
  background notifications, context compaction, changelog, AGENTS.md): done.
- **Mid-stream extras already shipped**: model selector shows every
  configured provider grouped together; the model can ask a multiple-choice
  question via a `​```ask-user` fenced block (Claude-Code-style); blockrun.ai
  added as a free, anonymous, keyless provider; rich Ollama support (pull
  with live progress, real quantization/disk-size/cloud-tag data, real
  `/api/show` capability detection); manual context-window override.
- **Phase 1–5** (providers/model-selector polish, real tool calling,
  attachments, sandbox workstation, artifacts): superseded in part — real
  image/text/code/PDF attachments shipped ahead of Phase 3 (below), driven
  by the user's explicit "everything now" on the feature backlog. Real tool
  calling, the sandbox workstation, and full editable artifacts remain
  unbuilt.
- **2026-08-18 second round ("everything now")** — deployment target raised
  to macOS 26, Liquid Glass unconditional; model selector overhaul (real
  price tiers, strength-sorted, provider cards, real descriptions); Memory
  (global, editable, model-proposable); real Attachments (images wired into
  actual multimodal requests for both OpenAI-compatible and Anthropic;
  text/code/PDF folded into request text; composer attach button, paste,
  drag-and-drop). Full details below.

## Active punch list (from 2026-08-18 feedback round)

Resolved this round:
- [x] Sidebar spacing between the New Chat/search row and the conversation
  list — bumped 8pt → 14pt.
- [x] Search morph gap — root cause was `newChatButton` keeping an
  unconditional `.frame(maxWidth: .infinity)` even while collapsed to
  icon-only, fixed to only greedily expand when search isn't showing. Added
  an always-visible X button (not just "clear text") that closes search
  back down.
- [x] blockrun.ai free-tier gating — confirmed live (`billing_mode` field,
  92 models total, 5 actually `"free"`; a non-free model 402s on an
  anonymous request). blockrun has no traditional login — it's the x402
  crypto-micropayment protocol, not an account system — so VelaChat now
  just filters the catalog to `billing_mode == "free"` unconditionally and
  says so honestly in the provider description, rather than pretending a
  login flow is coming.
- [x] Context compaction improvements, research-backed: pinned messages
  now survive compaction verbatim (never summarized, at any age) — the
  single highest-value fix per research, since "instructions don't survive
  compaction" is a real, reported failure mode elsewhere (Cursor). Added a
  4-message recency buffer (nothing very recent gets paraphrased away).
  Summarization prompt now explicitly asks for verbatim numbers/paths/code/
  decisions instead of paraphrasing, and bounds summary length (~500
  words). Fail-closed behavior (no boundary marker on a failed
  summarization call) was already correct, verified against the research.
- [x] Handoff document feature — built the most-feasible interpretation
  from the handoff research: a `/` command and conversation-menu action
  that generates a structured markdown handoff doc (goal / decisions /
  state / next steps, verbatim specifics) and copies it to the clipboard.
  Reuses the compaction summarization mechanism with different framing.

- [x] Settings back button — icon-only chevron in a glass circle, no
  trailing "Chat" label; bound to Esc too.
- [x] Composer pill height — `VelaControlButtonStyle` now uses a fixed
  30pt height instead of vertical padding, matching the send/context
  circular buttons exactly instead of approximately.
- [x] Liquid Glass — real `.glassEffect()`/`Glass`/`GlassEffectContainer`
  API (confirmed via research, see below) was already wired in for the
  composer container and card backgrounds (`VelaGlassContainer`,
  `nativeMaterial`, both already correct and availability-gated). Extended
  it to the pieces that weren't yet: composer pills, send button (filled
  states only — the empty/not-ready state stays a plain stroked outline on
  purpose, not untinted glass), context button, floating chrome chips
  (exit-fullscreen, pinned-messages, conversation-title menu), Settings
  back button, sidebar search toggle. New shared helpers in
  `Materials.swift`: `glassCapsule(tint:isPressed:interactive:)`,
  `glassCircle(tint:isPressed:interactive:)`, `glassChip(in:)` (neutral,
  for exit-fullscreen/pinned/search chips) — all gated
  `if #available(macOS 26.0, *)` with the prior `.ultraThinMaterial`/fill+
  stroke styling as the pre-Tahoe fallback. `Package.swift` deployment
  target left at `.v15` (gating, not raising the floor) — that's a real
  compatibility call for the user to make explicitly if they'd rather just
  require macOS 26+ and drop the fallback branches entirely.
  Scope was deliberately chrome/controls only (composer, floating pills,
  buttons) per Apple's own HIG guidance the research turned up — message
  bubbles, cards, and other large content areas were left alone.

Still open — concrete, not blocked on research:
- [ ] A general app-wide spacing pass — audit paddings/gaps beyond the
  sidebar spots already fixed above.
- [ ] More SF Symbols usage generally — several spots use text-only labels
  or generic icons where a more specific SF Symbol would read better.
- [ ] Smoother transitions/animations throughout — several state changes
  (message send, model switch) currently cut instead of animating.
- [x] Model selector overhaul — user specifics: visual polish, missing
  per-model info, weak provider separation, doesn't show levels/cost/
  strength. Fixed all four:
  - **Provider separation**: each provider is now a real card (background +
    border), not just vertical spacing between groups.
  - **Levels/strength**: each provider's models now sort strongest-to-
    weakest using the same scoring heuristic that already picks the
    default model, instead of alphabetically — this was a real, previously
    unimplemented gap, not just a display issue.
  - **Cost**: real $/$$/$$$/Free price tier per model, from actual
    per-provider pricing — OpenRouter and blockrun.ai both publish genuine
    $/1M-token pricing in their `/models` response (verified live, one
    dollars-per-token as a string, the other dollars-per-million as a
    number — normalized to the same unit). No other provider's `/models`
    endpoint is reachable without a key to verify pricing presence, so
    every other provider shows no price tier rather than a guessed one.
  - **Missing info**: each row now shows the model's real description (from
    the catalog or VelaChat's curated entries) as a subtitle, plus
    icon-labeled context/resource/vision/tools/price tags instead of bare
    text.
- [x] Deployment target raised to `.macOS(.v26)` (tools-version bumped to
  6.2 to unlock it) per explicit user choice — all the `if #available
  (macOS 26.0, *)` gates and their pre-Tahoe fallback branches were then
  removed from `Materials.swift` since they're now dead code; `swift build`
  confirmed clean from scratch both before and after.

## Research findings (2026-08-18)

- **Liquid Glass**: real, stable SwiftUI framework API — `.glassEffect(_
  glass: Glass = .regular, in shape: some Shape = .capsule, isEnabled: Bool
  = true)`, `Glass.regular/.clear/.identity`, chainable `.tint(_:)`/
  `.interactive(_:)`, `GlassEffectContainer(spacing:)` for merging/morphing
  overlapping glass shapes, `.glassEffectID(_:in:)`/`.glassEffectUnion`,
  `.buttonStyle(.glass)`/`.buttonStyle(.glassProminent)`. Needs macOS
  26.0+; this dev machine is on 27/SDK 26.2 so it's available. It's plain
  framework API (not an Xcode-macro dependency like `@Entry`/`#Preview`
  were), so it compiles fine under `swift build` with no full Xcode. Since
  `Package.swift` targets `.macOS(.v15)`, adoption needs either bumping the
  deployment target to `.v26` (drops pre-Tahoe support — a real
  compatibility call, not made yet) or `if #available(macOS 26.0, *)`
  gating with the current `.ultraThinMaterial` styling as fallback. Apple's
  own HIG guidance: glass is for the *chrome/navigation layer* (toolbars,
  floating panels, popovers), used sparingly, not for large content
  backgrounds — so first adoption should target the composer bar, the
  floating top-trailing menu, popovers, and the sidebar search pill, not
  every card in the transcript.
- **blockrun.ai**: see punch list above — resolved and shipped.
- **Context compaction**: see punch list above — resolved and shipped.
  Other findings not yet acted on: Gemini CLI's own team is researching a
  "union-find clustering" alternative to flat single-summary compaction
  because of known recall problems on long sessions — worth revisiting if
  compaction quality is still a complaint after the current fixes land.
- **"Handoff" concept**: real term of art in OpenAI's Agents SDK (live
  control transfer between agents with different system prompts/tools —
  needs a real tool-calling loop, which VelaChat doesn't have yet). Closest
  *directly buildable* match: this very Claude Code environment has a local
  skill literally named `handoff` that compacts a conversation into a
  portable document for a fresh agent to resume from — that's what got
  built (see punch list above). A future, bigger version (actually
  switching the active provider/model mid-conversation via a skill flag)
  is buildable later without needing Phase 2; true agent-to-agent handoff
  genuinely needs Phase 2 (real tool calling) to exist first.

New feature ask (not yet scoped):
- [ ] Git support for working in git repos — likely ties into the future
  sandbox workstation (Phase 4) rather than standing alone; needs its own
  design pass once that phase starts, or a lighter-weight standalone version
  if wanted sooner.

## Feature backlog — ideas to discuss, nothing here is committed

The user pasted a large list of feature ideas sourced from looking at other
AI chat clients (ChatGPT, Claude, etc.). Explicitly flagged as discussion
material, not a build order. Grouped here by theme for when we do that
discussion pass.

**Memory & search**
- Persistent memory across conversations (user + project facts) — partial
  overlap with the already-planned Phase 1 "cross-conversation memory."
- Editable memories (correct what's stored, ChatGPT-style).
- Global memory (usable app-wide, not per-conversation).
- Semantic search across chats/files/memories/attachments (meaning, not
  exact text).
- Natural-language search over past conversations ("where did we discuss
  X") — needs to be token-efficient if the model itself can trigger it.
- Model capability normalization — one common capability schema so the UI
  always knows what a given model actually supports, instead of per-provider
  heuristics.
- Temporary chats (not retained in history or memory).

**Composer & message editing**
- Edit + resend an earlier message and regenerate from that point (partial
  overlap — editing already exists; "resend from an arbitrary earlier point"
  may already work via existing edit/regenerate, needs checking).
- Continue generating a reply that stopped early.
- Markdown-aware composer.
- Fullscreen composer for long inputs.
- Clipboard image pasting.
- Native macOS voice dictation into the composer.
- Paste-as-file: huge clipboard pastes auto-convert to a temp attachment.

**Attachments**
- Images, PDFs, plain text, source code (language-aware), ZIP archives,
  audio, video, whole folders (workspace-scoped).
- Attachment inspector (type/size/pages/estimated tokens/context status).
- Inclusion controls (choose which attached files actually get sent).
- Attachment summarization (compress large docs before sending).
- Overlaps directly with the already-planned Phase 3 (attachments) — this
  list is a much richer version of that phase than originally scoped.

**@-references**
- @file, @workspace, @memory, @chat, @url — explicit reference syntax in
  the composer pulling in scoped context on demand.

**Artifacts**
- HTML/SVG/diagram/JSON/table artifact types with dedicated rendering.
- Version history + diffing between artifact versions.
- Workspace-scoped artifact storage.
- Overlaps directly with the already-planned Phase 5 (artifacts) — again, a
  richer version of what was scoped.

**Diffs & applying changes**
- Code diffs, document diffs, accept/reject model-proposed edits.

**History**
- Local-first history (already true today — VelaChat has never used a
  server; worth confirming this framing matches what's wanted).

**Statistics**
- Message/token (input+output)/model-usage/attachment/conversation-date/
  duration/lifetime/workspace statistics.

**Appearance**
- Themes, accent colors, UI font selection, monospace font selection,
  density controls, message-width controls.

## "Everything now" round — shipped (2026-08-18)

User's answers: prioritize everything, feature focus = Attachments + Memory
& search + Composer & editing + Appearance & stats, git support lightweight
now, polish passes on my own judgment. `/goal` set to keep working and ask
nothing further until it's done — so this section is written as I go rather
than reconstructed after a check-in.

- **Transitions pass**: model/thinking picker labels animate on change
  (`.contentTransition`), composer status/active-skills/slash-menu rows
  transition in/out instead of popping.
- **Memory** (`Memory.swift`): `MemoryItem` — global, durable, editable
  facts, included in every request as a system message. Manual add/edit/
  delete in Settings. The model can also propose one via a ```remember```
  fenced block (same convention as `​```ask-user`) — renders as a
  `MemoryProposalCard` the user has to actually click Save on; nothing is
  ever stored automatically.
- **Attachments** (`Attachments.swift`): real `Attachment` model — image,
  text, code, PDF (via PDFKit text extraction). Composer: paperclip button
  (NSOpenPanel), `.onPasteCommand` for clipboard images/files,
  `.onDrop` for drag-and-drop, chip row with thumbnails and remove buttons,
  same chips shown read-only on sent messages in the transcript.
  **Real wire-format work, not just UI**: `APIMessage` (OpenAI-compatible)
  and `AnthropicMessage` both got custom `Encodable.encode(to:)`
  implementations that emit a plain string `content` when there are no
  images (unchanged behavior for the ~100% of messages without one) or the
  real multipart content-block array when there are — OpenAI's
  `image_url`/base64 data-URI shape, Anthropic's `image`/base64-`source`
  shape (images ordered before text, per Anthropic's own documented
  recommendation). Text/code/PDF attachments fold into the outgoing message
  text as labeled blocks instead, since that needs no wire-format change at
  all. A hard 60KB truncation cap prevents one huge pasted file from
  silently blowing the context budget — real summarization (compressing
  instead of cutting off) is a known gap, not built this round. Context
  token estimates now include attachment tokens (images estimated via the
  common ~765-token single-image rule of thumb, text by byte count) so the
  "% left" readout and auto-compact trigger both stay honest once
  attachments are in play. A notice warns (not blocks) when adding an image
  to a model that doesn't advertise vision support.
  **Explicitly not built this round** (real scope-limits, not oversights):
  ZIP archives (needs extraction), audio/video (no verified provider
  support checked), folder/workspace attachments (needs the not-yet-built
  workspace concept from Phase 4), the attachment inspector as its own
  panel (chips show filename+size inline instead), inclusion-controls UI
  (the `isIncluded` field exists on the model but there's no toggle in the
  UI yet — everything attached is currently always sent).
- **Codex path**: also wired for real — Responses API's `input_image`
  content-part shape, alongside `input_text`/`output_text`. All three chat
  paths (OpenAI-compatible, Anthropic, Codex) now handle image attachments
  for real, not just the two more obvious ones.
- **Composer**: Continue Generating (a real "Continue" action — hover-row
  button, context menu, sends a short visible follow-up turn asking the
  model to pick up where it stopped, same pattern every major chat app
  uses — no attempt to splice text onto the truncated message in place).
  Fullscreen composer (expand button opens a real large `TextEditor` sheet
  for long messages, ⌘Return to send from there too). Paste-as-file (a
  >3,000-character jump in one composer text change — a paste, not typing —
  auto-converts the whole draft into a text attachment instead of leaving a
  wall of text in the field). Clipboard image paste was already covered by
  the attachments work above.
  **Voice dictation — deliberately not built as a custom feature**: macOS's
  own system dictation (Fn key twice, or Edit menu → Start Dictation)
  already works in the composer's `TextField` with zero code, since it's a
  standard AppKit-backed text control — there's no supported public API for
  an app to add its own "start dictation" trigger button; that's a
  user-invoked system service, not something apps call into. Building a
  custom SFSpeechRecognizer pipeline instead would mean new microphone/
  speech-recognition entitlements in a plain SwiftPM-built app bundle
  (unverified whether `build-app.sh` sets those up correctly) for a
  capability that already exists — skipped as unnecessary risk for
  something that isn't actually missing.
- **Statistics** (`StatisticsView.swift`, Settings → About → Statistics):
  real aggregated numbers only — conversations, messages, attachments,
  pinned count, first-conversation date, input/output token totals, and a
  per-model reply-count breakdown. Required a real fix, not just a new
  view: `ChatMessage.usage` didn't exist before — token counts only lived
  in `AppModel.usageByMessage`, an in-memory-only cache that reset every
  relaunch, which would have made "lifetime" stats quietly lie. Added a
  persisted `usage` field to `ChatMessage` itself so the numbers are
  actually real lifetime totals, with an honest footnote that not every
  provider reports usage on every request.
- **Appearance** (`Theme.swift` + Settings): accent color presets (6 hues,
  math-derived strong/soft/bubble/selection variants from one base hex
  each, not 30+ hand-picked values), message width (Compact/Comfortable/
  Wide), density (Compact/Comfortable/Spacious, affecting message spacing
  and bubble padding). Applied via a computed `static var` re-read each
  access rather than a cached constant, so changes land on the next natural
  re-render — real and correct, just not a guaranteed-instant animated
  transition everywhere without a bigger reactive-theme refactor.
  **A full light appearance was deliberately not built**: most of
  `Theme.swift` is hand-picked dark-mode hex, not the system's own dynamic
  colors — a real light mode means redesigning the whole palette, not
  flipping a switch, and doing that blind (no visual verification possible
  in this sandbox) risks shipping illegible text-on-background pairs with
  no way to catch it. Accent-only theming was the safe subset of "themes"
  that doesn't touch anything a text color depends on.
  **UI font selection was also skipped**: most of the app's `Text` views
  set an explicit `.font(...)`, which always overrides any ambient
  environment default — a real "pick a UI font" feature would need
  rebasing every one of those calls through a theme-aware font, not a
  small change. Monospace/code font selection (a much more contained
  integration point) wasn't reached this round either, given time.
- **Lightweight git support** (`Attachment.fromGitFolder`): attach a folder
  via the paperclip button or drag-and-drop; if it's a real git repo (has
  a `.git` directory), VelaChat runs actual read-only `git` commands
  (`branch --show-current`, `status --short`, `diff --stat`, `log -1`) via
  `Process` and folds the real output into the message as a text
  attachment with a distinct branch icon. No shell involved (argument
  arrays, not string interpolation) and no arguments are ever user-typed,
  so there's no injection surface. Verified the exact commands against
  this real repo before shipping. Deliberately just a one-shot inspection
  at attach time — no standing per-conversation working directory, no bash
  tool, no write access — that's still Phase 4 (the sandbox workstation),
  not this pass. A non-git folder is rejected with a clear notice rather
  than silently attached as nothing.

**Feature backlog items resolved by the above** (marking status inline
rather than duplicating the whole list): Memory & search → Persistent
Memory ✅, Editable Memories ✅, Global Memory ✅ (Semantic/natural-language
search over past chats — not built; would need embeddings infra this app
doesn't have, see below). Attachments → Image/PDF/Text/Source Code ✅
(ZIP/audio/video/folder-as-generic-attachment — not built, folder is
git-repo-only for now). Composer & editing → Continue Generating ✅,
Fullscreen Composer ✅, Clipboard Image Pasting ✅, Paste as File ✅ (Voice
Dictation — already free at the OS level, no code needed; Markdown Composer
— not built, the composer is currently a plain `TextField`, syntax
highlighting-while-typing wasn't attempted). Appearance & stats → Accent
Colors ✅, Density Controls ✅, Message Width Controls ✅, all Statistics
items ✅ (Themes — accent-only, not a full light mode, see above; UI/
Monospace Font Selection — not built).

**Explicitly not attempted this round, with real reasons**: Semantic
search (needs embeddings — no vector store or embedding-model integration
exists); @-references (@file/@workspace/@memory/@chat/@url — a real
composer-syntax feature needing its own parsing/autocomplete design, not
started); Artifacts themes (HTML/SVG/diagram/JSON/table rendering, version
history, diffing — untouched, still Phase 5); Diffs & apply/reject changes
(needs real tool calling first — Phase 2); Workspace-level anything
(folder attachments are git-repo-only, not a general workspace concept);
Temporary chats (not retained in history) — not built.

## "Do all that + the rest of the phases" round (2026-08-18/19)

`/goal` set to "continue" — this section written as work lands, same as
the round above.

- **Phase 2: real tool calling — actually built, not simulated.** Verified
  the exact streaming wire format live against blockrun.ai (a real,
  keyless, tool-capable model) before writing any accumulation code: both
  the request shape (`tools: [{"type":"function","function":{...}}]`) and
  the response shape (`delta.tool_calls[].index/id/function.{name,
  arguments}` accumulating across chunks, `finish_reason:"tool_calls"`) —
  then verified the full round-trip (tool_calls → tool result → final
  answer) with a second live call. Built a real multi-round loop, entirely
  inside `CompatibleChatClient` (`ChatAPI.swift`) for both OpenAI-
  compatible and Anthropic (which needed its own `content_block_start`/
  `input_json_delta`/`content_block_stop` accumulation — different shape,
  same idea). Capped at 5 rounds. Two real tools shipped
  (`ToolCatalog` in `Tools.swift`): `search_conversations` (the actual
  "let the AI search past conversations, token-efficient" ask — returns
  only matching excerpts, not whole conversations) and `web_search`
  (replaces the old blind pre-fetch with the model actually deciding
  whether to search — pre-fetch is kept as a fallback only for models/
  providers that don't support real tool calling, so nothing regresses for
  them). Tool use shows up in the transcript as a real collapsed
  `ToolUseDisclosure` card (same `ActivityRow` pattern as search/reasoning
  disclosures), not hidden.
- **Phase 4: sandbox workstation — real safety testing changed the scope,
  on purpose.** Before writing any Swift, wrote and hand-tested a
  `sandbox-exec` confinement profile for a `bash` tool — it could not be
  made to reliably confine even a bare `/bin/echo` (repeated SIGABRT,
  `sandbox-exec` being undocumented and Apple-deprecated). Given the model
  (not the user) would decide what commands run, shipping a bash tool that
  *looks* sandboxed but isn't would be actively dangerous — so it wasn't
  shipped. What *did* ship instead: a real per-conversation private folder
  on disk (`SandboxManager`, `Sandbox.swift`) with `write_file`/
  `read_file`/`list_workspace_files` tools, safety-bounded by strict path
  validation (refuses `..`, absolute paths, anything that resolves outside
  the folder) rather than process sandboxing — a fundamentally safer
  mechanism since there's no code-execution surface at all. On by default
  (Settings → Tools), with a "Reveal in Finder" button for transparency.
  The honest reasoning (tested and rejected, not just skipped) is
  documented inline in `Sandbox.swift` and in the Settings footer text
  itself, not just here.
- **Improve memory**: `search_conversations` (above) is the real, biggest
  improvement — actual search instead of "hope it's still in context."
  Also fixed a real token-efficiency gap: memory injection was unbounded
  (every saved memory, on every single request, forever) — now capped at
  ~2,000 characters, most-recent-first, with an honest "(N older memories
  omitted)" note rather than silently dropping them with no explanation.
- **Caching for tokens and prompts — researched before building, not
  assumed.** Confirmed via the `claude-api` skill's own current reference
  (not just training recall, which was subtly wrong — the token thresholds
  are neither flat nor monotonic across model generations): OpenAI and
  DeepSeek both cache automatically server-side already, zero client code
  possible or needed — so the real client-side work there was *reading*
  the already-present usage fields (`prompt_tokens_details.cached_tokens`,
  `prompt_cache_hit_tokens`) instead of leaving real savings data on the
  table unread. Anthropic is the one that actually needed code: attaches
  `cache_control:{"type":"ephemeral"}` to the system block (which, per
  Anthropic's documented request order, also covers `tools` rendered ahead
  of it — one breakpoint, not one per section). Real cache-hit tokens now
  show inline per-message (existing usage label) and aggregated in
  Statistics — never estimated, only ever what the provider actually
  reported.
- **Phase 5: artifacts — shipped, scoped.** HTML/SVG/Mermaid fenced code
  blocks past ~120 characters get a real "Open in Artifact" button
  (`VelaCodeBlock`, `MarkdownTheme.swift`) — no new model-facing convention
  needed, models already write these language tags unprompted. Opens a
  real side panel (`ArtifactPanel`, `ChatView.swift`) with a live
  `WKWebView` preview (SVG/HTML render directly; Mermaid wraps the source
  with mermaid.js loaded from its CDN rather than vendoring the library),
  real copy, and a real `NSSavePanel` download — this is a normal
  unsandboxed Mac app, so that's just as available here as any other native
  app. `ArtifactPresenter` is injected once at the `WindowGroup` level
  (`VelaChatApp.swift`) so the button works from deep inside the Markdown
  rendering tree without threading a binding through every intermediate
  view. **Version history and diffing were not built** — there's no
  reliable way to know two artifacts across different messages are "the
  same" one without the model explicitly signaling that (a title/id
  convention), which wasn't attempted this round; each open is independent.

- **"Is everything done?" — no, and here's the actual honest remainder**:
  semantic search (needs embeddings — no vector infra exists),
  @-references (@file/@workspace/@memory/@chat/@url composer syntax — not
  started), artifact version history/diffing (see just above), ZIP/audio/
  video attachments, attachment inclusion-controls UI (the `isIncluded`
  field exists on `Attachment` but nothing toggles it yet), a real bash/
  shell tool (deliberately not built — see Phase 4 above), workspace-level
  git write access (git support today is read-only inspection at attach
  time, not tied to the write-capable workspace tools — they're
  intentionally two separate things). Full clean `swift build` passed at
  every stage of this round, including the final one after Phase 5.

## Decisions log

- 2026-08-18: `working.md` (this file) replaces re-deriving status from
  conversation history each session — update it as work lands, don't let it
  drift.
- 2026-08-18: `/goal` set ("continue working, ask before starting then none
  after") — this session proceeds through the rest of the "everything now"
  list (Composer quick-wins, Appearance/Stats, lightweight git support)
  without further check-ins; decisions get made and logged here instead of
  asked about.
- 2026-08-18: "everything now" round complete — all four feature themes
  (Attachments, Memory & search, Composer & editing, Appearance & stats)
  plus lightweight git support plus the polish pass all shipped, each
  verified with a clean `swift build` and a final full `rm -rf .build`
  rebuild at the end. Several items were deliberately skipped with reasons
  logged above rather than faked (full light theme, UI-wide font swap,
  custom voice dictation, semantic search) — real scope calls, not
  oversights. Still open for a future round: Phase 2 (real tool calling),
  Phase 4 (sandbox workstation — git support today is one-shot inspection
  only, no standing working directory), Phase 5 (artifacts), @-references,
  attachment inclusion-controls UI, ZIP/audio/video/generic-folder
  attachments.

## "Visual-trust-recovery" round (2026-08-19) — first real commits

After the "do all that + rest of phases" round, the user reported the app
crashing on launch (`swift run`/raw binary — `UNUserNotificationCenter`
aborts without a real `.app` bundle behind it) and, once fixed, reacted
strongly negatively to the Liquid Glass UI work — "you broke the old
theme," repeated across many messages with real screenshots. This became
its own multi-round plan-mode pass (see git log for the four resulting
commits — **this repo's first commits ever**, previously zero despite
substantial prior work).

**Root-cause pattern behind nearly every visual bug found**: custom-drawn
chrome layered on top of chrome the system (or Liquid Glass itself) already
draws — a doubled sidebar/chat divider (native `NavigationSplitView`
divider + a hand-drawn one), a doubled row-selection outline (native
`List` selection chrome + custom background, fixed by rewriting the
sidebar as a plain `ScrollView`), and two buttons whose icon color exactly
matched their own glass tint (rendering as blank circles).

**Shipped, in commit order**:
1. Crash fix + doubled-chrome fixes (sidebar list→ScrollView, sidebar/chat
   divider, search-toggle button) + pill/fullscreen-button removal.
2. Full bug-fix batch: two invisible-icon buttons, 7 native-blue focus
   rings on `.roundedBorder` fields (confirmed `.tint()` doesn't fix
   this — AppKit's focus ring ignores it; the real fix is
   `.textFieldStyle(.plain)` + a manual flat background/stroke, now a
   shared `flatFieldStyle()` modifier in `Materials.swift`), model picker
   auto-fetch-on-open, composer pills flattened off `GlassEffectContainer`
   (was visually fusing adjacent pills into one blob) onto flat chips with
   real press feedback, sidebar row outline shown at rest not just on
   hover, corner-radius bump, list-mutation animations, several smaller
   fixes (hardcoded radius, silent artifact-save failure, mermaid CDN
   error/loading state, dead `isPressed` param, missing empty/loading
   states).
3. **Error handling pass**, per explicit request: a real data-integrity
   race (Stop immediately followed by Send could let a cancelled
   generation's completion handler stomp a new one's state — fixed via
   `Conversation.currentGenerationID`), manual "Regenerate Title" silently
   failing and corrupting `titleIsCustom` on failure, compaction silently
   discarding its result, `send()`'s busy-guard having no feedback,
   Codex/Anthropic streaming loops missing the `consecutiveParseFailures`
   escape hatch the generic path already had.
4. Model picker rework (removed the now-redundant per-provider refresh
   icon, widened the popover 460×420 → 560×560, added a real
   "Recommended" badge), a typewriter erase/type animation for
   conversation-title changes, Settings restructured from one 10-section
   scroll into three tabs (Providers / General / Tools & Skills) — all
   verified via screenshots (including Settings' three tabs via the
   established temporary-default-then-revert technique).
5. Remaining spacing consolidation (two competing popover-row padding
   conventions unified, sidebar header inset aligned to its siblings).

**Known real gap, not yet resolved**: the auto-title-generation bug's
actual root cause (why the network call fails) is still unconfirmed — the
related bugs around it were fixed and a failure log line was added
(`[VelaChat] Title generation failed...`, visible in Console.app), but no
live failure was ever actually observed, since this sandbox can't drive
the UI interactively to send a fresh message and watch. Worth checking
next real session.

**Explicitly deferred, not forgotten**: the large feature-backlog rethink
(item D in the plan) needs its own scoped conversation, not blind
implementation — the user flagged wanting to reconsider the earlier
"everything now"/"do all that" backlog but never specified which parts.
The original paused roadmap (provider logos sourced from real brand
assets, @-references in the composer, artifact version history/diffing,
attachments v2 — ZIP/audio/video, a real test suite + CI, import from
ChatGPT/Claude exports) is still fully unbuilt, exactly where the
previous round's plan file left it.

---

## Session 2026-08-19 — fog killed; both audits' fixes applied

**Scroll-edge fog: built to the grilled spec, rejected live, removed
entirely at user request.** The scroll-aware blur+wash fog (built on
`onScrollGeometryChange`, verified in the local SDK) rendered as a dark
band over the transcript — the wash color sat darker than the surface's
actual rendered background, the exact failure the native
`scrollEdgeEffectStyle` had. The user said "just remove that feature
completely": modifier, strips, all call sites, the Settings toggle, and
`isEdgeBlurEnabled` are gone (commit 9215b0d). If fog ever returns, the
lesson is: the wash must sample the *rendered* composite (vibrancy
included), not `Theme.background`.

**UX/state audit — all ranked items fixed** (commits bb8f6e5, 9b0f27e):
duplicated General toggles deleted; MCP tool calls resolve servers by
longest sanitized prefix (hyphenated names were 100% broken); stop/fail/
branch reconcile running activity shimmer + Stop records partial usage;
quick composer no longer wipes the main draft (`sendPreservingDraftText`);
tool-loop usage accumulates across rounds via `ToolLoopUsage` in
ChatAPI.swift (was ~5x undercount on 5-round replies); conversation
switch closes artifact panel/find bar and scrolls to bottom; provider
editor got a visible back row (Esc) and in-form Remove — the removed
window toolbar was silently hiding both NavigationStack's back chevron
AND the toolbar-placed Remove; syncFields no longer clobbers mid-edit
fields; MCP tools now join the composed SystemPrompt inventory (compose
moved inside generationTask after the merge) with a cold-start status
message and a 10s tools/list timeout; workspace folders deleted with
their conversation (`SandboxManager.cleanup`); prune keeps notice-only
chats and bails under Settings; attach menu resets to root; per-message $
priced against the reply's own provider.

**Visual audit — concrete items fixed** (last commit): composer inner
inset 16→34 (caret aligns with transcript text), jump-rail glass chip
flattened, all six `.borderedProminent` primaries → `.glassProminent`.
Artifact preview's white canvas kept deliberately (SVG/Mermaid wrappers
hardcode white; unstyled HTML needs it). **Visual audit items NOT done**
(details were lost to context compaction — re-derive before attempting):
surfaceLow/Mid/High tokens, Theme.Motion tokens, VelaIconButtonStyle
sweep, sheet chrome unification, sidebar gutter pass, accent-as-fill
badge rework, noticeKind-driven error tinting, provider-identity
language unification, Radius.field token.

---

## Session 2026-08-19 (round 5) — usage redesign, ChatGPT provider, resilience, agentic core

Interleaved build order, one commit per phase, all pushed.

**Usage (a2cec17).** `ProviderKind.usageStyle` splits the popover three
ways: subscription providers (Codex, ChatGPT) show ONLY real plan
windows; API-key providers show local meters + live rate headers; local
providers hide the gauge entirely. `QuotaSnapshot` is Codable and
snapshots persist (`velachat.quota-snapshots`, 7-day prune) with an
honest "as of" age — headers only arrive on responses, so there is no
free refresh except ChatGPT's own probe. Local counts moved to a new
Statistics section (the previously-dead `ProviderUsageRow`).

**ChatGPT Web provider — scoped Swift port** (542e906, 6eb5646) of
`~/data/chatgpt-web-runtime-v0.9.0`. No bun/node, no local server, no
compat adapters. `ChatGPTWeb/`: session-cookie auth via
`/api/auth/session` (Keychain, single-flight refresh, stable
oai-device-id, challenge detection), account model discovery with
reasoning efforts, sentinel-gated SSE conversation turns with
prefix-diffed snapshots, real continuation via conversation+node
mapping (diverged local history starts a fresh upstream conversation
with explicit replay), stream-drop recovery from conversation state,
stop_conversation on Stop. **Login is a WKWebView sheet on chatgpt.com**
— a real browser context, so Cloudflare passes; cookies are read from
the web view's own store and validated before persisting. Chat surface
only; Work/Codex/websocket/native-tools are in ideas.md.

**Resilience (d3570e1).** NWPathMonitor → `isOnline` + composer chip;
offline sends hold their turn and fire on reconnect (10 min cap);
transient pre-stream failures retry twice with jittered backoff; once
any event has arrived, retries stop (replay could duplicate the turn).
Stream idle timeouts 3600s → 180s.

**AI pass (621c07d).** SystemPrompt now takes a `Context` and stamps
date/time+timezone, model, provider, user's first name, workspace file
listing, attachments, skills, memory count, plus preamble conventions
and errors-are-feedback guidance. `current_datetime` retired. ask-user
cards take 1–4 questions with header chips and recommended markers
(legacy payloads still decode). Auto-continue on length cuts (max 2).
Tool budget 5 → 10 with real loop detection in all three loops.
`ToolCatalog.execute` gained a 120s timeout race and JSON-argument
repair.

**Agentic core (a3cb15f, 34a9847).** `update_plan` → live checklist
card; `edit_file` + `search_files`; `run_command` behind
`CommandRunner`'s deliberately conservative allowlist (only known
read-only binaries and read-only git subcommands auto-approve —
operators, paths, sudo, `find -exec` and anything unknown pause on an
approval card with editable command, separate always-allow and
explicitly-armed allow-all); conversations can adopt a **real folder**
as workspace root (+ menu), still escape-proofed by
`SandboxManager.resolve`. `spawn_agents` runs ≤3 parallel subagents
with a read-only tool slice (no nesting/shell/writes/memory), off by
default, with per-fan-out confirmation and an optional cheaper model.

**Utility tools (307e7fe).** `create_schedule_item` (EventKit writes,
SDK-verified), `system_status` (IOKit battery, disk, memory, uptime),
`analyze_image` (Vision OCR + classification, offered only to
non-vision models). `ideas.md` created with everything deferred.

**Not done / next.** ChatGPT tool emulation, uploads, and native web
search (P8) were the planned cut line and remain unbuilt. The ChatGPT
provider has NOT been exercised against a live account in this session
— sign-in, discovery, and a streamed reply still need a real run. The
visual audit's token sweeps (surface/motion tokens, icon-button and
sheet unification, sidebar gutters) are still outstanding from round 4.

---

## Session 2026-08-19 (round 6) — bugs, CI, Sparkle, audit

**Bugs the user reported, all fixed.**
- *Blurred titlebar after collapsing the sidebar.* Root cause:
  `NavigationSplitView` re-installs its toolbar when the column actually
  collapses, and the band survived until relaunch. The sidebar now
  narrows to an **icon rail** instead of collapsing (the user's own
  idea), which removes the trigger entirely; belt and braces, the
  transcript opts out of the macOS 26 scroll-edge effect and the window
  re-nils a re-installed toolbar on resize.
- *Sidebar min-width broken / New Chat text wrapping.* Self-inflicted:
  the rail's 60pt width was being written to `velachat.sidebar-width`,
  so expanded launches used ideal=60. Width is now only persisted while
  expanded, and clamped on read as well as write.
- *ChatGPT login "browser may not be secure".* Not our bug — Google
  refuses OAuth in embedded web views, permanently. Added **browser
  cookie import** (Chromium via SQLite + Keychain-derived AES key,
  Firefox via plain SQLite, Safari via binarycookies with an honest Full
  Disk Access message) plus a paste-a-token escape hatch. Verified
  against the real browsers on this machine.
- *Usage gauge staleness.* Hover starts a debounced refresh, click
  forces one; ChatGPT uses its usage endpoint, others harvest headers
  from a cheap /models probe, and the popover states the data's age.

**Composer outline (diagnosis only, unchanged as instructed).** The dark
rim is the system Liquid Glass edge from `glassEffect(.regular)` in
`Materials.swift:8`, not app code — the app's own stroke is teal at 16%.
Options: `.clear` glass (soft rim), `.identity`/flat fill (no rim, no
glass), or drop the redundant accent stroke. Waiting on the user's pick.

**Shipping.** CI (`.github/workflows/build.yml`) builds on macos-26 with
a cached SwiftPM graph, runs tests, packages the `.app`, **launches it
and fails if it dies**, and uploads a per-commit artifact; tags publish
releases. Sparkle self-update is wired with an EdDSA keypair minted via
openssl (no Keychain involvement); the private key is the
`SPARKLE_PRIVATE_KEY` GitHub secret.

**The launch-crash catch.** Adding Sparkle produced a bundle that passed
"binary exists", "Info.plist exists", and `codesign --verify` and still
died instantly (`Library not loaded: @rpath/Sparkle.framework`) because
nothing added the rpath. Both the build script and CI now verify the
bundle actually runs. This is the reason the CI launch check exists.

**Audit findings fixed.** Image attachments were base64'd into
UserDefaults (a 200 KB screenshot cost 200 KB of preferences plist);
they now live in `AttachmentStore` on disk, verified with a seven-case
round-trip harness including legacy migration and missing-blob
degradation. Per-message state dictionaries (usage, search, plan, finish
reason, reveal queues) leaked on conversation and message deletion —
one `discardTransientState` covers them all now.

**Cohesion.** `DefaultsKey` (all 38 keys), `Limits` (truncation sizes,
timeouts, loop caps), `Theme.surfaceLow/Mid/High` + `velaBorder`
replacing nine ad-hoc opacities and 18 hand-written strokes. ChatView
2,595 → 821 lines across three files by responsibility; AppModel's
generation path extracted to `AppModel+Generation.swift`.

**System prompt** now assembles from conditional sections with
priorities and a token budget, so a model is never told about tools it
doesn't have. **TTFT**: first token flushes immediately instead of
waiting for a reveal tick, MCP servers pre-warm at launch instead of in
front of the first request, connections warm on launch/provider switch
(no speculative model requests), and TTFT is measured and reported per
provider in Statistics.

**Tests** run in CI (XCTest needs Xcode, which this machine lacks):
command classifier, prompt assembly and budget, tool-argument repair,
usage accumulation, quota header parsing, cookie recognition.

**Not started from the round-6 plan:** the memory system (P3 — SQLite +
embeddings + dreaming), Inspector/workspace work (P4), Mac-native pass
(P5 — App Intents, light mode, Services, universal binary), Textual
migration (P6). The ChatGPT provider still has not been exercised
against a live account.

### Memory system (round 6, later) — foundation + integration shipped

`Sources/VelaChat/Memory/`: `MemoryStore` (SQLite/WAL, facts + FTS5-indexed
chunks + Float32 embedding blobs), `MemoryEmbedder` (on-device),
`MemoryIndexer` (incremental + resumable backfill).

**The load-bearing finding: on-device embeddings cannot retrieve on
their own.** Measured, twice:
1. Mean-pooled `NLContextualEmbedding` puts every pair of English
   sentences in a 0.77–0.89 cosine band. For a real query, a note about
   *pizza dough* scored 0.855 while the correct answer scored 0.852.
   `NLEmbedding.sentenceEmbedding` separates the same pair 0.274 vs
   0.140, so it is now preferred and contextual is only a fallback.
2. Even then: the query "zzzqqq unrelated gibberish xyzzy" scored an
   unrelated note at **0.279 — higher than the correct hit for a real
   question (0.274)**. No absolute threshold survives that, and no
   relative one either (nonsense still yields a confident top hit).

So retrieval is **keyword-first**: FTS5 decides what is a candidate (it
cannot invent a match), embeddings only re-rank those candidates. Real
semantic recall needs a real model — that is exactly what the opt-in
pplx-embed/MLX upgrade is for, and it is now a functional requirement,
not a nice-to-have.

Verified against a seeded store (8/8) and against the running app: the
backfill indexed real messages with embeddings, and querying that live
database returns the right conversations for "keyboard mash", "michael
jackson story", and "bash script".

Wired in: recall injected into the send path (silent when nothing
matches), a "Drew on N memories and N past messages" line under replies
that expands with Open/forget per item (forget really deletes), a
per-provider "Send memories to this provider" switch, and index status +
controls in Settings.

**Still to do on memory:** dreaming (background synthesis, merging,
contradiction resolution, time-shifting), fact-layer migration into the
store (facts still live in the old `memories` array and are mirrored,
not moved), and the MLX/pplx-embed opt-in.

## Session 2026-08-19 (round 7) — Phase 0 audit, updater gate, sidebar revert

Working from `~/Downloads/velachat-implementation-plan.md`. Phase 0 is an
audit with a STOP gate; this round delivers `audit.md` plus two fixes that
surfaced while doing it.

### The audit found the plan wrong on four rows

Full detail in `audit.md`. The one that matters:

**Folder attach is not missing — it is substantially built.**
`Conversation.workspaceRootPath` (`Models.swift:1078`), `workspaceRoot` with
sandbox fallback (`Models.swift:1116`), `setWorkspaceRoot`/`clearWorkspaceRoot`
(`AppModel.swift:1613`/`1645`), persisted through `SavedConversation`, threaded
into the tools and command runner, with detach UI in Settings. `SandboxManager`'s
symlink hardening exists *because* a real project folder can be the root — the
comment says so. **Phase 3B must extend this, not build a parallel system.**

Also: offline handling is partial not missing (a 10-minute wait with a visible
note already exists, `AppModel+Generation.swift:450-475`); stop-and-keep-partial
is built (the gap is a *discard* variant); retry-with-a-different-model is built
and already lands as an `AlternateStepper` sibling (the gap is a one-click
affordance, not the capability).

Confirmed real: the cost-math bug (`Usage.swift:124-131` never prices
`cachedTokens`), missing crash-safe streaming (traced every `saveHistory()` call
site — none fire during a stream), and the ten zero-hit rows.

### TCC grants DO survive a rebuild — measured, not reasoned

The plan flagged this as a possible Phase 4 blocker. Built `just app` twice with
a real code change between them:

- `CDHash` changed (`4f6ad3fc…` → `39f11be4…`)
- designated requirement **unchanged**:
  `identifier "com.velachat.desktop" and certificate leaf = H"04979854…"`

It is cdhash-*independent*, so TCC still sees the same app. Ad-hoc signing the
same bundle for contrast gives `designated => cdhash H"…"` — bound to the hash,
lost on every rebuild. **`just setup-signing` is a Phase 4 prerequisite, not a
convenience.** Worth a README line.

Also learned: a comment-only source edit produces a byte-identical binary, so
the first attempt at this experiment measured nothing. Needed a real code change.

### Sparkle "Unable to Check For Updates" — fixed

The dialog named the app as **"debug"**, i.e. `Bundle.main` was `.build/debug/`.
`swift run` executes the raw binary with no Info.plist, so no `SUFeedURL`, no
`SUPublicEDKey`, no XPC services — and `SPUStandardUpdaterController` puts a
modal alert on screen at launch. The old comment in `Updater.swift` claimed
Sparkle "no-ops when the feed or key is missing"; it does not, and that comment
is gone. Now gated on `AppModel.isRunningAsBundledApp`, the same latch
`UNUserNotificationCenter` already needed for the same reason. Settings says why
the control is off rather than leaving a dead button.

### Sidebar header reverted

Brook: *"reverse this. this is bad. why is it right next to the traffic lights"*.
Reverse-applied the `SidebarView.swift` portion of `14beefa` — `VelaMark` is
back, the brand row returns to `.padding(.horizontal, 14)` below the titlebar
safe area, `.ignoresSafeArea(.container, edges: .top)` and `trafficLightInset`
are gone, and the rail's top padding returns to 10. Nothing else from that
commit was touched.

### `just run` XCFramework error — diagnosed, not a cache bug

`error: XCFramework Info.plist not found at '/Users/brooklyn/data/unsloth fork/…'`
— the checkout was renamed and `.build/workspace-state.json` stores absolute
paths. `just clean` fixes it. Grepped the shared SwiftPM cache: no stale paths,
so it was never implicated and `--disable-dependency-cache` would fix nothing.
Recorded in `AGENTS.md`; fixed the matching stale `${workspaceFolder:unsloth fork}`
in `.vscode/launch.json`. **Standing rule confirmed with Brook: build caching in
CI only, never locally.**

### Needs human verification

- The updater fix was verified structurally: `swift run` now shows exactly one
  onscreen window (the 1180×780 main window) and no alert panel, and the process
  stays alive. **A screenshot was not possible** — no Screen Recording permission
  in this session (`screencapture` returns "could not create image from window"),
  per the standing `AGENTS.md` limitation. Someone should eyeball it once.
- The sidebar revert builds clean but was **not** visually confirmed, same reason.
- TCC §4.1 is settled by signature analysis; an end-to-end grant → rebuild →
  recheck cycle still wants one human pass.
- **CI may be silently skipping tests.** `build.yml:47-52` still says "No test
  target yet" and guards on `swift test --list-tests`, but `Package.swift`
  declares `VelaChatTests` and six test files exist. Not changed this round —
  worth confirming before Phase 1 adds three required suites.

### Round 7 (continued) — Phase 1A shipped, Phase 1B protocol layer, Phase 2 cost math

Brook said "just finish", so the plan's per-phase STOP gates were dropped
and work continued straight through.

#### Phase 1A — egress controls (shipped)

`Redaction.swift`: `RedactionRule` (10 built-ins, email off by default),
`Redactor` with longest-match-wins overlap resolution, `RedactionStore`
persisting to `DefaultsKey.redactionRules`, and `EgressPolicy` — a
lock-guarded process-wide gate.

Two decisions worth recording:

- **The transcript stores the redacted text, not the original.** A
  matched credential is therefore never written to `UserDefaults` at all,
  and the transcript can never claim to have sent something it didn't.
  `ChatMessage.redactions` carries the spans; `RedactionChipRow` renders
  them above the bubble with rule name and match count.
- **Local-only mode is enforced at request construction, not in the
  picker.** `EgressPolicy.check(_:)` throws, so no call site can forget to
  test the result. Gated: `baseURL(for:)` (which every provider request,
  model fetch, and quota probe funnels through), the hardcoded Codex
  endpoint, all three ChatGPT web-client request sites, SearXNG search,
  and remote provider logos. Loopback means loopback — a LAN model server
  is still egress and is refused.

#### Phase 1B — verified findings that contradict the plan

The plan's launch invocation is wrong in two places, both confirmed
against real `claude` 2.1.236 runs:

1. **`--setting-sources ""` does NOT isolate.** A session launched with
   only that flag reported, in its own init handshake: the user's MCP
   servers (`claude.ai Google Drive`, connected), 15 inherited skills, and
   the full inherited slash-command list. The plan asked for this to be
   confirmed empirically — it fails.
   **What actually works:** `--setting-sources "" --strict-mcp-config
   --disable-slash-commands` → `mcp_servers: []`, `skills: []`,
   `slash_commands: []`. Encoded in `ClaudeExecutableLocator.arguments`.
   Residue: the built-in `agents` list is still reported. Those ship with
   Claude Code rather than being inherited config, so it is left alone.
2. **`--permission-prompt-tool` does not exist in 2.1.236.** Not in
   `--help`, and passing it produces no control frames. The plan's
   permission design needs rework against the real control protocol.
3. **`--bare` is a trap.** It looks like the isolation flag and is not:
   it forces auth to `ANTHROPIC_API_KEY`/`apiKeyHelper` and never reads
   OAuth or Keychain, which defeats the entire premise of the bridge.
   Recorded in `ClaudeExecutableLocator` so nobody reaches for it.

Two things the plan didn't know exist, both valuable:

- **`rate_limit_event`** arrives unprompted on the stream carrying
  `status`, `rateLimitType` ("five_hour"), and a real `resetsAt` epoch.
  This is a far better quota source than the OAuth endpoint the plan
  designated as fallback: it costs no extra request and can't itself be
  rate-limited. Phase 2's auto-resume should prefer it.
- **`cache_creation.{ephemeral_5m,ephemeral_1h}_input_tokens`** is real
  and present on live responses — exactly the TTL split Phase 2's cost
  math needs. It is no longer hypothetical.

Shipped: `ClaudeControlProtocol.swift` (forgiving decode — unknown frame
types become `.unknown` rather than throwing), `JSONValue.swift`,
`InstructionFiles.swift`, `ClaudeExecutableLocator.swift`.
Fixture recorded from real sessions at
`Tests/VelaChatTests/Fixtures/claude-stream.jsonl` (only absolute paths
scrubbed; every field and shape is as emitted).

**Not built:** `ClaudeProcessTransport`, `ClaudeBridgeSession`,
`ClaudeBackend`, and the `Backend.swift` abstraction (1C). The protocol
layer they need is done and tested; the process/session plumbing is not.

#### Phase 2 — cost math (shipped)

The bug was exactly as described. `UsageSummary.costUSD` now prices fresh
input, output, 5-minute writes at 1.25x, 1-hour writes at 2x, reads at
0.10x, and halves for batch. `ProviderKind.promptTokensIncludeCached`
encodes the per-provider convention (Anthropic excludes cache reads from
`input_tokens`; OpenAI-style includes them in `prompt_tokens`) so the
correction is a capability, not a guess at the call site. A
provider-reported cost always wins over derived math.

Concrete size of the old bug, on a 100k-prompt/80k-cached OpenAI-style
request: **$0.315 charged versus $0.099 actual — a 3.2x overcount.**
Anthropic went the other way, billing cache writes at nothing.

Threaded end to end: Anthropic's `cache_creation` split now decodes,
flows through `ToolLoopUsage`, and lands on `UsageSummary`. Where only a
flat `cache_creation_input_tokens` exists it is attributed to the
5-minute tier — the cheaper one, so it can only under-state, never invent.

**Verified, no change needed:** usage is already taken from the final
cumulative event, not summed. `ToolLoopUsage.observe` *replaces* within a
round and folds at round boundaries, which is correct since each tool
round is its own billed request.

**Not built in Phase 2:** the two-meter UI (subscription window vs.
dollars), auto-resume at window reset, Codex `app-server` usage, and
per-message cost on hover.

#### Needs human verification

- **No test in this round was executed.** XCTest needs Xcode, which this
  machine doesn't have. `RedactionTests`, `InstructionFilesTests`,
  `ClaudeControlProtocolTests`, and `CostMathTests` are written and the
  package builds, but they have only ever run in CI. The cost
  expectations were independently recomputed outside Swift and agree, but
  that is not the same as the suite passing.
- Redaction chips, the Privacy settings card, and the local-only sidebar
  banner build clean but were **not** seen rendered — no Screen Recording
  permission in this session.
- `--include-partial-messages` is wired into the argument builder but
  never exercised, since no transport spawns the process yet.

### Round 7 (continued) — CI that can fail, a dock icon, and the bug CI caught

#### CI was structurally incapable of failing

The test step guarded on `swift test --list-tests` and skipped on any
non-zero exit. A test target that fails to **build** exits non-zero — so
a broken test suite was reported as "no tests defined yet" and the run
went green. It has been running `swift test` directly since.

The first run under the new step failed immediately, and every error was
in `MemoryStoreTests`, a suite that had never compiled: `throw XCTSkip`
in a non-throwing method, and `XCTAssertNil(await ...)`, which cannot
work because XCTAssert takes an autoclosure and an autoclosure cannot
contain `await`. Auditing the suites added this round for the same class
of mistake turned up five more (XCTUnwrap is throwing, so its callers
must be marked `throws`). None of it had ever been compiled anywhere.

**Now green: 146 tests, 0 failures**, and the bundle-launch check passes.

#### The bug the tests caught the moment they could

`SystemPrompt.compose` budgeted sections with `continue`, so a section
that didn't fit was skipped and later, *smaller*, lower-priority sections
could still slip in behind it. A squeezed prompt therefore lost its tool
inventory while keeping the artifacts guidance — exactly the "random
subset" the test's own comment says must not happen.

Fixed as the file already described itself: environment and the tool
inventory are never dropped ("the two things a model genuinely cannot
work without"), and everything below them `break`s rather than
`continue`s so priority order is real. Two tests pin both halves.

This is the first real bug the restored CI found, in the first run it was
able to fail.

#### Dock icon

The app had no `CFBundleIconFile` at all, so macOS drew the generic blank
tile. `Scripts/make-icon.swift` renders the same marque as `VelaMark`,
reading its colors from `Theme.swift`'s hand-tuned teal family so the two
cannot drift. `just icon` regenerates; the `.icns` is **committed** and
copied by `build-app.sh` rather than generated during the build, because
rasterizing an SF Symbol needs AppKit and doing that on a runner with no
window server is the classic works-locally-fails-in-CI trap.

Verified live: `NSRunningApplication.icon()` returns the real icon with
all reps from 16 to 2048. It renders **blue** rather than teal because
this Mac has `AppleIconAppearanceTheme = TintedDark` — macOS 26 recolors
every dock icon system-wide. The palette underneath is correct; switching
icon appearance away from Tinted shows the seafoam and coral.

#### Also shipped this round

- **Crash-safe streaming.** Partial replies are now persisted while they
  arrive, throttled to `Limits.streamingPersistInterval` (4s) because the
  encode behind `saveHistory` walks every conversation. A recovered
  fragment is explicitly labelled partial — silently presenting a
  truncated answer as a finished one is worse than losing it.
- **Stop and discard**, distinct from stop-and-keep, on ⇧⌘. and the send
  button's context menu. Promotes an existing alternate back into place
  rather than destroying edit history, and leaves the user's turn alone.
- **Pre-send cost estimate** in the existing `ContextInspector`. Input
  only, and worded as an estimate everywhere: the token count is a
  character approximation and the reply length is unknowable in advance.

#### Needs human verification

- The app builds and launches, but **the window would not composite
  onscreen** on the last two launches. Investigated rather than assumed:
  the 1382x865 window *exists* in the window list with
  `kCGWindowIsOnscreen` unset, the process sits at 0.1% CPU, and there is
  no crash report. That is the flake `AGENTS.md` documents, so per its
  instruction it was not "fixed" with an AppKit fallback. Earlier launches
  this session did composite normally.
- Redaction chips, the Privacy card, the local-only banner, the pre-send
  cost row, and the new stop-and-discard menu item have never been seen
  rendered — no Screen Recording permission in this session.
