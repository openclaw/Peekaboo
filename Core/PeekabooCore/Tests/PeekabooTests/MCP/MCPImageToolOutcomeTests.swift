import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAgentRuntime

@Suite(.serialized)
struct MCPImageToolOutcomeTests {
    @Test
    @MainActor
    func `background screen capture stays read only and silent`() async throws {
        let observation = ImageOutcomeObservationService(
            fixture: .screen(),
            outcome: nil,
            actionTarget: nil)
        let applications = ImageOutcomeApplicationService(applications: [])
        let response = try await Self.execute(
            arguments: ["app_target": "screen", "capture_focus": "background"],
            applications: applications,
            observation: observation)
        let meta = try Self.meta(response)

        #expect(!response.isError)
        #expect(applications.activationRequests.isEmpty)
        #expect(observation.requests.first?.capture.focus == .background)
        #expect(observation.requests.first?.capture.visualizerMode == CaptureVisualizerMode.none)
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(meta["state"] == nil)
        #expect(meta["target_receipt"] == nil)
    }

    @Test
    @MainActor
    func `background app capture emits exact window receipt without activation`() async throws {
        let fixture = try ImageObservationFixture.window()
        let observation = ImageOutcomeObservationService(
            fixture: fixture,
            outcome: nil,
            actionTarget: fixture.targetIdentity)
        let applications = ImageOutcomeApplicationService(applications: [fixture.application])
        let response = try await Self.execute(
            arguments: ["app_target": fixture.application.name, "capture_focus": "background"],
            applications: applications,
            observation: observation)
        let meta = try Self.meta(response)

        #expect(!response.isError)
        #expect(applications.activationRequests.isEmpty)
        #expect(observation.requests.first?.target == .app(
            identifier: fixture.application.name,
            window: .automatic))
        try Self.expectTargetReceipt(meta, fixture: fixture)
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
    }

    @Test
    @MainActor
    func `foreground screen capture reports one visible capture unit`() async throws {
        let outcome = Self.captureOutcome
        let observation = ImageOutcomeObservationService(
            fixture: .screen(),
            outcome: outcome,
            actionTarget: nil)
        let applications = ImageOutcomeApplicationService(applications: [])
        let response = try await Self.execute(
            arguments: ["app_target": "screen", "capture_focus": "foreground"],
            applications: applications,
            observation: observation)
        let meta = try Self.meta(response)

        #expect(!response.isError)
        #expect(applications.activationRequests.isEmpty)
        #expect(observation.requests.first?.capture.visualizerMode == .screenshotFlash)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
        #expect(meta["target_receipt"] == nil)
    }

    @Test
    @MainActor
    func `foreground frontmost capture reports visible unit and exact target`() async throws {
        let fixture = try ImageObservationFixture.window(kind: .frontmost)
        let observation = ImageOutcomeObservationService(
            fixture: fixture,
            outcome: Self.captureOutcome,
            actionTarget: fixture.targetIdentity)
        let applications = ImageOutcomeApplicationService(applications: [])
        let response = try await Self.execute(
            arguments: ["app_target": "frontmost", "capture_focus": "foreground"],
            applications: applications,
            observation: observation)
        let meta = try Self.meta(response)

        #expect(!response.isError)
        #expect(observation.requests.first?.target == .frontmost)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(Self.captureOutcome, in: response)
        try Self.expectTargetReceipt(meta, fixture: fixture)
    }

    @Test
    @MainActor
    func `foreground window id uses exact result aware focus`() async throws {
        let windows = MCPFocusResultWindowService()
        let fixture = try ImageObservationFixture.window(
            processIdentifier: windows.identity.ownerProcessIdentifier,
            processStartIdentity: windows.identity.ownerProcessStartIdentity,
            windowID: windows.identity.windowID,
            bounds: #require(windows.identity.capturedBounds))
        let observation = ImageOutcomeObservationService(
            fixture: fixture,
            outcome: Self.captureOutcome,
            actionTarget: fixture.targetIdentity)
        let applications = ImageOutcomeApplicationService(applications: [])
        let response = try await Self.execute(
            arguments: ["window_id": windows.identity.windowID, "capture_focus": "foreground"],
            applications: applications,
            observation: observation,
            windows: windows)
        let meta = try Self.meta(response)

        #expect(!response.isError)
        #expect(windows.focusCalls == 1)
        #expect(observation.requests.first?.target == .windowID(CGWindowID(windows.identity.windowID)))
        #expect(meta["delivery_mechanism"] == .string("composite"))
        #expect(meta["delivery_mode"] == .string("foreground"))
        #expect(meta["dispatched_unit_count"] == .int(2))
        try Self.expectTargetReceipt(meta, fixture: fixture)
    }

    @Test
    @MainActor
    func `foreground app capture composes pinned activation and visible capture`() async throws {
        let fixture = try ImageObservationFixture.window()
        let observation = ImageOutcomeObservationService(
            fixture: fixture,
            outcome: Self.captureOutcome,
            actionTarget: fixture.targetIdentity)
        let applications = ImageOutcomeApplicationService(
            applications: [fixture.application],
            activationOutcome: Self.activationOutcome)
        let response = try await Self.execute(
            arguments: ["app_target": fixture.application.name, "capture_focus": "foreground"],
            applications: applications,
            observation: observation)
        let meta = try Self.meta(response)

        #expect(!response.isError)
        #expect(applications.activationRequests == [ApplicationActivationRequest(
            identifier: "PID:\(fixture.processIdentity.processIdentifier)",
            expectedIdentity: fixture.processIdentity)])
        #expect(observation.requests.first?.target == .pid(
            fixture.processIdentity.processIdentifier,
            window: .automatic))
        #expect(meta["state"] == .string("dispatched_unverified"))
        #expect(meta["delivery_mechanism"] == .string("composite"))
        #expect(meta["delivery_mode"] == .string("foreground"))
        #expect(meta["dispatched_unit_count"] == .int(2))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        try Self.expectTargetReceipt(meta, fixture: fixture)
    }

    @Test
    @MainActor
    func `already active app contributes no dispatch unit before visible capture`() async throws {
        let fixture = try ImageObservationFixture.window()
        let observation = ImageOutcomeObservationService(
            fixture: fixture,
            outcome: Self.captureOutcome,
            actionTarget: fixture.targetIdentity)
        let applications = ImageOutcomeApplicationService(
            applications: [fixture.application],
            activationOutcome: .confirmedNoChange())
        let response = try await Self.execute(
            arguments: ["app_target": fixture.application.name, "capture_focus": "foreground"],
            applications: applications,
            observation: observation)
        let meta = try Self.meta(response)

        #expect(!response.isError)
        #expect(meta["delivery_mechanism"] == .string("capture_pipeline"))
        #expect(meta["dispatched_unit_count"] == .int(1))
        try Self.expectTargetReceipt(meta, fixture: fixture)
    }

    @Test
    @MainActor
    func `background target dependent capture rejects missing exact window safely`() async throws {
        let fixture = ImageObservationFixture.processOnly()
        let observation = ImageOutcomeObservationService(
            fixture: fixture,
            outcome: nil,
            actionTarget: fixture.targetIdentity)
        let applications = ImageOutcomeApplicationService(applications: [])
        let response = try await Self.execute(
            arguments: ["app_target": "frontmost", "capture_focus": "background"],
            applications: applications,
            observation: observation)
        let meta = try Self.meta(response)

        #expect(response.isError)
        #expect(meta["state"] == .string("refused"))
        #expect(meta["refusal_reason"] == .string("target_unavailable"))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
    }

    @Test
    @MainActor
    func `foreground target contradiction is unsafe and keeps composed units`() async throws {
        let activationFixture = try ImageObservationFixture.window(
            processIdentifier: 4101,
            processStartIdentity: 5101,
            windowID: 6101)
        let captureFixture = try ImageObservationFixture.window(
            processIdentifier: 4102,
            processStartIdentity: 5102,
            windowID: 6102)
        let observation = ImageOutcomeObservationService(
            fixture: captureFixture,
            outcome: Self.captureOutcome,
            actionTarget: captureFixture.targetIdentity)
        let applications = ImageOutcomeApplicationService(
            applications: [activationFixture.application],
            activationOutcome: Self.activationOutcome)
        let response = try await Self.execute(
            arguments: [
                "app_target": activationFixture.application.name,
                "capture_focus": "foreground",
            ],
            applications: applications,
            observation: observation)
        let meta = try Self.meta(response)

        #expect(response.isError)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["dispatched_unit_count"] == .int(2))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["target_receipt"] == nil)
    }

    @Test
    @MainActor
    func `target contradiction leaves preexisting caller output untouched`() async throws {
        let callerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-image-owned-\(UUID().uuidString).png")
        let sentinel = Data("caller-owned".utf8)
        try sentinel.write(to: callerURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: callerURL) }
        let activationFixture = try ImageObservationFixture.window(
            processIdentifier: 4101,
            processStartIdentity: 5101,
            windowID: 6101)
        let captureFixture = try ImageObservationFixture.window(
            processIdentifier: 4102,
            processStartIdentity: 5102,
            windowID: 6102)
        let observation = ImageOutcomeObservationService(
            fixture: captureFixture,
            outcome: Self.captureOutcome,
            actionTarget: captureFixture.targetIdentity)
        let applications = ImageOutcomeApplicationService(
            applications: [activationFixture.application],
            activationOutcome: Self.activationOutcome)

        let response = try await Self.execute(
            arguments: [
                "app_target": activationFixture.application.name,
                "capture_focus": "foreground",
                "path": callerURL.path,
            ],
            applications: applications,
            observation: observation)

        #expect(response.isError)
        #expect(try Data(contentsOf: callerURL) == sentinel)
    }

    @Test
    @MainActor
    func `mixed dispatched routes fail closed instead of erasing mutation`() async throws {
        let fixture = try ImageObservationFixture.window()
        let observation = ImageOutcomeObservationService(
            fixture: fixture,
            outcome: Self.captureOutcome.routed(to: .bridge),
            actionTarget: fixture.targetIdentity)
        let applications = ImageOutcomeApplicationService(
            applications: [fixture.application],
            activationOutcome: Self.activationOutcome)
        let response = try await Self.execute(
            arguments: ["app_target": fixture.application.name, "capture_focus": "foreground"],
            applications: applications,
            observation: observation)
        let meta = try Self.meta(response)

        #expect(response.isError)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["dispatched_unit_count"] == .int(2))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        try Self.expectTargetReceipt(meta, fixture: fixture)
    }

    @Test
    @MainActor
    func `activation missing outcome fails unsafe with exact process receipt`() async throws {
        let fixture = try ImageObservationFixture.window()
        let observation = ImageOutcomeObservationService(
            fixture: fixture,
            outcome: Self.captureOutcome,
            actionTarget: fixture.targetIdentity)
        let applications = ImageOutcomeApplicationService(
            applications: [fixture.application],
            activationOutcome: nil)
        let response = try await Self.execute(
            arguments: ["app_target": fixture.application.name, "capture_focus": "foreground"],
            applications: applications,
            observation: observation)
        let meta = try Self.meta(response)
        let receipt = try #require(meta["target_receipt"]?.objectValue)

        #expect(response.isError)
        #expect(observation.requests.isEmpty)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(receipt["pid"] == .int(Int(fixture.processIdentity.processIdentifier)))
        #expect(receipt["process_start_identity_decimal"] == .string(String(
            fixture.processIdentity.processStartIdentity)))
        #expect(receipt["window_id"] == nil)
    }

    @Test
    @MainActor
    func `activation target contradiction remains targetless`() async throws {
        let fixture = try ImageObservationFixture.window()
        let observation = ImageOutcomeObservationService(
            fixture: fixture,
            outcome: Self.captureOutcome,
            actionTarget: fixture.targetIdentity)
        let contradictoryTarget = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: fixture.processIdentity.processIdentifier + 1,
            processStartIdentity: fixture.processIdentity.processStartIdentity + 1))
        let applications = ImageOutcomeApplicationService(
            applications: [fixture.application],
            activationOutcome: Self.activationOutcome,
            activationTarget: contradictoryTarget)
        let response = try await Self.execute(
            arguments: ["app_target": fixture.application.name, "capture_focus": "foreground"],
            applications: applications,
            observation: observation)
        let meta = try Self.meta(response)

        #expect(response.isError)
        #expect(observation.requests.isEmpty)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["target_receipt"] == nil)
    }

    @Test
    @MainActor
    func `ordinary capture failure after activation does not invent a target`() async throws {
        let fixture = try ImageObservationFixture.window()
        let observation = ImageOutcomeObservationService(
            fixture: fixture,
            outcome: Self.captureOutcome,
            actionTarget: fixture.targetIdentity)
        observation.error = ImageOutcomeTestError.captureFailed
        let applications = ImageOutcomeApplicationService(
            applications: [fixture.application],
            activationOutcome: Self.activationOutcome)
        let response = try await Self.execute(
            arguments: ["app_target": fixture.application.name, "capture_focus": "foreground"],
            applications: applications,
            observation: observation)
        let meta = try Self.meta(response)

        #expect(response.isError)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["dispatched_unit_count"] == .int(2))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["target_receipt"] == nil)
    }

    @Test
    @MainActor
    func `empty inline image failure preserves outcome and exact target`() async throws {
        let fixture = try ImageObservationFixture.window(imageData: Data())
        let observation = ImageOutcomeObservationService(
            fixture: fixture,
            outcome: Self.captureOutcome,
            actionTarget: fixture.targetIdentity)
        let applications = ImageOutcomeApplicationService(applications: [])
        let response = try await Self.execute(
            arguments: ["app_target": "frontmost", "capture_focus": "foreground", "format": "data"],
            applications: applications,
            observation: observation)
        let meta = try Self.meta(response)

        #expect(response.isError)
        #expect(meta["state"] == .string("dispatched_unverified"))
        #expect(meta["evidence"] == .string("delivery_accepted"))
        #expect(meta["dispatched_unit_count"] == .int(1))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        try Self.expectTargetReceipt(meta, fixture: fixture)
    }

    @Test
    @MainActor
    func `downscale failure leaves preexisting caller output untouched`() async throws {
        let callerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-image-downscale-owned-\(UUID().uuidString).png")
        let sentinel = Data("caller-owned".utf8)
        try sentinel.write(to: callerURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: callerURL) }
        let fixture = try ImageObservationFixture.window(imageData: Data("not-an-image".utf8))
        let observation = ImageOutcomeObservationService(
            fixture: fixture,
            outcome: Self.captureOutcome,
            actionTarget: fixture.targetIdentity)

        let response = try await Self.execute(
            arguments: [
                "app_target": "frontmost",
                "capture_focus": "foreground",
                "path": callerURL.path,
                "max_dimension": 100,
            ],
            applications: ImageOutcomeApplicationService(applications: []),
            observation: observation)

        #expect(response.isError)
        #expect(try Data(contentsOf: callerURL) == sentinel)
    }

    @Test
    @MainActor
    func `successful validation atomically publishes final caller bytes`() async throws {
        let callerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-image-publish-\(UUID().uuidString).png")
        try Data("caller-owned".utf8).write(to: callerURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: callerURL) }
        let fixture = ImageObservationFixture.screen()
        let observation = ImageOutcomeObservationService(
            fixture: fixture,
            outcome: nil,
            actionTarget: nil)

        let response = try await Self.execute(
            arguments: [
                "app_target": "screen",
                "capture_focus": "background",
                "path": callerURL.path,
            ],
            applications: ImageOutcomeApplicationService(applications: []),
            observation: observation)

        #expect(!response.isError)
        #expect(try Data(contentsOf: callerURL) == fixture.imageData)
    }

    @Test
    @MainActor
    func `format data response uses processed downscaled bytes`() async throws {
        let fixture = ImageObservationFixture.screen(imageData: Self.makePNGData(width: 120, height: 80))
        let observation = ImageOutcomeObservationService(
            fixture: fixture,
            outcome: nil,
            actionTarget: nil)

        let response = try await Self.execute(
            arguments: [
                "app_target": "screen",
                "capture_focus": "background",
                "format": "data",
                "max_dimension": 30,
            ],
            applications: ImageOutcomeApplicationService(applications: []),
            observation: observation)

        #expect(!response.isError)
        guard case let .image(data: base64, mimeType: _, annotations: _, _meta: _) = response.content.first,
              let data = Data(base64Encoded: base64)
        else {
            Issue.record("Expected inline image bytes")
            return
        }
        #expect(Self.imageDimensions(from: data) == CGSize(width: 30, height: 20))
    }

    @Test
    @MainActor
    func `caller output publishes processed downscaled bytes`() async throws {
        let callerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-image-downscale-publish-\(UUID().uuidString).png")
        try Data("caller-owned".utf8).write(to: callerURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: callerURL) }
        let fixture = ImageObservationFixture.screen(imageData: Self.makePNGData(width: 120, height: 80))
        let observation = ImageOutcomeObservationService(
            fixture: fixture,
            outcome: nil,
            actionTarget: nil)

        let response = try await Self.execute(
            arguments: [
                "app_target": "screen",
                "capture_focus": "background",
                "path": callerURL.path,
                "max_dimension": 30,
            ],
            applications: ImageOutcomeApplicationService(applications: []),
            observation: observation)

        #expect(!response.isError)
        let data = try Data(contentsOf: callerURL)
        #expect(Self.imageDimensions(from: data) == CGSize(width: 30, height: 20))
    }

    @Test
    @MainActor
    func `settle cancellation preserves exact dispatched focus result`() async throws {
        let fixture = try ImageObservationFixture.window()
        let result = UIAutomationActionResult(
            payload: (),
            outcome: Self.activationOutcome,
            targetIdentity: fixture.targetIdentity)

        let error = await Task { @MainActor in
            withUnsafeCurrentTask { task in task?.cancel() }
            do {
                try await ImageTool.settleAfterFocus(result, operation: "fixture focus")
                return nil as (any Error)?
            } catch {
                return error
            }
        }.value
        let failure = try #require(error as? DesktopActionFailure)

        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.dispatchState.unitCount == .one)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.targetReceipt == fixture.targetIdentity?.actionTargetReceipt)
    }

    @Test
    @MainActor
    func `activation settle cancellation returns canonical failure before observation`() async throws {
        let fixture = try ImageObservationFixture.window()
        let observation = ImageOutcomeObservationService(
            fixture: fixture,
            outcome: Self.captureOutcome,
            actionTarget: fixture.targetIdentity)
        let applications = ImageOutcomeApplicationService(
            applications: [fixture.application],
            activationOutcome: Self.activationOutcome,
            cancelAfterActivationResult: true)

        let response = try await Task { @MainActor in
            try await Self.execute(
                arguments: [
                    "app_target": fixture.application.name,
                    "capture_focus": "foreground",
                ],
                applications: applications,
                observation: observation)
        }.value
        let meta = try Self.meta(response)

        #expect(response.isError)
        #expect(observation.requests.isEmpty)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["dispatched_unit_count"] == .int(1))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["target_receipt"] != nil)
    }

    private static let activationOutcome = DesktopActionOutcome.confirmedChange(
        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
        unitCount: .one)

    private static let captureOutcome = DesktopActionOutcome.dispatchedUnverified(
        delivery: .init(mechanism: .capturePipeline, mode: .foreground),
        evidence: .deliveryAccepted,
        unitCount: .one)

    @MainActor
    private static func execute(
        arguments: [String: Any],
        applications: ImageOutcomeApplicationService,
        observation: ImageOutcomeObservationService,
        windows: (any WindowManagementServiceProtocol)? = nil) async throws -> ToolResponse
    {
        var arguments = arguments
        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-image-outcome-\(UUID().uuidString).png")
            .path
        arguments["path"] = arguments["path"] ?? outputPath
        defer { try? FileManager.default.removeItem(atPath: outputPath) }
        let base = await MCPToolTestHelpers.makeContext()
        let permissionSource = MockScreenCaptureService(screenRecordingGranted: true)
        let context = MCPToolContext(
            automation: base.automation,
            menu: base.menu,
            windows: windows ?? base.windows,
            applications: applications,
            dialogs: base.dialogs,
            dock: base.dock,
            screenCapture: permissionSource,
            desktopObservation: observation,
            snapshots: base.snapshots,
            screens: base.screens,
            agent: base.agent,
            permissions: base.permissions,
            clipboard: base.clipboard,
            browser: base.browser,
            permissionsStatusProvider: base.permissionsStatusProvider,
            snapshotMutationCoordinator: base.snapshotMutationCoordinator,
            snapshotExecutionGate: base.snapshotExecutionGate,
            snapshotOwner: .legacyProcess,
            executionPolicy: .backgroundOnly)
        return try await ImageTool(context: context).execute(arguments: ToolArguments(raw: arguments))
    }

    private static func meta(_ response: ToolResponse) throws -> [String: Value] {
        try #require(response.meta?.objectValue)
    }

    private static func expectTargetReceipt(
        _ meta: [String: Value],
        fixture: ImageObservationFixture) throws
    {
        let receipt = try #require(meta["target_receipt"]?.objectValue)
        #expect(receipt["pid"] == .int(Int(fixture.processIdentity.processIdentifier)))
        #expect(receipt["process_start_identity_decimal"] == .string(String(
            fixture.processIdentity.processStartIdentity)))
        #expect(receipt["window_id"] == fixture.windowID.map(Value.int))
    }

    private static func makePNGData(width: Int, height: Int) -> Data {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            fatalError("Failed to generate test image")
        }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            fatalError("Failed to generate test image")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil)
        else {
            fatalError("Failed to create test PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            fatalError("Failed to encode test PNG")
        }
        return data as Data
    }

    private static func imageDimensions(from data: Data) -> CGSize? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}

