import CoreGraphics
import Foundation
import PeekabooAutomationKit
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeCaptureBindingTests {
    @Test
    func `app selected capture requires complete selector evidence live and offline`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = PeekabooBridgeRequest.captureWindow(.init(
            appIdentifier: "dev.peekaboo.fixture",
            windowIndex: 0,
            windowId: nil,
            visualizerMode: .none,
            scale: .logical1x))
        let valid = Self.capture(
            fixture: fixture,
            applicationProofs: [fixture.applicationProof],
            captureProofs: [
                fixture.applicationProof.selecting(windowIdentity: fixture.windowIdentity),
                fixture.windowProof,
            ])

        let validBundle = try await fixture.session.signedBundle(
            authority: fixture.authority,
            sequence: 0,
            request: request,
            response: .capture(valid),
            target: .window(fixture.windowIdentity))
        try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
            validBundle.receipt.payload,
            request: request,
            response: .capture(valid))
        try validBundle.validateIntegrity()

        let missingApplicationInfo = Self.capture(
            fixture: fixture,
            applicationProofs: [fixture.applicationProof],
            captureProofs: valid.metadata.selectorResolutionProofs,
            includesApplicationInfo: false)
        let missingWindowInfo = Self.capture(
            fixture: fixture,
            applicationProofs: [fixture.applicationProof],
            captureProofs: valid.metadata.selectorResolutionProofs,
            includesWindowInfo: false)
        #expect(PeekabooBridgeSelectorResolutionBinding.captureMismatch(
            request: request,
            result: missingApplicationInfo,
            requireProof: true) == "missing application selector proof")
        #expect(PeekabooBridgeSelectorResolutionBinding.captureMismatch(
            request: request,
            result: missingWindowInfo,
            requireProof: true) == "missing window selector proof")

        let forgeries = [
            Self.capture(
                fixture: fixture,
                applicationProofs: nil,
                captureProofs: valid.metadata.selectorResolutionProofs),
            Self.capture(
                fixture: fixture,
                applicationProofs: [fixture.applicationProof],
                captureProofs: [fixture.applicationProof.selecting(windowIdentity: fixture.windowIdentity)]),
            missingApplicationInfo,
            missingWindowInfo,
        ]
        for (offset, forgery) in forgeries.enumerated() {
            let bundle = try await fixture.session.signedBundle(
                authority: fixture.authority,
                sequence: UInt64(offset + 1),
                request: request,
                response: .capture(forgery),
                target: .window(fixture.windowIdentity))
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
                    bundle.receipt.payload,
                    request: request,
                    response: .capture(forgery))
            }
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try bundle.validateIntegrity()
            }
        }
    }

    @Test
    func `window ID selected capture does not require selector evidence`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = PeekabooBridgeRequest.captureWindow(.init(
            appIdentifier: "",
            windowIndex: nil,
            windowId: fixture.windowIdentity.windowID,
            visualizerMode: .none,
            scale: .logical1x))
        let capture = Self.capture(
            fixture: fixture,
            applicationProofs: nil,
            captureProofs: nil)
        let bundle = try await fixture.session.signedBundle(
            authority: fixture.authority,
            sequence: 0,
            request: request,
            response: .capture(capture),
            target: .window(fixture.windowIdentity))

        try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
            bundle.receipt.payload,
            request: request,
            response: .capture(capture))
        try bundle.validateIntegrity()
    }

    private struct Fixture {
        let root: URL
        let authority: PeekabooBridgeOperationReceiptAuthority
        let session: OperationReceiptSessionFixture
        let windowIdentity: WindowMutationIdentity
        let applicationProof: SelectorResolutionProof
        let windowProof: SelectorResolutionProof
    }

    private static func makeFixture() async throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp/pbor-capture-binding-\(UUID().uuidString)", isDirectory: true)
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let bounds = CGRect(x: 20, y: 30, width: 640, height: 480)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: bounds)
        let applicationProof = SelectorResolutionProof(
            scope: .application,
            normalizedSelector: "dev.peekaboo.fixture",
            matchKind: .bundleIdentifier,
            matchPrecedence: SelectorResolutionProof.MatchKind.bundleIdentifier.precedence,
            selectedProcessIdentity: identity.processIdentity,
            candidateSetSHA256: String(repeating: "a", count: 64),
            candidateCount: 1,
            winningCandidateCount: 1,
            hasWinningTie: false)
        let windowProof = SelectorResolutionProof(
            scope: .window,
            normalizedSelector: WindowSelectorResolutionProof.normalizedSelector(.index(0)),
            matchKind: .windowIndex,
            matchPrecedence: SelectorResolutionProof.MatchKind.windowIndex.precedence,
            selectedProcessIdentity: identity.processIdentity,
            selectedWindowIdentity: identity,
            candidateSetSHA256: String(repeating: "b", count: 64),
            candidateCount: 1,
            winningCandidateCount: 1,
            hasWinningTie: false)
        return Fixture(
            root: root,
            authority: authority,
            session: session,
            windowIdentity: identity,
            applicationProof: applicationProof,
            windowProof: windowProof)
    }

    private static func capture(
        fixture: Fixture,
        applicationProofs: [SelectorResolutionProof]?,
        captureProofs: [SelectorResolutionProof]?,
        includesApplicationInfo: Bool = true,
        includesWindowInfo: Bool = true) -> CaptureResult
    {
        let bounds = fixture.windowIdentity.capturedBounds ?? .zero
        let application = ServiceApplicationInfo(
            processIdentifier: fixture.windowIdentity.ownerProcessIdentifier,
            processStartIdentity: fixture.windowIdentity.ownerProcessStartIdentity,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "Fixture",
            selectorResolutionProofs: applicationProofs)
        let window = ServiceWindowInfo(
            windowID: fixture.windowIdentity.windowID,
            title: "Document",
            bounds: bounds,
            index: 0,
            mutationIdentity: fixture.windowIdentity)
        return CaptureResult(
            imageData: Data(),
            metadata: CaptureMetadata(
                size: bounds.size,
                mode: .window,
                applicationInfo: includesApplicationInfo ? application : nil,
                windowInfo: includesWindowInfo ? window : nil,
                diagnostics: CaptureDiagnostics(
                    requestedScale: .logical1x,
                    nativeScale: 2,
                    outputScale: 1,
                    scaleSource: "fixture",
                    finalPixelSize: bounds.size,
                    engine: "ScreenCaptureKit"),
                selectorResolutionProofs: captureProofs))
    }
}
