import Foundation
import Testing
@testable import PeekabooAutomationKit

struct DialogServiceOperationLaneTests {
    @Test
    @MainActor
    func `Cancelled queued dialog action never resolves or dispatches`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-dialog-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let ownerStarted = DialogOperationLatch()
        let ownerRelease = DialogOperationLatch()
        let service = DialogService(
            syntheticInputDriver: SyntheticInputDriver(),
            operationLaneCoordinator: coordinator)

        let owner = Task {
            try await coordinator.run(scope: .global, access: .write) {
                await ownerStarted.open()
                await ownerRelease.wait()
            }
        }
        await ownerStarted.wait()
        let dialogAction = Task { @MainActor in
            try await service.clickButton(
                buttonText: "Never dispatch",
                windowTitle: "Missing dialog",
                appName: nil)
        }
        try await Task.sleep(for: .milliseconds(50))
        dialogAction.cancel()
        await ownerRelease.open()

        try await owner.value
        await #expect(throws: CancellationError.self) {
            try await dialogAction.value
        }
    }
}

private actor DialogOperationLatch {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !self.opened else { return }
        self.opened = true
        let pending = self.continuations
        self.continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !self.opened else { return }
        await withCheckedContinuation { self.continuations.append($0) }
    }
}