@MainActor
private final class ImageOutcomeApplicationService: MockApplicationService,
ApplicationServiceTargetedActionResultProviding {
    private(set) var activationRequests: [ApplicationActivationRequest] = []
    var activationOutcome: DesktopActionOutcome?
    var activationTarget: DesktopTargetIdentity?
    var activationError: (any Error)?
    let cancelAfterActivationResult: Bool

    init(
        applications: [ServiceApplicationInfo],
        activationOutcome: DesktopActionOutcome? = nil,
        activationTarget: DesktopTargetIdentity? = nil,
        cancelAfterActivationResult: Bool = false)
    {
        self.activationOutcome = activationOutcome
        self.activationTarget = activationTarget
        self.cancelAfterActivationResult = cancelAfterActivationResult
        super.init(applications: applications)
    }

    func activateApplicationTargetedActionResult(
        request: ApplicationActivationRequest) async throws -> UIAutomationActionResult<Void>
    {
        self.activationRequests.append(request)
        if let activationError {
            throw activationError
        }
        let target: DesktopTargetIdentity? = if let activationTarget = self.activationTarget {
            activationTarget
        } else if let expectedIdentity = request.expectedIdentity {
            try DesktopTargetIdentity(processIdentity: expectedIdentity)
        } else {
            nil
        }
        let result = UIAutomationActionResult(
            payload: (),
            outcome: self.activationOutcome,
            targetIdentity: target)
        if self.cancelAfterActivationResult {
            withUnsafeCurrentTask { task in task?.cancel() }
        }
        return result
    }

    func hideApplicationTargetedActionResult(identifier _: String) async throws -> UIAutomationActionResult<Void> {
        throw PeekabooError.notImplemented("unused image test stub")
    }

    func hideApplicationTargetedActionResult(
        request _: ApplicationHideRequest) async throws -> UIAutomationActionResult<Void>
    {
        throw PeekabooError.notImplemented("unused image test stub")
    }

    func hideOtherApplicationsActionResult(identifier _: String) async throws -> DesktopActionResult<Void> {
        throw PeekabooError.notImplemented("unused image test stub")
    }

    func showAllApplicationsActionResult() async throws -> DesktopActionResult<Void> {
        throw PeekabooError.notImplemented("unused image test stub")
    }
}

