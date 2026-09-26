import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooBridgeTestSupport
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge

struct PeekabooBridgeSetValueFailureTests {
    enum ElementMutation: CaseIterable, Sendable {
        case setValue, performAction

        func request(snapshotID: String) -> PeekabooBridgeRequest {
            switch self {
            case .setValue:
                .setValue(.init(target: "T1", value: .string("hello"), snapshotId: snapshotID))
            case .performAction:
                .performAction(.init(target: "T1", actionName: "AXPress", snapshotId: snapshotID))
            }
        }
    }

    enum SnapshotReadCompletion: CaseIterable, Sendable {
        case found, missing, readError, cancellation
    }

    @Test(arguments: ElementMutation.allCases, SnapshotReadCompletion.allCases)
    @MainActor
    func `cancelled failure capture cannot invoke an element mutation`(
        mutation: ElementMutation,
        completion: SnapshotReadCompletion) async throws
    {
        let fixture = try await self.captureFixture(mutation: mutation, completion: completion)
        let operation = Task {
            try await self.handleCurrent(mutation.request(snapshotID: fixture.snapshotID), with: fixture.server)
        }
        guard await self.waitForCaptureRead(operation, snapshots: fixture.snapshots) else { return }
        operation.cancel()
        await fixture.snapshots.resumeRead()

        let failure = await #expect(throws: DesktopActionFailure.self) { try await operation.value }
        self.expectPreDispatchCancellation(failure)
        #expect(fixture.snapshots.readSnapshotIDs == [fixture.snapshotID])
        #expect(fixture.snapshots.readUsedAttestedSemantics)
        #expect(fixture.snapshots.wasCancelledAfterRead)
        self.expectNoMutation(in: fixture.services)
    }

    @Test(arguments: ElementMutation.allCases)
    @MainActor
    func `snapshot provider cancellation refuses before element dispatch`(
        mutation: ElementMutation) async throws
    {
        let fixture = try await self.captureFixture(mutation: mutation, completion: .cancellation)
        let operation = Task {
            try await self.handleCurrent(mutation.request(snapshotID: fixture.snapshotID), with: fixture.server)
        }
        guard await self.waitForCaptureRead(operation, snapshots: fixture.snapshots) else { return }
        await fixture.snapshots.resumeRead()

        let failure = await #expect(throws: DesktopActionFailure.self) { try await operation.value }
        self.expectPreDispatchCancellation(failure)
        #expect(!fixture.snapshots.wasCancelledAfterRead)
        self.expectNoMutation(in: fixture.services)
    }

    @Test(arguments: ElementMutation.allCases)
    @MainActor
    func `nonattested preparation preserves raw cancellation`(mutation: ElementMutation) async throws {
        let fixture = try await self.captureFixture(mutation: mutation, completion: .found)
        let operation = Task {
            try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(false) {
                try await fixture.server.handleAuthorized(
                    mutation.request(snapshotID: fixture.snapshotID),
                    peer: nil,
                    permissions: .init(screenRecording: true, accessibility: true, postEvent: true))
            }
        }
        operation.cancel()

        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(fixture.snapshots.readSnapshotIDs.isEmpty)
        self.expectNoMutation(in: fixture.services)
    }

    @Test(arguments: ElementMutation.allCases, SnapshotReadCompletion.allCases)
    @MainActor
    func `attested capture cancellation signs no dispatch and cancels its acquired barrier`(
        mutation: ElementMutation,
        completion: SnapshotReadCompletion) async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-capture-cancellation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await self.captureFixture(mutation: mutation, completion: completion)
        let signed = try await AttestedCaptureMutationFixture(
            root: root,
            request: mutation.request(snapshotID: fixture.snapshotID),
            services: fixture.services)
        #expect(signed.store.effectiveWatermark() == nil)
        let operation = signed.start()
        guard await self.waitForCaptureRead(operation, snapshots: fixture.snapshots) else { return }
        #expect(signed.store.effectiveWatermark() != nil)
        if completion != .cancellation {
            operation.cancel()
        }
        await fixture.snapshots.resumeRead()

