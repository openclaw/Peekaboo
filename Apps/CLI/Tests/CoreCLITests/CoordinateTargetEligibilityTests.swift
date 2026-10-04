import Commander
import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized)
@MainActor
struct CoordinateTargetEligibilityTests {
    @Test(arguments: ["size", "minimized", "offscreen", "shareability", "alpha"])
    func `returned ineligible windows explain their filter without input or titles`(reason: String) async throws {
        let row = Self.window(reason: reason)
        if reason == "size" {
            #expect(WindowFiltering.isRenderable(row, mode: .list))
            #expect(!WindowFiltering.isRenderable(row, mode: .capture))
        }
        let windows = CoordinateEligibilityWindows(rows: [row])
        let automation = CoordinateEligibilityAutomation()
        let services = FocusProofPressServices(windows: windows, automation: automation)
        var target = InteractionTargetOptions()
        target.windowId = 49
        let failure = try #require(await #expect(throws: PreDispatchActionError.self) {
            try await InteractionCoordinateResolver.resolveTargetWindow(target: target, services: services)
        })
        #expect(failure.code == .VALIDATION_ERROR)
        #expect(failure.failure.message.contains("window 49"))
        #expect(try failure.failure.message.contains(#require(WindowFiltering.disqualificationReason(for: row))))
        #expect(failure.failure.outcome.state == .refused)
        #expect(failure.failure.outcome.dispatchState == .none)
        #expect(failure.envelopeMutationDispatched == false)
        #expect(failure.envelopeRetrySafe == true)
        let envelope = makeErrorEnvelope(
            message: failure.failure.message,
            code: failure.code,
            hint: failure.hint,
            details: failure.failure.causeDescription,
            actionFailure: failure.failure
        )
        let encoded = try JSONEncoder().encode(envelope)
        let encodedText = try #require(String(data: encoded, encoding: .utf8))
        #expect(!encodedText.contains(Self.privateTitle))
        #expect(windows.focusCalls == 0)
        #expect(automation.moves == 0)
        #expect(automation.clickCalls.isEmpty)
    }

    @Test
    func `absent window stays not found and minimum eligible width remains accepted`() async throws {
        var target = InteractionTargetOptions()
        target.windowId = 49
        let windows = CoordinateEligibilityWindows(rows: [])
        let services = FocusProofPressServices(windows: windows, automation: CoordinateEligibilityAutomation())
        let missing = try #require(await #expect(throws: PeekabooError.self) {
            try await InteractionCoordinateResolver.resolveTargetWindow(target: target, services: services)
        })
        if case .windowNotFound = missing {} else {
            Issue.record("Expected the existing missing-window error")
        }
        windows.rows = [Self.window(reason: "eligible")]
        let selected = try #require(ObservationTargetResolver.bestWindow(from: windows.rows))
        #expect(selected.windowID == 49)
        #expect(selected.bounds.width == 80)
        let coordinates = try InteractionCoordinateResolver.resolveTargetWindowCoordinates(
            CGPoint(x: 5, y: 5), windowInfo: selected, targetApplication: nil
        )
        #expect(coordinates.screenPoint == CGPoint(x: 105, y: 205))
        #expect(windows.focusCalls == 0)
    }

    @Test
    func `move retains dispatched focus when subsequent coordinate eligibility fails`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coordinate-focus-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = CoordinateEligibilityWindows(rows: [Self.window(reason: "size")])
        let automation = CoordinateEligibilityAutomation()
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: FocusProofPressServices(windows: windows, automation: automation),
            interactionMutationTracker: InteractionMutationTracker(
                desktopMutationWatermarkStore: DesktopMutationWatermarkStore(directoryURL: directory)
            )
        )
        var command = MoveCommand()
        command.at = "5,5"
        command.target.windowId = 49
        command.focusOptions.foreground = true
        let output = try await captureStandardOutputBytes {
            defer { Logger.shared.setJsonOutputMode(false) }
            await #expect(throws: ExitCode.self) { try await command.run(using: runtime) }
        }
        let envelope = try JSONDecoder().decode(ResultEnvelope<Empty?>.self, from: output)
        #expect(windows.focusCalls == 1)
        #expect(automation.moves == 0)
        #expect(automation.clickCalls.isEmpty)
        #expect(envelope.outcome == CoordinateEligibilityWindows.focusOutcome.projection)
        #expect(envelope.target_receipt == windows.rows[0].mutationIdentity?.actionTargetReceipt)
        #expect(envelope.error?.mutation_dispatched == true)
        #expect(envelope.error?.retry_safe == false)
        #expect(envelope.error?.details?.contains("window too small") == true)
        let outputText = try #require(String(data: output, encoding: .utf8))
        #expect(!outputText.contains(Self.privateTitle))
    }

    private static let privateTitle = "PRIVATE-WINDOW-TITLE-SENTINEL"

    private static func window(reason: String) -> ServiceWindowInfo {
        let bounds = CGRect(x: 100, y: 200, width: reason == "size" ? 70 : 80, height: 100)
        return ServiceWindowInfo(
            windowID: 49,
            title: self.privateTitle,
            bounds: bounds,
            isMinimized: reason == "minimized",
            alpha: reason == "alpha" ? 0 : 1,
            isOnScreen: reason != "offscreen",
            sharingState: reason == "shareability" ? .some(.none) : nil,
            mutationIdentity: WindowMutationIdentity(
                windowID: 49, ownerProcessIdentifier: 420, ownerProcessStartIdentity: 9001, capturedBounds: bounds
            )
        )
    }
}

@MainActor
private final class CoordinateEligibilityWindows: ScriptedWindowInventoryService,
WindowManagementPinnedFocusActionResultProviding {
    var rows: [ServiceWindowInfo]
    var focusCalls = 0
    static let focusOutcome = DesktopActionOutcome.confirmedChange(
        route: .bridge, delivery: .init(mechanism: .accessibilityAction, mode: .foreground), unitCount: .one
    )

    init(rows: [ServiceWindowInfo]) {
        self.rows = rows
        super.init()
    }

    override func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        self.rows
    }

    @MainActor
    func focusWindowActionResult(target: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        try await self.focusWindowActionResult(
            target: target,
            expectedIdentity: #require(self.rows.first?.mutationIdentity)
        )
    }

    @MainActor
    func focusWindowActionResult(
        target: WindowTarget, expectedIdentity: WindowMutationIdentity
    ) async throws -> UIAutomationActionResult<Void> {
        #expect(target == .windowId(49))
        #expect(expectedIdentity == self.rows.first?.mutationIdentity)
        self.focusCalls += 1
        return try UIAutomationActionResult(
            payload: (),
            outcome: Self.focusOutcome,
            targetIdentity: DesktopTargetIdentity(
                exactWindow: UIAutomationTarget.ExactWindow(
                    identity: expectedIdentity, bounds: #require(expectedIdentity.capturedBounds)
                )
            )
        )
    }
}

@MainActor
private final class CoordinateEligibilityAutomation: MockAutomationService {
    var moves = 0
    override func moveMouse(
        to _: CGPoint,
        duration _: Int,
        steps _: Int,
        profile _: MouseMovementProfile
    ) async throws {
        self.moves += 1
    }
}
