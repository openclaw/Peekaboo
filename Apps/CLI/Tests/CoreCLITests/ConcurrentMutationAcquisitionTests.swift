import Darwin
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe), .serialized)
@MainActor
struct ConcurrentMutationAcquisitionTests {
    @Test(arguments: [false, true])
    func `Waiting concurrent IDs reserve ownership and cancellation allows retry`(cancel: Bool) async throws {
        let desktop = try CLIDesktopFixture()
        defer { desktop.removeDirectory() }
        let lockPath = desktop.root.appendingPathComponent("desktop-mutation-watermark.lock").path
        let holder = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        #expect(holder >= 0)
        guard holder >= 0 else { return }
        defer {
            flock(holder, LOCK_UN)
            close(holder)
        }
        #expect(flock(holder, LOCK_EX | LOCK_NB) == 0)
        let tracker = InteractionMutationTracker(desktopMutationWatermarkStore: desktop.watermarkStore)
        let id = UUID()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let first = Task { @MainActor in
            continuation.yield(())
            continuation.finish()
            try await tracker.beginConcurrentDurableMutation(id: id)
        }
        for await _ in started {}
        #expect(tracker.hasPendingDurableMutation)
        await #expect(throws: PeekabooError.self) {
            try await tracker.beginConcurrentDurableMutation(id: id)
        }
        if cancel {
            first.cancel()
            await #expect(throws: CancellationError.self) {
                try await first.value
            }
            #expect(!tracker.hasPendingDurableMutation)
            #expect(try Self.pendingCount(in: desktop.root) == 0)
        }
        flock(holder, LOCK_UN)
        if cancel {
            try await tracker.beginConcurrentDurableMutation(id: id)
        } else {
            try await first.value
        }
        #expect(try Self.pendingCount(in: desktop.root) == 1)
        await #expect(throws: PeekabooError.self) {
            try await tracker.beginConcurrentDurableMutation(id: id)
        }
        let peer = UUID()
        try await tracker.beginConcurrentDurableMutation(id: peer)
        #expect(try Self.pendingCount(in: desktop.root) == 2)
        try tracker.cancelConcurrentDurableMutation(id: id)
        #expect(tracker.hasPendingDurableMutation)
        #expect(try Self.pendingCount(in: desktop.root) == 1)
        _ = try tracker.completeConcurrentDurableMutation(id: peer, through: Date())
        #expect(!tracker.hasPendingDurableMutation)
        #expect(try Self.pendingCount(in: desktop.root) == 0)
    }

    private static func pendingCount(in root: URL) throws -> Int {
        let pending = root.appendingPathComponent("desktop-mutation-pending", isDirectory: true)
        guard FileManager.default.fileExists(atPath: pending.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil).count
    }
}
