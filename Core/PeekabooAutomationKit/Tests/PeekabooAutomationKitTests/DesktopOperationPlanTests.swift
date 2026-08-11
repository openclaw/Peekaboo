import CoreGraphics
import Foundation
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
                intent: .background)
        }

        let exact = try Self.exactWindowReceipt()
        let receipt = try DesktopOperationPlan.CaptureReceipt(exactWindow: exact)
        let plan = try self.makePlan(
            selector: .coordinates(CGPoint(x: 20, y: 30)),
            receipt: receipt,
            intent: .background)
        #expect(plan.captureReceipt.exactWindow == exact)
    }

    @Test
    func `receipt normalization rejects mismatched process generations`() throws {
        let exact = try Self.exactWindowReceipt(processStartIdentity: 11)
        let process = ApplicationProcessIdentity(processIdentifier: 321, processStartIdentity: 12)

        #expect(throws: (any Error).self) {
            _ = try DesktopOperationPlan.CaptureReceipt(
                processIdentity: process,
                exactWindow: exact)
        }
    }

    @Test
    func `lane scope is derived from intent and stable receipt`() throws {
        let process = ApplicationProcessIdentity(processIdentifier: 321, processStartIdentity: 11)
        let receipt = try DesktopOperationPlan.CaptureReceipt(processIdentity: process)

        let background = try self.makePlan(receipt: receipt, intent: .background)
        let foreground = try self.makePlan(receipt: receipt, intent: .foreground)

        #expect(background.laneScope == .process(process))
        #expect(foreground.laneScope == .global)
    }

    @Test
    func `route requirements remain path specific`() throws {
        let plan = try DesktopOperationPlan(
            verb: .click,
            selector: .focused,
            captureReceipt: DesktopOperationPlan.CaptureReceipt(),
            deliveryIntent: .foreground,
            strategy: .actionFirst,
            action: .init(requirements: .accessibilityAction) {
                UIInputExecutionResult.Action(outcome: .confirmedNoChange())
            },
            synthesis: .init(requirements: .globalEvents) {
                .confirmedNoChange()
            })

        #expect(plan.action?.requirements.permissions == [.accessibility])
        #expect(plan.action?.requirements.capabilities == [.accessibilityAction])
        #expect(plan.synthesis.requirements.permissions == [.eventSynthesizing])
        #expect(plan.synthesis.requirements.capabilities == [.globalEvents])
    }

    private func makePlan(
        selector: DesktopOperationPlan.Selector = .focused,
        receipt: DesktopOperationPlan.CaptureReceipt? = nil,
        intent: DesktopOperationPlan.DeliveryIntent = .foreground) throws -> DesktopOperationPlan
    {
        try DesktopOperationPlan(
            verb: .click,
            selector: selector,
            captureReceipt: receipt ?? DesktopOperationPlan.CaptureReceipt(),
            deliveryIntent: intent,
            strategy: .synthOnly,
            action: nil,
            synthesis: .init(requirements: .globalEvents) { .confirmedNoChange() })
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
