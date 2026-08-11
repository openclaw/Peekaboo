import Foundation
import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooCLI

struct BridgeDiagnosticsConcurrencyTests {
    private let identity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "test.peekaboo",
        teamIdentifier: nil,
        processIdentifier: 42,
        hostname: "test-host"
    )

    @Test
    func `probes run concurrently with a bound and return in candidate order`() async throws {
        let gate = BridgeProbeGate()
        let paths = ["/one", "/two", "/three", "/four"]
        let probeTask = Task {
            try await BridgeDiagnostics.probeCandidates(
                socketPaths: paths,
                identity: self.identity,
                maxConcurrentProbes: 2,
                probe: { socketPath, _ in
                    await gate.probe(socketPath)
                }
            )
        }

        await gate.waitUntilStarted(count: 2)
        #expect(await Set(gate.startedPaths) == Set(["/one", "/two"]))

        await gate.release("/two")
        await gate.waitUntilStarted(count: 3)
        #expect(await Set(gate.startedPaths) == Set(["/one", "/two", "/three"]))

        await gate.release("/three")
        await gate.waitUntilStarted(count: 4)
        #expect(await Set(gate.startedPaths) == Set(paths))

        await gate.release("/four")
        await gate.release("/one")

        let results = try await probeTask.value
        #expect(results.map(\.socketPath) == paths)
        #expect(results.compactMap { result in
            if case let .success(handshake) = result.outcome {
                return handshake.build
            }
            return nil
        } == paths)
    }

    @Test
    func `cancellation stops active probes without starting queued candidates`() async throws {
        let starts = BridgeProbeStarts()
        let paths = ["/one", "/two", "/three", "/four"]
        let probeTask = Task {
            try await BridgeDiagnostics.probeCandidates(
                socketPaths: paths,
                identity: self.identity,
                maxConcurrentProbes: 2,
                probe: { socketPath, _ in
                    await starts.record(socketPath)
                    try await Task.sleep(for: .seconds(30))
                    return Self.handshake(build: socketPath)
                }
            )
        }

        await starts.waitUntilStarted(count: 2)
        let cancelledAt = ContinuousClock.now
        probeTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await probeTask.value
        }
        #expect(cancelledAt.duration(to: .now) < .seconds(1))
        #expect(await Set(starts.paths) == Set(["/one", "/two"]))
    }

    @Test
    func `probe failures preserve typed errors and candidate order`() async throws {
        let paths = ["/slow", "/healthy"]
        let results = try await BridgeDiagnostics.probeCandidates(
            socketPaths: paths,
            identity: self.identity,
            maxConcurrentProbes: 2,
            probe: { socketPath, _ in
                if socketPath == "/slow" {
                    throw PeekabooBridgeErrorEnvelope(
                        code: .timeout,
                        message: "diagnostic deadline exceeded"
                    )
                }
                return Self.handshake(build: socketPath)
            }
        )

        #expect(results.map(\.socketPath) == paths)
        guard case let .failure(failure) = results[0].outcome else {
            Issue.record("Expected the first diagnostic candidate to fail")
            return
        }
        #expect(failure.code == PeekabooBridgeErrorCode.timeout.rawValue)
        #expect(failure.message == "diagnostic deadline exceeded")
        guard case let .success(handshake) = results[1].outcome else {
            Issue.record("Expected the second diagnostic candidate to succeed")
            return
        }
        #expect(handshake.build == "/healthy")
    }

    private nonisolated static func handshake(build: String) -> PeekabooBridgeHandshakeResponse {
        BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .onDemand,
            build: build,
            supportedOperations: [.permissionsStatus]
        )
    }
}

private actor BridgeProbeGate {
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var startedPaths: [String] = []

    func probe(_ socketPath: String) async -> PeekabooBridgeHandshakeResponse {
        await withCheckedContinuation { continuation in
            self.continuations[socketPath] = continuation
            self.startedPaths.append(socketPath)
            self.resumeSatisfiedStartWaiters()
        }
        return BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .onDemand,
            build: socketPath,
            supportedOperations: [.permissionsStatus]
        )
    }

    func waitUntilStarted(count: Int) async {
        guard self.startedPaths.count < count else { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append((count, continuation))
        }
    }

    func release(_ socketPath: String) {
        self.continuations.removeValue(forKey: socketPath)?.resume()
    }

    private func resumeSatisfiedStartWaiters() {
        let satisfied = self.startWaiters.filter { $0.count <= self.startedPaths.count }
        self.startWaiters.removeAll { $0.count <= self.startedPaths.count }
        satisfied.forEach { $0.continuation.resume() }
    }
}

private actor BridgeProbeStarts {
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var paths: [String] = []

    func record(_ socketPath: String) {
        self.paths.append(socketPath)
        let satisfied = self.startWaiters.filter { $0.count <= self.paths.count }
        self.startWaiters.removeAll { $0.count <= self.paths.count }
        satisfied.forEach { $0.continuation.resume() }
    }

    func waitUntilStarted(count: Int) async {
        guard self.paths.count < count else { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append((count, continuation))
        }
    }
}
