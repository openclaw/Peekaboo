import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import XCTest
@_spi(Testing) @testable import PeekabooAutomationKit

@MainActor
final class ApplicationMetadataSaturationTests: XCTestCase {
    func testRepeatedInventoriesAcrossServicesKeepRowsAndExactAXIndependent() async throws {
        let gate = MetadataNativeGate()
        defer { gate.release() }
        let entered = expectation(description: "inventory entered eight native getters")
        entered.expectedFulfillmentCount = 8
        let completion = MetadataCompletionProbe()
        let pool = DetachedApplicationMetadataPool(didComplete: completion.record)
        let pids = (990_000..<990_008).map(Int32.init)
        let firstService = self.service(pool: pool, pids: pids, generation: { _ in 1 }, timeout: 0.3, operation: { _ in
            gate.enter()
            entered.fulfill()
            gate.wait()
            return DetachedApplicationMetadataPoolTests.metadata
        })
        let first = Task { try await firstService.listApplications() }
        await fulfillment(of: [entered], timeout: 2)
        let firstOutput = try await first.value
        XCTAssertEqual(pool.retainedOperationCount, 8)
        XCTAssertEqual(firstOutput.data.applications.count, 8)
        XCTAssertTrue(firstOutput.metadata.warnings.allSatisfy { $0.contains("timed out") })

        // Exact reads use the SAME PID and generation as a blocked metadata getter.
        try await self.verifyExactReads(pid: pids[0], generation: 1)
        XCTAssertEqual(pool.retainedOperationCount, 8)

        let duplicateOutput = try await firstService.listApplications()
        XCTAssertEqual(duplicateOutput.data.applications, firstOutput.data.applications)
        let morePIDs = pids + (991_000..<991_008).map(Int32.init)
        let secondService = self.service(pool: pool, pids: morePIDs, generation: { _ in 2 }, operation: { _ in
            XCTFail("New PID or generation must not bypass aggregate saturation")
            return DetachedApplicationMetadataPoolTests.metadata
        })
        for _ in 0..<3 {
            let output = try await secondService.listApplications()
            XCTAssertEqual(output.summary.status, .partial)
            XCTAssertEqual(output.summary.counts["incompleteApplications"], 16)
            XCTAssertEqual(output.data.applications.count, 16)
            XCTAssertEqual(Set(output.data.applications.map(\.processIdentifier)), Set(morePIDs))
            for row in output.data.applications {
                XCTAssertEqual(row.processStartIdentity, 2)
                XCTAssertEqual(row.windowIDs, [Int(row.processIdentifier)])
                XCTAssertEqual(row.windowCount, 1)
                XCTAssertEqual(row.isHiddenKnown, false)
                XCTAssertNil(row.activationPolicy)
                XCTAssertFalse(row.isEligibleForBulkQuit)
                XCTAssertFalse(row.isEligibleForBackgroundInput)
                XCTAssertFalse(row.isUsableForBroadAutomationDiscovery)
                XCTAssertTrue(row.metadataWarnings?.contains { $0.contains("capacity was exhausted") } == true)
            }
            // Bridge transports these Codable rows; warnings must survive without the outer envelope.
            let roundTrip = try JSONDecoder().decode(
                [ServiceApplicationInfo].self,
                from: JSONEncoder().encode(output.data.applications))
            XCTAssertEqual(roundTrip, output.data.applications)
            XCTAssertEqual(Set(roundTrip.flatMap { $0.metadataWarnings ?? [] }), Set(output.metadata.warnings))
        }
        XCTAssertEqual(gate.count, 8)
        XCTAssertEqual(pool.retainedOperationCount, 8)
        let frozenRows = try JSONEncoder().encode(firstOutput.data.applications)
        gate.release()
        await fulfillment(of: [completion.expectation(at: 8)], timeout: 2)
        XCTAssertEqual(pool.retainedOperationCount, 0)
        XCTAssertEqual(
            try JSONDecoder().decode([ServiceApplicationInfo].self, from: frozenRows),
            firstOutput.data.applications)
        XCTAssertTrue(firstOutput.data.applications.allSatisfy { $0.isHiddenKnown == false })
    }

    func testCancelledInventoryPublishesNothingAndSaturationStillOmitsStaleGenerations() async throws {
        let gate = MetadataNativeGate()
        defer { gate.release() }
        let entered = expectation(description: "cancelled inventory native getters entered")
        entered.expectedFulfillmentCount = 8
        let completion = MetadataCompletionProbe()
        let pool = DetachedApplicationMetadataPool(didComplete: completion.record)
        let pids = (992_000..<992_008).map(Int32.init)
        let firstService = self.service(pool: pool, pids: pids, generation: { _ in 1 }, timeout: 5, operation: { _ in
            gate.enter()
            entered.fulfill()
            gate.wait()
            return DetachedApplicationMetadataPoolTests.metadata
        })
        let first = Task { try await firstService.listApplications() }
        await fulfillment(of: [entered], timeout: 2)
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Cancelled inventory must not publish partial or empty success")
        } catch is CancellationError {}
        XCTAssertEqual(pool.retainedOperationCount, 8)

