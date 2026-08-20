# Phase 0 — Audit

**Repo:** `github.com/bybrooklyn/velachat` · **Audited at:** `3250ad9` · **Date:** 2026-08-19

Ground truth for every row of the implementation plan's table. The plan's preliminary
reads were marked *"verify, do not trust"* — **four of them are wrong**, and one is wrong
in the direction that would have caused duplicate systems to be built.

Method: source reading against `Sources/VelaChat` (54 files, 22,592 lines), plus two
measured experiments (§4). No product behavior was changed for this audit.

---

## 1. Corrections — the plan is wrong about these four

### 1.1 Folder attach — **PARTIAL, not missing** ⚠️ *most consequential*

The plan says "Missing — `NSOpenPanel` exists in Settings/ChatView/QuickComposer for other
purposes." In fact a project-folder workspace is substantially built and persisted:

| Piece | Location |
|---|---|
| Storage | `Conversation.workspaceRootPath: String?` — `Models.swift:1078` |
| Resolution (falls back to sandbox) | `Conversation.workspaceRoot` — `Models.swift:1116` |
| Attach | `AppModel.setWorkspaceRoot(_:)` — `AppModel.swift:1613` |
| Detach | `AppModel.clearWorkspaceRoot(for:)` — `AppModel.swift:1645` |
| Persistence | `SavedConversation` — `Models.swift:1170`, `AppModel.swift:1845`/`1871` |
| Threaded into tools | `AppModel+Generation.swift:222`, `270`, `362`, `597` |
| Detach UI | `SettingsView.swift:522` |
| Prompt awareness | `promptContext.hasAttachedFolder` — `AppModel+Generation.swift:366` |

`SandboxManager.resolve` (`Sandbox.swift:52`) already hardens this against symlink escape
*specifically because* a real project folder can be the root — the comment says so
outright.

**Still missing:** `.gitignore`-aware ignore patterns, recent-projects list, sidebar drop
target / Finder drag-and-drop, git branch in the header, and the **whole-folder-read /
write-requires-approval** gate that Phase 3B calls its invariant.

**Consequence: Phase 3B must extend this, not build a second workspace system.**

### 1.2 Offline compose queue — **PARTIAL, not missing**

`AppModel+Generation.swift:450-475` already detects an unreachable network, holds the send,
posts a visible "Offline — waiting for the network" activity note, and gives up honestly
after 10 minutes. What is missing is *queue semantics*: it blocks the in-flight send task
rather than accepting the message, releasing the composer, and rendering a queued state in
the transcript.

### 1.3 Stop and keep partial — **BUILT** (the plan says "Unclear")

`stopGeneration` (`AppModel+Generation.swift:644`) flushes the reveal buffer, clears
`isStreaming`, reconciles running activities so tools don't shimmer forever, and records
usage for what was consumed. **Partial output is retained.** Also resolves a pending
`ask_user` continuation first, which would otherwise leak.

**Missing:** the *other* half — a distinct stop-**and-discard** action. Today there is one
Stop and it always keeps.

### 1.4 Retry with a different model — **BUILT, but two steps** (the plan says "Unclear")

`regenerate(_:)` (`AppModel.swift:1582`) works on any assistant reply, uses whatever
provider/model is currently selected, and preserves the prior reply as an alternate
(`AppModel+Generation.swift:88-89`) — so a cross-provider retry already lands as a sibling
in `AlternateStepper`, exactly as Phase 1D requires. `selectProviderAndModel`
(`AppModel.swift:737`) already switches provider and model together.

**Missing:** a one-click "Retry with…" model picker in the message action row
(`MessageViews.swift:265-278`, `415-435`). The capability exists; the affordance doesn't.

---

## 2. Verified as the plan expected

### Broken

| Item | Finding |
|---|---|
| **Cost math** | `UsageSummary.costUSD(for:)` — `Usage.swift:124-131` — is exactly `(prompt × inputPrice + completion × outputPrice) / 1_000_000`. `UsageSummary.cachedTokens` (`Models.swift:1340`) is parsed from the wire (`ChatAPI.swift:1376`, `prompt_tokens_details.cached_tokens`) and **never priced**. There is no cache-*creation* field anywhere in the model, so writes cannot be priced even in principle. Phase 2's description is accurate verbatim. |

### Missing (confirmed)

