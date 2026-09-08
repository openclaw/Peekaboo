import Darwin
import Foundation

/// Process-wide redirection for serial tests. A file avoids blocking a producer on pipe capacity.
func captureStandardOutputBytes(
    isolation: isolated (any Actor)? = #isolation,
    operation: () async throws -> Void
) async throws -> Data {
    await StandardOutputCaptureGate.shared.acquire()
    do {
        try Task.checkCancellation()
        let data = try await captureStandardOutputUnlocked(isolation: isolation, operation: operation)
        await StandardOutputCaptureGate.shared.release()
        return data
    } catch {
        await StandardOutputCaptureGate.shared.release()
        throw error
    }
}

private func captureStandardOutputUnlocked(
    isolation: isolated (any Actor)? = #isolation,
    operation: () async throws -> Void
) async throws -> Data {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("peekaboo-test-stdout-\(UUID().uuidString)")
    let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer {
        try? file.close()
        try? FileManager.default.removeItem(at: url)
    }

    do {
        let original = dup(STDOUT_FILENO)
        guard original >= 0 else { throw POSIXError(.EIO) }
        defer { close(original) }
        guard fflush(stdout) == 0, dup2(descriptor, STDOUT_FILENO) >= 0 else { throw POSIXError(.EIO) }
        defer {
            fflush(stdout)
            _ = dup2(original, STDOUT_FILENO)
        }
        try await operation()
    }

    try file.seek(toOffset: 0)
    return try file.readToEnd() ?? Data()
}

private actor StandardOutputCaptureGate {
    static let shared = StandardOutputCaptureGate()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if self.held {
            await withCheckedContinuation { self.waiters.append($0) }
        } else {
            self.held = true
        }
    }

    func release() {
        if self.waiters.isEmpty {
            self.held = false
        } else {
            self.waiters.removeFirst().resume()
        }
    }
}

func captureStandardOutputText(
    isolation: isolated (any Actor)? = #isolation,
    _ operation: () async throws -> Void
) async throws -> String {
    let data = try await captureStandardOutputBytes(isolation: isolation, operation: operation)
    return String(data: data, encoding: .utf8) ?? ""
}