        let result = try await signed.verifiedFailure(in: operation.value)
        self.expectPreDispatchCancellation(result.failure)
        #expect(result.receipt.payload.target == nil)
        #expect(result.receipt.payload.targetAttributionFailure == nil)
        #expect(fixture.snapshots.readSnapshotIDs == [fixture.snapshotID])
        #expect(fixture.snapshots.readUsedAttestedSemantics)
        #expect(fixture.snapshots.wasCancelledAfterRead == (completion != .cancellation))
        #expect(signed.store.effectiveWatermark() == nil)
        self.expectNoMutation(in: fixture.services)
    }

    @Test(arguments: ElementMutation.allCases)
    @MainActor
    func `attested cancellation after an accepted element mutation remains retry unsafe`(
        mutation: ElementMutation) async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-element-dispatch-cancellation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let automation = PostMutationCancellingAutomationService()
        let fixture = try await self.captureFixture(
            mutation: mutation,
            completion: .found,
            automation: automation)
        let signed = try await AttestedCaptureMutationFixture(
            root: root,
            request: mutation.request(snapshotID: fixture.snapshotID),
            services: fixture.services)
        #expect(signed.store.effectiveWatermark() == nil)
        let operation = signed.start()
        guard await self.waitForCaptureRead(operation, snapshots: fixture.snapshots) else { return }
        #expect(signed.store.effectiveWatermark() != nil)
        await fixture.snapshots.resumeRead()

        let result = try await signed.verifiedFailure(in: operation.value)
        #expect(result.failure.outcome.route == .bridge)
        #expect(result.failure.outcome.state == .indeterminate)
        #expect(result.failure.outcome.dispatchState == .mayHaveDispatched(unitCount: nil))
        #expect(result.failure.outcome.retrySafety == .unsafe)
        #expect(result.failure.outcome.refusalReason != .requestCancelled)
        #expect(automation.uiAutomationOutcomeScript.totalCallCount == 1)
        #expect((automation.lastSetValue != nil) == (mutation == .setValue))
        #expect((automation.lastPerformAction != nil) == (mutation == .performAction))
        #expect(signed.store.effectiveWatermark() != nil)
    }

    @Test(arguments: ElementMutation.allCases, [SnapshotReadCompletion.found, .missing, .readError])
    @MainActor
    func `optional failure capture does not prevent a live element mutation`(
        mutation: ElementMutation,
        completion: SnapshotReadCompletion) async throws
    {
        let fixture = try await self.captureFixture(mutation: mutation, completion: completion)
        let operation = Task {
            try await self.handleCurrent(mutation.request(snapshotID: fixture.snapshotID), with: fixture.server)
        }
        guard await self.waitForCaptureRead(operation, snapshots: fixture.snapshots) else { return }
        await fixture.snapshots.resumeRead()

        let handled = try await operation.value
        #expect(handled.outcome?.state == .dispatchedUnverified)
        #expect(handled.outcome?.dispatchState == .dispatched(unitCount: .one))
        #expect(handled.outcome?.delivery == fixture.services.automationStub.actionOutcome.delivery)
        #expect(handled.targetIdentity == fixture.services.automationStub.uiAutomationOutcomeTargetIdentity)
        #expect(fixture.services.automationStub.uiAutomationOutcomeScript.totalCallCount == 1)
        #expect((fixture.services.automationStub.lastSetValue != nil) == (mutation == .setValue))
        #expect((fixture.services.automationStub.lastPerformAction != nil) == (mutation == .performAction))
    }

    @MainActor
    private func captureFixture(
        mutation: ElementMutation,
        completion: SnapshotReadCompletion,
        automation: StubAutomationService? = nil) async throws -> (
        snapshotID: String,
        snapshots: GatedFailureCaptureSnapshotManager,
        services: StubServices,
        server: PeekabooBridgeServer)
    {
        let snapshotID = SnapshotReference.generate().rawValue
        let detection = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: .init(
                detectionTime: 0,
                elementCount: 0,
                method: "fixture",
                windowContext: WindowContext(
                    applicationName: "Fixture",
                    applicationProcessId: 123,
                    applicationProcessStartIdentity: 456)))
        let backing: InMemorySnapshotManager = if completion == .found {
            try await InMemorySnapshotManager.containing(detection)
        } else {
            InMemorySnapshotManager()
        }
        let snapshots = GatedFailureCaptureSnapshotManager(wrapping: backing, completion: completion)
        let services = StubServices(automation: automation, snapshots: snapshots)
        let automation = automation ?? services.automationStub
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(
                mechanism: mutation == .setValue ? .accessibilityValue : .accessibilityAction,
                mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        automation.uiAutomationOutcomeTargetIdentity = try DesktopTargetIdentity(
            processIdentity: .init(processIdentifier: 123, processStartIdentity: 456))
        let server = PeekabooBridgeServer(services: services, allowlistedTeams: [], allowlistedBundles: [])
        return (snapshotID, snapshots, services, server)
    }

    @MainActor
    private func handleCurrent(
        _ request: PeekabooBridgeRequest,
        with server: PeekabooBridgeServer) async throws -> PeekabooBridgeHandledResponse
    {
        try await PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(.current) {
            try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                try await server.handleAuthorized(
                    request,
                    peer: nil,
                    permissions: .init(screenRecording: true, accessibility: true, postEvent: true))
            }
        }
    }

    @MainActor
    private func waitForCaptureRead(
        _ operation: Task<some Sendable, some Error>,
        snapshots: GatedFailureCaptureSnapshotManager) async -> Bool
    {
        guard await snapshots.waitUntilReading() else {
            operation.cancel()
            await snapshots.resumeRead()
            Issue.record("The Bridge handler did not reach its snapshot capture gate within two seconds")
            _ = try? await operation.value
            return false
        }
        return true
    }

    private func expectPreDispatchCancellation(_ failure: DesktopActionFailure?) {
        #expect(failure?.outcome.route == .bridge)
        #expect(failure?.outcome.state == .refused)
        #expect(failure?.outcome.refusalReason == .requestCancelled)
        #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(failure?.outcome.retrySafety == .safe)
        #expect(failure?.outcome.delivery == nil)
        #expect(failure?.targetReceipt == nil)
    }

    @MainActor
    private func expectNoMutation(in services: StubServices) {
        #expect(services.automationStub.uiAutomationOutcomeScript.totalCallCount == 0)
        #expect(services.automationStub.lastSetValue == nil)
        #expect(services.automationStub.lastPerformAction == nil)
    }

    @Test
    @MainActor
    func `signed snapshot refusal cancels the Bridge mutation barrier without watermark`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-set-value-refusal-\(UUID().uuidString)", isDirectory: true)
        let socketPath = "/tmp/peekaboo-set-value-refusal-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root.appendingPathComponent("watermarks"))
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let services = await MainActor.run { StubServices(snapshots: snapshots) }
        await MainActor.run {
            services.automationStub.elementActionError = DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Target process generation changed before desktop mutation.",
                standardErrorCode: .snapshotStale)
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                desktopMutationWatermarkStore: store)
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()

        do {
            let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
            _ = try await client.handshake(client: .init(
                bundleIdentifier: "dev.peekaboo.set-value-refusal-tests",
                teamIdentifier: nil,
                processIdentifier: getpid(),
                hostname: nil))
            let failure = await #expect(throws: DesktopActionFailure.self) {
                _ = try await client.setValueWithOutcome(
                    target: "T1",
                    value: .string("hello"),
                    snapshotId: "S1")
            }
            #expect(failure?.outcome.route == .bridge)
            #expect(failure?.outcome.state == .refused)
            #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
            #expect(failure?.outcome.retrySafety == .safe)
            #expect(failure?.standardErrorCode == .snapshotStale)
            #expect(store.effectiveWatermark() == nil)
            #expect(services.automationStub.lastSetValue == nil)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    enum FailureTarget: CaseIterable {
        case process, exactWindow, wrongWindow, wrongGeneration

        var contradictsSnapshot: Bool {
            self == .wrongWindow || self == .wrongGeneration
        }
    }

    @Test(arguments: FailureTarget.allCases)
    @MainActor
    func `signed client preserves post-dispatch readback failure and target receipt`(
        target: FailureTarget) async throws
    {
        let socketPath = "/tmp/peekaboo-bridge-set-value-failure-\(UUID().uuidString).sock"
        let processGeneration = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let windowIdentity = WindowMutationIdentity(
            windowID: 91,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: processGeneration,
            capturedBounds: bounds)
        let snapshotID = SnapshotReference.generate().rawValue
        let detection = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: .init(
                detectionTime: 0,
                elementCount: 0,
                method: "fixture",
                windowContext: WindowContext(
                    applicationName: "Fixture",
                    applicationProcessId: getpid(),
                    applicationProcessStartIdentity: processGeneration,
                    windowID: target == .process ? nil : windowIdentity.windowID,
                    windowBounds: target == .process ? nil : bounds,
                    windowMutationIdentity: target == .process ? nil : windowIdentity)))
        let snapshots = try await InMemorySnapshotManager.containing(detection)
        let services = StubServices(snapshots: snapshots)
        let targetReceipt = DesktopActionTargetReceipt(
            processIdentifier: getpid(),
            processStartIdentity: target == .wrongGeneration ? processGeneration + 1 : processGeneration,
            windowID: target == .process ? nil : (target == .wrongWindow ? 92 : 91))
        await MainActor.run {
            services.automationStub.actionOutcome = .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one)
            services.automationStub.uiAutomationOutcomeTargetIdentity = try? DesktopTargetIdentity(
                processIdentity: .init(
                    processIdentifier: getpid(),
                    processStartIdentity: processGeneration))
            services.automationStub.elementActionError = DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "The submitted value could not be read back.",
                hint: "Observe the exact target before retrying.")
                .attributed(to: targetReceipt)
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.set-value-failure-tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil))
        let remote = await MainActor.run { RemoteElementActionUIAutomationService(client: client) }
        do {
            _ = try await remote.setValueWithOutcome(
                target: "T1",
                value: .string("hello"),
                snapshotId: snapshotID)
            Issue.record("Expected typed set-value failure")
        } catch let failure as DesktopActionFailure {
            if target.contradictsSnapshot {
                #expect(failure.message == "Bridge operation completed without a trustworthy exact target receipt.")
                #expect(failure.targetReceipt == nil)
                let mismatch = target == .wrongWindow ? "different windows" : "different process generations"
                #expect(failure.causeDescription?.contains(mismatch) == true)
            } else {
                #expect(failure.message == "The submitted value could not be read back.")
                #expect(failure.targetReceipt == targetReceipt)
                #expect(failure.hint?.contains("Observe the exact target") == true)
            }
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.projection.requiresFreshObservation)
        }
    }
}

