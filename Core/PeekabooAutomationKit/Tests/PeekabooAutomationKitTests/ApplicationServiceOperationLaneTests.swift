import AppKit
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ApplicationServiceOperationLaneTests {
    @Test
    @MainActor
    func `Quit revalidates process generation after waiting for its execution lane`() async throws {
        let runningApplication = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier > 0 && !$0.isTerminated
        })
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-application-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let expectedIdentity = ApplicationProcessIdentity(
            processIdentifier: runningApplication.processIdentifier,
            processStartIdentity: 70)
        let ownerStarted = ApplicationOperationLatch()
        let ownerRelease = ApplicationOperationLatch()
        let currentGeneration = ApplicationOperationGenerationBox(70)
        var terminationCalls = 0
        let service = ApplicationService(
            operationLaneCoordinator: coordinator,
            applicationOpenHandler: { _, _, _ in runningApplication },
            processStartIdentityProvider: { _ in currentGeneration.value },
            applicationQuitHandler: { _, _ in
                terminationCalls += 1
                return true
            })

        let owner = Task { @MainActor in
            try await coordinator.run(scope: .process(expectedIdentity), access: .write) {
                await ownerStarted.open()
                await ownerRelease.wait()
            }
        }
        await ownerStarted.wait()
        let quit = Task { @MainActor in
            try await service.quitApplication(request: ApplicationQuitRequest(
                identifier: "PID:\(runningApplication.processIdentifier)",
                expectedIdentity: expectedIdentity))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(terminationCalls == 0)
        currentGeneration.value = 71
        await ownerRelease.open()

        try await owner.value
        await #expect(throws: PeekabooError.self) {
            try await quit.value
        }
        #expect(terminationCalls == 0)
    }
}

private actor ApplicationOperationLatch {
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

private final class ApplicationOperationGenerationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: UInt64

    init(_ value: UInt64) {
        self.storedValue = value
    }

    var value: UInt64 {
        get { self.lock.withLock { self.storedValue } }
        set { self.lock.withLock { self.storedValue = newValue } }
    }
}
