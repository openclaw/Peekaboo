import CoreGraphics
import Foundation
import Testing
@testable import PeekabooFoundation

struct DesktopActionFailureSelectedLeafTests {
    @Test
    func `dispatched failure preserves selected leaf through routing attribution and coding`() throws {
        let leaf = try self.leaf()
        let failure = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "AXPress completion is unknown")
            .selectingLeaves([leaf])
            .attributed(to: leaf.selectedTargetReceipt)
            .routed(to: .bridge)

        #expect(failure.selectedLeafEvidence == [leaf])
        let decoded = try JSONDecoder().decode(
            DesktopActionFailure.self,
            from: JSONEncoder().encode(failure))
        #expect(decoded == failure)
    }

    @Test
    func `no-dispatch failure drops selected leaf evidence`() throws {
        let leaf = try self.leaf()
        let refusal = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Target changed")
            .selectingLeaves([leaf])

        #expect(refusal.selectedLeafEvidence == nil)
    }

    @Test
    func `decoding rejects selected leaf evidence on no-dispatch failure`() throws {
        let leaf = try self.leaf()
        let refusal = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Target changed")
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(refusal)) as? [String: Any])
        object["selected_leaf_evidence"] = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode([leaf])) as? [[String: Any]])
        let forged = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DesktopActionFailure.self, from: forged)
        }
    }

    private func leaf() throws -> DesktopSelectedLeafEvidence {
        try DesktopSelectedLeafEvidence(
            kind: .dockItem,
            normalizedSelector: "safari",
            matchKind: .exact,
            selectedTargetReceipt: .init(processIdentifier: 42, processStartIdentity: 99),
            selectedIndex: 0,
            selectedTitle: "Safari",
            selectedIdentifier: "com.apple.Safari",
            selectedRole: "AXDockItem",
            selectedFrame: CGRect(x: 10, y: 10, width: 20, height: 20),
            candidateSetSHA256: String(repeating: "a", count: 64),
            candidateCount: 1)
    }
}