@MainActor
private struct AttestedCaptureMutationFixture {
    let store: DesktopMutationWatermarkStore
    private let authority: PeekabooBridgeOperationReceiptAuthority
    private let session: OperationReceiptSessionFixture
    private let request: PeekabooBridgeRequest
    private let server: PeekabooBridgeServer

    init(root: URL, request: PeekabooBridgeRequest, services: StubServices) async throws {
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let store = DesktopMutationWatermarkStore(directoryURL: root.appendingPathComponent("watermarks"))
        self.authority = authority
        self.session = session
        self.store = store
        self.request = .projectedAction(.init(request: request))
        self.server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            desktopMutationWatermarkStore: store,
            desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: root.appendingPathComponent("coordination", isDirectory: true)),
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
            })
    }

    func start() -> Task<Data, Never> {
        let payload = self.session.request(authority: self.authority, sequence: 0, request: self.request)
        return Task {
            await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(self.authority) {
                await self.server.handleDecoded(.attestedOperation(payload), peer: self.session.peer)
            }
        }
    }

    func verifiedFailure(in data: Data) throws -> (
        failure: DesktopActionFailure,
        receipt: PeekabooBridgeOperationReceipt)
    {
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
        guard case let .attestedOperation(attested) = response,
              case let .projectedAction(projected) = attested.response,
              case let .error(envelope) = projected.response
        else {
            throw PeekabooError.invalidInput("Expected a signed projected Bridge failure")
        }
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: self.authority,
            sessionAttestation: self.session.attestation,
            receipt: attested.receipt,
            request: self.request,
            response: attested.response)
        try bundle.validate(trustAnchor: .listenerAttestation(self.authority.attestation))
        #expect(projected.outcome == envelope.actionOutcome)
        #expect(attested.receipt.payload.outcome == envelope.actionOutcome)
        #expect(attested.receipt.payload.operation == self.request.operation)
        return try (#require(envelope.desktopActionFailure), attested.receipt)
    }
}

