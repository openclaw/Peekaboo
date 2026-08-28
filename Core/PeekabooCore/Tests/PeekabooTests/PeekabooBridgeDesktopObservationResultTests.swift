import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
@MainActor
struct PeekabooBridgeDesktopObservationResultTests {
    @Test
    func `signed observation authenticates exact file bytes and rejects same-size replacement`() async throws {
        let fixture = try Self.fixture()
        let root = URL(fileURLWithPath: "/tmp/pb-ob-content-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let imageURL = root.appendingPathComponent("capture.png")
        let original = Data("signed-pixels-1".utf8)
        let replacement = Data("forged-pixels-1".utf8)
        #expect(original.count == replacement.count)
        try original.write(to: imageURL, options: .atomic)

        let observation = DesktopObservationResult(
            target: fixture.result.target,
            capture: CaptureResult(
                imageData: original,
                savedPath: imageURL.path,
                metadata: fixture.result.capture.metadata),
            elements: fixture.result.elements,
            files: DesktopObservationFiles(rawScreenshotPath: imageURL.path))
        let provider = ScriptedObservationResultProvider(results: [
            UIAutomationActionResult(
                payload: observation,
                outcome: .dispatchedUnverified(
                    delivery: Self.delivery,
                    evidence: .deliveryAccepted,
                    unitCount: .one),
                targetIdentity: fixture.target),
        ])
        let socketPath = root.appendingPathComponent("bridge.sock").path
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: Self.server(provider: provider),
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let result = try await client.desktopObservationWithOutcome(Self.request).payload

        #expect(result.capture.imageData.isEmpty)
        #expect(result.captureContentDigest != nil)
        #expect(try result.verifiedRawScreenshotData(requirement: .requireDigest) == original)
        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()

        try replacement.write(to: imageURL, options: .atomic)
        #expect(throws: DesktopObservationContentVerificationError.digestMismatch) {
            try result.verifiedRawScreenshotData(requirement: .requireDigest)
        }
    }

