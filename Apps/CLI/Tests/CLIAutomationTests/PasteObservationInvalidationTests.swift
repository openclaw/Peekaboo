import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

@Suite(.serialized, .tags(.safe))
@MainActor
struct PasteObservationInvalidationTests {
    enum Prefix: String, CaseIterable, Sendable {
        case none
        case clipboard
        case focus
    }

    @Test(arguments: Prefix.allCases)
    func `Admitted paste refusal preserves implicit latest only without earlier effects`(prefix: Prefix) async throws {
        let state = try await PasteQualificationState()
        defer { state.removeDirectory() }
        let snapshots = state.snapshots
        let snapshotID = state.snapshotID
        #expect(await snapshots.getMostRecentSnapshot() == snapshotID)
        #expect(snapshots.effectiveImplicitLatestInvalidationWatermark == nil)

        let automation = OutcomeStubAutomationService()
        automation.failHotkey(
            DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Synthetic desktop-lane admission timeout",
                standardErrorCode: .timeout
            ),
            onCall: 1
        )
        let clipboard = StubClipboardService()
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("prior".utf8),
            textPreview: "prior"
        )
        let windows = PasteFocusWindowService()
        let services = TestServicesFactory.makePeekabooServices(
            windows: windows,
            snapshots: snapshots,
            clipboard: clipboard,
            automation: automation
        )
        let tracker = state.tracker
        let gate = AdmittedPasteGate()
        var command = PasteCommand()
        command.transactionGate = gate
        command.focusOptions.foreground = true
        command.focusOptions.noAutoFocus = prefix != .focus
        command.restoreDelay = .milliseconds(0)
        command.runtimeOptions.jsonOutput = true
        if prefix == .clipboard {
            command.dataBase64 = Data("payload".utf8).base64EncodedString()
            command.uti = "public.data"
        }
        if prefix == .focus {
            command.target.windowId = PasteFocusWindowService.windowID
            command.focusOptions.focusTimeoutDuration = .milliseconds(1)
            command.focusOptions.focusRetryCount = 0
        }
        let result = try await InProcessCommandRunner.captureCommandOutput { @MainActor in
            defer { Logger.shared.setJsonOutputMode(false) }
            let runtime = CommandRuntime(
                configuration: command.runtimeOptions.makeConfiguration(),
                services: services,
                selectedRemoteSocketPath: nil,
                snapshotInvalidationRemoteSocketPaths: [],
                interactionMutationTracker: tracker
            )
            try await command.run(using: runtime)
        }
        let response = try JSONDecoder().decode(JSONResponse.self, from: Data(result.stdout.utf8))
        #expect(result.exitStatus == 1)
        #expect(response.error?.code == "TIMEOUT")
        #expect(response.outcome?.state == (prefix == .focus ? .indeterminate : .refused))
        #expect(response.error?.retry_safe == (prefix != .focus))
        #expect(response.error?.mutation_dispatched == (prefix == .focus))
        #expect(response.outcome?.requiresFreshObservation == (prefix == .focus))
        #expect(gate.admissionCalls == 1)
        #expect(gate.bodyCalls == 1)
        #expect(automation.outcomeHotkeyCallCount == 1)
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(automation.exactHotkeyCalls.isEmpty)
        #expect(windows.focusCalls.count == (prefix == .focus ? 1 : 0))
        #expect(windows.pinnedFocusCalls.count == (prefix == .focus ? 1 : 0))
        #expect(clipboard.getCallCount == 1)
        #expect(clipboard.saveCallCount == (prefix == .clipboard ? 1 : 0))
        #expect(clipboard.setCallCount == (prefix == .clipboard ? 1 : 0))
        #expect(clipboard.restoreCallCount == (prefix == .clipboard ? 1 : 0))
        #expect(clipboard.clearCallCount == 0)
        #expect(clipboard.current?.data == Data("prior".utf8))
        #expect(clipboard.current?.textPreview == "prior")
        #expect(!tracker.hasPendingDurableMutation)
        if prefix == .focus {
            #expect(response.target_receipt?.windowID == PasteFocusWindowService.windowID)
        }

        // Explicit mutation eligibility is distinct from retaining historical snapshot bytes.
        #expect(try await snapshots.getUIAutomationSnapshot(snapshotId: snapshotID) != nil)
        let lease = try await snapshots.beginSnapshotMutation(snapshotId: snapshotID)
        try await snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)

        if prefix == .none {
            #expect(await snapshots.getMostRecentSnapshot() == snapshotID)
            #expect(snapshots.effectiveImplicitLatestInvalidationWatermark == nil)
        } else {
            #expect(await snapshots.getMostRecentSnapshot() == nil)
            #expect(snapshots.effectiveImplicitLatestInvalidationWatermark != nil)
        }
    }

    @Test
    func `Wrapped background target refusal preserves observations before clipboard access`() async throws {
        let state = try await PasteQualificationState()
        defer { state.removeDirectory() }
        let applications = StubApplicationService(applications: [])
        let automation = OutcomeStubAutomationService()
        let clipboard = Self.makeClipboard()
        let windows = PasteFocusWindowService()
        let gate = AdmittedPasteGate()
        var command = PasteCommand()
        command.transactionGate = gate
        command.target.app = "Missing App"
        command.runtimeOptions.jsonOutput = true
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: windows,
            snapshots: state.snapshots,
            clipboard: clipboard,
            automation: automation
        )

        let response = try await Self.runRefused(command, services: services, state: state)

        #expect(response.error?.code == "APP_NOT_FOUND")
        #expect(response.outcome?.state == .refused)
        #expect(response.error?.retry_safe == true)
        #expect(response.error?.mutation_dispatched == false)
        #expect(response.outcome?.requiresFreshObservation == false)
        #expect(gate.admissionCalls == 1)
        #expect(gate.bodyCalls == 1)
        #expect(automation.outcomeHotkeyCallCount == 0)
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(automation.exactHotkeyCalls.isEmpty)
        #expect(windows.focusCalls.isEmpty)
        #expect(applications.activateCalls.isEmpty)
        #expect(clipboard.getCallCount == 0)
        #expect(clipboard.saveCallCount == 0)
        #expect(clipboard.setCallCount == 0)
        #expect(clipboard.restoreCallCount == 0)
        #expect(clipboard.clearCallCount == 0)
        #expect(state.tracker.mutationStartedAt == nil)
        #expect(!state.tracker.hasPendingDurableMutation)
        try await state.expectLatestAndLeasePreserved()
    }

    @Test(arguments: [false, true])
    func `Canonical failure after a partial clipboard write still invalidates and restores`(
        wrapped: Bool
    ) async throws {
        let state = try await PasteQualificationState()
        defer { state.removeDirectory() }
        let automation = OutcomeStubAutomationService()
        let clipboard = Self.makeClipboard()
        clipboard.setError = wrapped ? PreDispatchActionError(
            message: "Synthetic partial clipboard write failure",
            code: .TIMEOUT,
            hint: nil,
            reason: .targetUnavailable
        ) : Self.timeoutFailure
        clipboard.setMutatesBeforeThrow = true
        let gate = AdmittedPasteGate()
        var command = Self.currentClipboardCommand(gate: gate)
        command.dataBase64 = Data("partial payload".utf8).base64EncodedString()
        command.uti = "public.data"
        let services = TestServicesFactory.makePeekabooServices(
            snapshots: state.snapshots,
            clipboard: clipboard,
            automation: automation
        )

        let response = try await Self.runRefused(command, services: services, state: state)

        #expect(response.error?.code == "TIMEOUT")
        #expect(clipboard.getCallCount == 1)
        #expect(clipboard.saveCallCount == 1)
        #expect(clipboard.setCallCount == 1)
        #expect(clipboard.restoreCallCount == 1)
        #expect(clipboard.clearCallCount == 0)
        #expect(clipboard.current?.data == Data("prior".utf8))
        #expect(automation.outcomeHotkeyCallCount == 0)
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(gate.bodyCalls == 1)
        #expect(await state.snapshots.getMostRecentSnapshot() == nil)
        #expect(state.snapshots.effectiveImplicitLatestInvalidationWatermark != nil)
        try await state.expectExplicitLeaseReusable()
    }

    enum EnvelopeEvidence: String, CaseIterable, Sendable {
        case aggregateDispatch
        case unsafeRetry
        case dispatchedOverride
        case untypedRefusal
    }

    @Test(arguments: EnvelopeEvidence.allCases)
    func `Envelope evidence cannot be weakened to a wrapped leaf refusal`(evidence: EnvelopeEvidence) async throws {
        let state = try await PasteQualificationState()
        defer { state.removeDirectory() }
        var envelope = PasteQualificationEnvelopeFailure(envelopeActionFailure: Self.timeoutFailure)
        switch evidence {
        case .aggregateDispatch:
            envelope.envelopeActionOutcome = .indeterminate(evidence: .completionUnknown, unitCount: .one)
        case .unsafeRetry:
            envelope.envelopeRetrySafe = false
        case .dispatchedOverride:
            envelope.envelopeMutationDispatched = true
        case .untypedRefusal:
            envelope.envelopeActionFailure = nil
            envelope.envelopeRetrySafe = true
            envelope.envelopeMutationDispatched = false
        }
        let automation = OutcomeStubAutomationService()
        let clipboard = Self.makeClipboard()
        clipboard.getError = envelope
        let gate = AdmittedPasteGate()
        let command = Self.currentClipboardCommand(gate: gate)
        let services = TestServicesFactory.makePeekabooServices(
            snapshots: state.snapshots,
            clipboard: clipboard,
            automation: automation
        )

        _ = try await Self.runRefused(command, services: services, state: state)

        #expect(gate.bodyCalls == 1)
        #expect(clipboard.getCallCount == 1)
        #expect(clipboard.setCallCount == 0)
        #expect(clipboard.restoreCallCount == 0)
        #expect(automation.outcomeHotkeyCallCount == 0)
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(await state.snapshots.getMostRecentSnapshot() == nil)
        #expect(state.snapshots.effectiveImplicitLatestInvalidationWatermark != nil)
        try await state.expectExplicitLeaseReusable()
    }

    @Test
    func `Unclassified input failure cannot release a possible mutation as a no effect refusal`() async throws {
        let state = try await PasteQualificationState()
        defer { state.removeDirectory() }
        let automation = OutcomeStubAutomationService()
        automation.failHotkey(PasteQualificationError.unclassified, onCall: 1)
        let clipboard = Self.makeClipboard()
        let gate = AdmittedPasteGate()
        let command = Self.currentClipboardCommand(gate: gate)
        let services = TestServicesFactory.makePeekabooServices(
            snapshots: state.snapshots,
            clipboard: clipboard,
            automation: automation
        )

        let response = try await Self.runRefused(command, services: services, state: state)

        #expect(response.outcome?.state == .indeterminate)
        #expect(response.error?.retry_safe == false)
        #expect(response.error?.mutation_dispatched == true)
        #expect(response.outcome?.requiresFreshObservation == true)
        #expect(automation.outcomeHotkeyCallCount == 1)
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(clipboard.getCallCount == 1)
        #expect(clipboard.setCallCount == 0)
        #expect(clipboard.restoreCallCount == 0)
        #expect(gate.bodyCalls == 1)
        #expect(await state.snapshots.getMostRecentSnapshot() == nil)
        #expect(state.snapshots.effectiveImplicitLatestInvalidationWatermark != nil)
    }

    enum ForeignOwner: String, CaseIterable, Sendable {
        case markedAndDurable
        case durableOnly
        case interleavedMark
    }

    @Test(arguments: ForeignOwner.allCases)
    func `No effect paste preserves another owners mutation boundary and durable barrier`(
        owner: ForeignOwner
    ) async throws {
        let state = try await PasteQualificationState()
        defer { state.removeDirectory() }
        let originalBoundary = Date()
        if owner == .markedAndDurable {
            state.tracker.begin(at: originalBoundary)
        }
        #expect(try await state.tracker.beginDurableMutation())
        defer { try? state.tracker.cancelDurableMutation() }
        let originalSequence = state.tracker.mutationSequence
        let automation = PasteRefusalAutomation(failure: Self.timeoutFailure)
        var interleavedBoundary: Date?
        var interleavedSequence: UInt64?
        if owner == .interleavedMark {
            automation.beforeRefusal = {
                await Task.yield()
                state.tracker.begin()
                interleavedBoundary = state.tracker.mutationStartedAt
                interleavedSequence = state.tracker.mutationSequence
            }
        }
        let clipboard = Self.makeClipboard()
        let windows = PasteFocusWindowService()
        let gate = AdmittedPasteGate()
        let command = Self.currentClipboardCommand(gate: gate)
        let services = TestServicesFactory.makePeekabooServices(
            windows: windows,
            snapshots: state.snapshots,
            clipboard: clipboard,
            automation: automation
        )

        let response = try await Self.runRefused(command, services: services, state: state)

        #expect(response.outcome?.state == .refused)
        #expect(response.error?.code == "TIMEOUT")
        #expect(response.error?.retry_safe == true)
        #expect(response.error?.mutation_dispatched == false)
        #expect(response.outcome?.requiresFreshObservation == false)
        #expect(automation.attemptedHotkeys == 1)
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(windows.focusCalls.isEmpty)
        #expect(clipboard.getCallCount == 1)
        #expect(clipboard.setCallCount == 0)
        #expect(clipboard.saveCallCount == 0)
        #expect(clipboard.restoreCallCount == 0)
        #expect(gate.bodyCalls == 1)
        #expect(state.tracker.hasPendingDurableMutation)
        #expect(state.tracker.mutationSequence >= originalSequence)
        switch owner {
        case .markedAndDurable:
            #expect(state.tracker.mutationStartedAt == originalBoundary)
        case .durableOnly:
            #expect(state.tracker.mutationStartedAt == nil)
        case .interleavedMark:
            #expect(interleavedBoundary != nil)
            #expect(interleavedSequence != nil)
            #expect(state.tracker.mutationStartedAt == interleavedBoundary)
            #expect(state.tracker.mutationSequence == interleavedSequence)
        }
        // Mask only the caller's still-owned barrier to detect a permanent watermark underneath it.
        await state.tracker.withPendingDurableMutationVisible(createdByCurrentCommand: true) {
            #expect(state.store.effectiveWatermark() == nil)
            #expect(await state.snapshots.getMostRecentSnapshot() == state.snapshotID)
        }

        state.tracker.cancelUncommittedMutation(sequence: state.tracker.mutationSequence)
        try state.tracker.cancelDurableMutation()
        #expect(!state.tracker.hasPendingDurableMutation)
        #expect(state.tracker.mutationStartedAt == nil)
        try await state.expectLatestAndLeasePreserved()
    }

    @Test
    func `Background text predispatch refusal preserves observations without clipboard admission`() async throws {
        let state = try await PasteQualificationState()
        defer { state.removeDirectory() }
        let clipboard = Self.makeClipboard()
        let fixture = ExactBackgroundTextPasteFixture(snapshots: state.snapshots, clipboard: clipboard)
        fixture.automation.uiAutomationOutcomeScript.appendFailure(Self.timeoutFailure, for: .typeActions)
        let gate = AdmittedPasteGate()
        var command = PasteCommand()
        command.transactionGate = gate
        command.target.app = "TextEdit"
        command.target.windowId = ExactBackgroundTextPasteFixture.windowID
        command.textOption = "synthetic text"
        command.runtimeOptions.jsonOutput = true

        let response = try await Self.runRefused(command, services: fixture.services, state: state)

        #expect(response.error?.code == "TIMEOUT")
        #expect(response.outcome?.state == .refused)
        #expect(response.error?.retry_safe == true)
        #expect(response.error?.mutation_dispatched == false)
        #expect(response.outcome?.requiresFreshObservation == false)
        #expect(fixture.automation.uiAutomationOutcomeScript.callCount(for: .typeActions) == 1)
        #expect(fixture.automation.typeActionsCalls.isEmpty)
        #expect(fixture.automation.targetedTypeActionsCalls.isEmpty)
        #expect(fixture.automation.exactTypeActionsCalls.isEmpty)
        #expect(fixture.automation.hotkeyCalls.isEmpty)
        #expect(fixture.windows.focusCalls.isEmpty)
        #expect(clipboard.getCallCount == 0)
        #expect(clipboard.saveCallCount == 0)
        #expect(clipboard.setCallCount == 0)
        #expect(clipboard.restoreCallCount == 0)
        #expect(clipboard.clearCallCount == 0)
        #expect(gate.admissionCalls == 0)
        #expect(gate.bodyCalls == 0)
        #expect(state.tracker.mutationStartedAt == nil)
        #expect(!state.tracker.hasPendingDurableMutation)
        try await state.expectLatestAndLeasePreserved()
    }

    private static var timeoutFailure: DesktopActionFailure {
        .preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Synthetic desktop-lane admission timeout",
            standardErrorCode: .timeout
        )
    }

    private static func makeClipboard() -> StubClipboardService {
        let clipboard = StubClipboardService()
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("prior".utf8),
            textPreview: "prior"
        )
        return clipboard
    }

    private static func currentClipboardCommand(gate: AdmittedPasteGate) -> PasteCommand {
        var command = PasteCommand()
        command.transactionGate = gate
        command.focusOptions.foreground = true
        command.focusOptions.noAutoFocus = true
        command.restoreDelay = .milliseconds(0)
        command.runtimeOptions.jsonOutput = true
        return command
    }

    private static func runRefused(
        _ configuredCommand: PasteCommand,
        services: PeekabooServices,
        state: PasteQualificationState
    ) async throws -> JSONResponse {
        var command = configuredCommand
        let result = try await InProcessCommandRunner.captureCommandOutput { @MainActor in
            defer { Logger.shared.setJsonOutputMode(false) }
            let runtime = CommandRuntime(
                configuration: command.runtimeOptions.makeConfiguration(),
                services: services,
                selectedRemoteSocketPath: nil,
                snapshotInvalidationRemoteSocketPaths: [],
                interactionMutationTracker: state.tracker
            )
            try await command.run(using: runtime)
        }
        #expect(result.exitStatus == 1)
        return try JSONDecoder().decode(JSONResponse.self, from: Data(result.stdout.utf8))
    }
}