@MainActor
private final class PostMutationCancellingAutomationService: StubAutomationService {
    override func setValue(
        target: String,
        value: UIElementValue,
        snapshotId: String?) async throws -> ElementActionResult
    {
        _ = try await super.setValue(target: target, value: value, snapshotId: snapshotId)
        throw CancellationError()
    }

    override func performAction(
        target: String,
        actionName: String,
        snapshotId: String?) async throws -> ElementActionResult
    {
        _ = try await super.performAction(target: target, actionName: actionName, snapshotId: snapshotId)
        throw CancellationError()
    }
}

@MainActor
private final class GatedFailureCaptureSnapshotManager: SnapshotManagerProtocol {
    private let wrapped: InMemorySnapshotManager
    private let completion: PeekabooBridgeSetValueFailureTests.SnapshotReadCompletion
    private let readStarted = AsyncTestLatch()
    private let readReleased = AsyncTestLatch()
    private(set) var readSnapshotIDs: [String] = []
    private(set) var readUsedAttestedSemantics = false
    private(set) var wasCancelledAfterRead = false

    init(
        wrapping wrapped: InMemorySnapshotManager,
        completion: PeekabooBridgeSetValueFailureTests.SnapshotReadCompletion)
    {
        self.wrapped = wrapped
        self.completion = completion
    }

