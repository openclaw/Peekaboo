import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
struct ComposedInputParityValidationTests {
    private typealias Fixture = (services: PeekabooServices, snapshots: StubSnapshotManager, snapshotID: String)
    private static let canonicalSnapshotID = SnapshotReferenceFixtures.first.rawValue

    @Test(arguments: [
        "invalid", "10", "10,20,30", "nan,20", "10,inf", ",10,20", "10,,20", "10,20,",
    ])
    func `pixel focus type requires one finite coordinate pair`(_ point: String) throws {
        var command = try TypeCommand.parse([
            "hello", "--at", point, "--snapshot", Self.canonicalSnapshotID,
        ])

        let error = #expect(throws: ValidationError.self) {
            try command.validate()
        }
        #expect(error?.localizedDescription == "Invalid coordinates format. Use: x,y")
    }

    @Test
    func `pixel focus type requires one explicit background snapshot target`() throws {
        let invalidArguments = [
            ["hello", "--at", "10,20"],
            ["hello", "--at", "10,20", "--snapshot", "latest"],
            ["hello", "--at", "10,20", "--snapshot", Self.canonicalSnapshotID, "--foreground"],
            ["hello", "--at", "10,20", "--snapshot", Self.canonicalSnapshotID, "--app", "TextEdit"],
        ]

        for arguments in invalidArguments {
            #expect(throws: (any Error).self) {
                var command = try TypeCommand.parse(arguments)
                try command.validate()
            }
        }

        var accepted = try TypeCommand.parse([
            "hello", "--at", "10,20", "--coordinate-space", "image_pixels", "--snapshot",
            Self.canonicalSnapshotID,
            "--focus-background",
        ])
        try accepted.validate()
    }

    @Test(arguments: [
        ["--no-auto-focus"],
        ["--focus-timeout", "1s"],
        ["--focus-retry-count", "2"],
        ["--space-switch"],
        ["--bring-to-current-space"],
    ])
    func `pixel focus type rejects foreground focus overrides`(_ focusArguments: [String]) throws {
        var command = try TypeCommand.parse([
            "hello", "--at", "10,20", "--snapshot", Self.canonicalSnapshotID,
        ] + focusArguments)

        let error = #expect(throws: ValidationError.self) {
            try command.validate()
        }
        #expect(error?.localizedDescription ==
            "--at pixel typing owns exact-window background focus; remove foreground focus overrides")
    }

    @Test
    func `modifier click requires explicit foreground and exact snapshot authority`() throws {
        let invalidArguments = [
            ["--on", "B1", "--modifiers", "cmd", "--snapshot", Self.canonicalSnapshotID],
            ["--on", "B1", "--modifiers", "cmd", "--foreground"],
            ["--on", "B1", "--modifiers", "cmd", "--foreground", "--snapshot", "latest"],
            ["--on", "B1", "--modifiers", "fn", "--foreground", "--snapshot", Self.canonicalSnapshotID],
            ["--on", "B1", "--modifiers", "ctrl", "--foreground", "--snapshot", Self.canonicalSnapshotID],
            [
                "--on", "B1", "--modifiers", "cmd", "--right", "--foreground", "--snapshot",
                Self.canonicalSnapshotID,
            ],
            [
                "--on", "B1", "--modifiers", "cmd", "--foreground", "--snapshot", Self.canonicalSnapshotID,
                "--app", "Safari",
            ],
            [
                "--on", "B1", "--modifiers", "cmd", "--foreground", "--snapshot", Self.canonicalSnapshotID,
                "--space-switch",
            ],
        ]

        for arguments in invalidArguments {
            #expect(throws: (any Error).self) {
                var command = try ClickCommand.parse(arguments)
                try command.validate()
            }
        }

        var accepted = try ClickCommand.parse([
            "--on", "B1", "--modifiers", "cmd,shift", "--foreground", "--snapshot", Self.canonicalSnapshotID,
        ])
        try accepted.validate()
    }

    @Test
    @MainActor
    func `pixel focus receipt planning preserves cancellation without consuming snapshot`() async throws {
        let snapshots = StubSnapshotManager()
        let snapshotID = try await snapshots.createSnapshot()
        snapshots.uiAutomationSnapshotCancellation = true

        await #expect(throws: CancellationError.self) {
            _ = try await TypeCommand.planPixelFocusReceipt(
                snapshotID: snapshotID,
                snapshots: snapshots
            )
        }
        #expect(snapshots.invalidationCutoffs.isEmpty)
        let lease = try await snapshots.beginSnapshotMutation(snapshotId: snapshotID)
        try await snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    @MainActor
    func `modifier click receipt planning preserves cancellation without consuming snapshot`() async throws {
        let snapshots = StubSnapshotManager()
        let snapshotID = try await snapshots.createSnapshot()
        snapshots.uiAutomationSnapshotCancellation = true

        await #expect(throws: CancellationError.self) {
            _ = try await ClickCommand.modifierClickCoordinateAuthority(
                snapshotID: snapshotID,
                snapshots: snapshots
            )
        }
        #expect(snapshots.invalidationCutoffs.isEmpty)
        let lease = try await snapshots.beginSnapshotMutation(snapshotId: snapshotID)
        try await snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    @MainActor
    func `pixel focus pre-dispatch refusal preserves explicit snapshot`() async throws {
        let fixture = try await Self.makePixelFocusFixture(
            behavior: .failure(.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Snapshot lease admission refused before dispatch."
            ))
        )

        for _ in 0..<2 {
            let result = try await Self.runPixelFocusType(fixture)
            let object = try Self.jsonObject(result.stdout)
            let error = try #require(object["error"] as? [String: Any])

            #expect(result.exitStatus == 1)
            #expect(error["retry_safe"] as? Bool == true)
            #expect(error["mutation_dispatched"] as? Bool == false)
            #expect(try await fixture.snapshots.getDetectionResult(snapshotId: fixture.snapshotID) != nil)
            #expect(await fixture.snapshots.getMostRecentSnapshot() == fixture.snapshotID)
            #expect(fixture.snapshots.invalidationCutoffs.isEmpty)
        }

        let lease = try await fixture.snapshots.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await fixture.snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    @MainActor
    func `pixel focus dispatched-unverified result is non-success and invalidates explicit snapshot`() async throws {
        let fixture = try await Self.makePixelFocusFixture(
            behavior: .result(.dispatchedUnverified(
                delivery: Self.backgroundPixelFocusDelivery,
                evidence: .deliveryAccepted,
                unitCount: .one
            ))
        )

        let result = try await Self.runPixelFocusType(fixture)
        #expect(result.exitStatus == 1)
        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])
        #expect(outcome["state"] as? String == "dispatched_unverified")
        #expect(object["data"] is NSNull)
        #expect(!result.combinedOutput.contains("typedText"))
        #expect(!result.combinedOutput.contains("totalCharacters"))
        #expect(await fixture.snapshots.getMostRecentSnapshot() == nil)
        #expect(fixture.snapshots.invalidationCutoffs.count == 1)
    }

    @Test
    @MainActor
    func `pixel focus indeterminate failure invalidates explicit snapshot`() async throws {
        let fixture = try await Self.makePixelFocusFixture(
            behavior: .failure(.indeterminate(
                delivery: Self.backgroundPixelFocusDelivery,
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Pixel-focus typing completion is unknown."
            ))
        )

        let result = try await Self.runPixelFocusType(fixture)
        let object = try Self.jsonObject(result.stdout)
        let error = try #require(object["error"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(error["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
        #expect(await fixture.snapshots.getMostRecentSnapshot() == nil)
        #expect(fixture.snapshots.invalidationCutoffs.count == 1)
    }

    @Test
    @MainActor
    func `modifier click pre-dispatch refusal preserves explicit snapshot`() async throws {
        let fixture = try await Self.makeModifierClickFixture(
            behavior: .failure(.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Snapshot lease admission refused before dispatch."
            ))
        )

        for _ in 0..<2 {
            let result = try await Self.runModifierClick(fixture)
            let object = try Self.jsonObject(result.stdout)
            let error = try #require(object["error"] as? [String: Any])

            #expect(result.exitStatus == 1)
            #expect(error["retry_safe"] as? Bool == true)
            #expect(error["mutation_dispatched"] as? Bool == false)
            #expect(try await fixture.snapshots.getDetectionResult(snapshotId: fixture.snapshotID) != nil)
            #expect(await fixture.snapshots.getMostRecentSnapshot() == fixture.snapshotID)
            #expect(fixture.snapshots.invalidationCutoffs.isEmpty)
        }

        let lease = try await fixture.snapshots.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await fixture.snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    @MainActor
    func `modifier click dispatched result invalidates explicit snapshot`() async throws {
        let fixture = try await Self.makeModifierClickFixture(
            behavior: .result(.dispatchedUnverified(
                delivery: Self.foregroundModifierDelivery,
                evidence: .deliveryAccepted,
                unitCount: .one
            ))
        )

        let result = try await Self.runModifierClick(fixture)
        #expect(result.exitStatus == 0)
        #expect(await fixture.snapshots.getMostRecentSnapshot() == nil)
        #expect(fixture.snapshots.invalidationCutoffs.count == 1)
    }

    @Test
    @MainActor
    func `modifier click indeterminate failure invalidates explicit snapshot`() async throws {
        let fixture = try await Self.makeModifierClickFixture(
            behavior: .failure(.indeterminate(
                delivery: Self.foregroundModifierDelivery,
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Modifier-click completion is unknown."
            ))
        )

        let result = try await Self.runModifierClick(fixture)
        let object = try Self.jsonObject(result.stdout)
        let error = try #require(object["error"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(error["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
        #expect(await fixture.snapshots.getMostRecentSnapshot() == nil)
        #expect(fixture.snapshots.invalidationCutoffs.count == 1)
    }

    @MainActor
    private static func makeModifierClickFixture(
        behavior: ComposedInputStubBehavior
    ) async throws -> Fixture {
        try await self.makeComposedInputFixture(
            automation: ModifierClickStubAutomationService(behavior: behavior)
        )
    }

    @MainActor
    private static func makePixelFocusFixture(
        behavior: ComposedInputStubBehavior
    ) async throws -> Fixture {
        try await self.makeComposedInputFixture(
            automation: PixelFocusStubAutomationService(behavior: behavior)
        )
    }

    @MainActor
    private static func makeComposedInputFixture(
        automation: StubAutomationService
    ) async throws -> Fixture {
        let processIdentifier: pid_t = 12345
        let processStartIdentity: UInt64 = 7
        let windowID = 42
        let windowBounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        let windowIdentity = WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            capturedBounds: windowBounds
        )
        let application = ServiceApplicationInfo(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            bundleIdentifier: "com.example.test",
            name: "TestApp",
            activationPolicy: .regular
        )
        let window = ServiceWindowInfo(
            windowID: windowID,
            title: "Editor",
            bounds: windowBounds,
            isMainWindow: true,
            index: 0,
            mutationIdentity: windowIdentity
        )
        let windowsByApp = [application.name: [window]]
        let context = TestServicesFactory.makeAutomationTestContext(
            automation: automation,
            applications: StubApplicationService(applications: [application], windowsByApp: windowsByApp),
            windows: StubWindowService(windowsByApp: windowsByApp)
        )
        let snapshotID = try await context.snapshots.createSnapshot()
        let button = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
        )
        try await context.snapshots.storeDetectionResult(
            snapshotId: snapshotID,
            result: ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "/tmp/modifier-click.png",
                elements: DetectedElements(buttons: [button]),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 1,
                    method: "stub",
                    windowContext: WindowContext(
                        applicationName: application.name,
                        applicationBundleId: application.bundleIdentifier,
                        applicationProcessId: processIdentifier,
                        windowTitle: window.title,
                        windowID: windowID,
                        windowBounds: windowBounds,
                        windowMutationIdentity: windowIdentity
                    ),
                    truncationInfo: nil,
                    captureCoordinateContext: CaptureCoordinateContext(
                        metadata: CaptureMetadata(
                            size: windowBounds.size,
                            mode: .window,
                            windowInfo: window
                        ),
                        referenceID: snapshotID
                    )
                )
            )
        )
        return (context.services, context.snapshots, snapshotID)
    }

    @MainActor
    private static func runModifierClick(
        _ fixture: Fixture
    ) async throws -> CommandRunResult {
        try await InProcessCommandRunner.run(
            [
                "click", "--on", "B1", "--snapshot", fixture.snapshotID,
                "--foreground", "--modifiers", "cmd", "--json", "--no-remote",
            ],
            services: fixture.services
        )
    }

    @MainActor
    private static func runPixelFocusType(
        _ fixture: Fixture
    ) async throws -> CommandRunResult {
        try await InProcessCommandRunner.run(
            [
                "type", "hello", "--at", "60,45", "--snapshot", fixture.snapshotID,
                "--json", "--no-remote",
            ],
            services: fixture.services
        )
    }

    private static var backgroundPixelFocusDelivery: DesktopActionOutcome.Delivery {
        .init(mechanism: .windowTargetedEvents, mode: .background)
    }

    private static var foregroundModifierDelivery: DesktopActionOutcome.Delivery {
        .init(mechanism: .composite, mode: .foreground)
    }

    private static func jsonObject(_ output: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
}