@MainActor
private final class ImageOutcomeObservationService: DesktopObservationActionResultProviding {
    private let fixture: ImageObservationFixture
    private let outcome: DesktopActionOutcome?
    private let actionTarget: DesktopTargetIdentity?
    var error: (any Error)?
    private(set) var requests: [DesktopObservationRequest] = []

    init(
        fixture: ImageObservationFixture,
        outcome: DesktopActionOutcome?,
        actionTarget: DesktopTargetIdentity?)
    {
        self.fixture = fixture
        self.outcome = outcome
        self.actionTarget = actionTarget
    }

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        try self.result(for: request).payload
    }

    func observeActionResult(
        _ request: DesktopObservationRequest) async throws -> UIAutomationActionResult<DesktopObservationResult>
    {
        self.requests.append(request)
        if let error {
            throw error
        }
        return try self.result(for: request)
    }

    private func result(
        for request: DesktopObservationRequest) throws -> UIAutomationActionResult<DesktopObservationResult>
    {
        let path = request.output.path
        if let path {
            try self.fixture.imageData.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        let capture = CaptureResult(
            imageData: self.fixture.imageData,
            savedPath: path,
            metadata: self.fixture.captureMetadata)
        let payload = DesktopObservationResult(
            target: self.fixture.resolvedTarget,
            capture: capture,
            elements: nil,
            files: DesktopObservationFiles(rawScreenshotPath: path),
            diagnostics: DesktopObservationDiagnostics(warnings: ["image-fixture-warning"]))
        return UIAutomationActionResult(
            payload: payload,
            outcome: self.outcome,
            targetIdentity: self.actionTarget)
    }
}

