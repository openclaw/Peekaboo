import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooCore
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeHostIdentityTests {
    private struct LegacyHandshakeResponse: Codable {
        let negotiatedVersion: PeekabooBridgeProtocolVersion
        let hostKind: PeekabooBridgeHostKind
        let build: String?
        let supportedOperations: [PeekabooBridgeOperation]
        let permissionTags: [String: [PeekabooBridgePermissionKind]]?
    }

    @Test
    @MainActor
    func `current host identity comes from the serving process`() {
        let identity = PeekabooBridgeHostIdentity.current()

        #expect(identity.processIdentifier == getpid())
        #expect(identity.processStartIdentity == SystemIdentityResolver.processStartIdentity(getpid()))
        #expect(identity.processStartIdentityDecimal == identity.processStartIdentity.map(String.init))
    }

    @Test
    func `host identity preserves a lossless decimal process generation`() throws {
        let generation: UInt64 = 9_007_199_254_740_993
        let identity = PeekabooBridgeHostIdentity(
            processIdentifier: 4242,
            processStartIdentity: generation,
            bundleIdentifier: "boo.peekaboo.mac",
            bundleShortVersion: "4.0.0",
            bundleVersion: "400",
            codeSignatureHash: "abcdef",
            sourceCommit: "0123456789abcdef0123456789abcdef01234567")

        let data = try JSONEncoder.peekabooBridgeEncoder().encode(identity)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["processStartIdentityDecimal"] as? String == String(generation))
        #expect(object["sourceCommit"] as? String == "0123456789abcdef0123456789abcdef01234567")
        #expect(try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeHostIdentity.self,
            from: data).processStartIdentityDecimal == String(generation))
    }

    @Test
    func `new clients decode older host identity without decimal generation`() throws {
        let data = Data(#"""
        {
            "processIdentifier":4242,
            "processStartIdentity":9876543,
            "bundleIdentifier":"boo.peekaboo.mac",
            "bundleShortVersion":"4.0.0",
            "bundleVersion":"400",
            "codeSignatureHash":"abcdef"
        }
        """#.utf8)

        let identity = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeHostIdentity.self,
            from: data)
        #expect(identity.processStartIdentity == 9_876_543)
        #expect(identity.processStartIdentityDecimal == nil)
        #expect(identity.sourceCommit == nil)
    }

    @Test
    @MainActor
    func `missing generation and signature evidence remain unknown`() {
        let server = PeekabooBridgeServer(
            services: PeekabooServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            hostIdentity: .init(
                processIdentifier: 4242,
                processStartIdentity: nil,
                bundleIdentifier: "boo.peekaboo.mac",
                bundleShortVersion: "4.0.0",
                bundleVersion: "400",
                codeSignatureHash: nil))

        #expect(!server.hostCapabilities.contains(PeekabooBridgeHostCapability.hostGenerationIdentity))
        #expect(!server.hostCapabilities.contains(PeekabooBridgeHostCapability.codeSignatureBuildIdentity))
    }

    @Test
    func `handshake advertises injected host generation build and launch capabilities`() async throws {
        let hostIdentity = PeekabooBridgeHostIdentity(
            processIdentifier: 4242,
            processStartIdentity: 9_876_543,
            bundleIdentifier: "boo.peekaboo.mac",
            bundleShortVersion: "4.0.0",
            bundleVersion: "400",
            codeSignatureHash: "abcdef",
            sourceCommit: "0123456789abcdef0123456789abcdef01234567")
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                hostIdentity: hostIdentity,
                hostCapabilities: [PeekabooBridgeHostCapability.backgroundBridgeHost])
        }
        let request = PeekabooBridgeRequest.handshake(.init(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            client: .init(
                bundleIdentifier: "dev.peeka.cli",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            requestedHostKind: .gui))

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil)
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: responseData)
        guard case let .handshake(handshake) = response else {
            Issue.record("Expected handshake response, got \(response)")
            return
        }

        #expect(handshake.hostIdentity == hostIdentity)
        let expectedCapabilities: Set<String> = [
            PeekabooBridgeHostCapability.backgroundBridgeHost,
            PeekabooBridgeHostCapability.codeSignatureBuildIdentity,
            PeekabooBridgeHostCapability.desktopActionOutcomeProjection,
            PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
            PeekabooBridgeHostCapability.desktopObservationOCR,
            PeekabooBridgeHostCapability.hostGenerationIdentity,
            PeekabooBridgeHostCapability.processGenerationPinnedApplicationActivation,
            PeekabooBridgeHostCapability.processGenerationPinnedApplicationHide,
            PeekabooBridgeHostCapability.safeBackgroundApplicationLaunchNoOp,
            PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
        ]
        #expect(expectedCapabilities.isSubset(of: Set(handshake.hostCapabilities ?? [])))
    }

    @Test
    @MainActor
    func `host advertises desktop observation extensions only when desktop observation is allowed`() {
        let observationServer = PeekabooBridgeServer(
            services: PeekabooServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            hostIdentity: nil)
        let captureOnlyServer = PeekabooBridgeServer(
            services: PeekabooServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.captureScreen],
            hostIdentity: nil)
        let unverifiedObservationServer = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            hostIdentity: nil)

        #expect(observationServer.hostCapabilities.contains(PeekabooBridgeHostCapability.desktopObservationOCR))
        #expect(observationServer.hostCapabilities.contains(
            PeekabooBridgeHostCapability.desktopObservationCaptureEngine))
        #expect(!captureOnlyServer.hostCapabilities.contains(PeekabooBridgeHostCapability.desktopObservationOCR))
        #expect(!captureOnlyServer.hostCapabilities.contains(
            PeekabooBridgeHostCapability.desktopObservationCaptureEngine))
        #expect(!unverifiedObservationServer.hostCapabilities.contains(
            PeekabooBridgeHostCapability.desktopObservationCaptureEngine))
    }

    @Test
    func `new clients decode legacy handshakes without host identity`() throws {
        let data = Data(#"""
        {
            "negotiatedVersion":{"major":1,"minor":0},
            "hostKind":"gui",
            "build":"3.9.6 (396)",
            "supportedOperations":[],
            "permissionTags":{}
        }
        """#.utf8)

        let handshake = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeHandshakeResponse.self,
            from: data)

        #expect(handshake.hostIdentity == nil)
        #expect(handshake.hostCapabilities == nil)
    }

    @Test
    func `legacy clients ignore additive host handshake fields`() throws {
        let response = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: "4.0.0 (400)",
            supportedOperations: [],
            hostIdentity: .init(
                processIdentifier: 4242,
                processStartIdentity: 9_876_543,
                bundleIdentifier: "boo.peekaboo.mac",
                bundleShortVersion: "4.0.0",
                bundleVersion: "400",
                codeSignatureHash: "abcdef"),
            hostCapabilities: [PeekabooBridgeHostCapability.backgroundBridgeHost])

        let data = try JSONEncoder.peekabooBridgeEncoder().encode(response)
        let legacy = try JSONDecoder.peekabooBridgeDecoder().decode(LegacyHandshakeResponse.self, from: data)

        #expect(legacy.negotiatedVersion == response.negotiatedVersion)
        #expect(legacy.hostKind == .gui)
        #expect(legacy.build == response.build)
        #expect(legacy.supportedOperations.isEmpty)
    }
}
