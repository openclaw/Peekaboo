import Darwin
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct ClipboardPasteTransactionGateTests {
    @Test
    func `Process start identity distinguishes a live process from an invalid PID`() {
        #expect(ClipboardPasteTransactionGate.processStartIdentity(getpid()) != nil)
        #expect(ClipboardPasteTransactionGate.processStartIdentity(-1) == nil)
    }

    @Test
    @MainActor
    func `Transaction waits for an independently held process lock`() async throws {
        let fixture = try self.makeLockFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let heldFD = try await self.holdPasteTransactionLock(lockPath: fixture.path)
        var lockHeld = true
        defer {
            if lockHeld {
                flock(heldFD, LOCK_UN)
            }
            close(heldFD)
        }

        var operationRan = false
        let transaction = Task { @MainActor in
            try await ClipboardPasteTransactionGate.withExclusiveTransaction(lockPath: fixture.path) {
                operationRan = true
                return 42
            }
        }

        try await Task.sleep(for: .milliseconds(75))
        #expect(operationRan == false)

        #expect(flock(heldFD, LOCK_UN) == 0)
        lockHeld = false

        #expect(try await transaction.value == 42)
        #expect(operationRan)
    }

    @Test
    @MainActor
    func `Processes with different temporary directories contend on the same private lock`() async throws {
        let fixture = try self.makeLockFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let childTemporaryDirectory = fixture.root.appendingPathComponent("child-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: childTemporaryDirectory, withIntermediateDirectories: true)

        #expect(!ClipboardPasteTransactionGate.defaultLockPath.hasPrefix(NSTemporaryDirectory()))
        #expect(ClipboardPasteTransactionGate.defaultLockPath.hasSuffix(
            "/Library/Application Support/Peekaboo/clipboard-paste-transaction.lock"))

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = [
            "-MFcntl=:flock,O_CREAT,O_RDWR",
            "-MIO::Handle",
            "-e",
            #"my $p = $ARGV[0]; "# +
                #"sysopen(my $f, $p, O_CREAT|O_RDWR, 0600) or die $!; flock($f, LOCK_EX) or die $!; "# +
                #"STDOUT->autoflush(1); print "locked\n"; <STDIN>;"#,
            fixture.path,
        ]
        child.environment = ["TMPDIR": childTemporaryDirectory.path]
        let childInput = Pipe()
        let childOutput = Pipe()
        child.standardInput = childInput
        child.standardOutput = childOutput
        try child.run()
        defer {
            try? childInput.fileHandleForWriting.close()
            if child.isRunning {
                child.terminate()
            }
            child.waitUntilExit()
        }
        let readiness = try #require(try childOutput.fileHandleForReading.read(upToCount: 7))
        #expect(readiness == Data("locked\n".utf8))

        var operationRan = false
        let transaction = Task { @MainActor in
            try await ClipboardPasteTransactionGate.withExclusiveTransaction(lockPath: fixture.path) {
                operationRan = true
                return 42
            }
        }
        try await Task.sleep(for: .milliseconds(75))
        #expect(operationRan == false)

        try childInput.fileHandleForWriting.close()
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
        #expect(try await transaction.value == 42)
        #expect(operationRan)
    }

    @Test
    @MainActor
    func `Held lock wait fails at the deadline and never runs the transaction`() async throws {
        let fixture = try self.makeLockFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let heldFD = try await self.holdPasteTransactionLock(lockPath: fixture.path)
        defer {
            flock(heldFD, LOCK_UN)
            close(heldFD)
        }

        var operationRan = false
        let clock = ContinuousClock()
        let started = clock.now
        let failure = await #expect(throws: DesktopActionFailure.self) {
            try await ClipboardPasteTransactionGate.withExclusiveTransaction(
                lockPath: fixture.path,
                lockWait: .milliseconds(80))
            {
                operationRan = true
            }
        }
        try self.requireLockTimeout(failure, lockPath: fixture.path)
        let elapsed = clock.now - started
        #expect(elapsed >= .milliseconds(60))
        #expect(elapsed < .seconds(2))
        #expect(operationRan == false)
    }

    @Test(arguments: [Duration.zero, .milliseconds(1)])
    @MainActor
    func `Late in-process admission refuses before opening the lock`(lateness: Duration) async throws {
        let fixture = try self.makeLockFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let clock = PasteGateTestClock()
        let retryStarted = AsyncStream<Void>.makeStream()
        let holderFinished = AsyncStream<Void>.makeStream()
        defer {
            retryStarted.continuation.finish()
            holderFinished.continuation.finish()
        }
        var waiter: Task<Void, any Error>?
        var operationRan = false
        var retryCount = 0

        try await ClipboardPasteTransactionGate.withExclusiveTransaction(
            lockPath: fixture.root.appendingPathComponent("holder.lock").path)
        {
            waiter = Task { @MainActor in
                defer { retryStarted.continuation.finish() }
                try await ClipboardPasteTransactionGate.withExclusiveTransaction(
                    lockPath: fixture.path,
                    now: { clock.now },
                    retrySleep: {
                        retryCount += 1
                        clock.advance(by: .seconds(15) + lateness)
                        retryStarted.continuation.yield()
                        for await _ in holderFinished.stream {}
                    },
                    operation: {
                        operationRan = true
                    })
            }
            var retries = retryStarted.stream.makeAsyncIterator()
            _ = await retries.next()
        }
        holderFinished.continuation.finish()
        let transaction = try #require(waiter)
        let failure = await #expect(throws: DesktopActionFailure.self) {
            try await transaction.value
        }
        #expect(retryCount == 1)
        #expect(!operationRan)
        #expect(!FileManager.default.fileExists(atPath: fixture.path))
        try self.requireLockTimeout(failure, lockPath: fixture.path)
        try await self.requireLaterAdmission(lockPath: fixture.path, clock: clock)
    }

    @Test(arguments: [Duration.zero, .milliseconds(1)])
    @MainActor
    func `Late file-lock admission refuses and releases both gates`(lateness: Duration) async throws {
        let fixture = try self.makeLockFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let heldFD = try await self.holdPasteTransactionLock(lockPath: fixture.path)
        var lockHeld = true
        defer {
            if lockHeld {
                flock(heldFD, LOCK_UN)
            }
            close(heldFD)
        }
        let clock = PasteGateTestClock()
        var operationRan = false
        var retryCount = 0

        let failure = await #expect(throws: DesktopActionFailure.self) {
            try await ClipboardPasteTransactionGate.withExclusiveTransaction(
                lockPath: fixture.path,
                now: { clock.now },
                retrySleep: {
                    retryCount += 1
                    clock.advance(by: .seconds(15) + lateness)
                    if lockHeld {
                        guard flock(heldFD, LOCK_UN) == 0 else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        lockHeld = false
                    }
                },
                operation: {
                    operationRan = true
                })
        }
        #expect(retryCount == 1)
        #expect(!lockHeld)
        #expect(!operationRan)
        try self.requireLockTimeout(failure, lockPath: fixture.path)
        try await self.requireLaterAdmission(lockPath: fixture.path, clock: clock)
    }

    @Test
    @MainActor
    func `Cancellation before admission does not create the lock`() async throws {
        let fixture = try self.makeLockFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var operationRan = false
        let transaction = Task { @MainActor in
            try await ClipboardPasteTransactionGate.withExclusiveTransaction(lockPath: fixture.path) {
                operationRan = true
            }
        }
        transaction.cancel()
        await #expect(throws: CancellationError.self) {
            try await transaction.value
        }
        #expect(!operationRan)
        #expect(!FileManager.default.fileExists(atPath: fixture.path))
        try await self.requireLaterAdmission(lockPath: fixture.path, clock: PasteGateTestClock())
    }

    @Test
    @MainActor
    func `Admitted transaction can outlive its lock wait budget`() async throws {
        let fixture = try self.makeLockFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let clock = PasteGateTestClock()
        let result = try await ClipboardPasteTransactionGate.withExclusiveTransaction(
            lockPath: fixture.path,
            now: { clock.now },
            operation: {
                clock.advance(by: .seconds(20))
                return 42
            })
        #expect(result == 42)
        try await self.requireLaterAdmission(lockPath: fixture.path, clock: clock)
    }

    @Test
    @MainActor
    func `Lock timeout releases a snapshot mutation lease without running the body`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-paste-lease-refusal-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let lockPath = root.appendingPathComponent("clipboard-paste-transaction.lock").path
        defer {
            if FileManager.default.fileExists(atPath: root.path) {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let snapshots = InMemorySnapshotManager()
        let snapshotID = try await snapshots.createSnapshot()
        let clock = PasteGateTestClock()
        var operationRan = false
        let failure = await #expect(throws: DesktopActionFailure.self) {
            try await snapshots.withSnapshotMutation(
                snapshotId: snapshotID,
                operation: {
                    try await ClipboardPasteTransactionGate.withExclusiveTransaction(
                        lockPath: lockPath,
                        lockWait: .zero,
                        now: { clock.now },
                        operation: {
                            operationRan = true
                        })
                },
                outcome: { _ in nil })
        }
        try self.requireLockTimeout(failure, lockPath: lockPath)
        #expect(!operationRan)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let lease = try await snapshots.beginSnapshotMutation(snapshotId: snapshotID)
        try await snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    @MainActor
    func `Admitted operation errors retain their original identity`() async throws {
        let fixture = try self.makeLockFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var operationRan = false
        let error = await #expect(throws: PasteGateFixtureError.self) {
            let _: Void = try await ClipboardPasteTransactionGate.withExclusiveTransaction(lockPath: fixture.path) {
                operationRan = true
                throw PasteGateFixtureError.operationFailed
            }
        }
        #expect(error == .operationFailed)
        #expect(operationRan)
        try await self.requireLaterAdmission(lockPath: fixture.path, clock: PasteGateTestClock())
    }

    @Test
    @MainActor
    func `Cancellation while waiting never runs the transaction`() async throws {
        let fixture = try self.makeLockFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let heldFD = try await self.holdPasteTransactionLock(lockPath: fixture.path)
        defer {
            flock(heldFD, LOCK_UN)
            close(heldFD)
        }

        var operationRan = false
        let transaction = Task { @MainActor in
            try await ClipboardPasteTransactionGate.withExclusiveTransaction(lockPath: fixture.path) {
                operationRan = true
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        transaction.cancel()
        await #expect(throws: CancellationError.self) {
            try await transaction.value
        }
        #expect(operationRan == false)
    }

    @Test
    @MainActor
    func `Lock open failure is actionable and never runs the transaction`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-clipboard-gate-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let targetURL = root.appendingPathComponent("target")
        let lockURL = root.appendingPathComponent("lock")
        #expect(FileManager.default.createFile(atPath: targetURL.path, contents: Data()))
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: targetURL)

        var operationRan = false
        do {
            _ = try await ClipboardPasteTransactionGate.withExclusiveTransaction(lockPath: lockURL.path) {
                operationRan = true
            }
            Issue.record("Expected the symbolic lock path to fail closed")
        } catch let error as ClipboardPasteTransactionGate.GateError {
            switch error {
            case let .systemCall(operation, path, code):
                #expect(operation == "open")
                #expect(path == lockURL.path)
                #expect(code == ELOOP)
                #expect(error.localizedDescription.contains("Clipboard paste transaction lock failed"))
            case .fileSystem, .unsafeDirectory, .unsafeLockFile, .lockTimeout:
                Issue.record("Expected lock-file symlink rejection from open")
            }
        }
        #expect(operationRan == false)
    }

    @Test
    @MainActor
    func `Unsafe lock directory symlink fails closed`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-clipboard-gate-dir-tests-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: destination)
        defer { try? FileManager.default.removeItem(at: root) }

        var operationRan = false
        await #expect(throws: ClipboardPasteTransactionGate.GateError.self) {
            try await ClipboardPasteTransactionGate.withExclusiveTransaction(
                lockPath: linkedDirectory.appendingPathComponent("lock").path)
            {
                operationRan = true
            }
        }
        #expect(operationRan == false)
    }

    @Test
    @MainActor
    func `Transaction lock is a private current-user regular file`() async throws {
        let fixture = try self.makeLockFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await ClipboardPasteTransactionGate.withExclusiveTransaction(lockPath: fixture.path) {}

        var fileInfo = stat()
        #expect(lstat(fixture.path, &fileInfo) == 0)
        #expect(fileInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
        #expect(fileInfo.st_uid == geteuid())
        #expect(fileInfo.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0)
        #expect(fileInfo.st_mode & mode_t(S_IRUSR | S_IWUSR) == mode_t(S_IRUSR | S_IWUSR))
    }

    @Test
    func `Restore delay cap maps huge values onto 10s without sleeping them`() {
        #expect(ClipboardPasteTransactionGate.maximumRestoreDelayMilliseconds == 10000)
        #expect(ClipboardPasteTransactionGate.cappedRestoreDelayMilliseconds(3_600_000) == 10000)
        #expect(ClipboardPasteTransactionGate.cappedRestoreDelayMilliseconds(10001) == 10000)
        #expect(ClipboardPasteTransactionGate.cappedRestoreDelayMilliseconds(10000) == 10000)
        #expect(ClipboardPasteTransactionGate.cappedRestoreDelayMilliseconds(150) == 150)
        #expect(ClipboardPasteTransactionGate.cappedRestoreDelayMilliseconds(0) == 0)
        #expect(ClipboardPasteTransactionGate.cappedRestoreDelayMilliseconds(-1) == 0)
        #expect(
            ClipboardPasteTransactionGate.pasteConsumptionSleepDuration(milliseconds: 3_600_000) ==
                .milliseconds(10000))
        #expect(ClipboardPasteTransactionGate.pasteConsumptionSleepDuration(milliseconds: 0) == nil)
        #expect(ClipboardPasteTransactionGate.pasteConsumptionSleepDuration(milliseconds: -50) == nil)
    }

    @Test
    func `Huge restore delay wait returns within the 10s cap`() async {
        let clock = ContinuousClock()
        let started = clock.now
        await ClipboardPasteTransactionGate.waitForPasteConsumption(milliseconds: 60000)
        let elapsed = clock.now - started
        #expect(elapsed >= .seconds(9))
        #expect(elapsed < .seconds(12))
    }

    @Test
    func `Zero restore delay returns immediately`() async {
        let clock = ContinuousClock()
        let started = clock.now
        await ClipboardPasteTransactionGate.waitForPasteConsumption(milliseconds: 0)
        #expect(clock.now - started < .milliseconds(100))
    }

    @Test
    func `Paste consumption wait ignores cancellation during the capped settle`() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let wait = Task {
            await ClipboardPasteTransactionGate.waitForPasteConsumption(milliseconds: 180)
        }
        try await Task.sleep(for: .milliseconds(20))
        wait.cancel()
        await wait.value
        #expect(clock.now - started >= .milliseconds(140))
        #expect(clock.now - started < .milliseconds(1000))
    }

    private func requireLockTimeout(_ failure: DesktopActionFailure?, lockPath: String) throws {
        let failure = try #require(failure)
        #expect(failure.standardErrorCode == .timeout)
        #expect(failure.standardErrorCode?.rawValue == "TIMEOUT")
        let message = ClipboardPasteTransactionGate.GateError.lockTimeout(path: lockPath).localizedDescription
        #expect(failure.message == message)
        #expect(failure.outcome.state == .refused)
        #expect(failure.outcome.refusalReason == .targetUnavailable)
        #expect(failure.outcome.dispatchState == .none)
        #expect(failure.outcome.projection.mutationDispatched == false)
        #expect(failure.outcome.projection.retrySafe)
        #expect(failure.outcome.projection.requiresFreshObservation == false)
    }

    @MainActor
    private func requireLaterAdmission(lockPath: String, clock: PasteGateTestClock) async throws {
        let result = try await ClipboardPasteTransactionGate.withExclusiveTransaction(
            lockPath: lockPath,
            lockWait: .milliseconds(80),
            now: { clock.now },
            retrySleep: { clock.advance(by: .milliseconds(10)) },
            operation: { 42 })
        #expect(result == 42)
    }

    private func makeLockFixture() throws -> (root: URL, path: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-clipboard-gate-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: S_IRWXU)])
        return (root, root.appendingPathComponent("clipboard-paste-transaction.lock").path)
    }

    private func holdPasteTransactionLock(lockPath: String) async throws -> Int32 {
        try await ClipboardPasteTransactionGate.withExclusiveTransaction(lockPath: lockPath) {}
        let fd = open(
            lockPath,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        return fd
    }
}

private enum PasteGateFixtureError: Error, Equatable {
    case operationFailed
}

@MainActor
private final class PasteGateTestClock {
    private(set) var now = ContinuousClock.now

    func advance(by duration: Duration) {
        self.now = self.now.advanced(by: duration)
    }
}
