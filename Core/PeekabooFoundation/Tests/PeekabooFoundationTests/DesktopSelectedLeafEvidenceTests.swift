import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import PeekabooFoundation

struct DesktopSelectedLeafEvidenceTests {
    @Test(arguments: [
        CGRect(x: CGFloat.nan, y: 10, width: 20, height: 20),
        CGRect(x: CGFloat.infinity, y: 10, width: 20, height: 20),
        CGRect(x: 10, y: -CGFloat.infinity, width: 20, height: 20),
        CGRect(x: 10, y: 10, width: CGFloat.infinity, height: 20),
        CGRect(x: 10, y: 10, width: 20, height: CGFloat.nan),
    ])
    func `initializer rejects nonfinite selected frame components`(frame: CGRect) {
        #expect(throws: DesktopSelectedLeafEvidenceError.invalidEvidence) {
            try Self.leaf(frame: frame)
        }
    }

    @Test
    func `decoder rejects nonfinite frame even with matching canonical leaf hash`() throws {
        let valid = try Self.leaf(frame: Self.validFrame)
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(valid)) as? [String: Any])
        let forgedFrame = CGRect(x: CGFloat.nan, y: 10, width: 20, height: 20)
        object["selectedFrame"] = [["NaN", 10], [20, 20]]
        object["selectedLeafSHA256"] = Self.selectedLeafDigest(frame: forgedFrame)
        let forged = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN")

        #expect(throws: DecodingError.self) {
            try decoder.decode(DesktopSelectedLeafEvidence.self, from: forged)
        }
    }

    @Test
    func `finite selected frame keeps canonical hash and JSON coding`() throws {
        let leaf = try Self.leaf(frame: Self.validFrame)

        #expect(leaf.selectedLeafSHA256 == Self.selectedLeafDigest(frame: Self.validFrame))
        #expect(leaf.selectedLeafSHA256.count == 64)
        #expect(try JSONDecoder().decode(
            DesktopSelectedLeafEvidence.self,
            from: JSONEncoder().encode(leaf)) == leaf)
    }

    private static let validFrame = CGRect(x: 10, y: 10, width: 20, height: 20)

    private static func leaf(frame: CGRect) throws -> DesktopSelectedLeafEvidence {
        try DesktopSelectedLeafEvidence(
            kind: .dockItem,
            normalizedSelector: "safari",
            matchKind: .exact,
            selectedTargetReceipt: .init(processIdentifier: 42, processStartIdentity: 99),
            selectedIndex: 0,
            selectedTitle: "Safari",
            selectedIdentifier: "com.apple.Safari",
            selectedRole: "AXDockItem",
            selectedFrame: frame,
            candidateSetSHA256: String(repeating: "a", count: 64),
            candidateCount: 1)
    }

    private static func selectedLeafDigest(frame: CGRect) -> String {
        self.sha256([
            DesktopSelectedLeafEvidence.Kind.dockItem.rawValue,
            "42",
            "99",
            "-",
            "0",
            "",
            "com.apple.Safari",
            "AXDockItem",
            "",
            self.canonical(frame.origin.x),
            self.canonical(frame.origin.y),
            self.canonical(frame.size.width),
            self.canonical(frame.size.height),
        ])
    }

    private static func sha256(_ components: [String]) -> String {
        var data = Data()
        for component in components {
            let encoded = Data(component.utf8)
            var length = UInt64(encoded.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(encoded)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonical(_ value: CGFloat) -> String {
        String(format: "%016llx", Double(value).bitPattern)
    }
}
