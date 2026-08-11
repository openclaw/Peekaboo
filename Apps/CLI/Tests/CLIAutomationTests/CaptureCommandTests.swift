import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

struct CaptureCommandTests {
    @Test
    func `buildOptions clamps non-cadence values`() throws {
        var cmd = CaptureLiveCommand()
        cmd.duration = .seconds(999)
        cmd.idleFps = 5
        cmd.activeFps = 15
        cmd.threshold = 200
        cmd.heartbeat = .seconds(-1)
        cmd.quiet = .milliseconds(-10)
        cmd.maxFrames = 0
        cmd.resolutionCap = 10
        cmd.maxMb = -5

        let opts = try cmd.buildOptions()
        #expect(opts.duration <= 180)
        #expect(opts.idleFps == 5)
        #expect(opts.activeFps == 15)
        #expect(opts.changeThresholdPercent <= 100)
        #expect(opts.heartbeatSeconds >= 0)
        #expect(opts.quietMsToIdle >= 0)
        #expect(opts.maxFrames >= 1)
        #expect(opts.maxMegabytes == nil)
        #expect(opts.resolutionCap == 10)
    }

    @Test
    func `video options defaults`() throws {
        let cmd = CaptureVideoCommand()
        let opts = try cmd.buildOptions()
        #expect(opts.maxFrames >= 1)
        #expect(opts.resolutionCap == 1440)
        #expect(opts.diffStrategy == .fast)
    }
}
