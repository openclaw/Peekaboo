import Darwin
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct DesktopMutationExclusiveLockDeadlineTests {
    @Test
    func `cancellable mutation wait fails when another holder never unlocks`() async throws {
        let root = Self.temporaryDirectory(named: "exclusive-lock-deadline")
        defer { try? FileManager.default.removeItem(at: root) }
        guard let holder = Self.lockHolder(in: root) else { return }
        defer {
            flock(holder, LOCK_UN)
            close(holder)
        }

        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let waitTask = Task {
            try await store.beginMutationCancellable(exclusiveWaitNanoseconds: 80_000_000)
        }
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            waitTask.cancel()
        }
        defer { watchdog.cancel() }

        do {
            _ = try await waitTask.value
            Issue.record("A live exclusive holder should time out the waiter")
        } catch is CancellationError {
            Issue.record("Deadline should throw before the 2s watchdog cancels")
        } catch let error as PeekabooError {
            #expect(error.code == StandardErrorCode.timeout)
            #expect(error.localizedDescription.contains("desktop mutation watermark lock"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(try Self.pendingMutationCount(in: root) == 0)
    }

    @Test(arguments: [UInt64(0), 80_000_000, .max])
    func `cancellable mutation wait still acquires a free lock`(limit: UInt64) async throws {
        let root = Self.temporaryDirectory(named: "exclusive-lock-free")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)

        let mutation = try await store.beginMutationCancellable(exclusiveWaitNanoseconds: limit)
        #expect(try Self.pendingMutationCount(in: root) == 1)
        try store.cancelMutation(mutation)
        #expect(try Self.pendingMutationCount(in: root) == 0)
    }

    @Test
    func `cancellable mutation wait honors task cancellation before the deadline`() async throws {
        let root = Self.temporaryDirectory(named: "exclusive-lock-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        guard let holder = Self.lockHolder(in: root) else { return }
        defer {
            flock(holder, LOCK_UN)
            close(holder)
        }

        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let waitTask = Task {
            try await store.beginMutationCancellable(exclusiveWaitNanoseconds: 15_000_000_000)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        waitTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await waitTask.value
        }
        #expect(try Self.pendingMutationCount(in: root) == 0)
    }

    @Test
    func `already cancelled mutation cannot reserve an uncontended lock`() async throws {
        let root = Self.temporaryDirectory(named: "exclusive-lock-already-cancelled")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.beginMutationCancellable()
        }
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        #expect(try Self.pendingMutationCount(in: root) == 0)
    }

    private static func lockHolder(in root: URL) -> Int32? {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            Issue.record("Could not create watermark lock directory: \(error)")
            return nil
        }
        let path = root.appendingPathComponent("desktop-mutation-watermark.lock").path
        let holder = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard holder >= 0 else {
            Issue.record("Could not create watermark lock file")
            return nil
        }
        guard flock(holder, LOCK_EX | LOCK_NB) == 0 else {
            close(holder)
            Issue.record("Could not take exclusive lock for the fixture holder")
            return nil
        }
        return holder
    }

    private static func pendingMutationCount(in root: URL) throws -> Int {
        let pendingDirectory = root.appendingPathComponent("desktop-mutation-pending", isDirectory: true)
        guard FileManager.default.fileExists(atPath: pendingDirectory.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil).count
    }

    private static func temporaryDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-watermark-\(name)-\(UUID().uuidString)", isDirectory: true)
    }
}
