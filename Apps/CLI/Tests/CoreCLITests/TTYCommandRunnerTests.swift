import Darwin
import Foundation
import Testing

@Suite(.tags(.unit))
struct TTYCommandRunnerTests {
    @Test
    func `Kills process-group children on cleanup`() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tty-runner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let scriptURL = tmp.appendingPathComponent("spawn_child.sh")
        let script = """
        #!/bin/bash
        set -e
        sleep 60 &
        child=$!
        echo CHILD_PID=$child
        sleep 60
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let runner = TTYCommandRunner()
        let result = try runner.run(
            binary: scriptURL.path,
            send: "",
            options: .init(rows: 5, cols: 40, extraArgs: [])
        )

        guard let childPID = Self.extractChildPID(result.text) else {
            Issue.record("Did not capture child PID from PTY output. Output: \(result.text)")
            return
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while kill(childPID, 0) == 0, ContinuousClock.now < deadline {
            usleep(10000)
        }
        errno = 0
        let probe = kill(childPID, 0)
        let probeError = errno
        #expect(
            probe == -1 && probeError == ESRCH,
            "Child process (pid: \(childPID)) was not proven absent after cleanup"
        )
    }

    private static func extractChildPID(_ text: String) -> pid_t? {
        let pattern = #"CHILD_PID=([0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges >= 2,
              let pidRange = Range(match.range(at: 1), in: text) else { return nil }
        return pid_t(text[pidRange])
    }
}
