import CoreGraphics
import Darwin
import Foundation
import PeekabooFoundation
@preconcurrency import ScreenCaptureKit

enum ScreenCaptureKitCaptureGate {
    static let defaultExclusiveWaitNanoseconds: UInt64 = 8_000_000_000

    @TaskLocal private static var isInsideCaptureOperation = false
    @TaskLocal private static var captureTransactionUsage: CaptureTransactionUsage?
    @TaskLocal static var processOwnerClaimOverride:
        (@MainActor @Sendable () throws -> ScreenCaptureKitOwnerLease.OwnerReceipt)?
    @TaskLocal static var postCaptureSettleOverride: (@MainActor @Sendable () async -> Void)?
    private static let processOwnerLease = Result { try ScreenCaptureKitOwnerLease() }
    @MainActor private static let captureCoordinator = ScreenCaptureKitOperationCoordinator(
        lockFilePath: (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("boo.peekaboo.sckit-capture.lock"))

    @discardableResult
    @MainActor
    static func requireProcessOwner(
        operationName: String) throws -> ScreenCaptureKitOwnerLease.OwnerReceipt
    {
        do {
            if let processOwnerClaimOverride {
                return try processOwnerClaimOverride()
            }
            return try self.processOwnerLease.get().claim().receipt
        } catch let error as ScreenCaptureKitOwnerLease.LeaseError {
            throw self.captureError(for: error, operationName: operationName)
        } catch {
            throw OperationError.captureFailed(
                reason: "ScreenCaptureKit owner setup failed before \(operationName): " +
                    "\(error.localizedDescription). No ScreenCaptureKit operation was dispatched.")
        }
    }

    @MainActor
    static func withProcessOwner<T: Sendable>(
        operationName: String,
        operation: () async throws -> T) async throws -> T
    {
        try self.requireProcessOwner(operationName: operationName)
        return try await operation()
    }

    @MainActor
    static func runOwnedOperation<T: Sendable>(
        seconds: TimeInterval,
        operationName: String,
        operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T
    {
        try await self.withProcessOwner(operationName: operationName) {
            try await self.captureCoordinator.run(seconds: seconds, operationName: operationName) {
                try self.requireProcessOwner(operationName: operationName)
                self.captureTransactionUsage?.recordScreenCaptureKitUse()
                return try await operation()
            }
        }
    }

    @MainActor
    static var isQuarantined: Bool {
        self.captureCoordinator.isQuarantined
    }

    @MainActor
    static func withExclusiveCaptureOperation<T: Sendable>(
        operationName: String,
        exclusiveWaitNanoseconds: UInt64 = Self.defaultExclusiveWaitNanoseconds,
        _ operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T
    {
        guard !self.isInsideCaptureOperation else {
            return try await operation()
        }

        // Hold a broader cross-process lock for the capture transaction. Per-call SCK locks are not enough
        // because interleaving shareable-content reads and screenshot calls can leave replayd/SCK wedged.
        let fd = self.openExclusiveOperationLockDescriptor()
        guard fd >= 0 else {
            return try await operation()
        }
        defer { close(fd) }

        let deadline = DispatchTime.now().uptimeNanoseconds + exclusiveWaitNanoseconds
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                return try await operation()
            }

            try Task.checkCancellation()
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                throw OperationError.captureFailed(
                    reason: "Timed out waiting for the exclusive ScreenCaptureKit " +
                        "operation lock before \(operationName).")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        defer { flock(fd, LOCK_UN) }

        let usage = CaptureTransactionUsage()
        return try await self.$captureTransactionUsage.withValue(usage) {
            try await self.$isInsideCaptureOperation.withValue(true) {
                do {
                    let value = try await operation()
                    await self.settleAfterScreenCaptureKitUseIfNeeded(usage)
                    return value
                } catch {
                    await self.settleAfterScreenCaptureKitUseIfNeeded(usage)
                    throw error
                }
            }
        }
    }

    static func openExclusiveOperationLockDescriptor() -> Int32 {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("boo.peekaboo.sckit-operation.lock")
        // Agent actions can spawn long-lived children while this lock is held. Set close-on-exec atomically so an
        // abrupt owner exit cannot leave its capture transaction pinned by an inherited child descriptor.
        return open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    }

    @MainActor
    private static func settleAfterScreenCaptureKitUseIfNeeded(_ usage: CaptureTransactionUsage) async {
        guard usage.usedScreenCaptureKit else { return }
        // replayd can report transient TCC/capture failures when another CLI grabs SCK immediately after a
        // screenshot completes. Keep the transaction lock briefly only when this transaction entered SCK.
        if let postCaptureSettleOverride {
            await postCaptureSettleOverride()
        } else {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @MainActor
    static func captureImage(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration) async throws -> CGImage
    {
        try await self.runOwnedOperation(seconds: 3.0, operationName: "SCScreenshotManager.captureImage") {
            try await ScreenCaptureKitCallbackBridge<CGImage>.wait { completion in
                SCScreenshotManager.captureImage(
                    contentFilter: contentFilter,
                    configuration: configuration)
                { image, error in
                    if let image {
                        completion(.success(image))
                    } else {
                        completion(.failure(error ?? OperationError.captureFailed(
                            reason: "SCScreenshotManager returned neither an image nor an error")))
                    }
                }
            }
        }
    }

    @MainActor
    static func currentShareableContent() async throws -> SCShareableContent {
        try await self.runOwnedOperation(seconds: 5.0, operationName: "SCShareableContent.current") {
            try await SCShareableContent.current
        }
    }

    @MainActor
    static func shareableContent(
        excludingDesktopWindows: Bool,
        onScreenWindowsOnly: Bool) async throws -> SCShareableContent
    {
        try await self.runOwnedOperation(
            seconds: 5.0,
            operationName: "SCShareableContent.excludingDesktopWindows")
        {
            try await SCShareableContent.excludingDesktopWindows(
                excludingDesktopWindows,
                onScreenWindowsOnly: onScreenWindowsOnly)
        }
    }

    private static func captureError(
        for error: ScreenCaptureKitOwnerLease.LeaseError,
        operationName: String) -> PeekabooError
    {
        if case let .ownedByAnotherProcess(_, receipt) = error {
            return OperationError.captureFailed(
                reason: "ScreenCaptureKit is already owned by another Peekaboo process " +
                    "(PID \(receipt.processIdentifier), generation \(receipt.processStartIdentity)). " +
                    "Use the active Bridge host, verify and stop that exact owner before retrying, " +
                    "or explicitly choose the classic capture engine. No ScreenCaptureKit operation was dispatched.")
        }
        return OperationError.captureFailed(
            reason: "ScreenCaptureKit owner validation failed before \(operationName): " +
                "\(error.localizedDescription). No ScreenCaptureKit operation was dispatched.")
    }
}

@MainActor
private final class CaptureTransactionUsage {
    private(set) var usedScreenCaptureKit = false

    func recordScreenCaptureKitUse() {
        self.usedScreenCaptureKit = true
    }
}

/// ScreenCaptureKit has shipped completion paths that never call back. The outer operation coordinator owns
/// that abandoned lifetime and quarantines the SCK lane until a late callback arrives. An unsafe continuation is
/// intentional here: unlike the SDK-generated checked async overlay, process teardown cannot emit a misleading
/// continuation-leak diagnostic for framework work that Peekaboo has already timed out and quarantined.
enum ScreenCaptureKitCallbackBridge<Value: Sendable> {
    static func wait(
        _ start: @escaping @Sendable (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void) async throws
        -> Value
    {
        try await withUnsafeThrowingContinuation { continuation in
            start { result in
                continuation.resume(with: result)
            }
        }
    }
}

/// Owns the complete lifetime of one ScreenCaptureKit call, including an SCK call that ignores caller cancellation.
/// A timed-out call quarantines this coordinator until that exact call finishes, preventing orphan accumulation.
@MainActor
final class ScreenCaptureKitOperationCoordinator {
    private enum LeasePhase: Equatable {
        case acquiring
        case running
        case quarantined
    }

    private final class Lease {
        let id = UUID()
        let operationName: String
        var phase: LeasePhase = .acquiring
        var fileDescriptor: Int32?
        var ownsFileLock = false
        var operationTask: Task<Void, Never>?

        init(operationName: String) {
            self.operationName = operationName
        }
    }

    private let lockFilePath: String?
    private var activeLease: Lease?

    init(lockFilePath: String?) {
        self.lockFilePath = lockFilePath
    }

    func run<T: Sendable>(
        seconds: TimeInterval,
        operationName: String,
        operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T
    {
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(seconds, 0)))
        let lease = try await self.reserveLease(
            operationName: operationName,
            deadline: deadline,
            timeoutSeconds: seconds)

        do {
            try await self.acquireCrossProcessLock(
                for: lease,
                deadline: deadline,
                timeoutSeconds: seconds)
            try Self.checkDeadline(
                deadline,
                operationName: operationName,
                timeoutSeconds: seconds)
        } catch {
            self.release(lease)
            throw error
        }

        return try await self.runOwnedOperation(
            lease: lease,
            deadline: deadline,
            timeoutSeconds: seconds,
            operationName: operationName,
            operation: operation)
    }

    var isQuarantined: Bool {
        self.activeLease?.phase == .quarantined
    }

    private func reserveLease(
        operationName: String,
        deadline: ContinuousClock.Instant,
        timeoutSeconds: TimeInterval) async throws -> Lease
    {
        while let activeLease = self.activeLease {
            if activeLease.phase == .quarantined {
                throw OperationError.captureFailed(
                    reason: "ScreenCaptureKit is quarantined after an abandoned \(activeLease.operationName) call")
            }

            try Task.checkCancellation()
            try Self.checkDeadline(
                deadline,
                operationName: operationName,
                timeoutSeconds: timeoutSeconds)
            try await Self.sleepBeforeRetry(deadline: deadline)
        }

        try Task.checkCancellation()
        try Self.checkDeadline(
            deadline,
            operationName: operationName,
            timeoutSeconds: timeoutSeconds)
        let lease = Lease(operationName: operationName)
        self.activeLease = lease
        return lease
    }

    private func acquireCrossProcessLock(
        for lease: Lease,
        deadline: ContinuousClock.Instant,
        timeoutSeconds: TimeInterval) async throws
    {
        guard let lockFilePath else { return }

        let fd = open(lockFilePath, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            // The file lock is a defensive second layer; the in-process lease still protects this host.
            return
        }
        lease.fileDescriptor = fd

        while true {
            try Task.checkCancellation()
            try Self.checkDeadline(
                deadline,
                operationName: lease.operationName,
                timeoutSeconds: timeoutSeconds,
                waitingForCrossProcessGate: true)

            guard flock(fd, LOCK_EX | LOCK_NB) != 0 else {
                lease.ownsFileLock = true
                return
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                close(fd)
                lease.fileDescriptor = nil
                return
            }

            try await Self.sleepBeforeRetry(deadline: deadline)
        }
    }

    private func runOwnedOperation<T: Sendable>(
        lease: Lease,
        deadline: ContinuousClock.Instant,
        timeoutSeconds: TimeInterval,
        operationName: String,
        operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T
    {
        let race = ScreenCaptureKitTimeoutRace<T>()
        let leaseID = lease.id

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard race.setContinuation(continuation) else {
                    self.release(lease)
                    return
                }

                let operationTask = Task { @MainActor in
                    guard race.claimOperation() else {
                        self.release(lease)
                        return
                    }
                    lease.phase = .running

                    let result: Result<T, any Error>
                    do {
                        let value = try await operation()
                        result = .success(value)
                    } catch {
                        result = .failure(error)
                    }

                    // The framework call is truly over. Only now may another SCK call enter this host or process.
                    self.release(lease)
                    race.resume(result)
                }
                lease.operationTask = operationTask

                let timeoutTask = Task { @MainActor in
                    do {
                        let now = ContinuousClock.now
                        if now < deadline {
                            try await Task.sleep(for: now.duration(to: deadline))
                        }
                    } catch {
                        return
                    }
                    if race.resume(.failure(OperationError.timeout(
                        operation: operationName,
                        duration: timeoutSeconds)))
                    {
                        self.quarantineIfRunning(lease)
                    }
                }

                race.setTimeoutTask(timeoutTask)
            }
        } onCancel: {
            if race.cancel() {
                Task { @MainActor in
                    self.quarantineIfRunning(id: leaseID)
                }
            }
        }
    }

    private func quarantineIfRunning(_ lease: Lease) {
        guard self.activeLease === lease, lease.phase == .running else { return }
        lease.phase = .quarantined
    }

    private func quarantineIfRunning(id: UUID) {
        guard let lease = self.activeLease, lease.id == id else { return }
        self.quarantineIfRunning(lease)
    }

    private func release(_ lease: Lease) {
        guard self.activeLease === lease else { return }

        if lease.ownsFileLock, let fd = lease.fileDescriptor {
            flock(fd, LOCK_UN)
        }
        if let fd = lease.fileDescriptor {
            close(fd)
        }
        lease.operationTask = nil
        lease.fileDescriptor = nil
        lease.ownsFileLock = false
        self.activeLease = nil
    }

    private nonisolated static func checkDeadline(
        _ deadline: ContinuousClock.Instant,
        operationName: String,
        timeoutSeconds: TimeInterval,
        waitingForCrossProcessGate: Bool = false) throws
    {
        guard ContinuousClock.now < deadline else {
            let operation = waitingForCrossProcessGate
                ? "\(operationName) waiting for the ScreenCaptureKit gate; another process may be quarantined"
                : operationName
            throw OperationError.timeout(operation: operation, duration: timeoutSeconds)
        }
    }

    private nonisolated static func sleepBeforeRetry(deadline: ContinuousClock.Instant) async throws {
        let now = ContinuousClock.now
        guard now < deadline else { return }
        try await Task.sleep(for: min(now.duration(to: deadline), .milliseconds(10)))
    }
}

final class ScreenCaptureKitTimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var terminalResult: Result<T, any Error>?
    private var didFinish = false
    private var operationStarted = false

    /// Returns false when cancellation or another terminal result arrived before installation.
    func setContinuation(_ continuation: CheckedContinuation<T, any Error>) -> Bool {
        let terminalResult = self.lock.withLock { () -> Result<T, any Error>? in
            if let terminalResult = self.terminalResult {
                return terminalResult
            }
            self.continuation = continuation
            return nil
        }
        if let terminalResult {
            continuation.resume(with: terminalResult)
            return false
        }
        return true
    }

    func claimOperation() -> Bool {
        self.lock.withLock {
            guard !self.didFinish, !self.operationStarted else { return false }
            self.operationStarted = true
            return true
        }
    }

    func setTimeoutTask(_ timeoutTask: Task<Void, Never>) {
        var shouldCancelTimeout = false
        self.lock.withLock {
            shouldCancelTimeout = self.didFinish
            if !self.didFinish {
                self.timeoutTask = timeoutTask
            }
        }

        if shouldCancelTimeout {
            timeoutTask.cancel()
        }
    }

    /// Returns true only when this result won the caller-facing race.
    @discardableResult
    func resume(_ result: Result<T, any Error>) -> Bool {
        let continuation: CheckedContinuation<T, any Error>?
        let timeoutTask: Task<Void, Never>?

        self.lock.lock()
        guard !self.didFinish else {
            self.lock.unlock()
            return false
        }

        self.didFinish = true
        self.terminalResult = result
        continuation = self.continuation
        timeoutTask = self.timeoutTask
        self.continuation = nil
        self.timeoutTask = nil
        self.lock.unlock()

        timeoutTask?.cancel()
        continuation?.resume(with: result)
        return true
    }

    @discardableResult
    func cancel() -> Bool {
        self.resume(.failure(CancellationError()))
    }
}
