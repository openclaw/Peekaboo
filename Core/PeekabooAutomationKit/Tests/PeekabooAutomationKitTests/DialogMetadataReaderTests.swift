import ApplicationServices
import AXorcist
import Foundation
import PeekabooFoundation
import XCTest
@_spi(Testing) @testable import PeekabooAutomationKit

@MainActor
final class DialogMetadataReaderTests: XCTestCase {
    func testStalledMetadataReadTimesOutWithoutStarvingMainActorOrPublishingLateData() async throws {
        try await self.assertAbandonedRead(cancelling: false, pid: 950_001)
    }

    func testCancelledMetadataReadRetainsItsLaneUntilNativeCompletion() async throws {
        try await self.assertAbandonedRead(cancelling: true, pid: 950_002)
    }

    private func assertAbandonedRead(cancelling: Bool, pid: Int32) async throws {
        let started = expectation(description: "metadata raw read entered")
        let heartbeat = expectation(description: "main actor runs during the raw read")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let probe = MetadataReadProbe()
        let element = Self.element(pid)
        let owner = Self.owner(pid)
        let caller = try DialogOperationDeadline.bounded(
            timeoutSeconds: cancelling ? 10 : 1,
            operationName: "selected metadata caller")
        var observed: DialogOperationDeadline?
        var readers = DialogDiscoveryReaders()
        readers.metadata = { element, identity, budget in
            observed = budget
            return try await DialogMetadataReader.read(element, owner: identity, budget: budget) { _, name in
                let first = probe.update { state in
                    state.reads += 1
                    return state.reads == 1
                }
                if first {
                    probe.update { $0.blocked = true }
                    started.fulfill()
                    Task { @MainActor in
                        probe.update { $0.heartbeatDuringBlock = $0.blocked }
                        heartbeat.fulfill()
                    }
                    // A finite fallback releases even the old MainActor implementation during RED.
                    _ = release.wait(timeout: .now() + 5)
                    probe.update { $0.blocked = false }
                }
                return Self.leafAttribute(name)
            }
        }
        let service = Self.service(readers)
        var published = false
        let operation = Task { @MainActor in
            _ = try await DialogOperationDeadline.$current.withValue(caller) {
                try await service.readDialogMetadata(for: element, owner: owner)
            }
            published = true
        }
        defer { operation.cancel() }
        await fulfillment(of: [started, heartbeat], timeout: 2)
        XCTAssertTrue(probe.snapshot.heartbeatDuringBlock, "The test must observe a responsive actor before release")
        if cancelling {
            operation.cancel()
        }
        do {
            try await operation.value
            XCTFail("Stalled selected metadata must not publish a result")
        } catch is CancellationError {
            XCTAssertTrue(cancelling)
        } catch let PeekabooError.timeout(message) {
            XCTAssertFalse(cancelling)
            XCTAssertTrue(message.contains(caller.operationName))
        }
        XCTAssertEqual(observed?.deadline, caller.deadline)
        XCTAssertEqual(observed?.timeoutSeconds, caller.timeoutSeconds)
        XCTAssertTrue(probe.snapshot.blocked, "Caller completion must not wait for native completion")
        XCTAssertFalse(published)

        // Outlive the first read's finite fallback so an accidentally queued retry would execute,
        // rather than masquerading as a refusal by expiring in the queue.
        let retry = MetadataReadProbe()
        do {
            _ = try await DialogMetadataReader.read(
                element,
                owner: owner,
                budget: DialogOperationDeadline.bounded(timeoutSeconds: 10, operationName: "occupied metadata lane"))
            { _, name in
                retry.update { $0.reads += 1 }
                return Self.leafAttribute(name)
            }
            XCTFail("An abandoned native read must keep its process-generation lane occupied")
        } catch PeekabooError.timeout {}
        XCTAssertEqual(retry.snapshot.reads, 0)

        release.signal()
        _ = try await ElementDetectionTimeoutRunner.runDetached(
            targetProcessIdentifier: pid,
            targetProcessStartIdentity: owner.processStartIdentity,
            seconds: 10) { true }
        XCTAssertFalse(probe.snapshot.blocked)
        if !cancelling {
            XCTAssertEqual(probe.snapshot.reads, 1, "An expired leaf must not trigger additional attribute reads")
        }
        XCTAssertFalse(published, "Late native completion must not install metadata")
        let recovered = try await DialogMetadataReader.read(
            element,
            owner: owner,
            budget: DialogOperationDeadline.bounded(timeoutSeconds: 10, operationName: "recovered metadata lane"))
        { _, name in Self.leafAttribute(name) }
        XCTAssertEqual(recovered.dialogInfo.role, "AXSheet")
    }