| Item | Evidence |
|---|---|
| **Crash-safe streaming** | Traced every `saveHistory()` call in `AppModel+Generation.swift`: lines **102, 667, 995, 1140, 1180** — send start, stop, after finish, compaction, cleanup. **None during the stream.** With the 1s debounce (`AppModel.swift:725`) a hard quit 30s into a reply keeps only ~1s of text; `reconcileInterruptedMessages` (`AppModel.swift:1884`) then stamps *"Interrupted before finishing."* |
| **Diff rendering** | `editFileResult` (`Tools.swift:687-708`) returns the string `"Edited <path> — replaced N occurrence(s)."` No hunks, no structure. |
| **Security-scoped bookmarks** | `workspaceRootPath` is a plain `String?`. Zero `securityScoped` / `bookmarkData` hits. Phase 3A's `Workspace` enum is genuinely new. |
| **Redaction rules** | Zero hits. |
| **Local-only mode** | Zero hits; the three "local-only" strings are comments about `role: "notice"` cards. `ProviderKind.isLocal` (`Models.swift:177`) exists and is the natural hook, but enforces nothing. |
| **Checkpoints / rewind** | Zero hits. |
| **Quick Look** | Zero `QLPreview` hits. |
| **Multi-window / state restoration** | Zero `NSWindow`/restoration hits. |
| **Spotlight indexing** | Zero `CoreSpotlight` hits; the "Spotlight" strings are comments about ⌘K and the hotkey. |
| **App Intents / Shortcuts** | Zero hits. |
| **Services menu / Finder Quick Action** | Zero hits. One `NSSharingServicePicker` (`MessageViews.swift:507`) is the per-message share sheet. |
| **Computer use** | Zero `AXUIElement` / `ScreenCaptureKit` / `CGEvent` hits. |
| **Claude Code bridge** | Zero hits. |

### Partial

| Item | Built | Missing |
|---|---|---|
| **Pre-send cost/context preview** | `ContextButton` (`Components.swift:265`) shows a live fill ring, warning-tinted past 80%; `ContextInspector` (`Components.swift:904`) shows "% left", used/total tokens, a manual context-window override, and compaction. | **No cost estimate at all.** Phase 1D extends this popover; it must be labelled an estimate (invariant 5). |

### Built — no work needed

| Item | Location |
|---|---|
| Live quota from response headers | `QuotaSnapshot` `Models.swift:1207`; `probeQuotaHeaders` `ChatAPI.swift:56`; `refreshQuotaHeaders` `ProviderStore.swift:616`; persisted `AppModel.swift:382`/`431`; gauge `UsageViews.swift:199` |
| Per-reply cost display | `MessageViews.swift:310` |
| Usage ledger / windows | `UsageStore` `Usage.swift:49` — hourly buckets, 5h/today/week/month, 35-day prune |
| Auto-continue past max tokens | `ChatStreamEvent.finished(reason:)` `Models.swift:1322`; loop `AppModel+Generation.swift:454`; manual `continueGenerating` `AppModel.swift:1603` |
| Branch from message | `branchConversation(from:in:)` `AppModel.swift:1045`; `AlternateStepper` `MessageViews.swift:943` |
| Find in chat | `ChatFindBar` `ComposerMenus.swift:316`; wired `ChatView.swift:197` |
| Export | `Export.swift` — Markdown + PDF via CTFramesetter |
| MCP client | `McpClient` actor `McpClient.swift:44` |
| Skills | `SkillsStore` `Skills.swift:43` |
| Subagents | `Subagents.swift`; gated `AppModel+Generation.swift:154`, capped at 3 |
| Command palette | `CommandPaletteView.swift:21` |
| Sandbox workspace | `SandboxManager` `Sandbox.swift:31` |
| Approval card | `CommandApprovalCard` `ReplyCards.swift:83` |
| Plan / ask-user cards | `PlanCard` `ReplyCards.swift:172`; `AskUserQuestionCard` `ReplyCards.swift:264` |
| Artifacts + inspector | `Artifacts.swift` |

---

## 3. Repo facts the plan asked for

**`Package.swift` targets** — `.executableTarget(VelaChat)` at `Sources/VelaChat`, and
`.testTarget(VelaChatTests)` at `Tests/VelaChatTests`. Dependencies: `swift-markdown-ui`
(2.x), vendored `HighlightSwift` and `KeyboardShortcuts` (both patched to drop Xcode-only
`@Entry`/`#Preview` macros, unavailable under a Command-Line-Tools-only toolchain), and
`Sparkle` (2.9.6, a binary xcframework). `platforms: [.macOS(.v26)]`,
`swiftLanguageModes: [.v5]`.

**Info.plist usage strings** — generated inline by `Scripts/build-app.sh:38-89`:
`NSCalendarsFullAccessUsageDescription`, `NSRemindersFullAccessUsageDescription`, and
`NSAppTransportSecurity` → `NSAllowsLocalNetworking`. Nothing for Accessibility or Screen
Recording — correctly, since **macOS defines no Info.plist usage key for either**; both are
TCC-prompt-only, which is why §4.1 is the real Phase 4 gate.

**Instruction files** — `AGENTS.md` is a real file; **`CLAUDE.md` is a symlink to it.**
That is precisely the fourth case Phase 1's `InstructionFiles.swift` must handle, and it is
a live fixture in this very repo rather than a hypothetical.

