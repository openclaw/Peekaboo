import Darwin
import Dispatch
import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeCancellationTests {
    @Test
    func `client cancellation finishes shutdown before descriptor can be released for reuse`() throws {
        let shutdownEntered = DispatchSemaphore(value: 0)
        let allowShutdownToFinish = DispatchSemaphore(value: 0)
        let cancellationFinished = DispatchSemaphore(value: 0)
        let descriptorCleared = DispatchSemaphore(value: 0)
        let cancellation = PeekabooBridgeClientConnectionCancellation { _ in
            shutdownEntered.signal()
            _ = allowShutdownToFinish.wait(timeout: .now() + 1)
        }
        let descriptor: Int32 = 42
        try cancellation.install(fd: descriptor)

        Thread.detachNewThread {
            cancellation.cancel()
            cancellationFinished.signal()
        }
        #expect(shutdownEntered.wait(timeout: .now() + 1) == .success)

        Thread.detachNewThread {
            cancellation.clear(fd: descriptor)
            descriptorCleared.signal()
        }
        #expect(descriptorCleared.wait(timeout: .now() + 0.05) == .timedOut)

        allowShutdownToFinish.signal()
        #expect(cancellationFinished.wait(timeout: .now() + 1) == .success)
        #expect(descriptorCleared.wait(timeout: .now() + 1) == .success)
    }

    @Test
    func `peer liveness survives request half-close then detects full close without consuming data`() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let connection = try PeekabooBridgeConnectionLiveness(fd: sockets[0])
        var peerFD = sockets[1]
        defer {
            connection.close()
            if peerFD >= 0 {
                Darwin.close(peerFD)
            }
        }

        let requestData = Data("half-close sentinel".utf8)
        let written = requestData.withUnsafeBytes { bytes in
            Darwin.write(peerFD, bytes.baseAddress, bytes.count)
        }
        #expect(written == requestData.count)
        #expect(Darwin.shutdown(peerFD, SHUT_WR) == 0)

        #expect(connection.canReceiveResponse())
        let received = try PeekabooBridgeSocketIO.readAll(
            fd: sockets[0],
            maxBytes: 1024,
            deadline: Date().addingTimeInterval(1))
        #expect(received == requestData)
        #expect(connection.canReceiveResponse())
        var unexpectedResponseByte: UInt8 = 0
        let peeked = Darwin.recv(
            peerFD,
            &unexpectedResponseByte,
            1,
            MSG_PEEK | MSG_DONTWAIT)
        #expect(peeked == -1)
        #expect(errno == EAGAIN || errno == EWOULDBLOCK)

        Darwin.close(peerFD)
        peerFD = -1
        #expect(await Self.waitForPeerDisconnect(connection))
    }

    @Test
    func `peer probe descriptor cannot be recycled while a liveness check is running`() throws {
        let probeEntered = DispatchSemaphore(value: 0)
        let allowProbeToFinish = DispatchSemaphore(value: 0)
        let probeFinished = DispatchSemaphore(value: 0)
        let closeFinished = DispatchSemaphore(value: 0)
        let closedDescriptors = CancellationTestLockedValues<Int32>()
        let connection = try PeekabooBridgeConnectionLiveness(
            fd: 42,
            probeFD: 43,
            peerProbe: { _ in
                probeEntered.signal()
                _ = allowProbeToFinish.wait(timeout: .now() + 1)
                return true
            },
            shutdownHandler: { _ in },
            closeHandler: {
                closedDescriptors.append($0)
            })

        Thread.detachNewThread {
            _ = connection.canReceiveResponse()
            probeFinished.signal()
        }
        #expect(probeEntered.wait(timeout: .now() + 1) == .success)

        Thread.detachNewThread {
            connection.close()
            closeFinished.signal()
        }
        #expect(closeFinished.wait(timeout: .now() + 0.05) == .timedOut)

        allowProbeToFinish.signal()
        #expect(probeFinished.wait(timeout: .now() + 1) == .success)
        #expect(closeFinished.wait(timeout: .now() + 1) == .success)
        #expect(closedDescriptors.values == [43, 42])
    }

    @Test
    func `peer liveness follows private duplicate after accepted descriptor number is reused`() async throws {
        var original = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &original) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let acceptedFD = original[0]
        var originalPeerFD = original[1]
        let connection = try PeekabooBridgeConnectionLiveness(fd: acceptedFD)

        Darwin.close(acceptedFD)
        var replacement = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &replacement) == 0 else {
            connection.close()
            Darwin.close(originalPeerFD)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let replacementSourceFD = replacement[0]
        let replacementPeerFD = replacement[1]
        if replacementSourceFD != acceptedFD {
            #expect(dup2(replacementSourceFD, acceptedFD) == acceptedFD)
            Darwin.close(replacementSourceFD)
        }
        defer {
            connection.close()
            if originalPeerFD >= 0 {
                Darwin.close(originalPeerFD)
            }
            Darwin.close(replacementPeerFD)
        }

        var marker = UInt8(ascii: "R")
        #expect(Darwin.write(replacementPeerFD, &marker, 1) == 1)
        var receivedMarker: UInt8 = 0
        #expect(Darwin.read(acceptedFD, &receivedMarker, 1) == 1)
        #expect(receivedMarker == marker)

        #expect(Darwin.shutdown(originalPeerFD, SHUT_WR) == 0)
        #expect(connection.canReceiveResponse())
        Darwin.close(originalPeerFD)
        originalPeerFD = -1
        #expect(await Self.waitForPeerDisconnect(connection))

        #expect(Darwin.write(replacementPeerFD, &marker, 1) == 1)
        #expect(Darwin.read(acceptedFD, &receivedMarker, 1) == 1)
        #expect(receivedMarker == marker)
    }

    @Test
    func `request cancelled before task installation never reaches server work`() async throws {
        let tracker = PeekabooBridgeRequestTracker()
        let trackedRequest = try #require(tracker.begin())
        let executionProbe = CancellationTestCompletionProbe()
        let task = Task {
            guard await trackedRequest.awaitActivation() else {
                tracker.finish(trackedRequest)
                return
            }
            await executionProbe.markCompleted()
            tracker.finish(trackedRequest)
        }

        tracker.stopAcceptingAndCancelAll()
        trackedRequest.install(task: task)
        await task.value

        #expect(await executionProbe.isCompleted == false)
        #expect(tracker.activeCount == 0)
    }

    @Test
    @MainActor
    func `timed out bridge client cannot execute its queued desktop mutation`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-bridge-cancellation-\(UUID().uuidString)", isDirectory: true)
        let socketPath = "/tmp/pb-cancel-\(UUID().uuidString).sock"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: "\(socketPath).lock")
        }

        let store = DesktopMutationWatermarkStore(directoryURL: root.appendingPathComponent("watermarks"))
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let observations = CancellationTestObservationService()
        let admissions = CancellationTestAdmissionRecorder()
        let services = StubServices(snapshots: snapshots, desktopObservation: observations)
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            desktopMutationWatermarkStore: store,
            permissionStatusEvaluator: { _ in admissions.record() })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()

        let firstRequestData = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeRequest.desktopObservation(Self.mutatingObservationRequest(snapshotID: "S1")))
        let firstTask = Task { await server.decodeAndHandle(firstRequestData, peer: nil) }
        await observations.waitUntilFirstObservationStarted()

        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 0.05)
        try await Self.negotiateLegacyTransport(client)
        let queuedRequest = PeekabooBridgeRequest.desktopObservation(
            Self.mutatingObservationRequest(snapshotID: "S2"))
        let queuedTask = Task { try await client.send(queuedRequest) }
        await admissions.waitUntilRequestCount(3)

        do {
            _ = try await queuedTask.value
            Issue.record("Expected the queued client request to time out")
        } catch let failure as DesktopActionFailure {
            Self.expectResponseLostFailure(failure)
        } catch {
            Issue.record("Expected response-lost failure, got \(error)")
        }

        observations.releaseFirstObservation()
        _ = await firstTask.value
        await host.stop()

        #expect(observations.observationCount == 1)
    }

    @Test
    func `timed out bridge client cannot execute after the cross process barrier unblocks`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-bridge-flock-cancellation-\(UUID().uuidString)", isDirectory: true)
        let watermarkRoot = root.appendingPathComponent("watermarks", isDirectory: true)
        let socketPath = "/tmp/pb-flock-cancel-\(UUID().uuidString).sock"
        try FileManager.default.createDirectory(at: watermarkRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: "\(socketPath).lock")
        }

        let watermarkLockPath = watermarkRoot.appendingPathComponent("desktop-mutation-watermark.lock").path
        let watermarkLockFD = open(
            watermarkLockPath,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard watermarkLockFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var watermarkLockHeld = true
        defer {
            if watermarkLockHeld {
                _ = flock(watermarkLockFD, LOCK_UN)
            }
            close(watermarkLockFD)
        }
        guard flock(watermarkLockFD, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let store = DesktopMutationWatermarkStore(directoryURL: watermarkRoot)
        let (observations, admissions, activity, server) = await MainActor.run {
            let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
            let observations = CountingCancellationTestObservationService()
            let admissions = CancellationTestAdmissionRecorder()
            let activity = CancellationTestDaemonControl()
            let services = StubServices(snapshots: snapshots, desktopObservation: observations)
            let server = PeekabooBridgeServer(
                services: services,
                allowlistedTeams: [],
                allowlistedBundles: [],
                allowedOperations: [.desktopObservation, .permissionsStatus],
                daemonControl: activity,
                desktopMutationWatermarkStore: store,
                permissionStatusEvaluator: { _ in admissions.record() })
            return (observations, admissions, activity, server)
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()

        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 0.05)
        try await Self.negotiateLegacyTransport(client)
        let request = PeekabooBridgeRequest.desktopObservation(
            Self.mutatingObservationRequest(snapshotID: "blocked"))
        let requestTask = Task { try await client.send(request) }
        await admissions.waitUntilRequestCount(2)
        #expect(try await Self.waitForActiveRequestCount(1, activity: activity))

        do {
            _ = try await requestTask.value
            Issue.record("Expected the client request blocked on the watermark lock to time out")
        } catch let failure as DesktopActionFailure {
            Self.expectResponseLostFailure(failure)
        } catch {
            Issue.record("Expected response-lost failure, got \(error)")
        }

        let followUpClient = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1)
        try await Self.negotiateLegacyTransport(followUpClient)
        let followUp = try await followUpClient.send(.permissionsStatus)
        guard case .permissionsStatus = followUp else {
            Issue.record("Expected the bridge MainActor to remain responsive while the flock is held")
            #expect(flock(watermarkLockFD, LOCK_UN) == 0)
            watermarkLockHeld = false
            await host.stop()
            return
        }

        #expect(flock(watermarkLockFD, LOCK_UN) == 0)
        watermarkLockHeld = false
        #expect(try await Self.waitForActiveRequestCount(0, activity: activity))
        #expect(await MainActor.run { observations.observationCount } == 0)

        let postRelease = try await followUpClient.send(.permissionsStatus)
        guard case .permissionsStatus = postRelease else {
            Issue.record("Expected the host to remain active after the cancelled worker drained")
            await host.stop()
            return
        }
        await host.stop()
    }

    @Test
    @MainActor
    func `full close after half-close retains ownership until cancelled mutation finishes`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-bridge-retained-mutation-\(UUID().uuidString)", isDirectory: true)
        let socketPath = "/tmp/pb-disconnect-drain-\(UUID().uuidString).sock"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: "\(socketPath).lock")
        }

        let store = DesktopMutationWatermarkStore(directoryURL: root.appendingPathComponent("watermarks"))
        let observations = CancellationTestObservationService()
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let services = StubServices(snapshots: snapshots, desktopObservation: observations)
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation, .permissionsStatus],
            desktopMutationWatermarkStore: store)
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1,
            requestDrainTimeoutSec: 0.05)
        try await host.startChecked()

        let timedOutClient = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 0.25)
        try await Self.negotiateLegacyTransport(timedOutClient)
        let firstRequest = PeekabooBridgeRequest.desktopObservation(
            Self.mutatingObservationRequest(snapshotID: "blocked"))
        let firstTask = Task { try await timedOutClient.send(firstRequest) }
        let observationStarted = try await Self.waitForObservationStart(observations)
        guard observationStarted else {
            Issue.record("Expected the bridge observation to start")
            firstTask.cancel()
            _ = await host.stop()
            return
        }

        do {
            _ = try await firstTask.value
            Issue.record("Expected the first client to time out")
        } catch let failure as DesktopActionFailure {
            Self.expectResponseLostFailure(failure)
        } catch {
            Issue.record("Expected response-lost failure, got \(error)")
        }

        #expect(try await Self.waitForConnectionCount(0, host: host))
        #expect(await host.activeRequestCountForTesting() == 1)

        let followUpClient = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1)
        try await Self.negotiateLegacyTransport(followUpClient)
        let followUpResponse = try await followUpClient.send(.permissionsStatus)
        guard case .permissionsStatus = followUpResponse else {
            Issue.record("Expected follow-up response while the old mutation task remained blocked")
            observations.releaseFirstObservation()
            _ = await host.stop()
            return
        }

        let stopOutcome = await host.stop()
        guard case let .ownershipRetained(pendingCount, _) = stopOutcome else {
            Issue.record("Expected bounded stop to retain ownership, got \(stopOutcome)")
            observations.releaseFirstObservation()
            return
        }
        #expect(pendingCount == 1)
        #expect(await host.isRetainingOwnershipForRequestsForTesting)
        do {
            try await host.startChecked()
            Issue.record("Expected the draining host to reject restart")
        } catch let PeekabooBridgeHostError.requestsStillDraining(path, pendingCount) {
            #expect(path == socketPath)
            #expect(pendingCount == 1)
        }

        let replacement = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        do {
            try await replacement.startChecked()
            Issue.record("Expected the retained socket lease to reject a replacement host")
            _ = await replacement.stop()
        } catch let PeekabooBridgeHostError.socketAlreadyOwned(path) {
            #expect(path == socketPath)
        }

        observations.releaseFirstObservation()
        #expect(try await Self.waitForOwnershipRelease(host))
        #expect(await host.activeRequestCountForTesting() == 0)
        #expect(observations.observationCount == 1)

        try await replacement.startChecked()
        #expect(await replacement.stop() == .stopped)
    }

    @Test
    @MainActor
    func `host stop disconnects client but retains ownership for noncooperative request`() async throws {
        let socketPath = "/tmp/pb-stop-active-\(UUID().uuidString).sock"
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: "\(socketPath).lock")
        }

        let observations = CancellationTestObservationService()
        let services = StubServices(desktopObservation: observations)
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 30,
            requestDrainTimeoutSec: 0.05)
        try await host.startChecked()

        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 30)
        try await Self.negotiateLegacyTransport(client)
        let requestTask = Task { try await client.send(.desktopObservation(
            Self.nonmutatingObservationRequest(snapshotID: "active"))) }
        await observations.waitUntilFirstObservationStarted()
        #expect(await host.activeConnectionCountForTesting() == 1)

        let stopOutcome = await host.stop()
        guard case let .ownershipRetained(pendingCount, _) = stopOutcome else {
            Issue.record("Expected bounded stop to retain request ownership, got \(stopOutcome)")
            observations.releaseFirstObservation()
            return
        }
        #expect(pendingCount == 1)
        #expect(await host.activeConnectionCountForTesting() == 0)
        #expect(await host.activeRequestCountForTesting() == 1)
        do {
            _ = try await requestTask.value
            Issue.record("Expected host shutdown to terminate the active client request")
        } catch {
            // The exact transport error is not contractual; prompt termination is.
        }

        observations.releaseFirstObservation()
        #expect(try await Self.waitForOwnershipRelease(host))
        #expect(await host.activeRequestCountForTesting() == 0)
    }

    @Test
    @MainActor
    func `task cancellation shuts down bridge socket before its request deadline`() async throws {
        let socketPath = "/tmp/pb-client-task-cancel-\(UUID().uuidString).sock"
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: "\(socketPath).lock")
        }

        let observations = CancellationTestObservationService()
        let services = StubServices(desktopObservation: observations)
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 30)
        try await host.startChecked()

        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 30)
        try await Self.negotiateLegacyTransport(client)
        var requestFinished = false
        var receivedCancellation = false
        let requestTask = Task { @MainActor in
            defer { requestFinished = true }
            do {
                _ = try await client.send(.desktopObservation(
                    Self.nonmutatingObservationRequest(snapshotID: "cancelled")))
            } catch is CancellationError {
                receivedCancellation = true
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
            }
        }
        await observations.waitUntilFirstObservationStarted()

        requestTask.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !requestFinished, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(requestFinished)
        #expect(receivedCancellation)
        observations.releaseFirstObservation()
        await requestTask.value
        await host.stop()
    }

    private static func mutatingObservationRequest(snapshotID: String) -> DesktopObservationRequest {
        DesktopObservationRequest(
            target: .screen(index: 0),
            capture: DesktopCaptureOptions(focus: .background),
            detection: DesktopDetectionOptions(mode: .accessibility, allowWebFocusFallback: true),
            output: DesktopObservationOutputOptions(snapshotID: snapshotID))
    }

    private static func expectResponseLostFailure(_ failure: DesktopActionFailure) {
        #expect(failure.outcome.route == .bridge)
        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.evidence == .responseLost)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.outcome.projection.requiresFreshObservation)
    }

    private static func nonmutatingObservationRequest(snapshotID: String) -> DesktopObservationRequest {
        DesktopObservationRequest(
            target: .screen(index: 0),
            capture: DesktopCaptureOptions(focus: .background),
            detection: DesktopDetectionOptions(mode: .accessibility, allowWebFocusFallback: false),
            output: DesktopObservationOutputOptions(snapshotID: snapshotID))
    }

    private static func negotiateLegacyTransport(_ client: PeekabooBridgeClient) async throws {
        _ = try await client.handshake(
            client: PeekabooBridgeClientIdentity(
                bundleIdentifier: "dev.peekaboo.cancellation-tests",
                teamIdentifier: nil,
                processIdentifier: getpid(),
                hostname: nil),
            protocolVersion: .init(major: 1, minor: 28))
    }

    private static func waitForActiveRequestCount(
        _ expectedCount: Int,
        activity: CancellationTestDaemonControl) async throws -> Bool
    {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await activity.activeRequestCount != expectedCount {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private static func waitForConnectionCount(
        _ expectedCount: Int,
        host: PeekabooBridgeHost) async throws -> Bool
    {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await host.activeConnectionCountForTesting() != expectedCount {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private static func waitForOwnershipRelease(_ host: PeekabooBridgeHost) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await host.isRetainingOwnershipForRequestsForTesting {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private static func waitForPeerDisconnect(_ connection: PeekabooBridgeConnectionLiveness) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while connection.canReceiveResponse() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    @MainActor
    private static func waitForObservationStart(
        _ observations: CancellationTestObservationService) async throws -> Bool
    {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !observations.hasStarted {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

private enum CancellationTestError: Error {
    case timedOutWaitingForCondition
}

private actor CancellationTestCompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        self.isCompleted = true
    }
}

private final class CancellationTestLockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }

    func append(_ value: Value) {
        self.lock.lock()
        self.storage.append(value)
        self.lock.unlock()
    }
}

@MainActor
private final class CancellationTestDaemonControl: PeekabooDaemonControlProviding {
    private(set) var activeRequestCount = 0

    func daemonStatus() async -> PeekabooDaemonStatus {
        PeekabooDaemonStatus(
            running: true,
            pid: getpid(),
            startedAt: Date(),
            mode: .manual,
            bridge: PeekabooDaemonBridgeStatus(
                socketPath: "/tmp/peekaboo-cancellation-test.sock",
                hostKind: .onDemand,
                allowedOperations: [.desktopObservation]),
            activity: PeekabooDaemonActivityStatus(
                activeRequests: self.activeRequestCount,
                lastActivityAt: Date(),
                idleTimeoutSeconds: nil,
                idleExitAt: nil))
    }

    func requestStop() async -> Bool {
        true
    }

    func recordActivityStart(operation _: PeekabooBridgeOperation) async {
        self.activeRequestCount += 1
    }

    func recordActivityEnd(operation _: PeekabooBridgeOperation) async {
        self.activeRequestCount = max(0, self.activeRequestCount - 1)
    }
}

@MainActor
private final class CancellationTestAdmissionRecorder {
    private var requestCount = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record() -> PermissionsStatus {
        self.requestCount += 1
        let ready = self.waiters.filter { self.requestCount >= $0.count }
        self.waiters.removeAll { self.requestCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
        return PermissionsStatus(
            screenRecording: true,
            accessibility: true,
            appleScript: true,
            postEvent: true)
    }

    func waitUntilRequestCount(_ count: Int) async {
        guard self.requestCount < count else { return }
        await withCheckedContinuation { continuation in
            self.waiters.append((count: count, continuation: continuation))
        }
    }
}

@MainActor
private final class CancellationTestObservationService: DesktopObservationServiceProtocol {
    private(set) var observationCount = 0
    private var firstObservationStarted = false
    private var firstObservationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstObservationContinuation: CheckedContinuation<Void, Never>?

    var hasStarted: Bool {
        self.firstObservationStarted
    }

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.observationCount += 1
        if self.observationCount == 1 {
            self.firstObservationStarted = true
            self.firstObservationStartWaiters.forEach { $0.resume() }
            self.firstObservationStartWaiters.removeAll()
            await withCheckedContinuation { continuation in
                self.firstObservationContinuation = continuation
            }
        }
        return DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: StubScreenCaptureService.sampleData,
                savedPath: "/tmp/\(request.output.snapshotID ?? "stub").png",
                metadata: CaptureMetadata(
                    size: .init(width: 1, height: 1),
                    mode: .screen,
                    timestamp: Date())),
            elements: nil,
            files: DesktopObservationFiles())
    }

    func waitUntilFirstObservationStarted() async {
        guard !self.firstObservationStarted else { return }
        await withCheckedContinuation { continuation in
            self.firstObservationStartWaiters.append(continuation)
        }
    }

    func releaseFirstObservation() {
        self.firstObservationContinuation?.resume()
        self.firstObservationContinuation = nil
    }
}

@MainActor
private final class CountingCancellationTestObservationService: DesktopObservationServiceProtocol {
    private(set) var observationCount = 0

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.observationCount += 1
        return DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: StubScreenCaptureService.sampleData,
                savedPath: "/tmp/\(request.output.snapshotID ?? "stub").png",
                metadata: CaptureMetadata(
                    size: .init(width: 1, height: 1),
                    mode: .screen,
                    timestamp: Date())),
            elements: nil,
            files: DesktopObservationFiles())
    }
}
