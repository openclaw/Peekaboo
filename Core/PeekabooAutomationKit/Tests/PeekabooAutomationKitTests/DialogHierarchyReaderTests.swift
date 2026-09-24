import ApplicationServices
import AXorcist
import Foundation
import PeekabooFoundation
import XCTest
@_spi(Testing) @testable import PeekabooAutomationKit

@MainActor
final class DialogHierarchyReaderTests: XCTestCase {
    func testServiceOperationSharesOneFallbackAcrossRepeatedDiscovery() async throws {
        let root = Self.element(940_000)
        let owner = ApplicationProcessIdentity(processIdentifier: 940_000, processStartIdentity: 123)
        var observed: [DialogOperationDeadline] = []
        var readers = DialogDiscoveryReaders()
        readers.hierarchyNode = { _, _, budget in
            observed.append(budget)
            return Self.node(role: "AXSheet")
        }
        let service = Self.service(readers)
        try await service.runDialogOperation(scope: .global, access: .read) {
            _ = try await service.freshDialogElements(in: root, owner: owner)
            _ = try await service.freshDialogElements(in: root, owner: owner)
        }
        XCTAssertEqual(observed.count, 2)
        XCTAssertEqual(observed[0].timeoutSeconds, 20)
        XCTAssertEqual(observed[0].deadline, observed[1].deadline)
    }

    func testStalledNativeReadDoesNotStarveMainActorOrPublishLateCandidates() async throws {
        try await self.assertAbandonedRead(cancelling: false, pid: 940_001)
    }

    func testCancellationDoesNotWaitForNativeReadOrReachMutation() async throws {
        try await self.assertAbandonedRead(cancelling: true, pid: 940_002)
    }

    private func assertAbandonedRead(cancelling: Bool, pid: Int32) async throws {
        let started = expectation(description: "read started")
        let heartbeat = expectation(description: "main actor remains responsive")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let root = Self.element(pid)
        let owner = ApplicationProcessIdentity(processIdentifier: pid, processStartIdentity: 123)
        let node = Self.node(role: "AXSheet")
        var readers = DialogDiscoveryReaders()
        readers.hierarchyNode = { _, identity, budget in
            try await DialogHierarchyReader.run(owner: identity, budget: budget) {
                started.fulfill()
                _ = release.wait(timeout: .now() + 10)
                return node
            }
        }
        let service = Self.service(readers)
        var published = false
        var mutationCount = 0
        let operation = Task { @MainActor in
            let result = try await service.freshDialogElements(
                in: root,
                owner: owner,
                budget: DialogOperationDeadline.bounded(
                    timeoutSeconds: cancelling ? 10 : 1,
                    operationName: "dialog test"))
            published = true
            if result.structural.count == 1 {
                mutationCount += 1
            }
        }
        defer { operation.cancel() }
        await fulfillment(of: [started], timeout: 2)
        Task { @MainActor in heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 0.5)
        if cancelling {
            operation.cancel()
        }
        do {
            try await operation.value
            XCTFail("Stalled discovery must not publish a candidate")
        } catch is CancellationError {
            XCTAssertTrue(cancelling)
        } catch PeekabooError.timeout {
            XCTAssertFalse(cancelling)
        } catch {
            XCTFail("Unexpected discovery error: \(error)")
        }
        XCTAssertFalse(published)
        XCTAssertEqual(mutationCount, 0)
        do {
            _ = try await DialogHierarchyReader.run(
                owner: owner,
                budget: DialogOperationDeadline.bounded(timeoutSeconds: 1, operationName: "dialog test"))
            {
                XCTFail("An abandoned native read must retain its generation lane until it really finishes")
                return node
            }
            XCTFail("The still-occupied worker lane must refuse more work")
        } catch PeekabooError.timeout {}

        release.signal()
        _ = try await ElementDetectionTimeoutRunner.runDetached(
            targetProcessIdentifier: pid,
            targetProcessStartIdentity: owner.processStartIdentity,
            seconds: 10) { true }
        XCTAssertFalse(published, "Late native completion must not install dialog candidates")
        XCTAssertEqual(mutationCount, 0)
    }

    func testCancelledDiscoveryNeverStartsANativeRead() async throws {
        let root = Self.element(940_003)
        let owner = ApplicationProcessIdentity(processIdentifier: 940_003, processStartIdentity: 123)
        var readCount = 0
        var readers = DialogDiscoveryReaders()
        readers.hierarchyNode = { _, _, _ in
            readCount += 1
            return Self.node(role: "AXSheet")
        }
        let service = Self.service(readers)
        let operation = Task { @MainActor in
            try await service.freshDialogElements(in: root, owner: owner)
        }
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(readCount, 0)
    }

