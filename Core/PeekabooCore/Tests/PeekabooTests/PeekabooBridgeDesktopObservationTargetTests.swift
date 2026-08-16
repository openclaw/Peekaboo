import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@MainActor
struct PeekabooBridgeDesktopObservationTargetTests: DesktopObservationBindingFixtureProviding {
    @Test
    func `protocol 1 29 refuses web focus targets that cannot return exact window evidence`() async throws {
        let service = RecordingDesktopObservationService(result: Self.screenResult())
        let server = self.makeServer(observation: service)
        let targets: [DesktopObservationTargetRequest] = [
            .screen(index: 0),
            .allScreens,
            .area(CGRect(x: 10, y: 20, width: 30, height: 40)),
            .menubar,
            .menubarPopover(hints: ["Control Center"]),
        ]

        for target in targets {
            let request = PeekabooBridgeRequest.desktopObservation(Self.webFocusRequest(target: target))
            do {
                _ = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                    try await server.route(request, peer: nil)
                }
                Issue.record("Expected attested web focus to refuse target \(target)")
            } catch let envelope as PeekabooBridgeErrorEnvelope {
                let failure = try #require(envelope.desktopActionFailure)
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.refusalReason == .invalidRequest)
                #expect(failure.outcome.dispatchState == .none)
                #expect(failure.outcome.retrySafety == .safe)
                #expect(failure.message.contains("exact application or window target"))
            }
        }

        #expect(service.observationCount == 0)
    }

    @Test
    func `protocol 1 29 web focus signs a response resolved exact window`() async throws {
        let exact = Self.exactWindowResult()
        let service = RecordingDesktopObservationService(result: exact.result)
        let server = self.makeServer(observation: service)
        let request = PeekabooBridgeRequest.desktopObservation(
            Self.webFocusRequest(target: .windowID(CGWindowID(exact.identity.windowID))))

        let handled = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try await server.route(request, peer: nil)
        }

        #expect(service.observationCount == 1)
        guard case .responseResolved = handled.mutation?.target else {
            Issue.record("Expected response-resolved desktop observation target")
            return
        }
        try PeekabooBridgeOperationResultSemantics.validateSuccessfulTargetDisposition(
            request: request,
            handled: handled)
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: request,
            response: handled.response).target == .window(exact.identity))
    }

    @Test
    func `protocol 1 29 ignores web focus fallback when detection is disabled`() async throws {
        let result = Self.screenResult(index: 0)
        let service = RecordingDesktopObservationService(result: result)
        let server = self.makeServer(observation: service)
        let payload = DesktopObservationRequest(
            target: .screen(index: 0),
            capture: .init(focus: .background),
            detection: .init(mode: .none, allowWebFocusFallback: true))
        let request = PeekabooBridgeRequest.desktopObservation(payload)

        let handled = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try await server.route(request, peer: nil)
        }

        #expect(service.observationCount == 1)
        #expect(handled.mutation == nil)
        guard case .desktopObservation = handled.response else {
            Issue.record("Expected a read-only desktop observation response")
            return
        }

        let bundle = try await Self.makeBundle(
            request: request,
            response: .desktopObservation(result),
            target: .global)
        try bundle.validateIntegrity()
    }

    @Test
    func `protocol 1 29 opening menu bar popover signs exact click owner`() async throws {
        let processIdentity = ApplicationProcessIdentity(processIdentifier: 78, processStartIdentity: 91)
        let mutationTarget = try DesktopTargetIdentity(processIdentity: processIdentity)
        let bounds = CGRect(x: 1200, y: 700, width: 360, height: 300)
        let requestPayload = DesktopObservationRequest(
            target: .menubarPopover(
                hints: ["Control Center"],
                openIfNeeded: .init(clickHint: "Control Center", settleDelayNanoseconds: 0)),
            capture: .init(focus: .background),
            detection: .init(mode: .none))
        let result = DesktopObservationResult(
            target: .init(
                kind: .menubarPopover,
                app: .init(processIdentifier: -1, bundleIdentifier: nil, name: "Control Center"),
                bounds: bounds,
                detectionContext: .init(
                    applicationName: "Control Center",
                    windowTitle: "Control Center",
                    windowBounds: bounds),
                mutationTargetIdentity: DesktopObservationMutationTargetIdentity(mutationTarget)),
            capture: .init(
                imageData: Data(),
                metadata: .init(
                    size: bounds.size,
                    mode: .area,
                    displayInfo: .init(index: 0, name: "Fixture", bounds: bounds, scaleFactor: 1),
                    diagnostics: Self.captureDiagnostics(size: bounds.size))),
            elements: nil,
            diagnostics: .init(target: .init(
                requestedKind: "menubar-popover",
                resolvedKind: "menubar-popover",
                source: "click-location-area-fallback",
                hints: ["Control Center"],
                openIfNeeded: true,
                clickHint: "Control Center",
                bounds: bounds)))
        let service = RecordingDesktopObservationActionResultService(
            result: .init(
                payload: result,
                outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                    evidence: .deliveryAccepted,
                    unitCount: .one),
                targetIdentity: mutationTarget))
        let server = self.makeServer(observation: service)
        let request = PeekabooBridgeRequest.desktopObservation(requestPayload)

        let handled = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try await server.route(request, peer: nil)
        }

        #expect(service.observationCount == 1)
        guard case let .handlerResolved(resolvedTarget) = handled.mutation?.target else {
            Issue.record("Expected handler-resolved menu-bar mutation target")
            return
        }
        #expect(resolvedTarget == mutationTarget)
        try PeekabooBridgeOperationResultSemantics.validateSuccessfulTargetDisposition(
            request: request,
            handled: handled)
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: request,
            response: handled.response).target == .process(processIdentity))
    }

    @Test
    func `passive menu bar popover rejects injected mutation owner`() throws {
        let mutationTarget = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 78,
            processStartIdentity: 91))
        let bounds = CGRect(x: 1200, y: 700, width: 360, height: 300)
        let result = DesktopObservationResult(
            target: .init(
                kind: .menubarPopover,
                bounds: bounds,
                mutationTargetIdentity: DesktopObservationMutationTargetIdentity(mutationTarget)),
            capture: .init(
                imageData: Data(),
                metadata: .init(size: bounds.size, mode: .area)),
            elements: nil)

        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: .init(target: .menubarPopover(hints: ["Control Center"])),
            result: result) == "unexpected observation mutation target")
    }

    @Test
    func `protocol 1 28 keeps legacy screen web focus routing`() async throws {
        let service = RecordingDesktopObservationService(result: Self.screenResult())
        let server = self.makeServer(observation: service)
        let request = PeekabooBridgeRequest.desktopObservation(
            Self.webFocusRequest(target: .screen(index: 0)))

        let handled = try await server.route(request, peer: nil)

        #expect(service.observationCount == 1)
        guard case .global = handled.mutation?.target else {
            Issue.record("Expected receiptless legacy screen observation to retain global routing")
            return
        }
    }

    private func makeServer(
        observation: any DesktopObservationServiceProtocol) -> PeekabooBridgeServer
    {
        PeekabooBridgeServer(
            services: StubServices(desktopObservation: observation),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: false,
                    postEvent: true)
            })
    }

    private static func webFocusRequest(
        target: DesktopObservationTargetRequest) -> DesktopObservationRequest
    {
        DesktopObservationRequest(
            target: target,
            capture: DesktopCaptureOptions(focus: .background),
            detection: DesktopDetectionOptions(
                mode: .accessibility,
                allowWebFocusFallback: true))
    }

    private static func screenResult() -> DesktopObservationResult {
        DesktopObservationResult(
            target: .init(kind: .screen(index: 0)),
            capture: .init(
                imageData: Data(),
                metadata: .init(size: CGSize(width: 1, height: 1), mode: .screen)),
            elements: nil)
    }

    private static func exactWindowResult() -> (
        identity: WindowMutationIdentity,
        result: DesktopObservationResult)
    {
        let bounds = CGRect(x: 20, y: 30, width: 640, height: 480)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9_007_199_254_740_993,
            capturedBounds: bounds)
        let app = ApplicationIdentity(
            processIdentifier: 42,
            processStartIdentity: identity.ownerProcessStartIdentity,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "Fixture")
        let window = WindowIdentity(windowID: 73, title: "Fixture", bounds: bounds, index: 0)
        let captureApp = ServiceApplicationInfo(
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
        let context = WindowContext(
            applicationName: app.name,
            applicationBundleId: app.bundleIdentifier,
            applicationProcessId: app.processIdentifier,
            windowTitle: window.title,
            windowID: window.windowID,
            windowBounds: bounds,
            windowMutationIdentity: identity,
            shouldFocusWebContent: true)
        return (
            identity,
            DesktopObservationResult(
                target: .init(
                    kind: .windowID(CGWindowID(window.windowID)),
                    app: app,
                    window: window,
                    bounds: bounds,
                    detectionContext: context),
                capture: .init(
                    imageData: Data(),
                    metadata: .init(
                        size: bounds.size,
                        mode: .window,
                        applicationInfo: captureApp,
                        windowInfo: captureWindow,
                        diagnostics: Self.captureDiagnostics(size: bounds.size))),
                elements: ElementDetectionResult(
                    snapshotId: "desktop-observation-target",
                    screenshotPath: "",
                    elements: .init(),
                    metadata: .init(
                        detectionTime: 0,
                        elementCount: 0,
                        method: "fixture",
                        warnings: [],
                        windowContext: WindowContext(
                            applicationName: app.name,
                            applicationBundleId: app.bundleIdentifier,
                            applicationProcessId: app.processIdentifier,
                            windowTitle: window.title,
                            windowID: window.windowID,
                            windowBounds: bounds,
                            windowMutationIdentity: identity,
                            shouldFocusWebContent: true,
                            includeMenuBarElements: false,
                            traversalBudget: AXTraversalBudget.resolved()),
                        isDialog: false))))
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
private final class RecordingDesktopObservationService: DesktopObservationServiceProtocol {
    private let result: DesktopObservationResult
    private(set) var observationCount = 0

    init(result: DesktopObservationResult) {
        self.result = result
    }

    func observe(_: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.observationCount += 1
        return self.result
    }
}

@MainActor
private final class RecordingDesktopObservationActionResultService: DesktopObservationActionResultProviding {
    private let result: UIAutomationActionResult<DesktopObservationResult>
    private(set) var observationCount = 0

    init(result: UIAutomationActionResult<DesktopObservationResult>) {
        self.result = result
    }

    func observe(_: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.result.payload
    }

    func observeActionResult(
        _: DesktopObservationRequest) async throws -> UIAutomationActionResult<DesktopObservationResult>
    {
        self.observationCount += 1
        return self.result
    }
}