---

## 4. Measured experiments

### 4.1 Do TCC grants survive a rebuild under `just setup-signing`? — **YES** ✅

The plan calls this a potential blocking finding for Phase 4. It is resolved by
measurement, not inference.

Built `just app` twice with a real code change between the two so the binary hash moved
(a comment-only edit was tried first and produced a byte-identical binary — worth knowing).

| | Build A | Build C (after code change) |
|---|---|---|
| `CDHash` | `4f6ad3fc…` | `39f11be4…` **(changed)** |
| `Authority` | `VelaChat Local Dev` | `VelaChat Local Dev` |
| **Designated requirement** | `identifier "com.velachat.desktop" and certificate leaf = H"04979854…"` | **identical** |

The designated requirement is **cdhash-independent** — it names the bundle identifier and
the leaf certificate. TCC matches on the designated requirement, so a rebuild is still
"the same app" and grants persist.

Contrast, measured on an ad-hoc-signed copy of the same bundle:

```
Signature=adhoc
designated => cdhash H"dddd80a6…"
```

Ad-hoc signing binds the requirement **to the cdhash itself**, which changes on every
rebuild — that is the configuration in which grants are silently lost.

**Conclusion:** `just setup-signing` is a hard prerequisite for Phase 4, not an
optional convenience. With it, grants survive. Without it, they cannot. This should be
stated in the README exactly that way.

*Not tested:* an end-to-end grant-then-rebuild-then-recheck cycle, because granting
Accessibility requires GUI interaction this agent session cannot perform (no Accessibility
permission — see `AGENTS.md`). The signature analysis above determines the outcome, but a
human should confirm once.

### 4.2 The `just run` failure — stale absolute path, not a cache problem

Observed:

```
error: XCFramework Info.plist not found at
  '/Users/brooklyn/data/unsloth fork/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework'
```

The checkout is now `velachat`; `unsloth fork` is its former name. `.build/workspace-state.json`
stores **absolute** paths, so a `.build/` carried across the rename pointed at a directory
that no longer exists. `just clean` resolved it, and the stale reference is confirmed gone
from the current `workspace-state.json`.

Grepped `~/Library/Caches/org.swift.swiftpm` (`artifacts/`, `repositories/`, `manifests/`)
for `unsloth fork`: **no hits.** SwiftPM's shared cache was never implicated, so disabling
it (`--disable-dependency-cache`) would have cost network re-fetches without preventing
this. Recorded in `AGENTS.md` instead. A stale sibling remains in `.vscode/launch.json`
(`${workspaceFolder:unsloth fork}`), fixed in this round.

---

## 5. Open items and cautions

1. **CI's test guard is stale.** `.github/workflows/build.yml:47-52` says *"No test target
   yet — this stays green until one exists."* But `Package.swift` declares `VelaChatTests`
   and `Tests/VelaChatTests/` holds six test files. The guard runs
   `swift test --list-tests`; if that exits non-zero for any reason, **every test silently
   skips and CI still goes green.** Worth confirming tests actually run before Phase 1
   adds three required suites. *Not changed in this phase.*
2. **`--setting-sources ""` isolation — RESOLVED, and it FAILS.** Measured against real
   `claude` 2.1.236: that flag alone still reported the user's MCP servers, 15 inherited
   skills, and their full slash-command list in the init handshake. The working combination
   is `--setting-sources "" --strict-mcp-config --disable-slash-commands`. Two further
   findings: `--permission-prompt-tool` **does not exist** in this version (the plan's
   launch invocation names it), and `--bare` must never be used — it forces auth to
   `ANTHROPIC_API_KEY` and never reads OAuth, defeating the bridge's premise. Details in
   `working.md`.
3. **Commit drift.** The plan targets `dc07c65`; this audit is against `3250ad9`.
4. **`_recovered/` is tracked** (12 files under `_recovered/audit-1711Z/`) — an older
   recovery snapshot committed to the repo. Not touched; flagged only so it isn't mistaken
   for live source.

---

## 6. Recommended pruning before Phase 1

- **Phase 3B** — rewrite as *extend* the existing workspace-root feature (§1.1). The listed
  work reduces to ignore patterns, recents, drag-and-drop, the git-branch header, and the
  write-approval gate.
- **Phase 1D** — drop "retry with a different model" to an affordance-only task (§1.4);
  reduce "stop and keep partial" to adding stop-**and-discard** (§1.3); rescope "offline
  compose queue" to true queue semantics on top of the existing wait (§1.2).
- **Phase 1D crash-safe streaming and the Phase 2 cost rewrite are confirmed real** and
  should keep their full scope.
- **Phase 4** — record §4.1 in the README as stated: `just setup-signing` is a prerequisite,
  not a nicety.
