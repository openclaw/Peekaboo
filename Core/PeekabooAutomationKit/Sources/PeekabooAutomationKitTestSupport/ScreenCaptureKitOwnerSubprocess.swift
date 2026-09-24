import Foundation
import PeekabooAutomationKit

/// Holds a real subprocess owner lock at a caller-provided, task-private test path.
public final class ScreenCaptureKitOwnerSubprocess {
    public let process: Process
    private let input: Pipe
    private let output: Pipe
    private var stopped = false

    public init(lockURL: URL) throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import fcntl, os, sys
            path = sys.argv[1]
            descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            print("locked", flush=True)
            receipt = sys.stdin.buffer.readline().rstrip(b"\\n")
            os.ftruncate(descriptor, 0)
            os.pwrite(descriptor, receipt, 0)
            os.fsync(descriptor)
            print("ready", flush=True)
            sys.stdin.buffer.readline()
            """,
            lockURL.path,
        ]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let readiness = try output.fileHandleForReading.read(upToCount: 7)
        guard readiness.flatMap({ String(bytes: $0, encoding: .utf8) }) == "locked\n" else {
            process.terminate()
            throw SubprocessError("Lock subprocess did not become ready")
        }
        self.process = process
        self.input = input
        self.output = output
    }

    public func install(receipt: ScreenCaptureKitOwnerLease.OwnerReceipt) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(receipt)
        data.append(0x0A)
        try self.input.fileHandleForWriting.write(contentsOf: data)
        let readiness = try self.output.fileHandleForReading.read(upToCount: 6)
        guard readiness.flatMap({ String(bytes: $0, encoding: .utf8) }) == "ready\n" else {
            throw SubprocessError("Lock subprocess did not install its receipt")
        }
    }

    public func stopAndWait() throws {
        guard !self.stopped else { return }
        self.stopped = true
        try self.input.fileHandleForWriting.write(contentsOf: Data([0x0A]))
        try self.input.fileHandleForWriting.close()
        self.process.waitUntilExit()
        guard self.process.terminationStatus == 0 else {
            throw SubprocessError("Lock subprocess exited with \(self.process.terminationStatus)")
        }
    }

    public func stop() {
        guard !self.stopped else { return }
        self.stopped = true
        try? self.input.fileHandleForWriting.close()
        if self.process.isRunning {
            self.process.terminate()
            self.process.waitUntilExit()
        }
    }

    private struct SubprocessError: Error {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }
}
