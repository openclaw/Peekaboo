import Foundation
import PeekabooBridge
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
struct DaemonHistoricalCleanupTests {
    @Test
    func `only automatic build scoped daemons own deferred historical cleanup`() {
        let defaultSocketURL = URL(fileURLWithPath: PeekabooBridgeConstants.daemonSocketPath)
        let buildSocketPath = defaultSocketURL.deletingLastPathComponent()
            .appendingPathComponent("daemon-aaaaaaaaaaaaaaaa.sock").path

        #expect(DaemonCommand.Run.shouldScheduleHistoricalCleanup(.auto(
            bridgeSocketPath: buildSocketPath
        )))
        #expect(!DaemonCommand.Run.shouldScheduleHistoricalCleanup(.manual(
            bridgeSocketPath: buildSocketPath
        )))
        #expect(!DaemonCommand.Run.shouldScheduleHistoricalCleanup(.auto(
            bridgeSocketPath: PeekabooBridgeConstants.daemonSocketPath
        )))
        #expect(!DaemonCommand.Run.shouldScheduleHistoricalCleanup(.auto(
            bridgeSocketPath: "/tmp/daemon-aaaaaaaaaaaaaaaa.sock"
        )))
    }
}
