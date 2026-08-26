import Foundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooFoundation

struct SnapshotReferenceTests {
    @Test
    func `generated references are canonical unique 128 bit authorities`() {
        let references = Set((0..<64).map { _ in SnapshotReference.generate() })
        #expect(references.count == 64)
        #expect(references.allSatisfy { reference in
            reference.rawValue.count == SnapshotReference.encodedLength &&
                SnapshotReference(rawValue: reference.rawValue) == reference
        })
    }

    @Test(
        arguments: [
            "",
            "ps1_",
            "ps1_0000000000000000000000000000000",
            "ps1_000000000000000000000000000000000",
            "ps1_0000000000000000000000000000000g",
            "ps1_0000000000000000000000000000000A",
            "PS1_00000000000000000000000000000000",
            "../ps1_00000000000000000000000000000000",
            "1787675983803-1514",
        ])
    func `parser rejects malformed and legacy references`(_ rawValue: String) {
        #expect(SnapshotReference(rawValue: rawValue) == nil)
    }

    @Test
    func `parser never trims case folds or accepts non ASCII numerals`() {
        let canonical = SnapshotReferenceFixtures.first.rawValue
        let hostile = [
            " \(canonical)",
            "\(canonical) ",
            "\(canonical)\n",
            "PS1_" + String(canonical.dropFirst(SnapshotReference.prefix.count)),
            SnapshotReference.prefix + String(repeating: "A", count: 32),
            SnapshotReference.prefix + String(repeating: "٠", count: 32),
            SnapshotReference.prefix + String(repeating: "０", count: 32),
            SnapshotReference.prefix + String(repeating: "é", count: 32),
        ]

        #expect(hostile.allSatisfy { SnapshotReference(rawValue: $0) == nil })
    }

    @Test
    func `codable roundtrip retains only the canonical representation`() throws {
        let reference = SnapshotReferenceFixtures.first
        let data = try JSONEncoder().encode(reference)
        #expect(try JSONDecoder().decode(SnapshotReference.self, from: data) == reference)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SnapshotReference.self, from: Data(#""snapshot-1""#.utf8))
        }
    }
}
