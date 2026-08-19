import Darwin
import Foundation
import PeekabooAutomationKit
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooEmbeddedBridgeRuntimeTests {
    private struct RegistrationFailure: Error {}

    @Test
    @MainActor
    func `native assembly defaults to background first and owns every canonical native leaf`() {
        let services = PeekabooEmbeddedBridgeServices()

        #expect(services.inputPolicy.defaultStrategy == .actionFirst)
        #expect(services.inputPolicy.strategy(for: .setValue) == .actionOnly)
        #expect(services.inputPolicy.strategy(for: .performAction) == .actionOnly)
        #expect(PeekabooBridgeOperation.exactWindowTargetedClick.nativeServiceOwnsDesktopOperationLane)
        #expect(PeekabooBridgeOperation.nativeDesktopOperationLaneOperations == Set(
            PeekabooBridgeOperation.allCases.filter(\.nativeServiceOwnsDesktopOperationLane)))

        for operation in PeekabooBridgeOperation.allCases {
            #expect(services.ownsDesktopOperationLane(for: operation) ==
                operation.nativeServiceOwnsDesktopOperationLane)
        }
    }

    @Test
    @MainActor
    func `shared watermark invalidates snapshots across store instances`() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = DesktopMutationWatermarkStore(directoryURL: root)
        let secondStore = DesktopMutationWatermarkStore(directoryURL: root)
        let services = PeekabooEmbeddedBridgeServices(desktopMutationWatermarkStore: firstStore)

        let snapshotID = try await services.snapshots.createSnapshot()
        #expect(await services.snapshots.getMostRecentSnapshot() == snapshotID)

        let cutoff = Date().addingTimeInterval(1)
        _ = try secondStore.advance(through: cutoff)

        #expect(await services.snapshots.getMostRecentSnapshot() == nil)
        #expect(services.snapshots.effectiveImplicitLatestInvalidationWatermark == cutoff)
    }

    @Test
    func `embedded allowlist excludes browser daemon and interactive permission ownership`() {
        let operations = PeekabooBridgeOperation.embeddedDefaultAllowlist
        #expect(!operations.contains(.browserStatus))
        #expect(!operations.contains(.browserConnect))
        #expect(!operations.contains(.browserDisconnect))
        #expect(!operations.contains(.browserExecute))
        #expect(!operations.contains(.daemonStatus))
        #expect(!operations.contains(.daemonStop))
        #expect(!operations.contains(.requestPostEventPermission))
        #expect(!operations.contains(.agentExecutionTrace))
        #expect(!operations.contains(._appleScriptProbe))
        #expect(operations.contains(.desktopObservation))
        #expect(operations.contains(.exactWindowTargetedClick))
        #expect(operations.contains(.backgroundDialogClickButton))

        let attemptedBroadening = PeekabooEmbeddedBridgeRuntime.Configuration(
            socketPath: Self.socketPath(),
            allowlistedTeams: ["TEAMID"],
            allowlistedBundles: ["com.example.client"],
            allowedOperations: [
                .desktopObservation,
                .browserExecute,
                .daemonStop,
                .requestPostEventPermission,
                .agentExecutionTrace,
                ._appleScriptProbe,
            ],
            hostCapabilities: [PeekabooBridgeHostCapability.agentExecutionTrace])
        #expect(attemptedBroadening.allowedOperations == [.desktopObservation])
        #expect(attemptedBroadening.hostCapabilities.contains(PeekabooBridgeHostCapability.backgroundBridgeHost))
        #expect(!attemptedBroadening.hostCapabilities.contains(PeekabooBridgeHostCapability.agentExecutionTrace))
    }

    @Test
    @MainActor
    func `configuration rejects implicit authorization policy`() async {
        let services = PeekabooEmbeddedBridgeServices()
        let noTeams = PeekabooEmbeddedBridgeRuntime(
            configuration: .init(
                socketPath: Self.socketPath(),
                allowlistedTeams: [],
                allowlistedBundles: ["com.example.client"]),
            services: services)
        await #expect(throws: PeekabooEmbeddedBridgeRuntimeError.emptyTeamAllowlist) {
            try await noTeams.startChecked()
        }

        let noBundles = PeekabooEmbeddedBridgeRuntime(
            configuration: .init(
                socketPath: Self.socketPath(),
                allowlistedTeams: ["TEAMID"],
                allowlistedBundles: []),
            services: services)
        await #expect(throws: PeekabooEmbeddedBridgeRuntimeError.emptyBundleAllowlist) {
            try await noBundles.startChecked()
        }
    }

    @Test
    @MainActor
    func `screen capture capability registration failure leaves no partial host`() async {
        let socketPath = Self.socketPath()
        defer { Self.removeSocketArtifacts(socketPath) }
        let services = PeekabooEmbeddedBridgeServices()
        let configuration = PeekabooEmbeddedBridgeRuntime.Configuration(
            socketPath: socketPath,
            allowlistedTeams: ["TEAMID"],
            allowlistedBundles: ["com.example.client"],
            screenCaptureKitProcessCapabilityRegistrar: { throw RegistrationFailure() })
        let runtime = PeekabooEmbeddedBridgeRuntime(
            configuration: configuration,
            services: services)

        await #expect(throws: RegistrationFailure.self) {
            try await runtime.startChecked()
        }
        #expect(await runtime.snapshot().state == .stopped)
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test
    @MainActor
    func `concurrent lifecycle joins transitions and restart retains current capabilities`() async throws {
        let socketPath = Self.socketPath()
        defer { Self.removeSocketArtifacts(socketPath) }
        let runtime = Self.runtime(socketPath: socketPath)

        async let firstStart = runtime.startChecked()
        async let secondStart = runtime.startChecked()
        let (firstSnapshot, secondSnapshot) = try await (firstStart, secondStart)
        #expect(firstSnapshot == secondSnapshot)
        #expect(firstSnapshot.state == .ready)
        #expect(firstSnapshot.hostCapabilities.isSuperset(of: [
            PeekabooBridgeHostCapability.backgroundBridgeHost,
            PeekabooBridgeHostCapability.desktopActionOutcomeProjection,
            PeekabooBridgeHostCapability.explicitSnapshotPublication,
            PeekabooBridgeHostCapability.desktopObservationOCR,
            PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
            PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
            PeekabooBridgeHostCapability.safeBackgroundApplicationLaunchNoOp,
            PeekabooBridgeHostCapability.processGenerationPinnedApplicationActivation,
        ]))

        async let firstStop: Void = runtime.stopChecked()
        async let secondStop: Void = runtime.stopChecked()
        _ = await (firstStop, secondStop)
        #expect(await runtime.snapshot().state == .stopped)
        #expect(!FileManager.default.fileExists(atPath: socketPath))

        let restarted = try await runtime.restartChecked()
        #expect(restarted.state == .ready)
        #expect(restarted.hostCapabilities == firstSnapshot.hostCapabilities)
        await runtime.stopChecked()
    }

    @Test
    @MainActor
    func `failed socket ownership does not disturb the live runtime`() async throws {
        let socketPath = Self.socketPath()
        defer { Self.removeSocketArtifacts(socketPath) }
        let first = Self.runtime(socketPath: socketPath)
        let second = Self.runtime(socketPath: socketPath)

        _ = try await first.startChecked()
        await #expect(throws: PeekabooBridgeHostError.self) {
            try await second.startChecked()
        }
        #expect(await first.snapshot().state == .ready)
        #expect(await second.snapshot().state == .stopped)
        await first.stopChecked()
    }

    @Test
    @MainActor
    func `later stop wins when it overlaps an earlier start`() async throws {
        let socketPath = Self.socketPath()
        defer { Self.removeSocketArtifacts(socketPath) }
        let registrationEntered = AsyncTestGate()
        let releaseRegistration = AsyncTestGate()
        let stopJoinedStart = DispatchSemaphore(value: 0)
        let runtime = PeekabooEmbeddedBridgeRuntime(
            configuration: .init(
                socketPath: socketPath,
                allowlistedTeams: ["TEAMID"],
                allowlistedBundles: ["com.example.client"]),
            services: PeekabooEmbeddedBridgeServices(),
            lifecycleHooks: .init(
                didEnqueueStop: { stopJoinedStart.signal() },
                willStartHost: {
                    await registrationEntered.open()
                    await releaseRegistration.wait()
                }))

        let startTask = Task { try await runtime.startChecked() }
        await registrationEntered.wait()
        let stopTask = Task { await runtime.stopChecked() }
        #expect(await Self.wait(for: stopJoinedStart))
        await releaseRegistration.open()

        _ = try await startTask.value
        await stopTask.value
        #expect(await runtime.snapshot().state == .stopped)
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test
    @MainActor
    func `later start wins when it overlaps an earlier stop`() async throws {
        let socketPath = Self.socketPath()
        defer { Self.removeSocketArtifacts(socketPath) }
        let stopEntered = AsyncTestGate()
        let releaseStop = AsyncTestGate()
        let startEnqueued = DispatchSemaphore(value: 0)
        let runtime = PeekabooEmbeddedBridgeRuntime(
            configuration: .init(
                socketPath: socketPath,
                allowlistedTeams: ["TEAMID"],
                allowlistedBundles: ["com.example.client"]),
            services: PeekabooEmbeddedBridgeServices(),
            lifecycleHooks: .init(
                didEnqueueStart: { startEnqueued.signal() },
                willStopHost: {
                    await stopEntered.open()
                    await releaseStop.wait()
                }))
        _ = try await runtime.startChecked()
        #expect(await Self.wait(for: startEnqueued))

        let stopTask = Task { await runtime.stopChecked() }
        await stopEntered.wait()
        let startTask = Task { try await runtime.startChecked() }
        #expect(await Self.wait(for: startEnqueued))
        await releaseStop.open()

        await stopTask.value
        _ = try await startTask.value
        #expect(await runtime.snapshot().state == .ready)
        #expect(FileManager.default.fileExists(atPath: socketPath))

        await runtime.stopChecked()
    }

    @Test
    @MainActor
    func `later stop wins over an overlapping restart`() async throws {
        let socketPath = Self.socketPath()
        defer { Self.removeSocketArtifacts(socketPath) }
        let stopEntered = AsyncTestGate()
        let releaseStop = AsyncTestGate()
        let restartEnqueued = DispatchSemaphore(value: 0)
        let stopEnqueued = DispatchSemaphore(value: 0)
        let runtime = PeekabooEmbeddedBridgeRuntime(
            configuration: .init(
                socketPath: socketPath,
                allowlistedTeams: ["TEAMID"],
                allowlistedBundles: ["com.example.client"]),
            services: PeekabooEmbeddedBridgeServices(),
            lifecycleHooks: .init(
                didEnqueueStop: { stopEnqueued.signal() },
                didEnqueueRestart: { restartEnqueued.signal() },
                willStopHost: {
                    await stopEntered.open()
                    await releaseStop.wait()
                }))
        _ = try await runtime.startChecked()

        let restartTask = Task { try await runtime.restartChecked() }
        #expect(await Self.wait(for: restartEnqueued))
        await stopEntered.wait()
        let stopTask = Task { await runtime.stopChecked() }
        #expect(await Self.wait(for: stopEnqueued))
        await releaseStop.open()

        _ = try await restartTask.value
        await stopTask.value
        #expect(await runtime.snapshot().state == .stopped)
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test
    @MainActor
    func `queued stop start stop preserves the latest intent`() async throws {
        let socketPath = Self.socketPath()
        defer { Self.removeSocketArtifacts(socketPath) }
        let stopEntered = AsyncTestGate()
        let releaseStop = AsyncTestGate()
        let startEnqueued = DispatchSemaphore(value: 0)
        let stopEnqueued = DispatchSemaphore(value: 0)
        let runtime = PeekabooEmbeddedBridgeRuntime(
            configuration: .init(
                socketPath: socketPath,
                allowlistedTeams: ["TEAMID"],
                allowlistedBundles: ["com.example.client"]),
            services: PeekabooEmbeddedBridgeServices(),
            lifecycleHooks: .init(
                didEnqueueStart: { startEnqueued.signal() },
                didEnqueueStop: { stopEnqueued.signal() },
                willStopHost: {
                    await stopEntered.open()
                    await releaseStop.wait()
                }))
        _ = try await runtime.startChecked()
        #expect(await Self.wait(for: startEnqueued))

        let firstStop = Task { await runtime.stopChecked() }
        #expect(await Self.wait(for: stopEnqueued))
        await stopEntered.wait()
        let start = Task { try await runtime.startChecked() }
        #expect(await Self.wait(for: startEnqueued))
        let finalStop = Task { await runtime.stopChecked() }
        #expect(await Self.wait(for: stopEnqueued))
        await releaseStop.open()

        await firstStop.value
        _ = try await start.value
        await finalStop.value
        #expect(await runtime.snapshot().state == .stopped)
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test
    @MainActor
    func `unauthorized signed peer receives a typed refusal`() async throws {
        let socketPath = Self.socketPath()
        defer { Self.removeSocketArtifacts(socketPath) }
        let runtime = PeekabooEmbeddedBridgeRuntime(
            configuration: .init(
                socketPath: socketPath,
                allowlistedTeams: ["NOT_THE_CURRENT_TEAM"],
                allowlistedBundles: ["com.example.client"]),
            services: PeekabooEmbeddedBridgeServices())
        _ = try await runtime.startChecked()
        defer { Task { await runtime.stopChecked() } }

        let request = try JSONEncoder.peekabooBridgeEncoder().encode(PeekabooBridgeRequest.permissionsStatus)
        let responseData = try Self.sendUnixRequest(path: socketPath, request: request)
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: responseData)
        guard case let .error(error) = response else {
            Issue.record("Expected an unauthorized error response, got \(response)")
            return
        }
        #expect(error.code == .unauthorizedClient)
    }

    @MainActor
    private static func runtime(socketPath: String) -> PeekabooEmbeddedBridgeRuntime {
        PeekabooEmbeddedBridgeRuntime(
            configuration: .init(
                socketPath: socketPath,
                allowlistedTeams: ["TEAMID"],
                allowlistedBundles: ["com.example.client"]),
            services: PeekabooEmbeddedBridgeServices())
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-embedded-runtime-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func socketPath() -> String {
        "/tmp/peekaboo-embedded-runtime-\(UUID().uuidString).sock"
    }

    private static func removeSocketArtifacts(_ socketPath: String) {
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: "\(socketPath).lock")
    }

    private static func wait(
        for semaphore: DispatchSemaphore,
        timeout: DispatchTime = .now() + 2) async -> Bool
    {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: timeout) == .success)
            }
        }
    }

    private static func sendUnixRequest(path: String, request: Data) throws -> Data {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = path.withCString { strlcpy(&address.sun_path.0, $0, capacity) }
        guard copied < capacity else { throw POSIXError(.ENAMETOOLONG) }

        var localAddress = address
        let addressLength = socklen_t(MemoryLayout.size(ofValue: localAddress))
        let result = withUnsafePointer(to: &localAddress) { pointer -> Int32 in
            Darwin.connect(
                descriptor,
                UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr.self),
                addressLength)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        try request.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < request.count {
                let count = write(descriptor, baseAddress.advanced(by: written), request.count - written)
                if count > 0 {
                    written += count
                } else if count < 0, errno != EINTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        _ = shutdown(descriptor, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                response.append(buffer, count: count)
            } else if count == 0 {
                return response
            } else if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func open() {
        guard !self.isOpen else { return }
        self.isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
