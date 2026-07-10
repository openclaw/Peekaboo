import Darwin
import Foundation
import PeekabooBridge
import Testing
@testable import PeekabooCLI

@Suite(.serialized)
@MainActor
struct DaemonStartupGateTests {
    private struct DescriptorInspection: Sendable {
        let descriptorFlags: Int32
        let mode: mode_t
        let owner: uid_t
    }

    private enum ExpectedError: Error {
        case failure
    }

    @Test
    func `startup lock is private regular owned and close on exec`() async throws {
        let (root, lockURL) = try self.temporaryLockURL()
        defer { try? FileManager.default.removeItem(at: root) }

        let inspection = try await DaemonStartupGate.withExclusiveStartup(lockURL: lockURL) { fd in
            var fileInfo = stat()
            #expect(fstat(fd, &fileInfo) == 0)
            return DescriptorInspection(
                descriptorFlags: fcntl(fd, F_GETFD),
                mode: fileInfo.st_mode,
                owner: fileInfo.st_uid
            )
        }

        #expect(inspection.descriptorFlags & FD_CLOEXEC != 0)
        #expect(inspection.mode & mode_t(S_IFMT) == mode_t(S_IFREG))
        #expect(inspection.mode & mode_t(0o777) == mode_t(S_IRUSR | S_IWUSR))
        #expect(inspection.owner == geteuid())
    }

