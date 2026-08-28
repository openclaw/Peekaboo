import Darwin
import Dispatch
import Foundation
import OSLog

public enum PeekabooBridgeHostError: Error, LocalizedError, Sendable {
    case socketAlreadyOwned(path: String)
    case unsafeLeaseFile(path: String)
    case socketPathIsNotSocket(path: String)
    case socketPathTooLong(path: String)
    case requestsStillDraining(path: String, pendingCount: Int)
    case systemCallFailed(operation: String, path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case let .socketAlreadyOwned(path):
            "Bridge socket is already owned by another host: \(path)"
        case let .unsafeLeaseFile(path):
            "Refusing to use an unsafe bridge lease file: \(path)"
        case let .socketPathIsNotSocket(path):
            "Refusing to replace a non-socket bridge path: \(path)"
        case let .socketPathTooLong(path):
            "Bridge socket path is too long: \(path)"
        case let .requestsStillDraining(path, pendingCount):
            "Bridge host at \(path) is retaining ownership while \(pendingCount) request(s) finish"
        case let .systemCallFailed(operation, path, code):
            "\(operation) failed for \(path): \(String(cString: strerror(code)))"
        }
    }
}

public enum PeekabooBridgeHostStopOutcome: Sendable, Equatable {
    case stopped
    case ownershipRetained(pendingRequestCount: Int, oldestRequestAgeSeconds: TimeInterval)
}

struct PeekabooBridgeClientContext: @unchecked Sendable {
    let server: PeekabooBridgeServer
    let allowedTeamIDs: Set<String>
    let maxMessageBytes: Int
    let requestTimeoutSec: TimeInterval
    let connectionTracker: PeekabooBridgeConnectionTracker
    let requestTracker: PeekabooBridgeRequestTracker
    let bodyReadLimiter: PeekabooBridgeCapacityLimiter
    let admissionRefusalLimiter: PeekabooBridgeCapacityLimiter
    let acceptedConnectionLimiter: PeekabooBridgeCapacityLimiter
    let operationReceiptAuthority: PeekabooBridgeOperationReceiptAuthority?
    let authentication: PeekabooBridgeHostAuthentication
}

struct PeekabooBridgeHostAuthentication: @unchecked Sendable {
    let liveIdentity: @Sendable (Int32) throws -> PeekabooBridgeLivePeerIdentity
    let coldPeer: @Sendable (PeekabooBridgeLivePeerIdentity, Set<String>) -> PeekabooBridgePeer?

    static let live = PeekabooBridgeHostAuthentication(
        liveIdentity: { try PeekabooBridgeSocketIO.livePeerIdentity(fd: $0) },
        coldPeer: { liveIdentity, allowedTeamIDs in
            PeekabooBridgeHost.peerInfoIfAllowed(
                liveIdentity: liveIdentity,
                allowedTeamIDs: allowedTeamIDs)
        })
}

actor PeekabooBridgeConnectionTracker {
    private var activeConnections: [UUID: PeekabooBridgeConnectionLiveness] = [:]
    private var idleContinuations: [CheckedContinuation<Void, Never>] = []

    func begin(connection: PeekabooBridgeConnectionLiveness) {
        self.activeConnections[connection.id] = connection
    }

    func end(connection: PeekabooBridgeConnectionLiveness) {
        self.activeConnections.removeValue(forKey: connection.id)
        guard self.activeConnections.isEmpty else { return }
        let continuations = self.idleContinuations
        self.idleContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func disconnectAll() {
        for connection in self.activeConnections.values {
            connection.disconnectAndShutdown()
        }
    }

    var count: Int {
        self.activeConnections.count
    }

    func waitForIdle() async {
        guard !self.activeConnections.isEmpty else { return }
        await withCheckedContinuation { continuation in
            self.idleContinuations.append(continuation)
        }
    }
}

private func waitForPeekabooBridgeRequestsToDrain(
    _ tracker: PeekabooBridgeRequestTracker,
    timeoutSeconds: TimeInterval) async -> Bool
{
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    while tracker.activeCount > 0 {
        guard ContinuousClock.now < deadline else { return false }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
                continuation.resume()
            }
        }
    }
    return true
}

/// Converts listener readability into a coalesced async sequence.
///
/// A UNIX listener is level-triggered: one notification can represent several queued clients, so the accept loop
/// drains until `EAGAIN` before waiting for the next event. Keeping the source alive for the listener lifetime avoids
/// a polling sleep and lets shutdown explicitly finish the sequence before the descriptor is closed.
final class PeekabooBridgeListenerReadiness: @unchecked Sendable {
    let events: AsyncStream<Void>

    private let continuation: AsyncStream<Void>.Continuation
    private let cancellationEvents: AsyncStream<Void>
    private let source: any DispatchSourceRead
    private let lock = NSLock()
    private var isCancelled = false
    private var isFinishing = false
    private var isSuspended = false
    private var notificationCount = 0

    init(fileDescriptor: Int32) {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let cancellationPair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.events = pair.stream
        self.continuation = pair.continuation
        self.cancellationEvents = cancellationPair.stream
        self.source = DispatchSource.makeReadSource(
            fileDescriptor: fileDescriptor,
            queue: DispatchQueue.global(qos: .userInitiated))
        self.source.setEventHandler { [weak self] in
            self?.notifyReadable()
        }
        self.source.setCancelHandler {
            close(fileDescriptor)
            cancellationPair.continuation.yield(())
            cancellationPair.continuation.finish()
        }
        self.source.activate()
    }

    deinit {
        self.cancel()
    }

    func cancel() {
        self.lock.lock()
        guard !self.isCancelled else {
            self.lock.unlock()
            return
        }
        self.isCancelled = true
        let mustResume = self.isSuspended
        self.isSuspended = false
        self.lock.unlock()

        // A cancelled Dispatch source does not deliver its cancellation while suspended.
        if mustResume {
            self.source.resume()
        }
        self.continuation.finish()
        self.source.cancel()
    }

    /// Stops the async consumer before source cancellation closes the descriptor.
    func finishEvents() {
        self.lock.lock()
        guard !self.isFinishing else {
            self.lock.unlock()
            return
        }
        self.isFinishing = true
        self.lock.unlock()
        self.continuation.finish()
    }

    /// Waits until all queued source handlers have drained, making it safe for the owner to close the descriptor.
    func waitUntilCancelled() async {
        for await _ in self.cancellationEvents {
            return
        }
    }