    func waitUntilReading() async -> Bool {
        await self.readStarted.opensWithin(.seconds(2))
    }

    func resumeRead() async {
        await self.readReleased.open()
    }

    func getDetectionResult(snapshotId: String) async throws -> ElementDetectionResult? {
        self.readSnapshotIDs.append(snapshotId)
        self.readUsedAttestedSemantics = PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics
        await self.readStarted.open()
        await self.readReleased.wait()
        self.wasCancelledAfterRead = Task.isCancelled
        switch self.completion {
        case .found, .missing:
            return try await self.wrapped.getDetectionResult(snapshotId: snapshotId)
        case .readError:
            throw SnapshotError.storageError("Injected optional capture read failure")
        case .cancellation:
            throw CancellationError()
        }
    }

    func createSnapshot() async throws -> String {
        try await self.wrapped.createSnapshot()
    }

    func storeDetectionResult(snapshotId: String, result: ElementDetectionResult) async throws {
        try await self.wrapped.storeDetectionResult(snapshotId: snapshotId, result: result)
    }

    func getMostRecentSnapshot() async -> String? {
        await self.wrapped.getMostRecentSnapshot()
    }

    func getMostRecentSnapshot(applicationBundleId: String) async -> String? {
        await self.wrapped.getMostRecentSnapshot(applicationBundleId: applicationBundleId)
    }

    func listSnapshots() async throws -> [SnapshotInfo] {
        try await self.wrapped.listSnapshots()
    }

    func cleanSnapshot(snapshotId: String) async throws {
        try await self.wrapped.cleanSnapshot(snapshotId: snapshotId)
    }

    func cleanSnapshotsOlderThan(days: Int) async throws -> Int {
        try await self.wrapped.cleanSnapshotsOlderThan(days: days)
    }

    func cleanAllSnapshots() async throws -> Int {
        try await self.wrapped.cleanAllSnapshots()
    }

    func getSnapshotStoragePath() -> String {
        self.wrapped.getSnapshotStoragePath()
    }

    func storeScreenshot(_ request: SnapshotScreenshotRequest) async throws {
        try await self.wrapped.storeScreenshot(request)
    }

    func storeAnnotatedScreenshot(snapshotId: String, annotatedScreenshotPath: String) async throws {
        try await self.wrapped.storeAnnotatedScreenshot(
            snapshotId: snapshotId,
            annotatedScreenshotPath: annotatedScreenshotPath)
    }

    func getElement(snapshotId: String, elementId: String) async throws -> UIElement? {
        try await self.wrapped.getElement(snapshotId: snapshotId, elementId: elementId)
    }

    func findElements(snapshotId: String, matching query: String) async throws -> [UIElement] {
        try await self.wrapped.findElements(snapshotId: snapshotId, matching: query)
    }

    func getUIAutomationSnapshot(snapshotId: String) async throws -> UIAutomationSnapshot? {
        try await self.wrapped.getUIAutomationSnapshot(snapshotId: snapshotId)
    }
}