private struct ImageObservationFixture {
    let resolvedTarget: ResolvedObservationTarget
    let captureMetadata: CaptureMetadata
    let targetIdentity: DesktopTargetIdentity?
    let application: ServiceApplicationInfo
    let processIdentity: ApplicationProcessIdentity
    let windowID: Int?
    let imageData: Data

    static func screen(imageData: Data = Self.pngData) -> Self {
        let processIdentity = ApplicationProcessIdentity(processIdentifier: 1, processStartIdentity: 1)
        return Self(
            resolvedTarget: ResolvedObservationTarget(kind: .screen(index: 0)),
            captureMetadata: CaptureMetadata(size: CGSize(width: 1, height: 1), mode: .screen),
            targetIdentity: nil,
            application: ServiceApplicationInfo(processIdentifier: 1, bundleIdentifier: nil, name: "Screen"),
            processIdentity: processIdentity,
            windowID: nil,
            imageData: imageData)
    }

    static func processOnly(
        processIdentifier: Int32 = 4101,
        processStartIdentity: UInt64 = 5101,
        imageData: Data = Self.pngData) -> Self
    {
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity)
        let application = ServiceApplicationInfo(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            bundleIdentifier: "dev.peekaboo.image-fixture",
            name: "Image Fixture")
        let target = try? DesktopTargetIdentity(processIdentity: processIdentity)
        return Self(
            resolvedTarget: ResolvedObservationTarget(
                kind: .frontmost,
                app: ApplicationIdentity(
                    processIdentifier: processIdentifier,
                    processStartIdentity: processStartIdentity,
                    bundleIdentifier: application.bundleIdentifier,
                    name: application.name)),
            captureMetadata: CaptureMetadata(
                size: CGSize(width: 1, height: 1),
                mode: .frontmost,
                applicationInfo: application),
            targetIdentity: target,
            application: application,
            processIdentity: processIdentity,
            windowID: nil,
            imageData: imageData)
    }

    static func window(
        kind: ResolvedObservationKind = .appWindow,
        processIdentifier: Int32 = 4101,
        processStartIdentity: UInt64 = 5101,
        windowID: Int = 6101,
        bounds: CGRect = CGRect(x: 10, y: 20, width: 600, height: 400),
        imageData: Data = Self.pngData) throws -> Self
    {
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity)
        let identity = WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            capturedBounds: bounds)
        let target = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds))
        let application = ServiceApplicationInfo(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            bundleIdentifier: "dev.peekaboo.image-fixture.\(processIdentifier)",
            name: "Image Fixture \(processIdentifier)")
        let window = ServiceWindowInfo(
            windowID: windowID,
            title: "Image Window \(windowID)",
            bounds: bounds,
            index: 0,
            mutationIdentity: identity)
        let context = WindowContext(
            applicationName: application.name,
            applicationBundleId: application.bundleIdentifier,
            applicationProcessId: processIdentifier,
            windowTitle: window.title,
            windowID: windowID,
            windowBounds: bounds,
            windowMutationIdentity: identity)
        return Self(
            resolvedTarget: ResolvedObservationTarget(
                kind: kind,
                app: ApplicationIdentity(
                    processIdentifier: processIdentifier,
                    processStartIdentity: processStartIdentity,
                    bundleIdentifier: application.bundleIdentifier,
                    name: application.name),
                window: WindowIdentity(
                    windowID: windowID,
                    title: window.title,
                    bounds: bounds,
                    index: window.index),
                bounds: bounds,
                detectionContext: context),
            captureMetadata: CaptureMetadata(
                size: bounds.size,
                mode: kind == .frontmost ? .frontmost : .window,
                applicationInfo: application,
                windowInfo: window),
            targetIdentity: target,
            application: application,
            processIdentity: processIdentity,
            windowID: windowID,
            imageData: imageData)
    }

    private static let pngData = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
        0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D,
        0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    ])
}

private enum ImageOutcomeTestError: LocalizedError {
    case captureFailed

    var errorDescription: String? {
        "Fixture capture failed"
    }
}
