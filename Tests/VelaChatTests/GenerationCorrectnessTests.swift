import XCTest
@testable import VelaChat
import VelaCore

@MainActor
final class GenerationCorrectnessTests: XCTestCase {
    private final class DecisionBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var denied = false
        private(set) var questionDismissed = false
        func markDenied() { lock.lock(); denied = true; lock.unlock() }
        func markQuestionDismissed(_ answer: String?) { lock.lock(); questionDismissed = answer == nil; lock.unlock() }
    }
    private func attachment(_ name: String) -> Attachment {
        .fromText(filename: name, kind: .text, content: name, mimeType: "text/plain")
    }

    private func intent(
        conversation: Conversation,
        attachments: [Attachment],
        policy: SendIntent.DraftClearingPolicy
    ) -> SendIntent {
        let profile = ProviderProfile(kind: .openAI, name: "OpenAI", endpoint: "https://example.test/v1", model: "gpt-test")
        return SendIntent(
            identity: GenerationIdentity(conversationID: conversation.id),
            provider: profile,
            endpoint: profile.endpoint,
            requestedModel: profile.model,
            wireModel: profile.model,
            usesAutomaticModel: false,
            text: "hello",
            attachments: attachments,
            webSearchEnabled: false,
            usesNativeSearch: false,
            searchEndpoint: "",
            draftClearingPolicy: policy,
            draftTextSnapshot: conversation.draftText,
            draftAttachmentIDs: Set(attachments.map(\.id))
        )
    }

    func testAcceptedSendDoesNotClearDraftChangesMadeDuringPreparation() {
        let sent = attachment("sent.txt")
        let later = attachment("later.txt")
        let conversation = Conversation(draftText: "original")
        conversation.draftAttachments = [sent]
        let send = intent(conversation: conversation, attachments: [sent], policy: .textAndAttachments)

        conversation.draftText = "new text typed during discovery"
        conversation.draftAttachments.append(later)
        send.consumeAcceptedDraft(from: conversation)

        XCTAssertEqual(conversation.draftText, "new text typed during discovery")
        XCTAssertEqual(conversation.draftAttachments.map(\.id), [later.id])
    }

    func testQuickSendConsumesAttachmentsButPreservesMainComposerText() {
        let sent = attachment("sent.txt")
        let conversation = Conversation(draftText: "unfinished main-window draft")
        conversation.draftAttachments = [sent]
        let send = intent(conversation: conversation, attachments: [sent], policy: .attachmentsOnly)

        send.consumeAcceptedDraft(from: conversation)

        XCTAssertEqual(conversation.draftText, "unfinished main-window draft")
        XCTAssertTrue(conversation.draftAttachments.isEmpty)
    }

    func testBlobLivenessIncludesListedAndPendingDraftsAndRollbackSnapshots() {
        let messageAttachment = attachment("message.txt")
        let listedDraft = attachment("listed-draft.txt")
        let pendingDraft = attachment("pending-draft.txt")
        let rollbackAttachment = attachment("rollback.txt")

        let listed = Conversation(messages: [ChatMessage(role: "user", content: "hi", attachments: [messageAttachment])])
        listed.draftAttachments = [listedDraft]
        let pending = Conversation()
        pending.draftAttachments = [pendingDraft]
        let rollback = ChatMessage(role: "user", content: "old", attachments: [rollbackAttachment])

        let live = AppModel.liveAttachmentIDs(
            conversations: [listed],
            pendingConversation: pending,
            pendingRestorations: [[rollback]]
        )

        XCTAssertEqual(live, Set([messageAttachment.id, listedDraft.id, pendingDraft.id, rollbackAttachment.id]))
    }

    func testGenerationIdentitiesForSameConversationRemainDistinct() {
        let conversationID = UUID()
        XCTAssertNotEqual(
            GenerationIdentity(conversationID: conversationID),
            GenerationIdentity(conversationID: conversationID)
        )
    }

    func testBackfillCanonicalizesAnthropicAndClaudeCacheInputWithoutDoubleCountingOpenAI() {
        let summary = UsageSummary(
            promptTokens: 10,
            completionTokens: 3,
            cachedTokens: 20,
            cacheCreation5mTokens: 4,
            cacheCreation1hTokens: 6
        )

        XCTAssertEqual(AppModel.canonicalBackfillInputTokens(summary, providerKind: .anthropic), 40)
        XCTAssertEqual(AppModel.canonicalBackfillInputTokens(summary, providerKind: .claudeCode), 40)
        XCTAssertEqual(AppModel.canonicalBackfillInputTokens(summary, providerKind: .openAI), 10)
    }

    func testBackfillKeepsMissingAnthropicInputUnknown() {
        let outputOnly = UsageSummary(completionTokens: 7)
        XCTAssertNil(AppModel.canonicalBackfillInputTokens(outputOnly, providerKind: .anthropic))
    }

    func testDraftContextSignatureChangesForSameLengthEditsAndInclusion() {
        let model = AppModel()
        let file = attachment("draft.txt")
        let conversation = Conversation(draftText: "abcd")
        conversation.draftAttachments = [file]
        let first = model.draftContextSignature(conversation)

        conversation.draftText = "wxyz"
        let edited = model.draftContextSignature(conversation)
        XCTAssertNotEqual(first, edited)

        conversation.draftAttachments[0].isIncluded = false
        XCTAssertNotEqual(edited, model.draftContextSignature(conversation))
    }

    func testPostCompactionEstimateIncludesSummaryAndEarlierPins() {
        var pinned = ChatMessage(role: "user", content: "PINNED EXACT VALUE 123")
        pinned.isPinned = true
        let oldReply = ChatMessage(role: "assistant", content: "old reply")
        let marker = ChatMessage(role: "compaction", content: "summary with /exact/path")
        let recent = ChatMessage(role: "user", content: "recent turn")
        let conversation = Conversation(messages: [pinned, oldReply, marker, recent])
        let model = AppModel()

        let measured = model.transcriptUnits(for: conversation).units
        let expectedMinimum = TokenCalibration.units(of: marker.content)
            + TokenCalibration.units(of: pinned.content)
            + TokenCalibration.units(of: recent.content)
        XCTAssertGreaterThan(measured, expectedMinimum, "request wrapper text plus summary, pin, and recent turn must all be counted")
    }

    func testMessagePersistsImmutableProviderIdentity() throws {
        let providerID = UUID()
        let message = ChatMessage(
            role: "assistant",
            content: "done",
            providerName: "Renamable display name",
            providerID: providerID,
            providerKind: .openRouter,
            modelID: "openai/gpt-test"
        )
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.providerID, providerID)
        XCTAssertEqual(decoded.providerKind, .openRouter)
        XCTAssertEqual(decoded.modelID, "openai/gpt-test")
    }

    func testRoutedTelemetryKeepsRequestedAndWireModelsDistinct() {
        let profile = ProviderProfile(kind: .openRouter, name: "OpenRouter", endpoint: "https://openrouter.ai/api/v1")
        let prepared = PreparedRequest(
            profile: profile,
            requestedModel: "openai/gpt-5",
            wireModel: "openai/gpt-5:online",
            thinking: .auto,
            messages: [ChatMessage(role: "user", content: "hello")],
            tools: [],
            requestedOutputTokens: 0
        )
        let wireUsage = RequestUsage(
            providerID: profile.id,
            requestedModelID: "openai/gpt-5:online",
            effectiveModelID: "openai/gpt-5:online",
            purpose: .chat,
            outcome: .succeeded,
            inputTokens: 10,
            outputTokens: 2
        )
        let normalized = AppModel.normalizedRequestUsage(wireUsage, preparedRequest: prepared)
        XCTAssertEqual(normalized.requestedModelID, "openai/gpt-5")
        XCTAssertEqual(normalized.effectiveModelID, "openai/gpt-5:online")
    }

    func testCancellingConversationResolvesApprovalsAndQuestions() throws {
        let model = AppModel()
        let conversationID = UUID()
        let box = DecisionBox()
        let payload = try JSONDecoder().decode(
            AskUserQuestionPayload.self,
            from: Data(#"{"question":"Continue?","options":[]}"#.utf8)
        )
        model.installPendingApproval(AppModel.CommandApproval(
            conversationID: conversationID,
            command: "echo test",
            directory: URL(fileURLWithPath: "/tmp"),
            reason: "test",
            decide: { decision in if case .deny = decision { box.markDenied() } }
        ))
        model.installPendingQuestion(AppModel.PendingQuestion(
            conversationID: conversationID,
            payload: payload,
            respond: box.markQuestionDismissed
        ))

        model.cancelPendingInteractions(conversationID: conversationID)

        XCTAssertTrue(box.denied)
        XCTAssertTrue(box.questionDismissed)
        XCTAssertNil(model.pendingApprovalsByConversation[conversationID])
        XCTAssertNil(model.pendingQuestionsByConversation[conversationID])
    }

    func testStaleGenerationCannotInstallApproval() {
        let model = AppModel()
        let conversationID = UUID()
        let stale = GenerationIdentity(conversationID: conversationID)
        let box = DecisionBox()
        model.installPendingApproval(AppModel.CommandApproval(
            conversationID: conversationID,
            generationIdentity: stale,
            command: "echo test",
            directory: URL(fileURLWithPath: "/tmp"),
            reason: "test",
            decide: { decision in if case .deny = decision { box.markDenied() } }
        ))
        XCTAssertTrue(box.denied)
        XCTAssertNil(model.pendingApprovalsByConversation[conversationID])
    }
}