private enum ComposedInputStubBehavior {
    case result(DesktopActionOutcome)
    case failure(DesktopActionFailure)
}

@MainActor
private final class ModifierClickStubAutomationService: StubAutomationService,
ForegroundModifierClickServiceProtocol {
    let behavior: ComposedInputStubBehavior
    let supportsForegroundModifierClick = true
    let supportsForegroundModifierClickSnapshotLease = true
    let foregroundModifierClickUnavailableReason: String? = nil

    init(behavior: ComposedInputStubBehavior) {
        self.behavior = behavior
    }

    func foregroundModifierClickWithOutcome(
        _ request: ForegroundModifierClickRequest
    ) async throws -> UIAutomationActionResult<ForegroundModifierClickResult> {
        switch self.behavior {
        case let .failure(failure):
            throw failure
        case let .result(outcome):
            let exactWindow = try UIAutomationTarget.ExactWindow(
                identity: request.windowIdentity,
                bounds: request.windowBounds
            )
            return UIAutomationActionResult(
                payload: ForegroundModifierClickResult(
                    cursorRestoration: .notNeeded,
                    focusRestoration: .notNeeded
                ),
                outcome: outcome,
                targetIdentity: DesktopTargetIdentity(exactWindow: exactWindow)
            )
        }
    }
}

@MainActor
private final class PixelFocusStubAutomationService: StubAutomationService,
ExactWindowPixelFocusTypingServiceProtocol, CompositeTypeDeliveryServiceProtocol {
    let behavior: ComposedInputStubBehavior
    let supportsExactWindowPixelFocusTyping = true
    let exactWindowPixelFocusTypingUnavailableReason: String? = nil
    let supportsExactWindowCompositeTypeDelivery = true
    let exactWindowCompositeTypeDeliveryUnavailableReason: String? = nil

    init(behavior: ComposedInputStubBehavior) {
        self.behavior = behavior
    }

    func typeActionsByFocusingPixelWithOutcome(
        _ request: ExactWindowPixelFocusTypeRequest
    ) async throws -> UIAutomationActionResult<TypeResult> {
        switch self.behavior {
        case let .failure(failure):
            throw failure
        case let .result(outcome):
            let exactWindow = try UIAutomationTarget.ExactWindow(
                identity: request.windowIdentity,
                bounds: request.windowBounds
            )
            return UIAutomationActionResult(
                payload: TypeResult(totalCharacters: 5, keyPresses: 5),
                outcome: outcome,
                targetIdentity: DesktopTargetIdentity(exactWindow: exactWindow)
            )
        }
    }
}