    @Test
    func `signed observation preserves provider outcomes units and target`() async throws {
        let fixture = try Self.fixture()
        let two = try #require(DesktopActionOutcome.DispatchUnitCount(2))
        let three = try #require(DesktopActionOutcome.DispatchUnitCount(3))
        let outcomes: [DesktopActionOutcome] = [
            .confirmedChange(delivery: Self.delivery, unitCount: two),
            .confirmedNoChange(),
            .dispatchedUnverified(delivery: Self.delivery, evidence: .deliveryAccepted, unitCount: three),
            .suspectedNoop(delivery: Self.delivery, unitCount: two),
            .refused(reason: .targetUnavailable),
            .partial(delivery: Self.delivery, unitCount: two),
            .indeterminate(delivery: Self.delivery, evidence: .completionUnknown, unitCount: three),
        ]
        let provider = ScriptedObservationResultProvider(results: outcomes.map {
            UIAutomationActionResult(
                payload: fixture.result,
                outcome: $0,
                targetIdentity: fixture.target)
        })
        let root = URL(fileURLWithPath: "/tmp/pb-ob-result-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("bridge.sock").path
        let server = Self.server(provider: provider)
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        for outcome in outcomes {
            let expected = outcome.routed(to: .bridge)
            if [.partial, .indeterminate, .refused].contains(outcome.state) {
                do {
                    _ = try await client.desktopObservationWithOutcome(Self.request)
                    Issue.record("Expected \(outcome.state.rawValue) observation outcome to be an error response")
                } catch let failure as DesktopActionFailure {
                    #expect(failure.outcome == expected)
                    #expect(failure.targetReceipt == Self.targetReceipt)
                }
            } else {
                let result = try await client.desktopObservationWithOutcome(Self.request)
                #expect(result.outcome == expected)
                #expect(result.targetIdentity?.exactWindow?.identity == fixture.identity)
            }

            let bundle = try #require(await client.lastOperationReceiptBundle())
            try bundle.validate()
            #expect(bundle.receipt.payload.outcome == expected.projection)
            if outcome.state == .refused {
                #expect(bundle.receipt.payload.target == nil)
            } else {
                #expect(bundle.receipt.payload.target == .window(fixture.identity))
            }
        }

        #expect(provider.actionResultCount == outcomes.count)
        #expect(provider.legacyObserveCount == 0)
    }

    @Test
    func `legacy observation provider retains conservative synthesized mutation`() async throws {
        let fixture = try Self.fixture()
        let provider = LegacyObservationProvider(result: fixture.result)
        let server = Self.server(provider: provider)

        let handled = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try await server.route(.desktopObservation(Self.request), peer: nil)
        }

        #expect(provider.observeCount == 1)
        #expect(handled.outcome == .dispatchedUnverified(
            delivery: Self.delivery,
            evidence: .deliveryAccepted,
            unitCount: .one))
        guard case .responseResolved = handled.mutation?.target else {
            Issue.record("Expected the legacy exact observation to retain response target attribution")
            return
        }
    }

    @Test
    func `legacy observation provider refuses menu bar opening before dispatch`() async throws {
        let provider = LegacyObservationProvider(result: Self.readOnlyFixtureResult())
        let server = Self.server(provider: provider)
        let request = DesktopObservationRequest(
            target: .menubarPopover(
                hints: ["Control Center"],
                openIfNeeded: .init(clickHint: "Control Center")),
            capture: .init(focus: .background),
            detection: .init(mode: .none))

        do {
            _ = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                try await server.route(.desktopObservation(request), peer: nil)
            }
            Issue.record("Expected result-unaware menu-bar opening to be refused")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.actionOutcome?.outcome.state == .refused)
            #expect(envelope.actionOutcome?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
            #expect(envelope.actionOutcome?.outcome.refusalReason == .runtimeIncompatible)
        }

        #expect(provider.observeCount == 0)
    }

    @Test
    func `signed read-only observation never erases provider failure or dispatch`() async throws {
        let result = Self.readOnlyFixtureResult()
        let dispatched = DesktopActionOutcome.dispatchedUnverified(
            delivery: Self.delivery,
            evidence: .deliveryAccepted,
            unitCount: .one)
        let refused = DesktopActionOutcome.refused(reason: .targetUnavailable)
        let provider = ScriptedObservationResultProvider(results: [
            UIAutomationActionResult(
                payload: result,
                outcome: refused,
                targetIdentity: nil),
            UIAutomationActionResult(
                payload: result,
                outcome: dispatched,
                targetIdentity: nil),
            UIAutomationActionResult(
                payload: result,
                outcome: .confirmedNoChange(),
                targetIdentity: nil),
        ])
        let root = URL(fileURLWithPath: "/tmp/pb-ob-read-only-result-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("bridge.sock").path
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: Self.server(provider: provider),
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)

        for expected in [refused, dispatched] {
            do {
                _ = try await client.desktopObservationWithOutcome(Self.readOnlyRequest)
                Issue.record("Expected signed \(expected.state.rawValue) read-only observation failure")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome == expected.routed(to: .bridge))
                #expect(failure.targetReceipt == nil)
            } catch {
                Issue.record(error)
                return
            }
            let bundle = try #require(await client.lastOperationReceiptBundle())
            try bundle.validate()
            #expect(bundle.receipt.payload.outcome == expected.routed(to: .bridge).projection)
        }

        let noChange = try await client.desktopObservationWithOutcome(Self.readOnlyRequest)
        #expect(noChange.outcome == nil)
        #expect(noChange.targetIdentity == nil)
        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.outcome == nil)
        #expect(bundle.receipt.payload.target == .global)
        #expect(provider.actionResultCount == 3)
        await host.stop()
    }

    @Test(arguments: [false, true])
    func `signed read-only handler error keeps targetless refusal metadata`(exactWindowROI: Bool) async throws {
        let provider = FailingObservationProvider()
        let root = URL(fileURLWithPath: "/tmp/pb-ob-targetless-error-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("bridge.sock").path
        // Mirror GUI lane ownership: exercise provider failure, not ambient exact-window lookup.
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: Self.server(provider: provider, ownsObservationLane: true),
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let request = DesktopObservationRequest(
            target: exactWindowROI ? .pid(42, window: .id(73)) : .app(identifier: "Fixture", window: .automatic),
            capture: .init(
                engine: exactWindowROI ? .auto : .modern,
                scale: exactWindowROI ? .native : .logical1x,
                focus: .background,
                roi: exactWindowROI ? .init(bounds: CGRect(x: 20, y: 30, width: 320, height: 180)) : nil),
            detection: .init(mode: .accessibility))

        do {
            _ = try await client.desktopObservationWithOutcome(request)
            Issue.record("Expected the read-only capture failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.message.contains("fixture modern owner refusal"))
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.standardErrorCode == .captureFailed)
            #expect(failure.targetReceipt == nil)
        }

        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.target == nil)
        #expect(bundle.receipt.payload.targetAttributionFailure == nil)
        #expect(bundle.receipt.payload.targetAttributionEvidence == nil)
        #expect(bundle.receipt.payload.outcome?.outcome.state == .refused)
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: bundle.canonicalResponse)
        guard case let .error(envelope) = response else {
            Issue.record("Expected the original error response")
            return
        }
        #expect(envelope.context == "standard_error:CAPTURE_FAILED")
        #expect(envelope.message.contains("fixture modern owner refusal"))
        #expect(!envelope.operationMayHaveCompleted)
        #expect(envelope.actionOutcome?.outcome.refusalReason == .runtimeIncompatible)
        #expect(envelope.actionTargetReceipt == nil)
        #expect(provider.actionResultCount == 1)
        await host.stop()
    }

    @Test
    func `signed read-only precise failure keeps its reason hint and cause`() async throws {
        let expected = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .permissionDenied,
            message: "Fixture precise read-only refusal",
            hint: "Retain this exact recovery hint.",
            causeDescription: "Fixture precise cause")
        let provider = PreciseFailingObservationProvider(envelope: .init(
            code: .permissionDenied,
            actionFailure: expected,
            details: "Fixture envelope details"))
        let root = URL(fileURLWithPath: "/tmp/pb-ob-precise-error-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("bridge.sock").path
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: Self.server(provider: provider),
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)

        do {
            _ = try await client.desktopObservationWithOutcome(Self.readOnlyRequest)
            Issue.record("Expected the precise read-only refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == expected.outcome)
            #expect(failure.message == expected.message)
            #expect(failure.hint == expected.hint)
            #expect(failure.causeDescription == expected.causeDescription)
            #expect(failure.targetReceipt == nil)
        }

        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.target == nil)
        #expect(bundle.receipt.payload.targetAttributionFailure == nil)
        #expect(bundle.receipt.payload.outcome == expected.outcome.projection)
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: bundle.canonicalResponse)
        guard case let .error(envelope) = response else {
            Issue.record("Expected the precise error response")
            return
        }
        #expect(envelope.actionOutcome == expected.outcome.projection)
        #expect(envelope.actionFailureHint == expected.hint)
        #expect(envelope.actionFailureCauseDescription == expected.causeDescription)
        #expect(envelope.details == "Fixture envelope details")
        #expect(provider.actionResultCount == 1)
        await host.stop()
    }

    private static let delivery = DesktopActionOutcome.Delivery(
        mechanism: .capturePipeline,
        mode: .background)
    private static let request = DesktopObservationRequest(
        target: .windowID(73),
        capture: .init(focus: .background),
        detection: .init(mode: .accessibility, allowWebFocusFallback: true))
    private static let readOnlyRequest = DesktopObservationRequest(
        target: .screen(index: nil),
        capture: .init(focus: .background),
        detection: .init(mode: .accessibility, allowWebFocusFallback: false))
    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.observation-result-tests",
        teamIdentifier: nil,
        processIdentifier: getpid())
    private static let targetReceipt = DesktopActionTargetReceipt(
        processIdentifier: 42,
        processStartIdentity: 9001,
        windowID: 73)

    private static func server(
        provider: any DesktopObservationServiceProtocol,
        ownsObservationLane: Bool = false) -> PeekabooBridgeServer
    {
        PeekabooBridgeServer(
            services: StubServices(
                desktopObservation: provider,
                ownedDesktopOperationLanes: ownsObservationLane ? [.desktopObservation] : []),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
            })
    }

    private static func fixture() throws -> (
        identity: WindowMutationIdentity,
        target: DesktopTargetIdentity,
        result: DesktopObservationResult)
    {
        let bounds = CGRect(x: 20, y: 30, width: 640, height: 480)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9001,
            capturedBounds: bounds)
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds)
        let target = DesktopTargetIdentity(exactWindow: exactWindow)
        let app = ApplicationIdentity(
            processIdentifier: 42,
            processStartIdentity: 9001,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "Fixture")
        let window = WindowIdentity(
            windowID: 73,
            title: "Fixture",
            bounds: bounds,
            index: 0)
        let context = WindowContext(
            applicationName: app.name,
            applicationBundleId: app.bundleIdentifier,
            applicationProcessId: app.processIdentifier,
            windowTitle: window.title,
            windowID: window.windowID,
            windowBounds: bounds,
            windowMutationIdentity: identity,
            shouldFocusWebContent: true,
            includeMenuBarElements: false,
            traversalBudget: Self.request.detection.traversalBudget)
        let captureApplication = ServiceApplicationInfo(
            processIdentifier: app.processIdentifier,
            processStartIdentity: app.processStartIdentity,
            bundleIdentifier: app.bundleIdentifier,
            name: app.name)
        let captureWindow = ServiceWindowInfo(
            windowID: window.windowID,
            title: window.title,
            bounds: window.bounds,
            index: window.index,
            mutationIdentity: identity)
        let result = DesktopObservationResult(
            target: .init(
                kind: .windowID(73),
                app: app,
                window: window,
                bounds: bounds,
                detectionContext: context),
            capture: .init(
                imageData: Data(),
                metadata: .init(
                    size: bounds.size,
                    mode: .window,
                    applicationInfo: captureApplication,
                    windowInfo: captureWindow,
                    diagnostics: Self.captureDiagnostics(size: bounds.size))),
            elements: ElementDetectionResult(
                snapshotId: "fixture",
                screenshotPath: "",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "fixture",
                    windowContext: context)))
        return (identity, target, result)
    }

    private static func readOnlyFixtureResult() -> DesktopObservationResult {
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 720)
        return DesktopObservationResult(
            target: .init(kind: .screen(index: nil)),
            capture: .init(
                imageData: Data(),
                metadata: .init(
                    size: bounds.size,
                    mode: .screen,
                    displayInfo: .init(index: 0, name: "Fixture", bounds: bounds, scaleFactor: 1),
                    diagnostics: Self.captureDiagnostics(size: bounds.size))),
            elements: ElementDetectionResult(
                snapshotId: "fixture",
                screenshotPath: "",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "fixture",
                    windowContext: WindowContext(
                        shouldFocusWebContent: false,
                        includeMenuBarElements: false,
                        traversalBudget: Self.readOnlyRequest.detection.traversalBudget))))
    }

    private static func captureDiagnostics(size: CGSize) -> CaptureDiagnostics {
        CaptureDiagnostics(
            requestedScale: .logical1x,
            nativeScale: 2,
            outputScale: 1,
            scaleSource: "fixture",
            finalPixelSize: size,
            engine: "ScreenCaptureKit")
    }
}

