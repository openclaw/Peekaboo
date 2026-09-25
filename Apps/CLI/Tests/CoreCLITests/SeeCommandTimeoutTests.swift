import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized)
struct SeeCommandTimeoutTests {
    @Test(arguments: [false, true], [false, true])
    @MainActor
    func `see mutation intent includes web focus and menu opening`(webFocus: Bool, menubar: Bool) {
        var command = SeeCommand()
        command.webFocus = webFocus
        command.menubar = menubar

        #expect(command.mayMutateDuringObservation == (webFocus || menubar))
    }

    @Test(arguments: [false, true])
    @MainActor
    func `read-only tree and detection observations retain their fresh implicit snapshot`(treeOnly: Bool) async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let tracker = InteractionMutationTracker(desktopMutationWatermarkStore: store)
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let automation = ReadOnlySeeAutomation()
        let runtime = Self.runtime(tracker: tracker, snapshots: snapshots, automation: automation)
        var command = SeeCommand()
        command.windowId = 77
        command.runtime = runtime

        if treeOnly {
            command.tree = true
            command.noScreenshot = true
            try await command.run(using: runtime)
        } else {
            let snapshotID = try await snapshots.createSnapshot()
            let result = try await command.detectElements(
                imageData: Data([0x01]),
                windowContext: ReadOnlySeeAutomation.windowContext,
                snapshotID: snapshotID
            )
            try await snapshots.storeDetectionResult(snapshotId: snapshotID, result: result.payload)
        }

        #expect(automation.inspectionCount == (treeOnly ? 1 : 0))
        #expect(automation.detectionCount == (treeOnly ? 0 : 1))
        #expect(automation.lastWindowContext?.windowID == 77)
        #expect(automation.lastWindowContext?.shouldFocusWebContent != true)
        #expect(!tracker.hasPendingDurableMutation)
        #expect(store.effectiveWatermark() == nil)
        let listed = try await snapshots.listSnapshots()
        #expect(listed.count == 1)
        let snapshotID = try #require(listed.first?.id)
        let stored = try await snapshots.getDetectionResult(snapshotId: snapshotID)
        #expect(stored?.metadata.windowContext?.windowMutationIdentity == ReadOnlySeeAutomation.identity)
        #expect(stored?.elements.all.first?.label == "Synthetic field")
        #expect(await snapshots.getMostRecentSnapshot() == snapshotID)

        // Exercise the next command's startup and own-barrier exclusion without performing an action.
        try await CommanderRuntimeExecutor.catchUpSelectedHostIfNeeded(using: runtime, required: true)
        try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(using: runtime, required: true) {
            let observation = await InteractionObservationContext.resolve(
                explicitSnapshot: nil, fallbackToLatest: true, snapshots: snapshots
            )
            let resolvedSnapshotID = try observation.requireSnapshot()
            #expect(resolvedSnapshotID == snapshotID)
        }
        #expect(store.effectiveWatermark() == nil)
        #expect(!tracker.hasPendingDurableMutation)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `read-only timeout and cancellation create no mutation watermark`(cancelParent: Bool) async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let tracker = InteractionMutationTracker(desktopMutationWatermarkStore: store)
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let snapshotID = try await snapshots.createSnapshot()
        let runtime = Self.runtime(tracker: tracker, snapshots: snapshots)
        let gate = IgnoredCancellationWorkGate()
        defer { Task { await gate.release() } }
        let operation = Task { @MainActor in
            try await SeeCommand.withWallClockTimeout(
                seconds: cancelParent ? 10 : 0.02,
                interactionMutationTracker: runtime.observationTimeoutMutationTracker(mayMutateDesktop: false)
            ) {
                await gate.waitUntilReleased()
                await gate.markFinished()
                return "late read-only result"
            }
        }
        await gate.waitUntilStarted()
        #expect(store.effectiveWatermark() == nil)
        if cancelParent {
            operation.cancel()
            await #expect(throws: CancellationError.self) { try await operation.value }
        } else {
            await #expect(throws: CaptureError.self) { try await operation.value }
        }

        #expect(!tracker.hasPendingDurableMutation)
        #expect(store.effectiveWatermark() == nil)
        #expect(await snapshots.getMostRecentSnapshot() == snapshotID)
        await gate.release()
        await gate.waitUntilFinished()
        #expect(await Self.waitUntilReleased(tracker))
        #expect(store.effectiveWatermark() == nil)
        #expect(await snapshots.getMostRecentSnapshot() == snapshotID)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `read-only timeout wrapper neither commits nor releases a parent lease`(remote: Bool) async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let tracker = InteractionMutationTracker(desktopMutationWatermarkStore: store)
        let runtime = Self.runtime(tracker: tracker, remote: remote)
        #expect(try await tracker.beginDurableMutation())
        let gate = IgnoredCancellationWorkGate()
        defer { Task { await gate.release() } }