@MainActor
private struct PasteQualificationState {
    let directory: URL
    let store: DesktopMutationWatermarkStore
    let snapshots: InMemorySnapshotManager
    let snapshotID: String
    let tracker: InteractionMutationTracker

    init() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-paste-body-refusal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let store = DesktopMutationWatermarkStore(directoryURL: directory)
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        self.directory = directory
        self.store = store
        self.snapshots = snapshots
        self.snapshotID = try await snapshots.createSnapshot()
        self.tracker = InteractionMutationTracker(desktopMutationWatermarkStore: store)
    }

    func removeDirectory() {
        try? FileManager.default.removeItem(at: self.directory)
    }

    func expectLatestAndLeasePreserved() async throws {
        #expect(self.store.effectiveWatermark() == nil)
        #expect(self.snapshots.effectiveImplicitLatestInvalidationWatermark == nil)
        #expect(await self.snapshots.getMostRecentSnapshot() == self.snapshotID)
        try await self.expectExplicitLeaseReusable()
    }

    func expectExplicitLeaseReusable() async throws {
        #expect(try await self.snapshots.getUIAutomationSnapshot(snapshotId: self.snapshotID) != nil)
        let lease = try await self.snapshots.beginSnapshotMutation(snapshotId: self.snapshotID)
        try await self.snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }
}

