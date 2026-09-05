import Foundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe), .serialized)
struct GitStalenessProbeTests {
    @Test
    func `large real git status is drained before waiting for exit`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try #require(runGitStalenessProbe(arguments: ["init", "-q"], directory: root))
        let paths = (0..<1500).map {
            root.appendingPathComponent("tracked-\($0)-" + String(repeating: "x", count: 80))
        }
        for path in paths {
            try Data("before".utf8).write(to: path)
        }
        _ = try #require(runGitStalenessProbe(arguments: ["add", "."], directory: root))
        for path in paths {
            try Data("after".utf8).write(to: path)
        }
        let output = try #require(runGitStalenessProbe(arguments: ["status", "--porcelain=1"], directory: root))
        #expect(output.count > 65536)
        let lines = try #require(String(data: output, encoding: .utf8)).split(separator: "\n")
        #expect(lines.count == paths.count)
        #expect(lines.allSatisfy { $0.hasPrefix("AM tracked-") })
    }

    @Test
    func `noisy stderr does not fill an undrained pipe`() throws {
        let alias = "!i=0; while [ $i -lt 3000 ]; do " +
            "printf 'diagnostic diagnostic diagnostic\\n' >&2; i=$((i+1)); done; printf done"
        let output = try #require(runGitStalenessProbe(arguments: ["-c", "alias.probe=" + alias, "probe"]))
        #expect(String(data: output, encoding: .utf8) == "done")
    }

    @Test
    func `a failed git probe skips the optional diagnostic`() {
        #expect(runGitStalenessProbe(arguments: ["peekaboo-nonexistent-command"]) == nil)
    }
}