    @Test
    func `custom daemon sockets use an isolated startup lock while default family stays shared`() {
        let customSocketPath = "/tmp/peekaboo-custom-\(UUID().uuidString).sock"
        #expect(
            DaemonPaths.daemonStartupLockURL(socketPath: customSocketPath).path ==
                "\(customSocketPath).start.lock"
        )
        let defaultLockURL = DaemonPaths.daemonStartupLockURL()
        #expect(
            DaemonPaths.daemonStartupLockURL(socketPath: PeekabooBridgeConstants.daemonSocketPath) ==
                defaultLockURL
        )
        let buildScopedSocketURL = URL(fileURLWithPath: PeekabooBridgeConstants.daemonSocketPath)
            .deletingLastPathComponent()
            .appendingPathComponent("daemon-0123456789abcdef.sock")
        #expect(
            DaemonPaths.daemonStartupLockURL(socketPath: buildScopedSocketURL.path) == defaultLockURL
        )
        let customLookalikeSocketURL = buildScopedSocketURL
            .deletingLastPathComponent()
            .appendingPathComponent("daemon-testing.sock")
        #expect(
            DaemonPaths.daemonStartupLockURL(socketPath: customLookalikeSocketURL.path).path ==
                "\(customLookalikeSocketURL.path).start.lock"
        )
    }

    @Test
    func `startup gate allows distinct lock paths concurrently`() async throws {
        let (root, firstLockURL) = try self.temporaryLockURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let secondLockURL = root.appendingPathComponent("other-daemon-start.lock")

        var releaseFirst: CheckedContinuation<Void, Never>?
        defer { releaseFirst?.resume() }
        let first = Task { @MainActor in
            try await DaemonStartupGate.withExclusiveStartup(lockURL: firstLockURL) { _ in
                await withCheckedContinuation { continuation in
                    releaseFirst = continuation
                }
                return true
            }
        }
        while releaseFirst == nil {
            await Task.yield()
        }

        let secondEntered = try await DaemonStartupGate.withExclusiveStartup(
            lockURL: secondLockURL,
            timeout: .seconds(1)
        ) { _ in true }
        #expect(secondEntered)

        releaseFirst?.resume()
        releaseFirst = nil
        #expect(try await first.value)
    }

    @Test
    func `startup gate rejects a symbolic link`() async throws {
        let (root, lockURL) = try self.temporaryLockURL(createDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let targetURL = root.appendingPathComponent("target")
        #expect(FileManager.default.createFile(atPath: targetURL.path, contents: Data()))
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: targetURL)

        var operationRan = false
        do {
            _ = try await DaemonStartupGate.withExclusiveStartup(lockURL: lockURL) { _ in
                operationRan = true
                return true
            }
            Issue.record("Expected a symbolic startup lock to be rejected")
        } catch let error as DaemonStartupGate.GateError {
            guard case let .systemCall(operation, path, _) = error else {
                Issue.record("Expected an open error, got \(error)")
                return
            }
            #expect(operation == "open")
            #expect(path == lockURL.path)
        }
        #expect(!operationRan)
    }

    @Test
    func `startup gate times out while another process lock is held`() async throws {
        let (root, lockURL) = try self.temporaryLockURL(createDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let externalFD = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        let heldFD = try #require(externalFD >= 0 ? externalFD : nil)
        defer {
            flock(heldFD, LOCK_UN)
            close(heldFD)
        }
        #expect(flock(heldFD, LOCK_EX | LOCK_NB) == 0)

        let clock = ContinuousClock()
        let startedAt = clock.now
        var operationRan = false
        do {
            _ = try await DaemonStartupGate.withExclusiveStartup(
                lockURL: lockURL,
                timeout: .milliseconds(80),
                retryInterval: .milliseconds(5)
            ) { _ in
                operationRan = true
                return true
            }
            Issue.record("Expected the startup lock acquisition to time out")
        } catch let error as DaemonStartupGate.GateError {
            guard case .timedOut = error else {
                Issue.record("Expected a timeout, got \(error)")
                return
            }
        }

        #expect(!operationRan)
        #expect(clock.now - startedAt < .seconds(1))
    }

    @Test
    func `canceling startup lock acquisition returns promptly`() async throws {
        let (root, lockURL) = try self.temporaryLockURL(createDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let externalFD = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        let heldFD = try #require(externalFD >= 0 ? externalFD : nil)
        defer {
            flock(heldFD, LOCK_UN)
            close(heldFD)
        }
        #expect(flock(heldFD, LOCK_EX | LOCK_NB) == 0)

        let task = Task { @MainActor in
            try await DaemonStartupGate.withExclusiveStartup(lockURL: lockURL) { _ in true }
        }
        try await Task.sleep(for: .milliseconds(40))
        let clock = ContinuousClock()
        let canceledAt = clock.now
        task.cancel()

        switch await task.result {
        case .success:
            Issue.record("Expected startup lock acquisition cancellation")
        case let .failure(error):
            #expect(error is CancellationError)
        }
        #expect(clock.now - canceledAt < .seconds(1))
    }

    @Test
    func `throwing startup operation releases the lock`() async throws {
        let (root, lockURL) = try self.temporaryLockURL()
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let _: Bool = try await DaemonStartupGate.withExclusiveStartup(lockURL: lockURL) { _ in
                throw ExpectedError.failure
            }
            Issue.record("Expected the startup operation to throw")
        } catch ExpectedError.failure {}

        let reacquired = try await DaemonStartupGate.withExclusiveStartup(lockURL: lockURL) { _ in true }
        #expect(reacquired)
    }

    @Test
    func `startup gate serializes reentrant callers in the same process`() async throws {
        let (root, lockURL) = try self.temporaryLockURL()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(
            DaemonStartupGate.defaultAcquisitionTimeout >=
                .seconds(DaemonControlClient.defaultShutdownWaitSeconds * 4)
        )

        var releaseFirst: CheckedContinuation<Void, Never>?
        var secondStarted = false
        var secondEntered = false
        let first = Task { @MainActor in
            try await DaemonStartupGate.withExclusiveStartup(lockURL: lockURL) { _ in
                await withCheckedContinuation { continuation in
                    releaseFirst = continuation
                }
                return true
            }
        }
        while releaseFirst == nil {
            await Task.yield()
        }

        let second = Task { @MainActor in
            secondStarted = true
            return try await DaemonStartupGate.withExclusiveStartup(
                lockURL: lockURL,
                timeout: .seconds(1)
            ) { _ in
                secondEntered = true
                return true
            }
        }
        while !secondStarted {
            await Task.yield()
        }
        await Task.yield()
        #expect(!secondEntered)

        releaseFirst?.resume()
        #expect(try await first.value)
        #expect(try await second.value)
        #expect(secondEntered)
    }

    private func temporaryLockURL(createDirectory: Bool = false) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-daemon-gate-\(UUID().uuidString)", isDirectory: true)
        if createDirectory {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return (root, root.appendingPathComponent("daemon-start.lock"))
    }
}