@MainActor
private final class ScriptedObservationResultProvider: DesktopObservationActionResultProviding {
    private var results: [UIAutomationActionResult<DesktopObservationResult>]
    private(set) var actionResultCount = 0
    private(set) var legacyObserveCount = 0

    init(results: [UIAutomationActionResult<DesktopObservationResult>]) {
        self.results = results
    }

    func observe(_: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.legacyObserveCount += 1
        return try #require(self.results.first).payload
    }

    func observeActionResult(
        _: DesktopObservationRequest) async throws -> UIAutomationActionResult<DesktopObservationResult>
    {
        self.actionResultCount += 1
        return self.results.removeFirst()
    }
}

@MainActor
private final class LegacyObservationProvider: DesktopObservationServiceProtocol {
    private let result: DesktopObservationResult
    private(set) var observeCount = 0

    init(result: DesktopObservationResult) {
        self.result = result
    }

    func observe(_: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.observeCount += 1
        return self.result
    }
}

@MainActor
private final class FailingObservationProvider: DesktopObservationActionResultProviding {
    private(set) var actionResultCount = 0

    func observe(_: DesktopObservationRequest) async throws -> DesktopObservationResult {
        throw OperationError.captureFailed(reason: "fixture modern owner refusal")
    }

    func observeActionResult(
        _: DesktopObservationRequest) async throws -> UIAutomationActionResult<DesktopObservationResult>
    {
        self.actionResultCount += 1
        throw OperationError.captureFailed(reason: "fixture modern owner refusal")
    }
}

@MainActor
private final class PreciseFailingObservationProvider: DesktopObservationActionResultProviding {
    private let envelope: PeekabooBridgeErrorEnvelope
    private(set) var actionResultCount = 0

    init(envelope: PeekabooBridgeErrorEnvelope) {
        self.envelope = envelope
    }

    func observe(_: DesktopObservationRequest) async throws -> DesktopObservationResult {
        throw self.envelope
    }

    func observeActionResult(
        _: DesktopObservationRequest) async throws -> UIAutomationActionResult<DesktopObservationResult>
    {
        self.actionResultCount += 1
        throw self.envelope
    }
}
