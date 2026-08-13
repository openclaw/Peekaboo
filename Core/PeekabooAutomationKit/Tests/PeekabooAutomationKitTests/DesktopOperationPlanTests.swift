import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
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