    func testExpiredOrCancelledCallerNeverStartsARawMetadataRead() async throws {
        for cancelling in [false, true] {
            let probe = MetadataReadProbe()
            let budget = DialogOperationDeadline(
                deadline: .now.advanced(by: .seconds(cancelling ? 60 : -1)),
                timeoutSeconds: 60,
                operationName: "unadmitted metadata")
            let operation = Task { @MainActor in
                if cancelling {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return try await DialogMetadataReader.read(
                    Self.element(950_003), owner: Self.owner(950_003), budget: budget)
                { _, name in
                    probe.update { $0.reads += 1 }
                    return Self.leafAttribute(name)
                }
            }
            do {
                _ = try await operation.value
                XCTFail("An expired or cancelled caller must not enter metadata acquisition")
            } catch is CancellationError {
                XCTAssertTrue(cancelling)
            } catch PeekabooError.timeout {
                XCTAssertFalse(cancelling)
            }
            XCTAssertEqual(probe.snapshot.reads, 0)
        }
    }

    func testDiscoveryAndMetadataShareTheServiceFallbackDeadline() async throws {
        let element = Self.element(950_004)
        let owner = Self.owner(950_004)
        var observed: [DialogOperationDeadline] = []
        var readers = DialogDiscoveryReaders()
        readers.hierarchyNode = { _, identity, budget in
            XCTAssertEqual(identity, owner)
            observed.append(budget)
            return DialogHierarchyNode(
                evidence: DialogElementEvidence(
                    role: "AXSheet", subrole: "", roleDescription: "", identifier: "", title: ""),
                children: [])
        }
        readers.metadata = { _, identity, budget in
            XCTAssertEqual(identity, owner)
            observed.append(budget)
            return Self.metadata()
        }
        let service = Self.service(readers)
        try await service.runDialogOperation(scope: .global, access: .read) {
            _ = try await service.freshDialogElements(in: element, owner: owner)
            _ = try await service.readDialogMetadata(for: element, owner: owner)
            _ = try await service.readDialogMetadata(for: element, owner: owner)
        }
        XCTAssertEqual(observed.count, 3)
        let first = try XCTUnwrap(observed.first)
        XCTAssertEqual(first.timeoutSeconds, 20)
        XCTAssertTrue(observed.allSatisfy { $0.deadline == first.deadline })
    }

    func testServiceRejectsLateOrCancelledInjectedMetadata() async throws {
        for cancelling in [false, true] {
            let caller = try DialogOperationDeadline.bounded(
                timeoutSeconds: cancelling ? 10 : 0.1,
                operationName: "inherited metadata deadline")
            var observed: DialogOperationDeadline?
            var readers = DialogDiscoveryReaders()
            readers.metadata = { _, _, budget in
                observed = budget
                if cancelling {
                    withUnsafeCurrentTask { $0?.cancel() }
                } else {
                    try await ContinuousClock().sleep(until: budget.deadline)
                }
                return Self.metadata()
            }
            let service = Self.service(readers)
            let operation = Task { @MainActor in
                try await DialogOperationDeadline.$current.withValue(caller) {
                    try await service.readDialogMetadata(for: Self.element(950_005), owner: Self.owner(950_005))
                }
            }
            do {
                _ = try await operation.value
                XCTFail("Late or cancelled injected metadata must not bypass final admission")
            } catch is CancellationError {
                XCTAssertTrue(cancelling)
            } catch let PeekabooError.timeout(message) {
                XCTAssertFalse(cancelling)
                XCTAssertTrue(message.contains(caller.operationName))
            }
            XCTAssertEqual(observed?.deadline, caller.deadline)
            XCTAssertEqual(observed?.timeoutSeconds, caller.timeoutSeconds)
        }
    }

    private nonisolated static func leafAttribute(_ name: String) -> (error: AXError, value: CFTypeRef?) {
        name == "AXRole" ? (.success, "AXSheet" as CFString) : (.attributeUnsupported, nil)
    }

    private static func element(_ pid: Int32) -> Element {
        Element(AXUIElementCreateApplication(-pid))
    }

    private static func owner(_ pid: Int32) -> ApplicationProcessIdentity {
        ApplicationProcessIdentity(processIdentifier: pid, processStartIdentity: 123)
    }

    private static func metadata() -> DialogElements {
        DialogElements(dialogInfo: DialogInfo(title: "Fixture", role: "AXSheet", bounds: .zero))
    }

    private static func service(_ readers: DialogDiscoveryReaders) -> DialogService {
        DialogService(syntheticInputDriver: SyntheticInputDriver(), discoveryReaders: readers)
    }
}

/// The synchronous read callback and MainActor heartbeat share only this lock-protected test state.
private final class MetadataReadProbe: @unchecked Sendable {
    struct State {
        var reads = 0
        var blocked = false
        var heartbeatDuringBlock = false
    }

    private let lock = NSLock()
    private var state = State()

    var snapshot: State {
        self.lock.withLock { self.state }
    }

    @discardableResult
    func update<Result>(_ operation: (inout State) -> Result) -> Result {
        self.lock.withLock { operation(&self.state) }
    }
}