private enum PasteQualificationError: Error {
    case unclassified
}

private struct PasteQualificationEnvelopeFailure: ResultEnvelopeError {
    var envelopeActionFailure: DesktopActionFailure?
    var envelopeActionOutcome: DesktopActionOutcome?
    var envelopeRetrySafe: Bool?
    var envelopeMutationDispatched: Bool?
    let envelopeEffect: ActionEffect? = .refused
    let envelopeHint: String? = nil
}

@MainActor
private final class PasteRefusalAutomation: StubAutomationService, ScriptedUIAutomationActionOutcomeProviding {
    let uiAutomationOutcomeScript = UIAutomationOutcomeScript()
    let failure: DesktopActionFailure
    var beforeRefusal: (@MainActor () async -> Void)?
    private(set) var attemptedHotkeys = 0

    init(failure: DesktopActionFailure) {
        self.failure = failure
        super.init()
    }

    @MainActor
    func hotkeyWithOutcome(keys _: String, holdDuration _: Int) async throws -> UIAutomationActionResult<Void> {
        self.attemptedHotkeys += 1
        await self.beforeRefusal?()
        throw self.failure
    }
}

@MainActor
private final class AdmittedPasteGate: ClipboardPasteTransactionGating {
    private(set) var admissionCalls = 0
    private(set) var bodyCalls = 0

    func withExclusiveTransaction<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        self.admissionCalls += 1
        self.bodyCalls += 1
        return try await operation()
    }
}
