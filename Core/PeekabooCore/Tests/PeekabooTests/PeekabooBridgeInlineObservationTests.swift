import CoreGraphics
import Darwin
import Foundation
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeInlineObservationTests: DesktopObservationBindingFixtureProviding {
    @Test(arguments: [false, true])
    func `default inline output preserves legacy canonical request bytes`(withArtifacts: Bool) throws {
        let legacyOutput = LegacyOutput(
            path: withArtifacts ? "/tmp/observation-wire-fixture.png" : nil,
            format: .png,
            saveRawScreenshot: withArtifacts,
            saveAnnotatedScreenshot: false,
            saveSnapshot: withArtifacts,
            snapshotID: withArtifacts ? "ps1_0123456789abcdef0123456789abcdef" : nil)
        let legacy = LegacyRequest.desktopObservation(LegacyObservation(
            target: .screen(index: 0),
            capture: DesktopCaptureOptions(),
            detection: DesktopDetectionOptions(mode: .none),
            output: legacyOutput,
            timeout: DesktopObservationTimeouts()))
        let legacyBytes = try PeekabooBridgeOperationReceiptCoding.canonicalData(legacy)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: legacyBytes)
        guard case let .desktopObservation(observation) = decoded else {
            Issue.record("Expected a desktop observation request")
            return
        }
        #expect(!observation.output.includeImageData)
        #expect(try PeekabooBridgeOperationReceiptCoding.canonicalData(decoded) == legacyBytes)

        var explicitFalse = observation
        explicitFalse.output.includeImageData = false
        #expect(try PeekabooBridgeOperationReceiptCoding.canonicalData(
            PeekabooBridgeRequest.desktopObservation(explicitFalse)) == legacyBytes)
        var inline = observation
        inline.output.includeImageData = true
        let inlineBytes = try PeekabooBridgeOperationReceiptCoding.canonicalData(
            PeekabooBridgeRequest.desktopObservation(inline))
        #expect(inlineBytes != legacyBytes)
        #expect(try #require(String(data: inlineBytes, encoding: .utf8)).contains("\"includeImageData\":true"))
        #expect(try PeekabooBridgeOperationReceiptCoding.sha256(decoded) !=
            PeekabooBridgeOperationReceiptCoding.sha256(PeekabooBridgeRequest.desktopObservation(inline)))
        let roundTrip = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: inlineBytes)
        guard case let .desktopObservation(inlineObservation) = roundTrip else {
            Issue.record("Expected an inline desktop observation request")
            return
        }
        #expect(inlineObservation.output.includeImageData)
    }

    @Test(arguments: [false, true], [false, true])
    @MainActor
    func `server returns inline bytes only when requested`(
        includeImageData: Bool,
        actionAwareProvider: Bool) async throws
    {
        let fixture = Self.result()
        let provider: any DesktopObservationServiceProtocol = actionAwareProvider
            ? InlineActionObservationProvider(result: fixture)
            : ObservationProvider(result: fixture)
        let server = Self.server(provider: provider)
        #expect(server.hostCapabilities.contains(PeekabooBridgeHostCapability.desktopObservationInlinePixels))
        let request = Self.request(includeImageData: includeImageData)
        let handled = try await server.handleAuthorized(
            .desktopObservation(request), peer: nil, permissions: Self.permissions)
        guard case let .desktopObservation(result) = handled.response else {
            Issue.record("Expected desktop observation pixels")
            return
        }
        #expect(result.capture.imageData == (includeImageData ? Self.pixels : Data()))
        #expect(result.captureContentDigest == fixture.captureContentDigest)
        #expect(result.files.rawScreenshotPath == nil)
        #expect(result.files.annotatedScreenshotPath == nil)
        #expect(result.files.publishedSnapshotID == nil)
        #expect(result.elements == nil)
        if includeImageData {
            #expect(try result.verifiedCaptureImageData(requirement: .requireDigest) == Self.pixels)
        }
    }

    @Test
    @MainActor
    func `inline output does not create artifacts or reserve a snapshot`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-inline-output-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = InMemorySnapshotManager()
        let writer = ObservationOutputWriter(snapshotManager: snapshots)
        let output = DesktopObservationOutputOptions(
            path: root.appendingPathComponent("frame.png").path,
            includeImageData: true)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(try await writer.reserveSnapshotIfNeeded(options: output) == nil)
        let written = try await writer.write(capture: Self.result().capture, elements: nil, options: output)
        #expect(written.files.rawScreenshotPath == nil)
        #expect(written.files.annotatedScreenshotPath == nil)
        #expect(written.files.publishedSnapshotID == nil)
        #expect(try await snapshots.listSnapshots().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    @MainActor
    func `inline host capability belongs to transport and requires the operation`() async throws {
        let provider = ObservationProvider(result: Self.result())
        let server = PeekabooBridgeServer(
            services: StubServices(snapshots: InMemorySnapshotManager(), desktopObservation: provider),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.captureScreen],
            hostCapabilities: [PeekabooBridgeHostCapability.desktopObservationInlinePixels])
        #expect(!server.hostCapabilities.contains(PeekabooBridgeHostCapability.desktopObservationInlinePixels))
        let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await server.handleDesktopObservationRequest(.desktopObservation(Self.request()))
        }
        #expect(error?.code == .operationNotSupported)
        #expect(provider.observationCount == 0)
    }

    @Test
    @MainActor
    func `inline provider cannot return empty bytes on receiptless transport`() async throws {
        let provider = ObservationProvider(result: Self.result(bytes: Data()))
        let server = Self.server(provider: provider)
        let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await server.handleDesktopObservationRequest(.desktopObservation(Self.request()))
        }
        #expect(error?.code == .internalError)
        #expect(error?.message.contains("requested inline capture pixels") == true)
        #expect(provider.observationCount == 1)
    }

    @Test
    func `inline typed binding rejects empty and tampered content live and offline`() async throws {
        let valid = Self.result()
        let tampered = Self.result(bytes: Data("tampered-inline-bytes".utf8), digest: valid.captureContentDigest)
        let empty = Self.result(bytes: Data())
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: Self.request(), result: valid) == nil)
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: Self.request(), result: tampered) == "inline capture content digest")
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: Self.request(), result: empty) == "requested inline capture pixels")
        for result in [tampered, empty] {
            let bundle = try await Self.makeBundle(
                request: .desktopObservation(Self.request()),
                response: .desktopObservation(result),
                target: .global)
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try bundle.validateIntegrity()
            }
        }
    }

    @Test(arguments: [false, true])
    func `client refuses missing inline capability before request dispatch`(hasOperation: Bool) async throws {
        let handshake = Self.handshake(
            capabilities: hasOperation ? [] : [PeekabooBridgeHostCapability.desktopObservationInlinePixels],
            operations: hasOperation ? [.desktopObservation] : [])
        let peer = try ScriptedBridgePeer(responses: [.handshake(handshake)])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        do {
            try await Self.negotiate(client)
            let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
                try await client.desktopObservation(Self.request())
            }
            #expect(error?.code == .operationNotSupported)
            #expect(error?.message.contains("desktopObservationInlinePixels") == true)
            #expect(await peer.requests.count == 1)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test(arguments: [false, true])
    func `client validates inline bytes even on receiptless hosts`(tampered: Bool) async throws {
        let valid = Self.result()
        let invalid = tampered
            ? Self.result(bytes: Data("changed".utf8), digest: valid.captureContentDigest)
            : Self.result(bytes: Data())
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(Self.handshake()),
            .desktopObservation(valid),
            .desktopObservation(invalid),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        do {
            try await Self.negotiate(client)
            #expect(try await client.desktopObservation(Self.request()).capture.imageData == Self.pixels)
            await #expect(throws: (any Error).self) {
                try await client.desktopObservation(Self.request())
            }
            #expect(await peer.requests.count == 3)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `replacement handshake clears inline pixel capability before transport`() async throws {
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(Self.handshake()),
            .handshake(Self.handshake(capabilities: [])),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        do {
            try await Self.negotiate(client)
            #expect(await client.desktopObservationInlinePixelsEnabled)
            try await Self.negotiate(client)
            #expect(await !client.desktopObservationInlinePixelsEnabled)
            let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
                try await client.desktopObservation(Self.request())
            }
            #expect(error?.code == .operationNotSupported)
            #expect(await peer.requests.count == 2)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `receiptless inline pixels still require a content digest`() async throws {
        let invalid = Self.replacingDigest(Self.result(), with: nil)
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(Self.handshake()),
            .desktopObservation(invalid),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        do {
            try await Self.negotiate(client)
            await #expect(throws: DesktopObservationContentVerificationError.missingDigest) {
                try await client.desktopObservation(Self.request())
            }
            #expect(await peer.requests.count == 2)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `inline pixels retain the existing response size bound`() async throws {
        let oversized = Self.result(bytes: Data(repeating: 1, count: 4096))
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(Self.handshake()),
            .desktopObservation(oversized),
        ])
        let client = PeekabooBridgeClient(
            socketPath: peer.socketPath, maxResponseBytes: 2048, requestTimeoutSec: 1)
        do {
            try await Self.negotiate(client)
            await #expect(throws: (any Error).self) {
                try await client.desktopObservation(Self.request())
            }
            #expect(await peer.requests.count == 2)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test(arguments: ["valid", "stale-digest", "post-signing-tamper"])
    func `attested client verifies inline bytes before returning the observation`(variant: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-inline-receipt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let request = PeekabooBridgeRequest.desktopObservation(Self.request())
        let valid = Self.result()
        let tampered = Self.result(bytes: Data("changed-inline-bytes".utf8), digest: valid.captureContentDigest)
        let signedResponse = PeekabooBridgeResponse.desktopObservation(
            variant == "stale-digest" ? tampered : valid)
        let wireResponse = variant == "post-signing-tamper"
            ? PeekabooBridgeResponse.desktopObservation(tampered)
            : signedResponse
        let bundle = try await session.signedBundle(
            authority: authority,
            sequence: 0,
            request: request,
            response: signedResponse,
            target: .global)
        let listener = authority.attestation
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            supportedOperations: [.desktopObservation],
            hostIdentity: .init(
                processIdentifier: listener.host.processIdentifier,
                processStartIdentity: listener.host.processStartIdentity,
                bundleIdentifier: "dev.peekaboo.inline-receipt-tests",
                bundleShortVersion: "1",
                bundleVersion: "1",
                codeSignatureHash: listener.host.codeSignatureHash),
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.desktopActionOutcomeProjection,
                PeekabooBridgeHostCapability.desktopObservationInlinePixels,
            ],
            operationAttestation: listener,
            operationSessionAttestation: session.attestation)
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(handshake),
            .attestedOperation(.init(response: wireResponse, receipt: bundle.receipt)),
        ])
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 2,
            operationClientInstanceID: session.clientInstanceID)
        do {
            _ = try await client.handshake(client: .init(
                bundleIdentifier: "dev.peekaboo.inline-receipt-tests",
                teamIdentifier: nil,
                processIdentifier: getpid()))
            if variant == "valid" {
                let result = try await client.desktopObservationWithOutcome(Self.request())
                #expect(result.payload.capture.imageData == Self.pixels)
                #expect(result.payload.captureContentDigest == valid.captureContentDigest)
            } else {
                let expected = PeekabooBridgeOperationReceiptError.receiptMismatch(
                    variant == "stale-digest" ? "desktop observation inline capture content digest" : "operation facts")
                await #expect(throws: expected) {
                    try await client.desktopObservationWithOutcome(Self.request())
                }
            }
            let requests = await peer.requests
            #expect(requests.count == 2)
            let sent = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeRequest.self, from: #require(requests.last))
            guard case let .attestedOperation(operation) = sent else {
                Issue.record("Expected inline pixels to use the signed operation path")
                await peer.stop()
                return
            }
            #expect(operation.sessionID == session.attestation.sessionID)
            #expect(operation.requestID == bundle.receipt.payload.requestID)
            #expect(try PeekabooBridgeOperationReceiptCoding.sha256(operation.request) ==
                PeekabooBridgeOperationReceiptCoding.sha256(request))
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    private static let pixels = Data("synthetic-inline-capture-content".utf8)
    private static let legacyVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 28)

    private static func request(includeImageData: Bool = true) -> DesktopObservationRequest {
        DesktopObservationRequest(
            target: .screen(index: 0),
            detection: .init(mode: .none),
            output: .init(includeImageData: includeImageData))
    }

    private static func result(
        bytes: Data = Self.pixels,
        digest: DesktopObservationContentDigest? = nil) -> DesktopObservationResult
    {
        let fixture = Self.screenResult(index: 0)
        return DesktopObservationResult(
            target: fixture.target,
            capture: .init(imageData: bytes, metadata: fixture.capture.metadata),
            elements: nil,
            captureContentDigest: digest ?? DesktopObservationContentDigest(
                captureImageData: bytes, rawScreenshotData: nil, annotatedScreenshotData: nil))
    }

    private static func handshake(
        capabilities: [String] = [PeekabooBridgeHostCapability.desktopObservationInlinePixels],
        operations: [PeekabooBridgeOperation] = [.desktopObservation]) -> PeekabooBridgeHandshakeResponse
    {
        BridgeTestFixtures.handshake(
            negotiatedVersion: self.legacyVersion,
            supportedOperations: operations,
            hostCapabilities: capabilities)
    }

    private static func negotiate(_ client: PeekabooBridgeClient) async throws {
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.inline-observation-tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: self.legacyVersion)
    }

    private enum LegacyRequest: Encodable {
        case desktopObservation(LegacyObservation)
    }

    private struct LegacyObservation: Encodable {
        let target: DesktopObservationTargetRequest
        let capture: DesktopCaptureOptions
        let detection: DesktopDetectionOptions
        let output: LegacyOutput
        let timeout: DesktopObservationTimeouts
    }

    private struct LegacyOutput: Encodable {
        let path: String?
        let format: ImageFormat
        let saveRawScreenshot: Bool
        let saveAnnotatedScreenshot: Bool
        let saveSnapshot: Bool
        let snapshotID: String?
    }
}

@MainActor
private final class InlineActionObservationProvider: DesktopObservationActionResultProviding {
    private let result: DesktopObservationResult

    init(result: DesktopObservationResult) {
        self.result = result
    }

    func observe(_: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.result
    }

    func observeActionResult(
        _: DesktopObservationRequest) async throws -> UIAutomationActionResult<DesktopObservationResult>
    {
        UIAutomationActionResult(payload: self.result, outcome: nil)
    }
}