        let operation = Task { @MainActor in
            try await SeeCommand.withWallClockTimeout(
                seconds: 10,
                interactionMutationTracker: runtime.observationTimeoutMutationTracker(mayMutateDesktop: false)
            ) {
                await gate.waitUntilReleased()
                return "read-only"
            }
        }
        await gate.waitUntilStarted()

        #expect(tracker.hasPendingDurableMutation)
        #expect(store.effectiveWatermark() != nil)
        // A read must not extend its parent's mutation authority while waiting for more read-only work.
        try tracker.cancelDurableMutation()
        #expect(!tracker.hasPendingDurableMutation)
        #expect(store.effectiveWatermark() == nil)
        await gate.release()
        #expect(try await operation.value == "read-only")
        #expect(!tracker.hasPendingDurableMutation)
        #expect(store.effectiveWatermark() == nil)
    }

    @Test
    @MainActor
    func `mutation-capable observation still publishes its completion boundary`() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let tracker = InteractionMutationTracker(desktopMutationWatermarkStore: store)
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let runtime = Self.runtime(tracker: tracker, snapshots: snapshots)
        let snapshotID = try await snapshots.createSnapshot()

        let value = try await SeeCommand.withWallClockTimeout(
            seconds: 1,
            interactionMutationTracker: runtime.observationTimeoutMutationTracker(mayMutateDesktop: true)
        ) { "potential mutation" }

        #expect(value == "potential mutation")
        #expect(!tracker.hasPendingDurableMutation)
        #expect(store.effectiveWatermark() != nil)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
        #expect(try await snapshots.getUIAutomationSnapshot(snapshotId: snapshotID) != nil)
    }

    @Test
    func `returns result before timeout`() async throws {
        let result = try await SeeCommand.withWallClockTimeout(seconds: 1.0) {
            "ok"
        }
        #expect(result == "ok")
    }

    @Test
    func `throws detectionTimedOut when operation exceeds deadline`() async {
        let startedAt = Date()
        let error = await #expect(throws: CaptureError.self) {
            try await SeeCommand.withWallClockTimeout(seconds: 0.05) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        continuation.resume(returning: "late")
                    }
                }
            }
        }

        switch error {
        case let .detectionTimedOut(seconds):
            #expect(seconds == 0.05, "Timeout should propagate configured deadline")
        default:
            Issue.record("Unexpected capture error: \(error)")
        }
        #expect(Date().timeIntervalSince(startedAt) < 0.25)
    }

    @Test
    func `parent cancellation remains cancellation`() async throws {
        let task = Task {
            try await SeeCommand.withWallClockTimeout(seconds: 5) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "late"
            }
        }

        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test
    func `nested timeout errors pass through unchanged`() async {
        let error = await #expect(throws: PeekabooError.self) {
            try await SeeCommand.withWallClockTimeout(seconds: 5) {
                throw PeekabooError.timeout("nested capture timeout")
            }
        }

        guard case let .timeout(reason) = error else {
            Issue.record("Expected nested PeekabooError.timeout")
            return
        }
        #expect(reason == "nested capture timeout")
    }

    @Test
    @MainActor
    func `timed out mutation keeps barrier until ignored cancellation work finishes`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-local-timeout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let gate = IgnoredCancellationWorkGate()
        defer { Task { await gate.release() } }

        let operation = Task { @MainActor in
            try await withMainActorCommandTimeout(
                seconds: 0.01,
                operationName: "delayed mutation",
                desktopMutationWatermarkStore: store
            ) {
                await gate.waitUntilReleased()
            }
        }
        await gate.waitUntilStarted()
        await #expect(throws: PeekabooError.self) {
            try await operation.value
        }

        let firstPendingRead = try #require(store.effectiveWatermark())
        try await Task.sleep(for: .milliseconds(2))
        #expect(try #require(store.effectiveWatermark()) > firstPendingRead)

        await gate.release()
        #expect(try await Self.waitForStableWatermark(store))
    }

    @Test
    @MainActor
    func `see timeout retains the command barrier until ignored cancellation work finishes`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-see-timeout-lease-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let tracker = InteractionMutationTracker(desktopMutationWatermarkStore: store)
        #expect(try await tracker.beginDurableMutation())
        let gate = IgnoredCancellationWorkGate()
        defer { Task { await gate.release() } }

        let operation = Task { @MainActor in
            try await SeeCommand.withWallClockTimeout(
                seconds: 0.01,
                interactionMutationTracker: tracker
            ) {
                await gate.waitUntilReleased()
            }
        }
        await gate.waitUntilStarted()
        await #expect(throws: CaptureError.self) {
            try await operation.value
        }

        #expect(try tracker.completeDurableMutation(through: Date()) == nil)
        let firstPendingRead = try #require(store.effectiveWatermark())
        try await Task.sleep(for: .milliseconds(2))
        #expect(try #require(store.effectiveWatermark()) > firstPendingRead)

        await gate.release()
        #expect(try await Self.waitForStableWatermark(store))
    }

    private static func waitForStableWatermark(
        _ store: DesktopMutationWatermarkStore,
        timeout: Duration = .seconds(1)
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var previous = store.effectiveWatermark()

        repeat {
            try await Task.sleep(for: .milliseconds(5))
            let current = store.effectiveWatermark()
            if current != nil, current == previous {
                return true
            }
            previous = current
        } while clock.now < deadline

        return false
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-read-only-see-\(UUID())")
    }

    @MainActor
    private static func runtime(
        tracker: InteractionMutationTracker,
        snapshots: any SnapshotManagerProtocol = InMemorySnapshotManager(),
        automation: any UIAutomationServiceProtocol = MockAutomationService(),
        remote: Bool = false
    ) -> CommandRuntime {
        CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: FocusProofPressServices(
                windows: MockWindowService(result: []), automation: automation, snapshots: snapshots
            ),
            selectedRemoteSocketPath: remote ? "/tmp/unused-observation-host.sock" : nil,
            interactionMutationTracker: tracker
        )
    }

    @MainActor
    private static func waitUntilReleased(_ tracker: InteractionMutationTracker) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while tracker.hasPendingDurableMutation, clock.now < deadline {
            await Task.yield()
        }
        return !tracker.hasPendingDurableMutation
    }
}

private actor IgnoredCancellationWorkGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var started = false
    private var finished = false
    private var finishedContinuations: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        self.started = true
        let startedContinuations = self.startedContinuations
        self.startedContinuations.removeAll()
        for continuation in startedContinuations {
            continuation.resume()
        }
        guard !self.released else { return }
        await withCheckedContinuation { continuation in
            self.releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !self.started else { return }
        await withCheckedContinuation { continuation in
            self.startedContinuations.append(continuation)
        }
    }

    func release() {
        self.released = true
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }

    func markFinished() {
        self.finished = true
        let continuations = self.finishedContinuations
        self.finishedContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitUntilFinished() async {
        guard !self.finished else { return }
        await withCheckedContinuation { self.finishedContinuations.append($0) }
    }
}

@MainActor
private final class ReadOnlySeeAutomation: MockAutomationService, UIAutomationObservationActionResultProviding {
    static let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
    static let identity = WindowMutationIdentity(
        windowID: 77, ownerProcessIdentifier: 42, ownerProcessStartIdentity: 9001, capturedBounds: bounds
    )
    static var windowContext: WindowContext {
        WindowContext(
            applicationName: "Synthetic application",
            applicationProcessId: 42,
            windowTitle: "Synthetic window",
            windowID: 77,
            windowBounds: self.bounds,
            windowMutationIdentity: self.identity
        )
    }

    private(set) var inspectionCount = 0
    private(set) var detectionCount = 0
    private(set) var lastWindowContext: WindowContext?

    @MainActor
    func inspectAccessibilityTreeActionResult(
        windowContext: WindowContext?
    ) async throws -> UIAutomationActionResult<ElementDetectionResult> {
        self.inspectionCount += 1
        self.lastWindowContext = windowContext
        return try Self.result(snapshotID: "synthetic-source")
    }

    @MainActor
    func detectElementsActionResult(
        in _: Data,
        snapshotId: String?,
        windowContext: WindowContext?,
        requestTimeoutSec _: TimeInterval?
    ) async throws -> UIAutomationActionResult<ElementDetectionResult> {
        self.detectionCount += 1
        self.lastWindowContext = windowContext
        let snapshotID = try #require(snapshotId)
        return try Self.result(snapshotID: snapshotID)
    }

    private static func result(snapshotID: String) throws -> UIAutomationActionResult<ElementDetectionResult> {
        let field = DetectedElement(
            id: "synthetic-field",
            type: .textField,
            label: "Synthetic field",
            bounds: CGRect(x: 20, y: 30, width: 100, height: 30),
            isEnabled: true
        )
        return try UIAutomationActionResult(
            payload: ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "",
                elements: DetectedElements(textFields: [field]),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 1,
                    method: "synthetic",
                    windowContext: self.windowContext,
                    truncationInfo: nil
                )
            ),
            outcome: nil,
            targetIdentity: DesktopTargetIdentity(
                exactWindow: UIAutomationTarget.ExactWindow(identity: self.identity, bounds: self.bounds)
            )
        )
    }
}
