import Darwin
import Foundation

/// Optional startup diagnostics must drain output while Git runs and stop at one deadline.
nonisolated func runGitStalenessProbe(
    arguments: [String],
    directory: URL? = nil,
    timeoutSeconds: TimeInterval = 5
) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let descriptor = pipe.fileHandleForReading.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
    defer { try? pipe.fileHandleForReading.close() }
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(timeoutSeconds)
    do {
        try process.run()
        try? pipe.fileHandleForWriting.close()
        var waitedForExit = false
        defer {
            if !waitedForExit, process.isRunning {
                try? waitForProcessExit(process, timeoutSeconds: 0)
            }
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let maximumBytes = 8 * 1024 * 1024
        while clock.now < deadline {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard data.count <= maximumBytes - count else { return nil }
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 {
                let remaining = clock.now.duration(to: deadline).components
                let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
                waitedForExit = true
                try waitForProcessExit(process, timeoutSeconds: max(0, seconds))
                return process.terminationStatus == 0 ? data : nil
            }
            if errno == EINTR {
                continue
            }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { return nil }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    } catch { return nil }
}
