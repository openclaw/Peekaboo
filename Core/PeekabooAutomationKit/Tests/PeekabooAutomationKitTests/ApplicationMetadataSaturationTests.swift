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
        do {
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
            await self.verifySaturatedFinalValidation(pool: pool, metadataGate: gate, pid: pids[0])
            let frozenRows = try JSONEncoder().encode(firstOutput.data.applications)
            gate.release()
            await fulfillment(of: [completion.expectation(at: 8)], timeout: 5)
            XCTAssertEqual(pool.retainedOperationCount, 0)
            XCTAssertEqual(
                try JSONDecoder().decode([ServiceApplicationInfo].self, from: frozenRows),
                firstOutput.data.applications)
            XCTAssertTrue(firstOutput.data.applications.allSatisfy { $0.isHiddenKnown == false })
        } catch {
            await self.verifyInventorySlotDrained()
            gate.release()
            _ = await first.result
            await fulfillment(of: [completion.expectation(at: 8)], timeout: 5)
            XCTAssertEqual(pool.retainedOperationCount, 0)
            throw error
        }
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

    private func verifySaturatedFinalValidation(
        pool: DetachedApplicationMetadataPool,
        metadataGate: MetadataNativeGate,
        pid: Int32) async
    {
        let finalGate = MetadataNativeGate()
        defer { finalGate.release() }
        let finalEntered = expectation(description: "saturated inventory entered final generation validation")
        let finalFinished = expectation(description: "final generation getter finished")
        let generationReads = AutomationTestLockedValue(0)
        let metadataOverloads = AutomationTestLockedValue(0)
        let finalGetterReturned = AutomationTestLockedValue(false)
        let service = self.service(
            pool: pool,
            pids: [pid],
            generation: { observedPID in
                XCTAssertEqual(observedPID, pid)
                let read = generationReads.withValue { reads in
                    reads += 1
                    return reads
                }
                if read == 2 {
                    XCTAssertEqual(metadataOverloads.value, 1)
                    finalGate.enter()
                    finalEntered.fulfill()
                    // This synchronous watchdog also releases the old MainActor implementation.
                    finalGate.wait(watchdogSeconds: 5)
                    finalGetterReturned.value = true
                    finalFinished.fulfill()
                }
                return 2
            },
            metadataOverloads: metadataOverloads,
            operation: { _ in
                XCTFail("A new generation must be rejected while all eight metadata reservations remain retained")
                return DetachedApplicationMetadataPoolTests.metadata
            })
        let inventory = Task { try await service.listApplications() }
        await fulfillment(of: [finalEntered], timeout: 2)

        var timeoutReason: String?
        do {
            _ = try await inventory.value
            XCTFail("Saturated inventory must time out without publishing partial rows or skipping final validation")
        } catch let error as PeekabooError {
            if case let .timeout(reason) = error {
                timeoutReason = reason
            } else {
                XCTFail("Expected inventory timeout, got \(error)")
            }
        } catch {
            XCTFail("Expected PeekabooError.timeout, got \(error)")
        }
        XCTAssertEqual(generationReads.value, 2)
        XCTAssertEqual(metadataOverloads.value, 1)
        XCTAssertEqual(finalGate.count, 1)
        XCTAssertFalse(finalGetterReturned.value, "Caller must time out while final validation is still held")
        XCTAssertEqual(metadataGate.count, 8)
        XCTAssertEqual(pool.retainedOperationCount, 8)

        finalGate.release()
        await fulfillment(of: [finalFinished], timeout: 5)
        XCTAssertTrue(finalGetterReturned.value)
        do {
            _ = try await inventory.value
            XCTFail("Late final validation must not replace the original inventory timeout with success")
        } catch let error as PeekabooError {
            if case let .timeout(reason) = error {
                XCTAssertEqual(reason, timeoutReason)
            } else {
                XCTFail("Expected the same terminal inventory timeout, got \(error)")
            }
        } catch {
            XCTFail("Expected the same terminal PeekabooError.timeout, got \(error)")
        }
        // The getter's finished signal precedes release of the inventory worker's native slot.
        await self.verifyInventorySlotDrained()
        XCTAssertEqual(generationReads.value, 2)
        XCTAssertEqual(metadataGate.count, 8)
        XCTAssertEqual(pool.retainedOperationCount, 8)
    }

    private func verifyInventorySlotDrained() async {
        let seedReads = AutomationTestLockedValue(0)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw SaturationFixtureError.unused },
            frontmostProcessIdentifierProvider: { nil },
            processStartIdentityProvider: { _ in
                XCTFail("Empty synthetic inventory must not read process generations")
                return nil
            },
            runningApplicationProcessIdentifiersProvider: {
                seedReads.withValue { $0 += 1 }
                return []
            },
            applicationWindowCatalogProvider: { [] },
            applicationMetadataProvider: { _, _, _ in
                XCTFail("Empty synthetic inventory must not read native metadata")
                return DetachedApplicationMetadataPoolTests.metadata
            })
        let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            let readsBeforeAttempt = seedReads.value
            do {
                let output = try await service.listApplications()
                XCTAssertEqual(seedReads.value, readsBeforeAttempt + 1)
                XCTAssertTrue(output.data.applications.isEmpty)
                XCTAssertTrue(output.metadata.warnings.isEmpty)
                XCTAssertEqual(output.summary.status, .success)
                return
            } catch let error as PeekabooError {
                guard case .timeout = error,
                      seedReads.value == readsBeforeAttempt,
                      ContinuousClock.now < cleanupDeadline
                else {
                    XCTFail("Empty synthetic inventory failed to prove native-slot drain: \(error)")
                    return
                }
                // Only retry busy admission: a timed-out attempt must not have entered its PID provider.
                await Task.yield()
            } catch {
                XCTFail("Unexpected inventory cleanup error: \(error)")
                return
            }
        }
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
        metadataOverloads: AutomationTestLockedValue<Int>? = nil,
        operation: @escaping @Sendable (DetachedApplicationMetadataRequest) throws -> DetachedApplicationMetadata)
        -> ApplicationService
    {
        ApplicationService(
            applicationOpenHandler: { _, _, _ in throw SaturationFixtureError.unused },
            frontmostProcessIdentifierProvider: { nil },
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
                do {
                    return try await DetachedApplicationMetadataCoordinator.run(
                        processIdentifier: pid,
                        processStartIdentity: generation,
                        timeoutSeconds: timeout,
                        pool: pool,
                        operation: operation)
                } catch ApplicationMetadataAdmissionError.overloaded {
                    metadataOverloads?.withValue { $0 += 1 }
                    throw ApplicationMetadataAdmissionError.overloaded
                }
            },
            applicationMetadataTimeout: timeout)
    }
}

private enum SaturationFixtureError: Error {
    case unused
}