    /// Re-enables listener notifications after the accept queue has been drained to `EAGAIN`.
    func rearm() {
        self.lock.lock()
        guard !self.isCancelled, !self.isFinishing, self.isSuspended else {
            self.lock.unlock()
            return
        }
        self.isSuspended = false
        self.lock.unlock()
        self.source.resume()
    }

    #if DEBUG
    var notificationCountForTesting: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.notificationCount
    }
    #endif

    private func notifyReadable() {
        self.lock.lock()
        guard !self.isCancelled, !self.isFinishing, !self.isSuspended else {
            self.lock.unlock()
            return
        }
        // Dispatch read sources are level-triggered. Suspend until the async consumer drains accept(), otherwise a
        // queued client can repeatedly invoke this lightweight handler faster than the consumer gets scheduled.
        self.isSuspended = true
        self.notificationCount += 1
        self.source.suspend()
        self.lock.unlock()
        self.continuation.yield(())
    }
}

enum PeekabooBridgeAcceptLoop {
    typealias ClientHandler = @Sendable (Int32, PeekabooBridgeConnectionLiveness) async -> Void
    typealias ConnectionAcceptor = @Sendable (Int32) async -> AcceptResult
    typealias ConnectionRegistration = @Sendable (PeekabooBridgeConnectionLiveness) async -> Void
    typealias PreparedConnection = (fd: Int32, connection: PeekabooBridgeConnectionLiveness)

    enum AcceptResult: Sendable {
        case prepared(PreparedConnection)
        case retry
        case drained
        case listenerClosed
        case failure(Int32)
    }

    enum DrainOutcome: Equatable, Sendable {
        case rearm
        case stop
    }

    private static let logger = Logger(subsystem: "boo.peekaboo.bridge", category: "host")

    fileprivate static func run(
        listenFD: Int32,
        readiness: PeekabooBridgeListenerReadiness,
        context: PeekabooBridgeClientContext,
        clientHandler: @escaping ClientHandler) async
    {
        defer { readiness.cancel() }
        for await _ in readiness.events {
            guard !Task.isCancelled else { return }
            let outcome = await self.drainConnections(
                listenFD: listenFD,
                acceptConnection: {
                    await self.acceptConnection(
                        $0,
                        limiter: context.acceptedConnectionLimiter)
                },
                registerConnection: { connection in
                    await context.connectionTracker.begin(connection: connection)
                },
                unregisterConnection: { connection in
                    await context.connectionTracker.end(connection: connection)
                    context.acceptedConnectionLimiter.finish()
                },
                clientHandler: clientHandler)
            guard outcome == .rearm else { return }
            readiness.rearm()
        }
    }

    static func drainConnections(
        listenFD: Int32,
        acceptConnection: @escaping ConnectionAcceptor,
        registerConnection: @escaping ConnectionRegistration,
        unregisterConnection: @escaping ConnectionRegistration,
        clientHandler: @escaping ClientHandler) async -> DrainOutcome
    {
        while !Task.isCancelled {
            switch await acceptConnection(listenFD) {
            case let .prepared(prepared):
                await registerConnection(prepared.connection)
                guard !Task.isCancelled else {
                    prepared.connection.close()
                    await unregisterConnection(prepared.connection)
                    return .stop
                }
                Task.detached(priority: .userInitiated) {
                    await clientHandler(prepared.fd, prepared.connection)
                    prepared.connection.close()
                    await unregisterConnection(prepared.connection)
                }
            case .retry:
                continue
            case .drained:
                return .rearm
            case .listenerClosed:
                return .stop
            case let .failure(code):
                self.logger.error("accept failed: \(code, privacy: .public)")
                try? await Task.sleep(nanoseconds: 50_000_000)
                return Task.isCancelled ? .stop : .rearm
            }
        }
        return .stop
    }

    private static func acceptConnection(
        _ listenFD: Int32,
        limiter: PeekabooBridgeCapacityLimiter) async -> AcceptResult
    {
        var addr = sockaddr()
        var len = socklen_t(MemoryLayout<sockaddr>.size)
        let client = accept(listenFD, &addr, &len)
        if client >= 0 {
            guard limiter.begin() else {
                close(client)
                return .retry
            }
            guard let prepared = self.prepareConnection(client) else {
                limiter.finish()
                return .retry
            }
            return .prepared(prepared)
        }
        if errno == EINTR {
            return .retry
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            return .drained
        }
        if errno == EBADF || errno == EINVAL {
            return .listenerClosed
        }
        return .failure(errno)
    }

    private static func prepareConnection(_ client: Int32) -> PreparedConnection? {
        var one: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        do {
            try PeekabooBridgeSocketIO.configureConnectedSocket(client)
        } catch {
            self.logger.error(
                "failed to configure bridge client socket: \(error.localizedDescription, privacy: .private)")
            close(client)
            return nil
        }
        do {
            return try (client, PeekabooBridgeConnectionLiveness(fd: client))
        } catch {
            self.logger.error(
                "failed to create bridge liveness probe: \(error.localizedDescription, privacy: .private)")
            close(client)
            return nil
        }
    }
}

