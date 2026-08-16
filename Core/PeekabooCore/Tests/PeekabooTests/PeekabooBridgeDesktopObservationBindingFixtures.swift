import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
@testable import PeekabooBridge

protocol DesktopObservationBindingFixtureProviding {}

extension DesktopObservationBindingFixtureProviding {
    static func windowResult(
        _ options: WindowResultOptions) -> (result: DesktopObservationResult, identity: WindowMutationIdentity)
    {
        let bounds = CGRect(x: 20, y: 30, width: 640, height: 480)
        let identity = WindowMutationIdentity(
            windowID: options.windowID,
            ownerProcessIdentifier: options.processIdentifier,
            ownerProcessStartIdentity: options.generation,
            capturedBounds: bounds)
        let selector = options.bundleIdentifier ?? options.applicationName
        let selectorProof = SelectorResolutionProof(
            scope: .application,
            normalizedSelector: selector,
            matchKind: options.bundleIdentifier == nil ? .exactName : .bundleIdentifier,
            matchPrecedence: options.bundleIdentifier == nil
                ? SelectorResolutionProof.MatchKind.exactName.precedence
                : SelectorResolutionProof.MatchKind.bundleIdentifier.precedence,
            selectedProcessIdentity: identity.processIdentity,
            candidateSetSHA256: String(repeating: "a", count: 64),
            candidateCount: 1,
            winningCandidateCount: 1,
            hasWinningTie: false)
        let windowSelection = options.windowSelector ?? .title(options.title)
        let windowMatchKind: SelectorResolutionProof.MatchKind = switch windowSelection {
        case .automatic: .automaticWindowRank
        case .index: .windowIndex
        case .id: .windowID
        case let .title(title):
            options.title.compare(title, options: .caseInsensitive) == .orderedSame
                ? .exactWindowTitle
                : .partialWindowTitle
        }
        let windowProof = SelectorResolutionProof(
            scope: .window,
            normalizedSelector: WindowSelectorResolutionProof.normalizedSelector(windowSelection),
            matchKind: windowMatchKind,
            matchPrecedence: windowMatchKind.precedence,
            selectedProcessIdentity: identity.processIdentity,
            selectedWindowIdentity: identity,
            candidateSetSHA256: String(repeating: "b", count: 64),
            candidateCount: 1,
            winningCandidateCount: 1,
            hasWinningTie: false)
        let app = ApplicationIdentity(
            processIdentifier: options.processIdentifier,
            processStartIdentity: options.generation,
            bundleIdentifier: options.bundleIdentifier,
            name: options.applicationName,
            selectorResolutionProofs: [selectorProof, windowProof])
        let window = WindowIdentity(
            windowID: options.windowID,
            title: options.title,
            bounds: bounds,
            index: options.index)
        let context = WindowContext(
            applicationName: options.applicationName,
            applicationBundleId: options.bundleIdentifier,
            applicationProcessId: options.processIdentifier,
            windowTitle: options.title,
            windowID: options.windowID,
            windowBounds: bounds,
            windowMutationIdentity: identity)
        let captureApp = ServiceApplicationInfo(
            processIdentifier: options.processIdentifier,
            processStartIdentity: options.captureGeneration ?? options.generation,
            bundleIdentifier: options.bundleIdentifier,
            name: options.applicationName)
        let captureWindow = ServiceWindowInfo(
            windowID: options.windowID,
            title: options.title,
            bounds: bounds,
            index: options.index,
            mutationIdentity: identity)
        return (
            DesktopObservationResult(
                target: .init(
                    kind: .windowID(CGWindowID(options.windowID)),
                    app: app,
                    window: window,
                    bounds: bounds,
                    detectionContext: context),
                capture: .init(
                    imageData: Data(),
                    metadata: .init(
                        size: bounds.size,
                        mode: options.captureMode,
                        applicationInfo: captureApp,
                        windowInfo: captureWindow,
                        diagnostics: Self.captureDiagnostics(size: bounds.size))),
                elements: nil)
                .withCaptureContentDigest(rawScreenshotData: nil, annotatedScreenshotData: nil),
            identity)
    }

    static func screenResult(index: Int) -> DesktopObservationResult {
        self.screenResult(targetIndex: index, captureIndex: index)
    }

