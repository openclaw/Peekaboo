import Darwin
import Foundation
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
        let heldFD = try await self.holdPasteTransactionLock()
        var lockHeld = true
        defer {
            if lockHeld {
                flock(heldFD, LOCK_UN)
            }
            close(heldFD)
        }

        var operationRan = false
        let transaction = Task { @MainActor in
            try await ClipboardPasteTransactionGate.withExclusiveTransaction {
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
    func `Processes with different temporary directories contend on the canonical user lock`() async throws {
        let childTemporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-clipboard-child-tmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: childTemporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: childTemporaryDirectory) }

        #expect(!ClipboardPasteTransactionGate.defaultLockPath.hasPrefix(NSTemporaryDirectory()))
        #expect(ClipboardPasteTransactionGate.defaultLockPath.hasSuffix(
            "/Library/Application Support/Peekaboo/clipboard-paste-transaction.lock"))

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = [
            "-MFcntl=:flock,O_CREAT,O_RDWR",
            "-MIO::Handle",
            "-e",
            #"my $p = "$ENV{HOME}/Library/Application Support/Peekaboo/clipboard-paste-transaction.lock"; "# +
                #"sysopen(my $f, $p, O_CREAT|O_RDWR, 0600) or die $!; flock($f, LOCK_EX) or die $!; "# +
                #"STDOUT->autoflush(1); print "locked\n"; <STDIN>;"#,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = childTemporaryDirectory.path
        child.environment = environment
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
        }
        let readiness = try #require(try childOutput.fileHandleForReading.read(upToCount: 7))
        #expect(readiness == Data("locked\n".utf8))

        var operationRan = false
        let transaction = Task { @MainActor in
            try await ClipboardPasteTransactionGate.withExclusiveTransaction {
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
    func `Cancellation while waiting never runs the transaction`() async throws {
        let heldFD = try await self.holdPasteTransactionLock()
        defer {
            flock(heldFD, LOCK_UN)
            close(heldFD)
        }

        var operationRan = false
        let transaction = Task { @MainActor in
            try await ClipboardPasteTransactionGate.withExclusiveTransaction {
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
            case .fileSystem, .unsafeDirectory, .unsafeLockFile:
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
    func `Canonical lock is a private current-user regular file`() async throws {
        try await ClipboardPasteTransactionGate.withExclusiveTransaction {}

        var fileInfo = stat()
        #expect(lstat(ClipboardPasteTransactionGate.defaultLockPath, &fileInfo) == 0)
        #expect(fileInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
        #expect(fileInfo.st_uid == geteuid())
        #expect(fileInfo.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0)
        #expect(fileInfo.st_mode & mode_t(S_IRUSR | S_IWUSR) == mode_t(S_IRUSR | S_IWUSR))
    }

    private func holdPasteTransactionLock() async throws -> Int32 {
        try await ClipboardPasteTransactionGate.withExclusiveTransaction {}
        let fd = open(
            ClipboardPasteTransactionGate.defaultLockPath,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                close(fd)
                throw error
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return fd
    }
}
