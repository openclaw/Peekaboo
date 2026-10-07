import Foundation
import PeekabooAgentRuntimeTestSupport
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooCore

@Suite(.serialized, AuthorityTestIsolation())
@MainActor
struct AutomationWaitDurationTests {
    @Test(arguments: [-1, Int.min])
    func `negative waits refuse the whole sequence before preparation or input`(duration: Int) async throws {
        for withPrefix in [false, true] {
            let fixture = AutomationWaitFixture()
            let prefix: [AutomationAction] = withPrefix ? [Self.marker] : []
            let error = await #expect(throws: PeekabooError.self) {
                _ = try await fixture.services.automate(
                    appIdentifier: "owned-fixture", actions: prefix + [.wait(milliseconds: duration)])
            }
            #expect(error?.localizedDescription == PeekabooError
                .invalidInput("Automation wait duration cannot be negative").localizedDescription)
            #expect(fixture.snapshots.createCalls.isEmpty && fixture.snapshots.createExplicitCallCount == 0)
            #expect(fixture.snapshots.storeDetectionResultCalls.isEmpty)
            #expect(fixture.capture.captureAttemptCount == 0 && fixture.automation.detectionCallCount == 0)
            #expect(fixture.automation.clickCalls.isEmpty)
            #expect(await !fixture.automation.preparationCompleted.isOpen)
        }
    }

    @Test(arguments: [
        Int(UInt64.max / 1_000_000) - 1,
        Int(UInt64.max / 1_000_000),
        Int(UInt64.max / 1_000_000) + 1,
        Int.max,
    ])
    func `large waits cancel after completed preparation without running later input`(duration: Int) async throws {
        let fixture = AutomationWaitFixture()
        let completion = AsyncTestLatch()
        let task = Task {
            defer { Task { await completion.open() } }
            return try await fixture.services.automate(
                appIdentifier: "owned-fixture",
                actions: [Self.marker, .wait(milliseconds: duration), Self.suffix])
        }
        defer { task.cancel() }
        let prepared = await fixture.automation.preparationCompleted.opensWithin(.seconds(2))
        try #require(prepared)
        #expect(fixture.snapshots.createCalls.count == 1)
        #expect(fixture.capture.captureAttemptCount == 1 && fixture.automation.detectionCallCount == 1)
        #expect(fixture.snapshots.storeDetectionResultCalls.count == 1 && fixture.automation.clickCalls.count == 1)
        #expect(await !completion.isOpen)
        task.cancel()
        let completed = await completion.opensWithin(.seconds(2))
        try #require(completed)
        let error = await #expect(throws: PeekabooError.self) { _ = try await task.value }
        let expected = CancellationError().asPeekabooError(context: "Action execution failed")
        #expect(error?.localizedDescription == expected.localizedDescription)
        #expect(fixture.automation.clickCalls.count == 1)
    }

    @Test(arguments: [0, 1])
    func `wait observes cancellation already set by the preceding action`(duration: Int) async throws {
        let fixture = AutomationWaitFixture()
        fixture.automation.cancelAfterFirstClick = true
        let task = Task {
            try await fixture.services.automate(
                appIdentifier: "owned-fixture",
                actions: [Self.marker, .wait(milliseconds: duration), Self.suffix])
        }
        defer { task.cancel() }
        let error = await #expect(throws: PeekabooError.self) { _ = try await task.value }
        let expected = CancellationError().asPeekabooError(context: "Action execution failed")
        #expect(error?.localizedDescription == expected.localizedDescription)
        #expect(fixture.automation.clickCalls.count == 1)
    }

    @Test
    func `zero and ordinary waits remain successful ordered actions`() async throws {
        let fixture = AutomationWaitFixture()
        let result = try await fixture.services.automate(
            appIdentifier: "owned-fixture", actions: [.wait(milliseconds: 0), .wait(milliseconds: 1)])
        #expect(result.actions.map(\.success) == [true, true])
        #expect(fixture.capture.captureAttemptCount == 1 && fixture.automation.detectionCallCount == 1)
        #expect(fixture.automation.clickCalls.isEmpty)
    }

    private static let marker = AutomationAction.click(target: .query("prepared-marker"), type: .single)
    private static let suffix = AutomationAction.click(target: .query("must-not-run"), type: .single)
}

@MainActor
private struct AutomationWaitFixture {
    let snapshots = SnapshotMutationRecordingManager(wrapping: InMemorySnapshotManager())
    let capture = MockScreenCaptureService(screenRecordingGranted: true)
    let automation = AutomationWaitFixtureAutomation(accessibilityGranted: true)

    var services: PeekabooServices {
        let defaults = AuthorityTestSupport.services(snapshotManager: self.snapshots)
        return PeekabooServices(
            screenCapture: self.capture,
            applications: defaults.applications,
            automation: self.automation,
            windows: defaults.windows,
            menu: defaults.menu,
            dock: defaults.dock,
            dialogs: defaults.dialogs,
            snapshots: self.snapshots,
            files: defaults.files,
            clipboard: defaults.clipboard,
            configuration: defaults.configuration,
            screens: defaults.screens)
    }
}

@MainActor
private final class AutomationWaitFixtureAutomation: MockAutomationService {
    let preparationCompleted = AsyncTestLatch()
    var detectionCallCount = 0
    var cancelAfterFirstClick = false

    override func click(target: ClickTarget, clickType: ClickType, snapshotId: String?) async throws {
        try await super.click(target: target, clickType: clickType, snapshotId: snapshotId)
        if self.clickCalls.count == 1 {
            if self.cancelAfterFirstClick {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            await self.preparationCompleted.open()
        }
    }

    override func detectElements(in _: Data, snapshotId: String?, windowContext _: WindowContext?) async throws
        -> ElementDetectionResult
    {
        self.detectionCallCount += 1
        guard let snapshotId else { throw PeekabooError.invalidInput("Owned detection requires a snapshot") }
        return ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/owned-fixture.png",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0, elementCount: 0, method: "owned-fixture", truncationInfo: nil))
    }
}
