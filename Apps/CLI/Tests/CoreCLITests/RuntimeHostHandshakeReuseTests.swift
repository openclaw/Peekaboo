import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import Testing
@testable import PeekabooCLI

extension ScreenCaptureKitOwnerRuntimeTests {
    @Test
    func `SCK safety handshake is reused for selection and authenticated dispatch`() async throws {
        let socketPath = "/tmp/peekaboo-safety-handshake-reuse-\(UUID().uuidString).sock"
        var permissionEvaluationCount = 0
        let host = try await Self.startHost(
            socketPath: socketPath,
            processIdentifier: 4242,
            processStartIdentity: 9001,
            codeSignatureHash: "owner-build",
            permissionEvaluationObserver: {
                permissionEvaluationCount += 1
            }
        )
        defer { Task { await host.stop() } }

        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "boo.peekaboo.test.client",
            teamIdentifier: nil,
            processIdentifier: getpid()
        )
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: socketPath,
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let handshakeCache = RuntimeHostResolver.RemoteHandshakeCache(identity: identity)

        let unawareHost = try await RuntimeHostResolver.firstScreenCaptureKitOwnerUnawareHost(
            candidates: [candidate],
            identity: identity,
            handshakeCache: handshakeCache,
            externalHostPresence: { _ in .absent }
        )
        #expect(unawareHost == nil)
        #expect(permissionEvaluationCount == 1)
        #expect(handshakeCache.entry(
            for: candidate,
            identity: PeekabooBridgeClientIdentity(
                bundleIdentifier: identity.bundleIdentifier,
                teamIdentifier: identity.teamIdentifier,
                processIdentifier: identity.processIdentifier + 1,
                hostname: identity.hostname
            )
        ) == nil)

        var options = CommandRuntimeOptions()
        options.captureEnginePreference = "auto"
        options.transportsCaptureEnginePreference = true
        options.requiresCaptureEnginePreferenceHost = true
        options.requiresScreenCaptureKitOwnerCapability = true
        options.requiresDesktopObservation = true
        options.requiresScreenCapturePermission = true

        var permissionRejections: [String] = []
        let mismatched = try await RuntimeHostResolver.resolveRemoteServices(
            candidates: [candidate],
            identity: identity,
            options: options,
            requiredOwner: ScreenCaptureKitOwnerLease.OwnerReceipt(
                processIdentifier: 4242,
                processStartIdentity: 9001,
                codeSignatureHash: "different-build"
            ),
            snapshotInvalidationRemoteSocketPaths: [],
            permissionRejections: &permissionRejections,
            handshakeCache: handshakeCache
        )
        #expect(mismatched == nil)
        #expect(permissionEvaluationCount == 1)

        let resolved = try await RuntimeHostResolver.resolveRemoteServices(
            candidates: [candidate],
            identity: identity,
            options: options,
            requiredOwner: ScreenCaptureKitOwnerLease.OwnerReceipt(
                processIdentifier: 4242,
                processStartIdentity: 9001,
                codeSignatureHash: "owner-build"
            ),
            snapshotInvalidationRemoteSocketPaths: [],
            permissionRejections: &permissionRejections,
            handshakeCache: handshakeCache
        )
        let resolution = try #require(resolved)

        #expect(resolution.selectedRemoteSocketPath == socketPath)
        #expect(permissionRejections.isEmpty)
        #expect(permissionEvaluationCount == 1)

        let permissions = try await resolution.services.permissionsStatus()
        #expect(permissions.screenRecording)
        #expect(permissionEvaluationCount == 2)
        await host.stop()
    }
}
