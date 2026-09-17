import ShitsuraeCore
import Testing
@testable import Shitsurae

@Suite("Arrange action result presentation")
struct ArrangeActionResultTests {
    @Test(arguments: [("success", 0), ("partial", 51), ("failed", 50)])
    func cliCompletionRefreshesRuntimeOnlyAfterActiveLeaseEnds(result: String, exitCode: Int) throws {
        let coordinator = ArrangeOperationCoordinator()
        let idle = coordinator.status()
        let token = try coordinator.tryAdmit(requestID: "cli", operation: .arrangeSet)
        coordinator.update(token: token, phase: .placing, inFlight: true)
        let busy = coordinator.status()
        #expect(!ArrangeOperationPollPresentation.make(previous: idle, next: busy).shouldRefreshRuntime)
        coordinator.finish(token: token, result: result, exitCode: exitCode, detail: "frameDidNotConverge")
        let complete = coordinator.status()
        let presentation = ArrangeOperationPollPresentation.make(previous: busy, next: complete)
        #expect(presentation.shouldRefreshRuntime)
        #expect(presentation.label == "Apply Layout Set")
        #expect(presentation.outcome?.kind == (exitCode == 0 ? .success : result == "partial" ? .partial : .failed))
        #expect(!ArrangeOperationPollPresentation.make(previous: complete, next: complete).shouldRefreshRuntime)
    }

    @Test func latestDisplayGenerationIsCoalescedAndConfigInvalidationDropsStaleEvent() throws {
        var events = DisplayChangeEventState()
        events.recordDisplayChange()
        let started = events.beginLatest()
        let first = try #require(started)
        events.recordDisplayChange()
        events.recordDisplayChange()
        let latest = events.generation
        events.didAdmit(first)
        #expect(events.pendingGeneration == latest)
        let whileProcessing = events.beginLatest()
        #expect(whileProcessing == nil)
        events.finish()
        let next = events.beginLatest()
        #expect(next == latest)
        events.didAdmit(latest)
        events.finish()
        let done = events.beginLatest()
        #expect(done == nil)
        events.recordDisplayChange()
        events.invalidateForConfigurationChange()
        #expect(events.pendingGeneration == nil)
    }

    @Test func userFacingPhaseDoesNotExposeJournalOrOwnershipTerms() {
        #expect(ArrangeOperationPhase.journaled.displayLabel == "Preparing")
        #expect(ArrangeOperationPhase.ownershipCommitted.displayLabel == "Placing Windows")
    }
    private func result(
        _ value: String,
        unresolved: [PendingUnresolvedSlot] = []
    ) -> LayoutSetExecutionJSON {
        LayoutSetExecutionJSON(
            requestID: "request",
            setName: "mobile",
            result: value,
            phase: "finalizing",
            ownershipCommitted: true,
            selectedSet: "mobile",
            memberResults: [],
            releasedCount: 0,
            transferredCount: 0,
            unresolved: unresolved,
            warnings: [],
            focusOutcome: "notRequested",
            recoveryRequired: false,
            elapsedMS: 1,
            exitCode: value == "success" ? 0 : ErrorCode.partialSuccess.rawValue
        )
    }

    @Test func partialResultNeverPresentsAsSuccess() {
        let presentation = ArrangeActionResultPresentation.make(
            result: result(
                "partial",
                unresolved: [PendingUnresolvedSlot(slot: 2, spaceID: 1, reason: "windowNotFound")]
            )
        )

        #expect(presentation.kind == .partial)
        #expect(presentation.message == "windowNotFound")
        #expect(ArrangeActionResultPresentation.make(result: result("success")).kind == .success)
        #expect(ArrangeActionResultPresentation.make(result: result("failed")).kind == .failed)
    }

    @Test func protectedAdoptedResultAndCLIPollRemainPartialWithRecoveryReason() throws {
        let reason = "retainedAdoptedGeometryBlocked"
        let execution = result("partial", unresolved: [PendingUnresolvedSlot(slot: 7, spaceID: 1, reason: reason)])
        let presentation = ArrangeActionResultPresentation.make(result: execution)
        #expect(presentation.kind == .partial && presentation.message == reason)
        for operation in [ArrangeOperationKind.arrange, .arrangeSet] {
            let coordinator = ArrangeOperationCoordinator()
            let token = try coordinator.tryAdmit(requestID: "protected-adopted", operation: operation)
            let busy = coordinator.status()
            coordinator.finish(token: token, result: "partial", exitCode: 51, detail: reason)
            let poll = ArrangeOperationPollPresentation.make(previous: busy, next: coordinator.status())
            #expect(poll.shouldRefreshRuntime && poll.outcome?.kind == .partial && poll.outcome?.message == reason)
        }
        let journal = PendingLayoutTransition(requestID: "protected-adopted", scopeKind: .local, phase: .postcommit,
            sourceLayoutNames: ["main"], targetLayoutNames: ["main"], sourceSelectedSet: nil, targetSet: nil,
            definitionDigest: "definition", topologyDigest: "topology")
        #expect(ArrangeActionResultPresentation.shouldOfferRecovery(state: RuntimeState(pendingLayoutTransition: journal), needsReapply: false))
    }

    @Test func pendingVisibilityAloneDoesNotOfferTransitionRecovery() {
        let visibilityOnly = RuntimeState(
            pendingVisibilityConvergences: [
                PendingVisibilityConvergence(
                    requestID: "visibility",
                    startedAt: "2026-09-16T00:00:00Z",
                    displayID: "primary",
                    layoutName: "mobile",
                    targetSpaceID: 1
                ),
            ]
        )
        #expect(!ArrangeActionResultPresentation.shouldOfferRecovery(
            state: visibilityOnly,
            needsReapply: false
        ))
        #expect(ArrangeActionResultPresentation.shouldOfferRecovery(
            state: visibilityOnly,
            needsReapply: true
        ))

        let transition = PendingLayoutTransition(
            requestID: "transition",
            scopeKind: .layoutSet,
            phase: .precommit,
            sourceLayoutNames: ["home"],
            targetLayoutNames: ["mobile"],
            sourceSelectedSet: nil,
            targetSet: nil,
            definitionDigest: "digest",
            topologyDigest: "topology"
        )
        #expect(ArrangeActionResultPresentation.shouldOfferRecovery(
            state: RuntimeState(pendingLayoutTransition: transition),
            needsReapply: false
        ))
    }

    @Test func unavailableOrInvalidConfigOffersRecoveryOnlyForSavedManagement() {
        let active = RuntimeState(activeWorkspaces: [ActiveWorkspace(displayID: "primary", layoutName: "gone", spaceID: 1)])
        #expect(ArrangeActionResultPresentation.shouldOfferRecovery(state: active, needsReapply: false, configurationUnavailable: true))
        var hidden = SlotEntry.makeEntry(layoutName: "gone", spaceID: 1, definition: WindowDefinition(match: WindowMatchRule(bundleID: "Editor"), slot: 1))
        hidden.visibilityState = .hiddenOffscreen
        #expect(ArrangeActionResultPresentation.shouldOfferRecovery(state: RuntimeState(slots: [hidden]), needsReapply: false, configurationUnavailable: true))
        #expect(!ArrangeActionResultPresentation.shouldOfferRecovery(state: RuntimeState(), needsReapply: false, configurationUnavailable: true))
    }
}
