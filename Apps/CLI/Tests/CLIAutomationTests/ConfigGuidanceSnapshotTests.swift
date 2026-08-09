import Foundation
import Testing
@testable import PeekabooCLI

struct ConfigGuidanceSnapshotTests {
    @Test
    func `init guidance matches snapshot`() throws {
        let rendered = PeekabooConfigMessages.initGuidance(path: "/tmp/config.json")
            .joined(separator: "\n")

        guard let snapshotURL = Bundle.module.url(
            forResource: "config_init",
            withExtension: "txt"
        ) else {
            Issue.record("Snapshot file config_init.txt not found in test bundle")
            return
        }

        let snapshot = try String(contentsOf: snapshotURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(rendered.trimmingCharacters(in: .whitespacesAndNewlines) == snapshot)
    }
}
