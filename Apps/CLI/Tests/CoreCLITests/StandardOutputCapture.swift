import Darwin
import Foundation

/// Process-wide redirection for serial tests. A file avoids blocking a producer on pipe capacity.
func captureStandardOutputBytes(
    isolation: isolated (any Actor)? = #isolation,
    operation: () async throws -> Void
) async throws -> Data {
    try await captureStandardStreamBytes(isolation: isolation, standardError: false, operation: operation)
}

func captureStandardErrorBytes(
    isolation: isolated (any Actor)? = #isolation,
    operation: () async throws -> Void
) async throws -> Data {
    try await captureStandardStreamBytes(isolation: isolation, standardError: true, operation: operation)
}

private func captureStandardStreamBytes(
    isolation: isolated (any Actor)?,
    standardError: Bool,
    operation: () async throws -> Void
) async throws -> Data {
    await StandardStreamCaptureGate.shared.acquire()
    do {
        try Task.checkCancellation()
        let data = try await captureStandardStreamUnlocked(
            isolation: isolation, standardError: standardError, operation: operation
        )
        await StandardStreamCaptureGate.shared.release()
        return data
    } catch {
        await StandardStreamCaptureGate.shared.release()
        throw error
    }
}

private func captureStandardStreamUnlocked(
    isolation: isolated (any Actor)?,
    standardError: Bool,
    operation: () async throws -> Void
) async throws -> Data {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("peekaboo-test-stream-\(UUID().uuidString)")
    let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer {
        try? file.close()
        try? FileManager.default.removeItem(at: url)
    }

    do {
        let stream = standardError ? stderr : stdout
        let targetDescriptor = standardError ? STDERR_FILENO : STDOUT_FILENO
        let original = dup(targetDescriptor)
        guard original >= 0 else { throw POSIXError(.EIO) }
        defer { close(original) }
        guard fflush(stream) == 0, dup2(descriptor, targetDescriptor) >= 0 else { throw POSIXError(.EIO) }
        defer {
            fflush(stream)
            _ = dup2(original, targetDescriptor)
        }
        try await operation()
    }

    try file.seek(toOffset: 0)
    return try file.readToEnd() ?? Data()
}

private actor StandardStreamCaptureGate {
    static let shared = StandardStreamCaptureGate()
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