    func testEveryNodeSharesOneDeadlineAndLateInjectedResultsAreRejected() async throws {
        let root = Self.element(940_004)
        let child = Self.element(940_005)
        let owner = ApplicationProcessIdentity(processIdentifier: 940_004, processStartIdentity: 123)
        let budget = try DialogOperationDeadline.bounded(timeoutSeconds: 0.1, operationName: "dialog test")
        var deadlines: [ContinuousClock.Instant] = []
        var readers = DialogDiscoveryReaders()
        readers.hierarchyNode = { element, _, budget in
            deadlines.append(budget.deadline)
            if element == root {
                return Self.node(role: "AXWindow", children: [child])
            }
            try await ContinuousClock().sleep(until: budget.deadline)
            return Self.node(role: "AXSheet")
        }
        do {
            _ = try await Self.service(readers).freshDialogElements(in: root, owner: owner, budget: budget)
            XCTFail("Incomplete hierarchy must not publish an apparently unique sheet")
        } catch PeekabooError.timeout {}
        XCTAssertEqual(deadlines, [budget.deadline, budget.deadline])
    }

    func testCyclesAndSharedChildrenRetainIdentityAndStructuralPrecedence() async throws {
        let root = Self.element(940_006)
        let first = Self.element(940_007)
        let second = Self.element(940_008)
        let owner = ApplicationProcessIdentity(processIdentifier: 940_006, processStartIdentity: 123)
        var visited: [Element] = []
        var readers = DialogDiscoveryReaders()
        readers.hierarchyNode = { element, identity, _ in
            XCTAssertEqual(identity, owner)
            visited.append(element)
            if element == root {
                return Self.node(role: "AXDialog", children: [first, second, first])
            }
            return Self.node(role: "AXSheet", children: [root])
        }
        let result = try await Self.service(readers).freshDialogElements(in: root, owner: owner)
        XCTAssertEqual(visited, [root, first, second])
        XCTAssertEqual(result.structural, [first, second], "Two sheets must remain ambiguous")
        XCTAssertTrue(result.legacy.isEmpty)
        XCTAssertTrue(CFEqual(result.structural[0].underlyingElement, first.underlyingElement))
    }

    func testIncompleteClassificationCannotEstablishUniqueness() async throws {
        let root = Self.element(940_009)
        let sheet = Self.element(940_010)
        let unreadable = Self.element(940_011)
        let owner = ApplicationProcessIdentity(processIdentifier: 940_009, processStartIdentity: 123)
        var readers = DialogDiscoveryReaders()
        readers.hierarchyNode = { element, _, _ in
            if element == root {
                return Self.node(role: "AXWindow", children: [sheet, unreadable])
            }
            if element == sheet {
                return Self.node(role: "AXSheet")
            }
            throw PeekabooError.accessibilityIncomplete("Unreadable dialog classification")
        }
        do {
            _ = try await Self.service(readers).freshDialogElements(in: root, owner: owner)
            XCTFail("One readable sheet does not establish complete discovery")
        } catch PeekabooError.accessibilityIncomplete {}
    }

    func testLargeAndDeepReadableHierarchiesRetainCompleteUniqueDialog() async throws {
        let nodes = (0..<1024).map { Self.element(941_000 + Int32($0)) }
        let indices = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1, $0) })
        let owner = ApplicationProcessIdentity(processIdentifier: 940_012, processStartIdentity: 123)
        for deep in [false, true] {
            var visitedCount = 0
            var readers = DialogDiscoveryReaders()
            readers.hierarchyNode = { element, _, _ in
                visitedCount += 1
                let index = try XCTUnwrap(indices[element])
                let children = deep
                    ? (index + 1 < nodes.count ? [nodes[index + 1]] : [])
                    : (index == 0 ? Array(nodes.dropFirst()) : [])
                return Self.node(role: index == nodes.count - 1 ? "AXSheet" : "AXGroup", children: children)
            }
            let result = try await Self.service(readers).freshDialogElements(in: nodes[0], owner: owner)
            XCTAssertEqual(result.structural, [nodes[nodes.count - 1]])
            XCTAssertEqual(visitedCount, nodes.count)
        }
    }

    func testLargeHierarchyPreservesAmbiguityBeyondTheFirstSheet() async throws {
        let nodes = (0..<1024).map { Self.element(943_000 + Int32($0)) }
        let owner = ApplicationProcessIdentity(processIdentifier: 943_000, processStartIdentity: 123)
        var readers = DialogDiscoveryReaders()
        readers.hierarchyNode = { element, _, _ in
            Self.node(
                role: element == nodes[1] || element == nodes[1023] ? "AXSheet" : "AXGroup",
                children: element == nodes[0] ? Array(nodes.dropFirst()) : [])
        }
        let result = try await Self.service(readers).freshDialogElements(in: nodes[0], owner: owner)
        XCTAssertEqual(result.structural, [nodes[1], nodes[1023]])
    }

    private static func element(_ pid: Int32) -> Element {
        Element(AXUIElementCreateApplication(pid))
    }

    private static func node(role: String, children: [Element] = []) -> DialogHierarchyNode {
        DialogHierarchyNode(
            evidence: DialogElementEvidence(
                role: role,
                subrole: "",
                roleDescription: "",
                identifier: "",
                title: ""),
            children: children)
    }

    private static func service(_ readers: DialogDiscoveryReaders) -> DialogService {
        DialogService(syntheticInputDriver: SyntheticInputDriver(), discoveryReaders: readers)
    }
}