        let stable: Int32 = 993_000
        let drifting: Int32 = 993_001
        let missing: Int32 = 993_002
        let driftingReads = AutomationTestLockedValue(0)
        let secondService = self.service(
            pool: pool,
            pids: [stable, drifting, missing],
            generation: { pid in
                if pid == missing {
                    return nil
                }
                if pid == drifting {
                    return driftingReads.withValue { reads in
                        reads += 1
                        return reads == 1 ? 2 : 3
                    }
                }
                return 2
            },
            operation: { _ in
                XCTFail("Saturated inventory must not invoke enrichment")
                return DetachedApplicationMetadataPoolTests.metadata
            })
        let output = try await secondService.listApplications()
        XCTAssertEqual(output.data.applications.map(\.processIdentifier), [stable])
        XCTAssertEqual(output.data.applications.first?.windowIDs, [Int(stable)])
        XCTAssertEqual(output.summary.status, .partial)
        XCTAssertEqual(output.summary.counts["omittedApplications"], 2)
        XCTAssertTrue(output.metadata.warnings.contains { $0.contains("capacity was exhausted") })
        XCTAssertTrue(output.metadata.warnings.contains { $0.contains("changed process generation") })
        XCTAssertTrue(output.metadata.warnings.contains { $0.contains("lacked process-generation identity") })
        gate.release()
        await fulfillment(of: [completion.expectation(at: 8)], timeout: 2)
        XCTAssertEqual(pool.retainedOperationCount, 0)
        XCTAssertEqual(output.data.applications.first?.isHiddenKnown, false)
    }

    private func verifyExactReads(pid: Int32, generation: UInt64) async throws {
        let detached = try await ElementDetectionTimeoutRunner.runDetached(
            targetProcessIdentifier: pid,
            targetProcessStartIdentity: generation,
            seconds: 0.5) { "exact AX" }
        XCTAssertEqual(detached, "exact AX")
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: pid,
            ownerProcessStartIdentity: generation,
            capturedBounds: bounds)
        let service = UIAutomationService(
            actionInputDriver: ActionInputDriver(),
            automationElementResolver: AutomationElementResolver(),
            exactWindowFocusReader: { observedPID in
                ExactWindowFocusSnapshot(
                    processIdentifier: observedPID,
                    windowID: 42,
                    frame: CGRect(x: 50, y: 100, width: 200, height: 30))
            },
            exactKeyWindowReader: { observedPID in
                ExactKeyWindowSnapshot(
                    processIdentifier: observedPID, windowID: 42, isSheet: false, hasAttachedSheet: false)
            },
            exactWindowIdentityValidator: { candidate, candidateBounds in
                candidate.hasSameStableReceipt(as: identity) && candidateBounds == bounds
            })
        try await service.requireExactWindowKeyboardFocus(
            expectedWindowIdentity: identity,
            expectedWindowBounds: bounds)
        let windows = try await DetachedAXWindowEnumerationCoordinator.run(
            processIdentifier: pid, processStartIdentity: generation, timeoutSeconds: 0.5)
        { _ in
            DetachedAXWindowEnumerationResult(
                descriptors: [.init(windowID: 42, title: "Synthetic", bounds: bounds)],
                focusedWindowID: 42,
                timedOut: false,
                incomplete: false,
                reportedWindowCount: 1)
        }
        XCTAssertEqual(windows.descriptors.map(\.windowID), [42])
    }

    private func service(
        pool: DetachedApplicationMetadataPool,
        pids: [Int32],
        generation: @escaping ApplicationService.ProcessStartIdentityProvider,
        timeout: TimeInterval = 0.3,
        operation: @escaping @Sendable (DetachedApplicationMetadataRequest) throws -> DetachedApplicationMetadata)
        -> ApplicationService
    {
        ApplicationService(
            applicationOpenHandler: { _, _, _ in throw SaturationFixtureError.unused },
            processStartIdentityProvider: generation,
            runningApplicationProcessIdentifiersProvider: { pids },
            applicationWindowCatalogProvider: {
                pids.map { pid in
                    WindowIdentityInfo(
                        windowID: CGWindowID(pid),
                        title: "Synthetic",
                        bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                        ownerPID: pid,
                        applicationName: "Synthetic \(pid)",
                        bundleIdentifier: nil,
                        layer: 0,
                        alpha: 1,
                        axIdentifier: nil)
                }
            },
            applicationMetadataProvider: { pid, generation, timeout in
                try await DetachedApplicationMetadataCoordinator.run(
                    processIdentifier: pid,
                    processStartIdentity: generation,
                    timeoutSeconds: timeout,
                    pool: pool,
                    operation: operation)
            },
            applicationMetadataTimeout: timeout,
            applicationInventoryOverallTimeout: 10)
    }
}

private enum SaturationFixtureError: Error {
    case unused
}
