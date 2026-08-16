import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.fast))
@MainActor
struct ObservationPolicyDefaultsTests {
    @Test
    func `See defaults to read only observation`() throws {
        let command = try SeeCommand.parse([])

        #expect(!command.webFocus)
        #expect(!command.noWebFocus)
        let request = try command.makeObservationRequest(target: .frontmost)
        #expect(request.capture.focus == .background)
        #expect(!request.detection.allowWebFocusFallback)
        #expect(request.timeout.overall == 20)
        #expect(request.timeout.detection == 20)
    }

    @Test
    func `See propagates its overall timeout to remote observation`() throws {
        var configured = try SeeCommand.parse([])
        configured.timeout = .seconds(45)
        var analyzed = try SeeCommand.parse([])
        analyzed.analyze = "summarize"

        #expect(try configured.makeObservationRequest(target: .frontmost).timeout.overall == 45)
        #expect(try configured.makeObservationRequest(target: .frontmost).timeout.detection == 45)
        #expect(try analyzed.makeObservationRequest(target: .frontmost).timeout.overall == 60)
    }

    @Test
    func `See menu timeout projection preserves exact mutation receipt`() throws {
        var command = try SeeCommand.parse(["--menubar"])
        command.runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: PeekabooServices()
        )
        let target = DesktopActionTargetReceipt(
            processIdentifier: 321,
            processStartIdentity: 654,
            windowID: 700
        )
        let progress = DesktopObservationActionProgressReceipt(
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: DesktopActionOutcome.DispatchUnitCount(3)
            ),
            targetReceipt: target
        )

        let failure = try #require(command.failurePreservingConditionalTimeout(
            CaptureError.detectionTimedOut(0.5),
            progress: progress
        ) as? DesktopActionFailure)

        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.delivery?.mechanism == .windowTargetedEvents)
        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 3)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.targetReceipt == target)
    }

    @Test
    func `See web timeout before dispatch remains a raw safe timeout`() throws {
        var command = try SeeCommand.parse(["--web-focus"])
        command.runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: PeekabooServices()
        )

        let projected = command.failurePreservingConditionalTimeout(
            CaptureError.detectionTimedOut(0.5),
            progress: nil
        )

        guard case let CaptureError.detectionTimedOut(seconds) = projected else {
            Issue.record("Expected the pre-dispatch web timeout to remain a CaptureError")
            return
        }
        #expect(seconds == 0.5)
    }

    @Test
    func `See carries its capture engine in the desktop observation request`() throws {
        var classic = try SeeCommand.parse([])
        classic.captureEngine = "cg"
        var modern = try SeeCommand.parse([])
        modern.captureEngine = "sckit"

        #expect(try classic.makeObservationRequest(target: .frontmost).capture.engine == .legacy)
        #expect(try modern.makeObservationRequest(target: .frontmost).capture.engine == .modern)
    }

    @Test
    func `See safety override clamps transported auto requests to classic`() throws {
        var command = try SeeCommand.parse(["--capture-engine", "auto"])
        command.runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil),
            services: PeekabooServices(),
            captureEngineSafetyOverride: .legacy
        )

        #expect(try command.makeObservationRequest(target: .frontmost).capture.engine == .legacy)
        #expect(command.makePixelObservationRequest(
            target: .frontmost,
            outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("capture.png")
        ).capture.engine == .legacy)
    }

    @Test
    func `exact pixel observation can publish a coordinate receipt without detection`() throws {
        let command = try SeeCommand.parse(["--window-id", "42", "--no-elements"])
        let processTarget = try SeeCommand.parse(["--app", "Fixture", "--no-elements"])
        let streamed = try SeeCommand.parse(["--window-id", "42", "--no-elements", "--path", "-"])
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("capture.png")
        let ordinary = command.makePixelObservationRequest(target: .windowID(42), outputURL: outputURL)
        let receipt = command.makePixelObservationRequest(
            target: .windowID(42),
            outputURL: outputURL,
            snapshotID: "coordinate-receipt"
        )

        #expect(command.publishesPixelCoordinateReceipt)
        #expect(!processTarget.publishesPixelCoordinateReceipt)
        #expect(!streamed.publishesPixelCoordinateReceipt)
        #expect(!ordinary.output.saveSnapshot)
        #expect(ordinary.output.snapshotID == nil)
        #expect(receipt.detection.mode == .none)
        #expect(receipt.output.saveSnapshot)
        #expect(receipt.output.snapshotID == "coordinate-receipt")
    }

    @Test
    func `See web focus fallback is a positive opt in`() throws {
        let enabled = try SeeCommand.parse(["--web-focus"])
        #expect(enabled.webFocus)
        #expect(try enabled.makeObservationRequest(target: .frontmost).detection.allowWebFocusFallback)

        let compatibility = try SeeCommand.parse(["--no-web-focus"])
        #expect(compatibility.noWebFocus)
        #expect(try !(compatibility.makeObservationRequest(target: .frontmost).detection.allowWebFocusFallback))
    }

    @Test
    func `See exposes AX tree inspection without enabling web focus`() throws {
        let command = try SeeCommand.parse(["--tree", "--no-screenshot"])
        #expect(command.tree)
        #expect(command.noScreenshot)
        #expect(!command.webFocus)
    }

    @Test
    func `See pixel capture and live capture default to background focus policy`() throws {
        #expect(try SeeCommand.parse(["--no-elements"]).captureFocus == .background)
        #expect(try CaptureLiveCommand.parse([]).captureFocus == .background)
        #expect(CaptureActionCommand().captureFocus == .background)
    }
}