    static func screenResult(
        targetIndex: Int?,
        captureIndex: Int) -> DesktopObservationResult
    {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        return DesktopObservationResult(
            target: .init(kind: .screen(index: targetIndex)),
            capture: .init(
                imageData: Data(),
                metadata: .init(
                    size: bounds.size,
                    mode: .screen,
                    displayInfo: .init(index: captureIndex, name: "Fixture", bounds: bounds, scaleFactor: 1),
                    diagnostics: Self.captureDiagnostics(size: bounds.size))),
            elements: nil)
            .withCaptureContentDigest(rawScreenshotData: nil, annotatedScreenshotData: nil)
    }

    static func replacingElements(
        _ result: DesktopObservationResult,
        with elements: ElementDetectionResult) -> DesktopObservationResult
    {
        DesktopObservationResult(
            target: result.target,
            capture: result.capture,
            elements: elements,
            ocr: result.ocr,
            files: result.files,
            timings: result.timings,
            diagnostics: result.diagnostics,
            captureContentDigest: result.captureContentDigest)
    }

    static func replacingCaptureSavedPath(
        _ result: DesktopObservationResult,
        with path: String) -> DesktopObservationResult
    {
        DesktopObservationResult(
            target: result.target,
            capture: CaptureResult(
                imageData: result.capture.imageData,
                savedPath: path,
                metadata: result.capture.metadata,
                warning: result.capture.warning),
            elements: result.elements,
            ocr: result.ocr,
            files: result.files,
            timings: result.timings,
            diagnostics: result.diagnostics,
            captureContentDigest: result.captureContentDigest)
    }

    static func replacingOutput(
        _ result: DesktopObservationResult,
        files: DesktopObservationFiles,
        rawData: Data? = nil,
        annotatedData: Data? = nil) -> DesktopObservationResult
    {
        DesktopObservationResult(
            target: result.target,
            capture: result.capture,
            elements: result.elements,
            ocr: result.ocr,
            files: files,
            timings: result.timings,
            diagnostics: result.diagnostics)
            .withCaptureContentDigest(
                rawScreenshotData: rawData,
                annotatedScreenshotData: annotatedData)
    }

    static func replacingDigest(
        _ result: DesktopObservationResult,
        with digest: DesktopObservationContentDigest?) -> DesktopObservationResult
    {
        DesktopObservationResult(
            target: result.target,
            capture: result.capture,
            elements: result.elements,
            ocr: result.ocr,
            files: result.files,
            timings: result.timings,
            diagnostics: result.diagnostics,
            captureContentDigest: digest)
    }

    static func captureDiagnostics(
        size: CGSize,
        scale: CaptureScalePreference = .logical1x,
        engine: String = "ScreenCaptureKit") -> CaptureDiagnostics
    {
        CaptureDiagnostics(
            requestedScale: scale,
            nativeScale: 2,
            outputScale: scale == .native ? 2 : 1,
            scaleSource: "fixture",
            finalPixelSize: size,
            engine: engine)
    }

    @MainActor
    static func server(provider: any DesktopObservationServiceProtocol) -> PeekabooBridgeServer {
        PeekabooBridgeServer(
            services: StubServices(desktopObservation: provider),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
            })
    }

    static var permissions: PermissionsStatus {
        PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
    }

    static func makeBundle(
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse,
        target: PeekabooBridgeOperationTargetReceipt) async throws -> PeekabooBridgeOperationReceiptBundle
    {
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: "/tmp/observation-binding-\(UUID().uuidString)/bridge.sock")
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let accepted = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: request)
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: accepted.claim,
            request: request,
            response: response,
            target: target)
        let receipt = try await authority.signAndArchive(payload, claim: accepted.claim)
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: receipt,
            request: request,
            response: response)
        authority.complete(accepted.claim)
        return bundle
    }
}

struct WindowResultOptions {
    let processIdentifier: Int32
    let generation: UInt64
    let bundleIdentifier: String?
    let applicationName: String
    let windowID: Int
    let title: String
    let index: Int
    var captureGeneration: UInt64?
    var captureMode: CaptureMode = .window
    var windowSelector: WindowSelection?
}

@MainActor
final class ObservationProvider: DesktopObservationServiceProtocol {
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
