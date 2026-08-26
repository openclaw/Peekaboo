import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct DesktopOperationPlanTests {
    @Test
    func `selector normalization rejects blank semantic targets`() throws {
        #expect(throws: (any Error).self) {
            try self.makePlan(selector: .elementID("  "))
        }
        #expect(throws: (any Error).self) {
            try self.makePlan(selector: .query("\n"))
        }

        let plan = try self.makePlan(selector: .query("  Save  "))
        #expect(plan.selector == .query("Save"))
    }

    @Test
    func `background coordinates require exact capture receipt`() throws {
        #expect(throws: (any Error).self) {
            try self.makePlan(
                selector: .coordinates(CGPoint(x: 20, y: 30)),
                receipt: DesktopOperationPlan.CaptureReceipt(
                    target: .process(UIAutomationTarget.Process(processIdentifier: 321))))
        }

        let exact = try Self.exactWindowReceipt()
        let receipt = DesktopOperationPlan.CaptureReceipt(target: .exactWindow(exact))
        let plan = try self.makePlan(
            selector: .coordinates(CGPoint(x: 20, y: 30)),
            receipt: receipt)
        #expect(plan.captureReceipt.exactWindow == exact)
    }

    @Test
    func `exact window receipt rejects mismatched captured bounds`() throws {
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 321,
            ownerProcessStartIdentity: 11,
            capturedBounds: CGRect(x: 1, y: 2, width: 300, height: 200))

        #expect(throws: (any Error).self) {
            _ = try DesktopOperationPlan.ExactWindowReceipt(
                identity: identity,
                bounds: CGRect(x: 1, y: 2, width: 301, height: 200))
        }
    }

    @Test
    func `lane scope is derived from the validated target`() throws {
        let process = ApplicationProcessIdentity(processIdentifier: 321, processStartIdentity: 11)
        let processReceipt = try DesktopOperationPlan.CaptureReceipt(
            target: .process(UIAutomationTarget.Process(
                processIdentifier: process.processIdentifier,
                identity: process)))

        let background = try self.makePlan(receipt: processReceipt)
        let foreground = try self.makePlan()

        #expect(background.laneScope == .process(process))
        #expect(foreground.laneScope == .global)
        #expect(background.deliveryIntent == .background)
        #expect(foreground.deliveryIntent == .foreground)
    }

    @Test
    func `receipt validation ignores current minimized state`() throws {
        let processIdentity = AutomationTestFixtures.processIdentity()
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let capturedIdentity = AutomationTestFixtures.windowIdentity(
            processIdentity: processIdentity,
            bounds: bounds,
            isMinimized: false)
        let currentIdentity = capturedIdentity.withMinimizedState(true)
        let receipt = try DesktopOperationPlan.CaptureReceipt(
            target: .exactWindow(UIAutomationTarget.ExactWindow(
                identity: capturedIdentity,
                bounds: bounds)))
        let context = WindowContext(
            applicationProcessId: processIdentity.processIdentifier,
            windowID: capturedIdentity.windowID,
            windowBounds: bounds,
            windowMutationIdentity: currentIdentity)

        try DesktopOperationSnapshotReceiptValidator.validate(
            context: context,
            receipt: receipt,
            validateCurrentIdentity: false,
            processStartIdentityProvider: { _ in nil },
            exactWindowIdentityValidator: { _, _ in false })
    }

    @Test
    func `nonexact background receipt retains its exact process generation`() throws {
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: 321,
            processStartIdentity: 77)
        let detectionResult = AutomationTestFixtures.detectionResult(
            windowContext: WindowContext(
                applicationBundleId: "com.example.TestApp",
                applicationProcessId: processIdentity.processIdentifier,
                applicationProcessStartIdentity: processIdentity.processStartIdentity))

        let receipt = try DesktopOperationSnapshotReceiptValidator.captureReceipt(
            snapshotID: detectionResult.snapshotId,
            detectionResult: detectionResult,
            requireExactWindow: false,
            processStartIdentityProvider: { _ in processIdentity.processStartIdentity },
            exactWindowIdentityValidator: { _, _ in false })

        #expect(try receipt.target == .process(UIAutomationTarget.Process(
            processIdentifier: processIdentity.processIdentifier,
            identity: processIdentity)))
        #expect(receipt.processIdentity == processIdentity)
        #expect(receipt.exactWindow == nil)
    }

    @Test
    func `nonexact background receipt rejects missing generation before live validation`() {
        let detectionResult = AutomationTestFixtures.detectionResult(
            windowContext: WindowContext(applicationProcessId: 321))

        let failure = #expect(throws: DesktopActionFailure.self) {
            _ = try DesktopOperationSnapshotReceiptValidator.captureReceipt(
                snapshotID: detectionResult.snapshotId,
                detectionResult: detectionResult,
                requireExactWindow: false,
                processStartIdentityProvider: { _ in
                    Issue.record("Missing generation reached live process validation")
                    return nil
                },
                exactWindowIdentityValidator: { _, _ in false })
        }

        #expect(failure?.outcome.state == .refused)
        #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(failure?.standardErrorCode == .snapshotStale)
        #expect(failure?.causeDescription == DesktopTargetIdentityError.missingProcessGeneration.localizedDescription)
    }

    @Test
    func `nonexact background receipt rejects a substituted live generation`() {
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: 321,
            processStartIdentity: 77)
        let detectionResult = AutomationTestFixtures.detectionResult(
            windowContext: WindowContext(
                applicationProcessId: processIdentity.processIdentifier,
                applicationProcessStartIdentity: processIdentity.processStartIdentity))

        let failure = #expect(throws: DesktopActionFailure.self) {
            _ = try DesktopOperationSnapshotReceiptValidator.captureReceipt(
                snapshotID: detectionResult.snapshotId,
                detectionResult: detectionResult,
                requireExactWindow: false,
                processStartIdentityProvider: { _ in processIdentity.processStartIdentity + 1 },
                exactWindowIdentityValidator: { _, _ in false })
        }
        #expect(failure?.outcome.state == .refused)
        #expect(failure?.standardErrorCode == .snapshotStale)
    }

    @Test
    func `process receipt revalidation rejects PID reuse and process substitution`() throws {
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: 321,
            processStartIdentity: 77)
        let receipt = try DesktopOperationPlan.CaptureReceipt(
            target: .process(UIAutomationTarget.Process(
                processIdentifier: processIdentity.processIdentifier,
                identity: processIdentity)))
        let reusedPID = WindowContext(
            applicationProcessId: processIdentity.processIdentifier,
            applicationProcessStartIdentity: processIdentity.processStartIdentity + 1)
        let substitutedProcess = WindowContext(
            applicationProcessId: processIdentity.processIdentifier + 1,
            applicationProcessStartIdentity: processIdentity.processStartIdentity)

        for context in [reusedPID, substitutedProcess] {
            let failure = #expect(throws: DesktopActionFailure.self) {
                try DesktopOperationSnapshotReceiptValidator.validate(
                    context: context,
                    receipt: receipt,
                    validateCurrentIdentity: false,
                    processStartIdentityProvider: { _ in processIdentity.processStartIdentity },
                    exactWindowIdentityValidator: { _, _ in false })
            }
            #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
            #expect(failure?.standardErrorCode == .snapshotStale)
        }
    }

    @Test
    func `capture planner preserves process versus exact window scope`() throws {
        let processIdentity = AutomationTestFixtures.processIdentity()
        let processDetection = AutomationTestFixtures.detectionResult(
            windowContext: WindowContext(
                applicationProcessId: processIdentity.processIdentifier,
                applicationProcessStartIdentity: processIdentity.processStartIdentity))
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let windowIdentity = AutomationTestFixtures.windowIdentity(
            processIdentity: processIdentity,
            bounds: bounds)
        let windowDetection = AutomationTestFixtures.detectionResult(
            windowContext: WindowContext(
                applicationProcessId: processIdentity.processIdentifier,
                applicationProcessStartIdentity: processIdentity.processStartIdentity,
                windowID: windowIdentity.windowID,
                windowBounds: bounds,
                windowMutationIdentity: windowIdentity))

        let processReceipt = try DesktopOperationSnapshotReceiptValidator.captureReceipt(
            snapshotID: processDetection.snapshotId,
            detectionResult: processDetection,
            requireExactWindow: false,
            processStartIdentityProvider: { _ in processIdentity.processStartIdentity },
            exactWindowIdentityValidator: { _, _ in false })
        let windowReceipt = try DesktopOperationSnapshotReceiptValidator.captureReceipt(
            snapshotID: windowDetection.snapshotId,
            detectionResult: windowDetection,
            requireExactWindow: false,
            processStartIdentityProvider: { _ in processIdentity.processStartIdentity },
            exactWindowIdentityValidator: { identity, actualBounds in
                identity == windowIdentity && actualBounds == bounds
            })

        #expect(processReceipt.processIdentity == processIdentity)
        #expect(processReceipt.exactWindow == nil)
        #expect(windowReceipt.exactWindow?.identity == windowIdentity)
    }

    @Test
    func `capture receipt classifies incomplete immutable window evidence before live validation`() throws {
        let process = AutomationTestFixtures.processIdentity()
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let identity = AutomationTestFixtures.windowIdentity(
            processIdentity: process,
            bounds: nil)
        let detectionResult = AutomationTestFixtures.detectionResult(
            windowContext: WindowContext(
                applicationProcessId: process.processIdentifier,
                windowID: identity.windowID,
                windowBounds: bounds,
                windowMutationIdentity: identity))

        let failure = #expect(throws: DesktopActionFailure.self) {
            _ = try DesktopOperationSnapshotReceiptValidator.captureReceipt(
                snapshotID: detectionResult.snapshotId,
                detectionResult: detectionResult,
                requireExactWindow: true,
                processStartIdentityProvider: { _ in
                    Issue.record("Incomplete receipt reached live process validation")
                    return nil
                },
                exactWindowIdentityValidator: { _, _ in
                    Issue.record("Incomplete receipt reached live window validation")
                    return false
                })
        }

        #expect(failure?.standardErrorCode == .snapshotStale)
        #expect(failure?.causeDescription == DesktopTargetIdentityError.incompleteExactWindow.localizedDescription)
        #expect(failure?.localizedDescription.contains("immutable captured bounds") == true)
    }

    @Test
    func `capture receipt keeps structural bounds conflict distinct from live drift`() throws {
        let process = AutomationTestFixtures.processIdentity()
        let capturedBounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let identity = AutomationTestFixtures.windowIdentity(
            processIdentity: process,
            bounds: capturedBounds)
        let detectionResult = AutomationTestFixtures.detectionResult(
            windowContext: WindowContext(
                applicationProcessId: process.processIdentifier,
                windowID: identity.windowID,
                windowBounds: capturedBounds.offsetBy(dx: 1, dy: 0),
                windowMutationIdentity: identity))

        let failure = #expect(throws: DesktopActionFailure.self) {
            _ = try DesktopOperationSnapshotReceiptValidator.captureReceipt(
                snapshotID: detectionResult.snapshotId,
                detectionResult: detectionResult,
                requireExactWindow: true,
                processStartIdentityProvider: { _ in process.processStartIdentity },
                exactWindowIdentityValidator: { _, _ in true })
        }

        #expect(failure?.standardErrorCode == .snapshotStale)
        #expect(failure?.causeDescription == DesktopTargetIdentityError.contradictoryWindowBounds.localizedDescription)
    }

    @Test
    func `capture receipt preserves live process drift as stale snapshot`() throws {
        let process = AutomationTestFixtures.processIdentity()
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let identity = AutomationTestFixtures.windowIdentity(
            processIdentity: process,
            bounds: bounds)
        let detectionResult = AutomationTestFixtures.detectionResult(
            windowContext: WindowContext(
                applicationProcessId: process.processIdentifier,
                windowID: identity.windowID,
                windowBounds: bounds,
                windowMutationIdentity: identity))

        do {
            _ = try DesktopOperationSnapshotReceiptValidator.captureReceipt(
                snapshotID: detectionResult.snapshotId,
                detectionResult: detectionResult,
                requireExactWindow: true,
                processStartIdentityProvider: { _ in process.processStartIdentity + 1 },
                exactWindowIdentityValidator: { _, _ in true })
            Issue.record("Expected live process drift to remain a stale-snapshot failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.standardErrorCode == .snapshotStale)
            #expect(failure.message.lowercased().contains("process generation"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func makePlan(
        selector: DesktopOperationPlan.Selector = .focused,
        receipt: DesktopOperationPlan.CaptureReceipt? = nil) throws -> DesktopOperationPlan
    {
        try DesktopOperationPlan(
            verb: .click,
            selector: selector,
            captureReceipt: receipt ?? DesktopOperationPlan.CaptureReceipt(target: .foreground),
            strategy: .synthOnly,
            action: nil,
            synthesis: .init { .confirmedNoChange() })
    }

    private static func exactWindowReceipt(
        processStartIdentity: UInt64 = 11) throws -> DesktopOperationPlan.ExactWindowReceipt
    {
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        return try DesktopOperationPlan.ExactWindowReceipt(
            identity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: 321,
                ownerProcessStartIdentity: processStartIdentity,
                capturedBounds: bounds),
            bounds: bounds)
    }
}
