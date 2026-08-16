import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct DesktopLeafSelectionTests {
    private struct Value: Equatable {
        let name: String
    }

    @Test
    func `exact match wins independently of candidate order`() throws {
        let folded = self.candidate(index: 0, name: "WiFi")
        let exact = self.candidate(index: 1, name: "Wi-Fi")

        for candidates in [[folded, exact], [exact, folded]] {
            let selection = try DeterministicDesktopLeafSelector.select(
                named: "Wi-Fi",
                from: candidates)
            #expect(selection.candidate.value == Value(name: "Wi-Fi"))
            #expect(selection.matchKind == .exact)
        }
    }

    @Test
    func `winning precedence ambiguity refuses instead of selecting first`() {
        let candidates = [
            self.candidate(index: 0, name: "Clock", fields: ["Clock", "Time"]),
            self.candidate(index: 1, name: "Clock", fields: ["Clock", "Date"]),
        ]

        #expect(throws: DesktopLeafSelectionError.self) {
            try DeterministicDesktopLeafSelector.select(named: "Clock", from: candidates)
        }
    }

    @Test
    func `partial ambiguity refuses even when one candidate appears first`() {
        let candidates = [
            self.candidate(index: 0, name: "Safari Technology Preview"),
            self.candidate(index: 1, name: "Safari"),
        ]

        #expect(throws: DesktopLeafSelectionError.self) {
            try DeterministicDesktopLeafSelector.select(named: "Saf", from: candidates)
        }
    }

    @Test
    func `selected leaf evidence detects reorder and substitution`() throws {
        let original = try self.evidence(index: 0, title: "Clock", candidateDigest: "a")
        let reordered = try self.evidence(index: 1, title: "Clock", candidateDigest: "b")
        let substituted = try self.evidence(
            index: 0,
            title: "Control Center",
            candidateDigest: "a",
            identifier: "fixture.substituted")

        #expect(!original.hasSameResolvedLeaf(as: reordered))
        #expect(!original.hasSameResolvedLeaf(as: substituted))
        #expect(try original.hasSameResolvedLeaf(as: original.selecting(
            normalizedSelector: "clock",
            matchKind: .normalizedExact)))
    }

    @Test
    func `stable identifier tolerates a dynamic status title`() throws {
        let original = try self.evidence(index: 0, title: "12:34", candidateDigest: "a")
        let updated = try self.evidence(index: 0, title: "12:35", candidateDigest: "a")

        #expect(original.hasSameResolvedLeaf(as: updated))
        #expect(original.selectedLeafSHA256 == updated.selectedLeafSHA256)
    }

    @Test
    func `selected leaf decoding rejects a forged leaf digest`() throws {
        let evidence = try self.evidence(index: 0, title: "Clock", candidateDigest: "a")
        let encoder = JSONEncoder()
        let data = try encoder.encode(evidence)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["selectedLeafSHA256"] = String(repeating: "0", count: 64)
        let forged = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DesktopSelectedLeafEvidence.self, from: forged)
        }
    }

    private func candidate(
        index: Int,
        name: String,
        fields: [String]? = nil) -> DeterministicDesktopLeafSelector.Candidate<Value>
    {
        .init(
            value: Value(name: name),
            index: index,
            displayName: name,
            matchFields: fields ?? [name],
            stableIdentity: "\(index)|\(name)")
    }

    private func evidence(
        index: Int,
        title: String,
        candidateDigest: Character,
        identifier: String? = nil) throws -> DesktopSelectedLeafEvidence
    {
        try DesktopSelectedLeafEvidence(
            kind: .menuBarItem,
            normalizedSelector: String(index),
            matchKind: .index,
            selectedProcessIdentity: .init(processIdentifier: 42, processStartIdentity: 99),
            selectedIndex: index,
            selectedTitle: title,
            selectedIdentifier: identifier ?? "fixture.\(index)",
            selectedRole: "AXStatusItem",
            selectedFrame: CGRect(x: CGFloat(index * 30), y: 0, width: 20, height: 20),
            candidateSetSHA256: String(repeating: candidateDigest, count: 64),
            candidateCount: 2)
    }
}