/// Lightweight UNIX-domain socket host for Peekaboo automation.
///
/// This is a single-request-per-connection protocol: clients write one JSON request then half-close,
/// the host replies with one JSON response and closes.
public final actor PeekabooBridgeHost {
    private struct SocketIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct SocketStatus: Equatable {
        let identity: SocketIdentity
        let mode: mode_t
        let ownerUID: uid_t

        var isSocket: Bool {
            (self.mode & S_IFMT) == S_IFSOCK
        }
    }

    private struct ProcessMetadata {
        let ownerUID: uid_t
        let status: UInt32
    }

    struct PeerSigningIdentity: Equatable, Sendable {
        let bundleIdentifier: String?
        let teamIdentifier: String?
        let codeSignatureHash: String?
        let sourceCommit: String?

        init(
            bundleIdentifier: String?,
            teamIdentifier: String?,
            codeSignatureHash: String?,
            sourceCommit: String? = nil)
        {
            self.bundleIdentifier = bundleIdentifier
            self.teamIdentifier = teamIdentifier
            self.codeSignatureHash = codeSignatureHash
            self.sourceCommit = sourceCommit
        }
    }

    typealias PeerSigningInformationProvider = (_ processIdentifier: pid_t) -> [String: Any]?

    private enum LegacySocketOwnerState {
        case held
        case unheld
        case indeterminate
    }

    private enum LeaseMarkerState {
        case empty
        case identity(SocketIdentity)
        case incomplete
        case invalid
    }

    private struct LeaseMarkerSnapshot {
        let state: LeaseMarkerState
    }

    private struct SocketLease {
        let fd: Int32
        let recordedIdentity: SocketIdentity?
    }

    nonisolated static let logger = Logger(subsystem: "boo.peekaboo.bridge", category: "host")
    private nonisolated static let leaseMarkerPrefix = "peekaboo-bridge-lease-v1"

    private var listenFD: Int32 = -1
    private var leaseFD: Int32 = -1
    private var socketIdentity: SocketIdentity?
    private var acceptTask: Task<Void, Never>?
    var browserHandoffMaintenanceTask: Task<Void, Never>?
    private var listenerReadiness: PeekabooBridgeListenerReadiness?
    private var stopTask: Task<PeekabooBridgeHostStopOutcome, Never>?
    private var ownershipCleanupTask: Task<Void, Never>?
    private var operationReceiptAuthority: PeekabooBridgeOperationReceiptAuthority?
    private var lifecycleGeneration: UInt64 = 0
    private let connectionTracker = PeekabooBridgeConnectionTracker()
    private let requestTracker: PeekabooBridgeRequestTracker
    private let bodyReadLimiter: PeekabooBridgeCapacityLimiter
    private let admissionRefusalLimiter: PeekabooBridgeCapacityLimiter
    private let acceptedConnectionLimiter: PeekabooBridgeCapacityLimiter

    private let socketPath: String
    private let maxMessageBytes: Int
    private let allowedTeamIDs: Set<String>
    private let requestTimeoutSec: TimeInterval
    private let requestDrainTimeoutSec: TimeInterval
    var browserHandoffMaintenanceIntervalMilliseconds: Int64 = 1000
    let server: PeekabooBridgeServer
    private var authentication = PeekabooBridgeHostAuthentication.live

    public init(
        socketPath: String = PeekabooBridgeConstants.peekabooSocketPath,
        server: PeekabooBridgeServer,
        maxMessageBytes: Int = 64 * 1024 * 1024,
        allowedTeamIDs: Set<String> = PeekabooBridgeConstants.trustedReleaseTeamIDs,
        requestTimeoutSec: TimeInterval = PeekabooBridgeConstants.defaultRequestTimeoutSeconds,
        requestDrainTimeoutSec: TimeInterval = 1.0,
        maximumConcurrentRequests: Int = 32)
    {
        self.socketPath = socketPath
        self.server = server
        self.maxMessageBytes = maxMessageBytes
        self.allowedTeamIDs = allowedTeamIDs
        self.requestTimeoutSec = requestTimeoutSec
        self.requestDrainTimeoutSec = max(0.01, requestDrainTimeoutSec)
        let normalizedRequestCapacity = max(1, maximumConcurrentRequests)
        let connectionCapacity = normalizedRequestCapacity.addingReportingOverflow(
            min(8, normalizedRequestCapacity))
        self.requestTracker = PeekabooBridgeRequestTracker(
            maximumActiveRequestCount: normalizedRequestCapacity)
        self.bodyReadLimiter = PeekabooBridgeCapacityLimiter(
            maximumCount: max(4, normalizedRequestCapacity))
        self.admissionRefusalLimiter = PeekabooBridgeCapacityLimiter(
            maximumCount: min(4, normalizedRequestCapacity))
        self.acceptedConnectionLimiter = PeekabooBridgeCapacityLimiter(
            maximumCount: max(8, connectionCapacity.overflow ? Int.max : connectionCapacity.partialValue))
    }

    deinit {
        self.browserHandoffMaintenanceTask?.cancel()
        if self.server.supportsBrowserHandoffMaintenance {
            Self.continueBrowserHandoffShutdownMaintenance(
                server: self.server,
                intervalMilliseconds: self.browserHandoffMaintenanceIntervalMilliseconds)
        }
    }

    #if DEBUG
    func setAuthenticationForTesting(_ authentication: PeekabooBridgeHostAuthentication) {
        precondition(self.listenFD == -1)
        self.authentication = authentication
    }

    func setBrowserHandoffMaintenanceIntervalForTesting(milliseconds: Int64) {
        precondition(self.listenFD == -1)
        precondition(milliseconds > 0)
        self.browserHandoffMaintenanceIntervalMilliseconds = milliseconds
    }
    #endif

    public func start() async {
        do {
            try await self.startChecked()
        } catch {
            Self.logger.error(
                """
                Failed to start bridge host at \(self.socketPath, privacy: .private): \
                \(error.localizedDescription, privacy: .private)
                """)
        }
    }

    public func startChecked() async throws {
        guard self.stopTask == nil else {
            throw PeekabooBridgeHostError.requestsStillDraining(
                path: self.socketPath,
                pendingCount: self.requestTracker.activeCount)
        }
        guard self.listenFD == -1 else { return }
        let startGeneration = self.lifecycleGeneration
        try await self.server.prepareScreenCaptureKitOwnershipForServing()
        try Task.checkCancellation()
        guard self.lifecycleGeneration == startGeneration else {
            throw CancellationError()
        }
        guard self.listenFD == -1 else { return }
        guard self.stopTask == nil else {
            throw PeekabooBridgeHostError.requestsStillDraining(
                path: self.socketPath,
                pendingCount: self.requestTracker.activeCount)
        }
        guard self.ownershipCleanupTask == nil,
              self.leaseFD == -1,
              self.requestTracker.activeCount == 0,
              self.operationReceiptAuthority == nil
        else {
            throw PeekabooBridgeHostError.requestsStillDraining(
                path: self.socketPath,
                pendingCount: self.requestTracker.activeCount)
        }

        let path = self.socketPath
        let fm = FileManager.default

        let parent = (path as NSString).deletingLastPathComponent
        let dir = parent.isEmpty ? "." : parent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let lease = try Self.acquireLease(path: path)
        do {
            try Self.clearLeaseIdentity(fd: lease.fd, path: path)
            let (fd, identity) = try Self.makeListeningSocket(
                path: path,
                recoverableIdentity: lease.recordedIdentity,
                leaseFD: lease.fd)
            self.listenFD = fd
            self.leaseFD = lease.fd
            self.socketIdentity = identity
        } catch {
            flock(lease.fd, LOCK_UN)
            close(lease.fd)
            throw error
        }
        let operationReceiptAuthority: PeekabooBridgeOperationReceiptAuthority?
        if self.server.supportedVersions.upperBound >= PeekabooBridgeConstants.attestedOperationReceiptVersion {
            do {
                operationReceiptAuthority = try PeekabooBridgeOperationReceiptAuthority(
                    socketPath: path,
                    maximumClaimCount: self.server.operationReceiptSessionCapacity)
                self.operationReceiptAuthority = operationReceiptAuthority
            } catch {
                close(self.listenFD)
                self.listenFD = -1
                self.releaseOwnership()
                throw error
            }
        } else {
            operationReceiptAuthority = nil
        }

        let fd = self.listenFD
        let listenerReadiness = PeekabooBridgeListenerReadiness(fileDescriptor: fd)
        self.listenerReadiness = listenerReadiness
        self.requestTracker.startAccepting()

        let context = PeekabooBridgeClientContext(
            server: self.server,
            allowedTeamIDs: self.allowedTeamIDs,
            maxMessageBytes: self.maxMessageBytes,
            requestTimeoutSec: self.requestTimeoutSec,
            connectionTracker: self.connectionTracker,
            requestTracker: self.requestTracker,
            bodyReadLimiter: self.bodyReadLimiter,
            admissionRefusalLimiter: self.admissionRefusalLimiter,
            acceptedConnectionLimiter: self.acceptedConnectionLimiter,
            operationReceiptAuthority: operationReceiptAuthority,
            authentication: self.authentication)

        self.acceptTask = Task.detached(priority: .userInitiated) {
            await PeekabooBridgeAcceptLoop.run(
                listenFD: fd,
                readiness: listenerReadiness,
                context: context)
            { fd, connection in
                await Self.handleClient(
                    fd: fd,
                    connection: connection,
                    context: context)
            }
        }
        self.startBrowserHandoffMaintenanceIfNeeded()
    }

    func advertisedHostCapabilities() async -> Set<String> {
        await MainActor.run { self.server.hostCapabilities }
    }

    @discardableResult
    public func stop() async -> PeekabooBridgeHostStopOutcome {
        self.lifecycleGeneration &+= 1
        if let stopTask = self.stopTask {
            return await stopTask.value
        }

        let stopTask = Task { [self] in
            await self.stopOnce()
        }
        self.stopTask = stopTask
        let outcome = await stopTask.value
        self.stopTask = nil
        return outcome
    }

    /// Waits for deferred request draining to release the socket lease after `stop()` retained ownership.
    public func waitUntilFullyStopped() async {
        await self.ownershipCleanupTask?.value
    }

    private func stopOnce() async -> PeekabooBridgeHostStopOutcome {
        if self.ownershipCleanupTask != nil {
            let snapshot = self.requestTracker.drainSnapshot
            return .ownershipRetained(
                pendingRequestCount: snapshot.count,
                oldestRequestAgeSeconds: snapshot.oldestAgeSeconds)
        }
        let browserHandoffMaintenanceTask = self.browserHandoffMaintenanceTask
        browserHandoffMaintenanceTask?.cancel()
        self.browserHandoffMaintenanceTask = nil
        self.requestTracker.stopAcceptingAndCancelAll()
        let acceptTask = self.acceptTask
        acceptTask?.cancel()
        self.acceptTask = nil
        let listenerReadiness = self.listenerReadiness
        listenerReadiness?.finishEvents()
        self.listenerReadiness = nil
        await acceptTask?.value
        listenerReadiness?.cancel()
        await listenerReadiness?.waitUntilCancelled()
        if self.listenFD != -1 {
            self.listenFD = -1
        }
        await self.connectionTracker.disconnectAll()
        // Catch a connection accepted between the first snapshot and listener shutdown.
        await self.connectionTracker.disconnectAll()
        self.requestTracker.stopAcceptingAndCancelAll()
        await self.connectionTracker.waitForIdle()
        self.startBrowserHandoffShutdownMaintenance()
        guard await waitForPeekabooBridgeRequestsToDrain(
            self.requestTracker,
            timeoutSeconds: self.requestDrainTimeoutSec)
        else {
            let snapshot = self.requestTracker.drainSnapshot
            let message = "Bridge ownership retained with \(snapshot.count) request(s) still running " +
                "after \(snapshot.oldestAgeSeconds)s"
            Self.logger.error("\(message, privacy: .public)")
            self.ownershipCleanupTask = Task { [self] in
                await self.requestTracker.waitForIdle()
                await browserHandoffMaintenanceTask?.value
                self.releaseRetainedOwnership()
            }
            return .ownershipRetained(
                pendingRequestCount: snapshot.count,
                oldestRequestAgeSeconds: snapshot.oldestAgeSeconds)
        }
        await browserHandoffMaintenanceTask?.value
        self.releaseOwnership()
        return .stopped
    }

    private func releaseRetainedOwnership() {
        self.releaseOwnership()
        self.ownershipCleanupTask = nil
    }

    private func releaseOwnership() {
        var canClearLeaseIdentity = self.socketIdentity == nil
        if let identity = self.socketIdentity {
            do {
                _ = try Self.removeOwnedSocket(
                    path: self.socketPath,
                    expectedIdentity: identity)
                canClearLeaseIdentity = true
            } catch {
                Self.logger.error(
                    """
                    Failed to remove bridge socket at \(self.socketPath, privacy: .private): \
                    \(error.localizedDescription, privacy: .private)
                    """)
            }
        }
        self.socketIdentity = nil
        self.operationReceiptAuthority = nil
        if self.leaseFD != -1 {
            if canClearLeaseIdentity {
                do {
                    try Self.clearLeaseIdentity(fd: self.leaseFD, path: self.socketPath)
                } catch {
                    Self.logger.error(
                        """
                        Failed to clear bridge lease at \(self.socketPath, privacy: .private): \
                        \(error.localizedDescription, privacy: .private)
                        """)
                }
            }
            flock(self.leaseFD, LOCK_UN)
            close(self.leaseFD)
            self.leaseFD = -1
        }
    }

    #if DEBUG
    func activeConnectionCountForTesting() async -> Int {
        await self.connectionTracker.count
    }

    func activeRequestCountForTesting() -> Int {
        self.requestTracker.activeCount
    }

    func activeBodyReadCountForTesting() -> Int {
        self.bodyReadLimiter.activeCount
    }

    func admissionRefusalCapacityForTesting() -> (active: Int, peak: Int, maximum: Int) {
        (
            active: self.admissionRefusalLimiter.activeCount,
            peak: self.admissionRefusalLimiter.peakActiveCount,
            maximum: self.admissionRefusalLimiter.maximumCount)
    }

    func acceptedConnectionCapacityForTesting() -> (active: Int, peak: Int, maximum: Int) {
        (
            active: self.acceptedConnectionLimiter.activeCount,
            peak: self.acceptedConnectionLimiter.peakActiveCount,
            maximum: self.acceptedConnectionLimiter.maximumCount)
    }

    func stopAcceptingRequestsForTesting() {
        self.requestTracker.stopAcceptingAndCancelAll()
    }

    func listenerReadinessNotificationCountForTesting() -> Int? {
        self.listenerReadiness?.notificationCountForTesting
    }

    var isRetainingOwnershipForRequestsForTesting: Bool {
        self.ownershipCleanupTask != nil
    }
    #endif

    private nonisolated static func acquireLease(path: String) throws -> SocketLease {
        let leasePath = "\(path).lock"
        var created = true
        var fd = open(
            leasePath,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        if fd < 0, errno == EEXIST {
            created = false
            fd = open(leasePath, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            if errno == ELOOP {
                throw PeekabooBridgeHostError.unsafeLeaseFile(path: leasePath)
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "open",
                path: leasePath,
                code: errno)
        }
        var leaseInfo = stat()
        guard fstat(fd, &leaseInfo) == 0 else {
            let code = errno
            close(fd)
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "fstat",
                path: leasePath,
                code: code)
        }
        guard (leaseInfo.st_mode & S_IFMT) == S_IFREG,
              leaseInfo.st_uid == geteuid(),
              leaseInfo.st_nlink == 1
        else {
            close(fd)
            throw PeekabooBridgeHostError.unsafeLeaseFile(path: leasePath)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK {
                throw PeekabooBridgeHostError.socketAlreadyOwned(path: path)
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "flock",
                path: leasePath,
                code: code)
        }

        let markerSnapshot: LeaseMarkerSnapshot
        do {
            markerSnapshot = try self.readLeaseMarker(fd: fd, path: leasePath)
        } catch {
            flock(fd, LOCK_UN)
            close(fd)
            throw error
        }
        if !created, case .invalid = markerSnapshot.state {
            flock(fd, LOCK_UN)
            close(fd)
            throw PeekabooBridgeHostError.unsafeLeaseFile(path: leasePath)
        }

        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            flock(fd, LOCK_UN)
            close(fd)
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "fchmod",
                path: leasePath,
                code: code)
        }

        let recordedIdentity: SocketIdentity? = switch markerSnapshot.state {
        case .empty, .incomplete, .invalid:
            nil
        case let .identity(identity):
            identity
        }
        return SocketLease(
            fd: fd,
            recordedIdentity: recordedIdentity)
    }

    private nonisolated static func makeListeningSocket(
        path: String,
        recoverableIdentity: SocketIdentity?,
        leaseFD: Int32) throws -> (Int32, SocketIdentity)
    {
        _ = try self.socketAddress(path: path)
        let recoverableStatus = try self.recoverableSocketStatus(
            path: path,
            recoverableIdentity: recoverableIdentity)

        let temporaryPath = try self.temporarySocketPath(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "socket",
                path: path,
                code: errno)
        }

        var boundIdentity: SocketIdentity?
        do {
            try PeekabooBridgeSocketIO.configureConnectedSocket(fd)
            let address = try self.socketAddress(path: temporaryPath)
            var localAddress = address
            let length = socklen_t(MemoryLayout.size(ofValue: localAddress))
            let bindResult = withUnsafePointer(to: &localAddress) {
                Darwin.bind(fd, UnsafePointer<sockaddr>(OpaquePointer($0)), length)
            }
            guard bindResult == 0 else {
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "bind",
                    path: temporaryPath,
                    code: errno)
            }

            guard let temporaryStatus = self.socketStatus(path: temporaryPath),
                  temporaryStatus.isSocket
            else {
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "lstat",
                    path: temporaryPath,
                    code: errno)
            }
            boundIdentity = temporaryStatus.identity

            guard chmod(temporaryPath, S_IRUSR | S_IWUSR) == 0 else {
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "chmod",
                    path: temporaryPath,
                    code: errno)
            }
            guard let permissionedStatus = self.socketStatus(path: temporaryPath),
                  permissionedStatus.isSocket,
                  permissionedStatus.identity == temporaryStatus.identity
            else {
                throw PeekabooBridgeHostError.socketAlreadyOwned(path: temporaryPath)
            }
            guard listen(fd, SOMAXCONN) == 0 else {
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "listen",
                    path: temporaryPath,
                    code: errno)
            }
            try self.publishSocket(
                temporaryPath: temporaryPath,
                finalPath: path,
                temporaryStatus: temporaryStatus,
                replacing: recoverableStatus)

            guard let publishedStatus = self.socketStatus(path: path),
                  publishedStatus.isSocket,
                  publishedStatus.identity == temporaryStatus.identity
            else {
                throw PeekabooBridgeHostError.socketAlreadyOwned(path: path)
            }
            try self.recordLeaseIdentity(
                temporaryStatus.identity,
                fd: leaseFD,
                path: path)
            return (fd, temporaryStatus.identity)
        } catch {
            try? self.clearLeaseIdentity(fd: leaseFD, path: path)
            if let boundIdentity {
                for candidate in [temporaryPath, path] {
                    _ = try? self.removeOwnedSocket(
                        path: candidate,
                        expectedIdentity: boundIdentity)
                }
            }
            close(fd)
            throw error
        }
    }

    private nonisolated static func recoverableSocketStatus(
        path: String,
        recoverableIdentity: SocketIdentity?) throws -> SocketStatus?
    {
        guard let status = self.socketStatus(path: path) else {
            let code = errno
            if code == ENOENT {
                return nil
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "lstat",
                path: path,
                code: code)
        }
        guard status.isSocket else {
            throw PeekabooBridgeHostError.socketPathIsNotSocket(path: path)
        }
        let canRecoverLegacySocket = recoverableIdentity == nil &&
            status.ownerUID == geteuid() &&
            self.legacySocketOwnerState(
                path: path,
                targetIdentity: status.identity,
                ownerUID: status.ownerUID) == .unheld
        guard status.identity == recoverableIdentity || canRecoverLegacySocket else {
            throw PeekabooBridgeHostError.socketAlreadyOwned(path: path)
        }
        return status
    }

    private nonisolated static func temporarySocketPath(for path: String) throws -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let directory = parent.isEmpty ? "." : parent
        let separatorBytes = directory == "/" ? 0 : 1
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let availableBytes = capacity - 1 - directory.utf8.count - separatorBytes
        guard availableBytes > 0 else {
            throw PeekabooBridgeHostError.socketPathTooLong(path: path)
        }

        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let filenameLength = min(16, availableBytes)
        let finalFilename = (path as NSString).lastPathComponent
        for _ in 0..<128 {
            let filename = String((0..<filenameLength).map { _ in alphabet.randomElement()! })
            guard filename != finalFilename else { continue }
            let candidate = (directory as NSString).appendingPathComponent(filename)
            guard self.socketStatus(path: candidate) == nil, errno == ENOENT else { continue }
            _ = try self.socketAddress(path: candidate)
            return candidate
        }

        throw PeekabooBridgeHostError.systemCallFailed(
            operation: "temporary socket path",
            path: path,
            code: EEXIST)
    }

    private nonisolated static func throwExistingSocketError(path: String) throws -> Never {
        guard let status = self.socketStatus(path: path) else {
            let code = errno
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "lstat",
                path: path,
                code: code)
        }
        guard status.isSocket else {
            throw PeekabooBridgeHostError.socketPathIsNotSocket(path: path)
        }
        throw PeekabooBridgeHostError.socketAlreadyOwned(path: path)
    }

    private nonisolated static func publishSocket(
        temporaryPath: String,
        finalPath: String,
        temporaryStatus: SocketStatus,
        replacing recoverableStatus: SocketStatus?) throws
    {
        guard let recoverableStatus else {
            let publishResult = renameatx_np(
                AT_FDCWD,
                temporaryPath,
                AT_FDCWD,
                finalPath,
                UInt32(RENAME_EXCL))
            guard publishResult == 0 else {
                let code = errno
                if code == EEXIST {
                    try self.throwExistingSocketError(path: finalPath)
                }
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "renameatx_np",
                    path: finalPath,
                    code: code)
            }
            return
        }

        let swapResult = renameatx_np(
            AT_FDCWD,
            temporaryPath,
            AT_FDCWD,
            finalPath,
            UInt32(RENAME_SWAP))
        if swapResult != 0 {
            let swapCode = errno
            if swapCode == ENOENT {
                let publishResult = renameatx_np(
                    AT_FDCWD,
                    temporaryPath,
                    AT_FDCWD,
                    finalPath,
                    UInt32(RENAME_EXCL))
                if publishResult == 0 {
                    return
                }
                let publishCode = errno
                if publishCode == EEXIST {
                    try self.throwExistingSocketError(path: finalPath)
                }
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "renameatx_np",
                    path: finalPath,
                    code: publishCode)
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "renameatx_np",
                path: finalPath,
                code: swapCode)
        }

        let publishedStatus = self.socketStatus(path: finalPath)
        let displacedStatus = self.socketStatus(path: temporaryPath)
        guard publishedStatus?.isSocket == true,
              publishedStatus?.identity == temporaryStatus.identity,
              displacedStatus == recoverableStatus
        else {
            let restoreResult = renameatx_np(
                AT_FDCWD,
                temporaryPath,
                AT_FDCWD,
                finalPath,
                UInt32(RENAME_SWAP))
            guard restoreResult == 0 else {
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "renameatx_np restore",
                    path: finalPath,
                    code: errno)
            }
            try self.throwExistingSocketError(path: finalPath)
        }

        guard unlink(temporaryPath) == 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "unlink quarantined socket",
                path: temporaryPath,
                code: errno)
        }
        self.logger.info(
            """
            Replaced stale bridge socket path=\(finalPath, privacy: .private) \
            inode=\(recoverableStatus.identity.inode, privacy: .public)
            """)
    }

    @discardableResult
    private nonisolated static func removeOwnedSocket(
        path: String,
        expectedIdentity: SocketIdentity) throws -> Bool
    {
        guard self.socketStatus(path: path) != nil else {
            let code = errno
            if code == ENOENT {
                return true
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "lstat",
                path: path,
                code: code)
        }

        let (placeholderPath, placeholderIdentity) = try self.createPlaceholder(for: path)
        var placeholderLocation: String? = placeholderPath
        defer {
            if let placeholderLocation,
               self.socketStatus(path: placeholderLocation)?.identity == placeholderIdentity
            {
                unlink(placeholderLocation)
            }
        }

        let swapResult = renameatx_np(
            AT_FDCWD,
            placeholderPath,
            AT_FDCWD,
            path,
            UInt32(RENAME_SWAP))
        guard swapResult == 0 else {
            let code = errno
            if code == ENOENT {
                return true
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "renameatx_np",
                path: path,
                code: code)
        }
        placeholderLocation = path

        guard self.socketStatus(path: placeholderPath)?.identity == expectedIdentity else {
            let restoreResult = renameatx_np(
                AT_FDCWD,
                placeholderPath,
                AT_FDCWD,
                path,
                UInt32(RENAME_SWAP))
            guard restoreResult == 0 else {
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "renameatx_np restore",
                    path: path,
                    code: errno)
            }
            placeholderLocation = placeholderPath
            return false
        }

        let cleanupPath = try self.temporarySocketPath(for: path)
        let movePlaceholderResult = renameatx_np(
            AT_FDCWD,
            path,
            AT_FDCWD,
            cleanupPath,
            UInt32(RENAME_EXCL))
        guard movePlaceholderResult == 0 else {
            let code = errno
            let restoreResult = renameatx_np(
                AT_FDCWD,
                placeholderPath,
                AT_FDCWD,
                path,
                UInt32(RENAME_SWAP))
            if restoreResult == 0 {
                placeholderLocation = placeholderPath
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "renameatx_np quarantine",
                path: path,
                code: code)
        }
        placeholderLocation = cleanupPath

        guard unlink(placeholderPath) == 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "unlink quarantined socket",
                path: placeholderPath,
                code: errno)
        }
        guard unlink(cleanupPath) == 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "unlink socket placeholder",
                path: cleanupPath,
                code: errno)
        }
        placeholderLocation = nil
        return true
    }

    private nonisolated static func createPlaceholder(
        for path: String) throws -> (path: String, identity: SocketIdentity)
    {
        for _ in 0..<128 {
            let placeholderPath = try self.temporarySocketPath(for: path)
            let fd = open(
                placeholderPath,
                O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR)
            if fd < 0, errno == EEXIST {
                continue
            }
            guard fd >= 0 else {
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "open placeholder",
                    path: placeholderPath,
                    code: errno)
            }
            close(fd)

            guard let status = self.socketStatus(path: placeholderPath),
                  !status.isSocket,
                  status.ownerUID == geteuid()
            else {
                unlink(placeholderPath)
                throw PeekabooBridgeHostError.unsafeLeaseFile(path: placeholderPath)
            }
            return (placeholderPath, status.identity)
        }

        throw PeekabooBridgeHostError.systemCallFailed(
            operation: "create placeholder",
            path: path,
            code: EEXIST)
    }

    private nonisolated static func socketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = path.withCString { strlcpy(&address.sun_path.0, $0, capacity) }
        guard copied < capacity else {
            throw PeekabooBridgeHostError.socketPathTooLong(path: path)
        }
        address.sun_len = UInt8(MemoryLayout.size(ofValue: address))
        return address
    }

    private nonisolated static func readLeaseMarker(fd: Int32, path: String) throws -> LeaseMarkerSnapshot {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "fstat",
                path: path,
                code: errno)
        }
        guard info.st_size > 0 else {
            return LeaseMarkerSnapshot(state: .empty)
        }
        guard info.st_size <= 64 * 1024 else {
            return LeaseMarkerSnapshot(state: .invalid)
        }

        var buffer = [UInt8](repeating: 0, count: Int(info.st_size))
        var bytesRead = 0
        while bytesRead < buffer.count {
            let result = buffer.withUnsafeMutableBytes { bytes in
                pread(
                    fd,
                    bytes.baseAddress!.advanced(by: bytesRead),
                    bytes.count - bytesRead,
                    off_t(bytesRead))
            }
            if result > 0 {
                bytesRead += result
                continue
            }
            if result == -1, errno == EINTR {
                continue
            }
            if result == 0 {
                return LeaseMarkerSnapshot(state: .invalid)
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "pread",
                path: path,
                code: errno)
        }

        guard let contents = String(bytes: buffer, encoding: .utf8) else {
            return LeaseMarkerSnapshot(state: .invalid)
        }

        var lastIdentity: SocketIdentity?
        var sawIncompleteRecord = false
        let records = contents.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, record) in records.enumerated() {
            if record.isEmpty {
                continue
            }
            if let identity = self.parseLeaseIdentity(record) {
                lastIdentity = identity
                continue
            }
            if index == records.indices.last, self.isIncompleteLeaseRecord(record) {
                sawIncompleteRecord = true
                continue
            }
            return LeaseMarkerSnapshot(state: .invalid)
        }
        if let lastIdentity {
            return LeaseMarkerSnapshot(state: .identity(lastIdentity))
        }
        return LeaseMarkerSnapshot(state: sawIncompleteRecord ? .incomplete : .empty)
    }

    private nonisolated static func parseLeaseIdentity(_ record: Substring) -> SocketIdentity? {
        let fields = record.split(whereSeparator: \.isWhitespace)
        guard fields.count == 3,
              fields[0] == Substring(self.leaseMarkerPrefix),
              let device = UInt64(fields[1]),
              let inode = UInt64(fields[2]),
              let convertedDevice = dev_t(exactly: device),
              let convertedInode = ino_t(exactly: inode)
        else {
            return nil
        }
        return SocketIdentity(device: convertedDevice, inode: convertedInode)
    }

    private nonisolated static func isIncompleteLeaseRecord(_ record: Substring) -> Bool {
        let prefix = Substring(self.leaseMarkerPrefix)
        if prefix.starts(with: record) {
            return true
        }
        guard record.hasPrefix(prefix) else { return false }

        let suffix = record.dropFirst(prefix.count)
        guard suffix.allSatisfy({ $0.isWhitespace || $0.isNumber }) else { return false }
        let fields = suffix.split(whereSeparator: \.isWhitespace)
        guard fields.count <= 2 else { return false }
        if let deviceField = fields.first {
            guard let device = UInt64(deviceField), dev_t(exactly: device) != nil else { return false }
        }
        if fields.count == 2 {
            guard let inode = UInt64(fields[1]), ino_t(exactly: inode) != nil else { return false }
        }
        return true
    }

    private nonisolated static func recordLeaseIdentity(
        _ identity: SocketIdentity,
        fd: Int32,
        path: String) throws
    {
        let marker = "\(self.leaseMarkerPrefix) \(UInt64(identity.device)) \(UInt64(identity.inode))\n"
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "fstat",
                path: "\(path).lock",
                code: errno)
        }
        guard info.st_size == 0 else {
            throw PeekabooBridgeHostError.unsafeLeaseFile(path: "\(path).lock")
        }

        let bytes = Array(marker.utf8)

        var written = 0
        while written < bytes.count {
            let result = bytes.withUnsafeBytes { buffer in
                pwrite(
                    fd,
                    buffer.baseAddress!.advanced(by: written),
                    bytes.count - written,
                    off_t(written))
            }
            if result > 0 {
                written += result
                continue
            }
            if result == -1, errno == EINTR {
                continue
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "pwrite",
                path: "\(path).lock",
                code: errno)
        }

        guard fsync(fd) == 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "fsync",
                path: "\(path).lock",
                code: errno)
        }
    }

    private nonisolated static func clearLeaseIdentity(fd: Int32, path: String) throws {
        guard ftruncate(fd, 0) == 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "ftruncate",
                path: "\(path).lock",
                code: errno)
        }
        guard fsync(fd) == 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "fsync",
                path: "\(path).lock",
                code: errno)
        }
    }

    private nonisolated static func socketStatus(path: String) -> SocketStatus? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return SocketStatus(
            identity: SocketIdentity(device: info.st_dev, inode: info.st_ino),
            mode: info.st_mode,
            ownerUID: info.st_uid)
    }

    private nonisolated static func legacySocketOwnerState(
        path: String,
        targetIdentity: SocketIdentity,
        ownerUID: uid_t) -> LegacySocketOwnerState
    {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return .indeterminate }

        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 64)
        let listedCount = proc_listallpids(
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard listedCount > 0, Int(listedCount) < pids.count else { return .indeterminate }

        var inspectionWasIncomplete = false
        for pid in pids.prefix(Int(listedCount)) where pid > 0 {
            guard let process = self.processMetadata(pid: pid) else {
                if kill(pid, 0) == 0 {
                    inspectionWasIncomplete = true
                }
                continue
            }
            guard process.ownerUID == ownerUID, process.status != UInt32(SZOMB) else { continue }

            let descriptorBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard descriptorBytes > 0 else {
                if let current = self.processMetadata(pid: pid),
                   current.ownerUID == ownerUID,
                   current.status != UInt32(SZOMB)
                {
                    inspectionWasIncomplete = true
                }
                continue
            }

            let descriptorCapacity = Int(descriptorBytes) / MemoryLayout<proc_fdinfo>.stride + 16
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: descriptorCapacity)
            let descriptorBufferBytes = Int32(descriptors.count * MemoryLayout<proc_fdinfo>.stride)
            let listedDescriptorBytes = proc_pidinfo(
                pid,
                PROC_PIDLISTFDS,
                0,
                &descriptors,
                descriptorBufferBytes)
            guard listedDescriptorBytes > 0 else {
                if let current = self.processMetadata(pid: pid),
                   current.ownerUID == ownerUID,
                   current.status != UInt32(SZOMB)
                {
                    inspectionWasIncomplete = true
                }
                continue
            }
            guard listedDescriptorBytes < descriptorBufferBytes else {
                inspectionWasIncomplete = true
                continue
            }

            let descriptorCount = Int(listedDescriptorBytes) / MemoryLayout<proc_fdinfo>.stride
            for descriptor in descriptors.prefix(descriptorCount)
                where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET
            {
                var socketInfo = socket_fdinfo()
                let socketInfoSize = Int32(MemoryLayout<socket_fdinfo>.stride)
                let socketInfoResult = proc_pidfdinfo(
                    pid,
                    descriptor.proc_fd,
                    PROC_PIDFDSOCKETINFO,
                    &socketInfo,
                    socketInfoSize)
                guard socketInfoResult == socketInfoSize else {
                    if self.processStillHasSocketDescriptor(pid: pid, fd: descriptor.proc_fd) != false {
                        inspectionWasIncomplete = true
                    }
                    continue
                }
                guard socketInfo.psi.soi_family == AF_UNIX,
                      socketInfo.psi.soi_kind == SOCKINFO_UN
                else {
                    continue
                }

                var address = socketInfo.psi.soi_proto.pri_un.unsi_addr.ua_sun
                let boundPath = withUnsafePointer(to: &address.sun_path.0) {
                    String(cString: $0)
                }
                if boundPath == path {
                    return .held
                }
                if boundPath.hasPrefix("/") {
                    if self.socketStatus(path: boundPath)?.identity == targetIdentity {
                        return .held
                    }
                    continue
                }

                if let currentDirectory = self.processCurrentDirectory(pid: pid) {
                    let baseURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
                    let resolvedPath = URL(
                        fileURLWithPath: boundPath,
                        relativeTo: baseURL).standardizedFileURL.path
                    if self.socketStatus(path: resolvedPath)?.identity == targetIdentity {
                        return .held
                    }
                }

                // The kernel retains a relative UNIX socket name but not the process's bind-time cwd.
                // If the process changed directories, matching the final component is the strongest safe
                // signal available. Treat it as incomplete inspection instead of deleting a possibly live socket.
                if (boundPath as NSString).lastPathComponent == (path as NSString).lastPathComponent {
                    inspectionWasIncomplete = true
                }
            }
        }
        return inspectionWasIncomplete ? .indeterminate : .unheld
    }

    private nonisolated static func processCurrentDirectory(pid: pid_t) -> String? {
        var pathInfo = proc_vnodepathinfo()
        let pathInfoSize = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let result = proc_pidinfo(
            pid,
            PROC_PIDVNODEPATHINFO,
            0,
            &pathInfo,
            pathInfoSize)
        guard result == pathInfoSize else { return nil }

        var path = pathInfo.pvi_cdir.vip_path
        return withUnsafePointer(to: &path.0) { pointer in
            let value = String(cString: pointer)
            return value.isEmpty ? nil : value
        }
    }

    private nonisolated static func processMetadata(pid: pid_t) -> ProcessMetadata? {
        var processInfo = proc_bsdinfo()
        let processInfoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let processInfoResult = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &processInfo,
            processInfoSize)
        if processInfoResult == processInfoSize {
            return ProcessMetadata(ownerUID: processInfo.pbi_uid, status: processInfo.pbi_status)
        }

        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kernelInfo = kinfo_proc()
        var kernelInfoSize = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(
            &mib,
            u_int(mib.count),
            &kernelInfo,
            &kernelInfoSize,
            nil,
            0)
        guard result == 0, kernelInfoSize == MemoryLayout<kinfo_proc>.stride else {
            return nil
        }
        return ProcessMetadata(
            ownerUID: kernelInfo.kp_eproc.e_ucred.cr_uid,
            status: UInt32(kernelInfo.kp_proc.p_stat))
    }

    private nonisolated static func processStillHasSocketDescriptor(pid: pid_t, fd: Int32) -> Bool? {
        let descriptorBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard descriptorBytes > 0 else {
            return self.processMetadata(pid: pid)?.status == UInt32(SZOMB) ? false : nil
        }

        let capacity = Int(descriptorBytes) / MemoryLayout<proc_fdinfo>.stride + 16
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let descriptorBufferBytes = Int32(descriptors.count * MemoryLayout<proc_fdinfo>.stride)
        let listedBytes = proc_pidinfo(
            pid,
            PROC_PIDLISTFDS,
            0,
            &descriptors,
            descriptorBufferBytes)
        guard listedBytes > 0, listedBytes < descriptorBufferBytes else {
            return self.processMetadata(pid: pid)?.status == UInt32(SZOMB) ? false : nil
        }

        let count = Int(listedBytes) / MemoryLayout<proc_fdinfo>.stride
        return descriptors.prefix(count).contains {
            $0.proc_fd == fd && $0.proc_fdtype == PROX_FDTYPE_SOCKET
        }
    }
}
