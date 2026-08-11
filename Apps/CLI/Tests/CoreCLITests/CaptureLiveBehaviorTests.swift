import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

struct CaptureLiveBehaviorTests {
    @Test
    func `resolveMode defaults to window when targeting app pid title or index`() throws {
        var cmd = CaptureLiveCommand()
        cmd.app = "Safari"
        #expect(try cmd.resolveMode() == .window)

        cmd.app = nil
        cmd.pid = 123
        #expect(try cmd.resolveMode() == .window)

        cmd.pid = nil
        cmd.windowTitle = "Log"
        #expect(try cmd.resolveMode() == .window)

        cmd.windowTitle = nil
        cmd.windowIndex = 0
        #expect(try cmd.resolveMode() == .window)
    }

    @Test
    func `resolveMode defaults to frontmost when no targeting`() throws {
        let cmd = CaptureLiveCommand()
        #expect(try cmd.resolveMode() == .frontmost)
    }

    @Test
    func `resolveMode uses area when region is provided`() throws {
        var cmd = CaptureLiveCommand()
        cmd.region = "10,20,300,200"
        #expect(try cmd.resolveMode() == .area)
        #expect(try cmd.parseRegion() == CGRect(x: 10, y: 20, width: 300, height: 200))
    }

    @Test
    func `resolveMode accepts region alias for area`() throws {
        var cmd = CaptureLiveCommand()
        cmd.mode = "region"
        cmd.region = "10,20,300,200"
        #expect(try cmd.resolveMode() == .area)
    }

    @Test
    func `resolveMode rejects invalid mode`() {
        var cmd = CaptureLiveCommand()
        cmd.mode = "banana"
        #expect(throws: ValidationError.self) {
            _ = try cmd.resolveMode()
        }
    }

    @Test
    func `parseRegion rejects malformed or empty dimensions`() {
        var invalid = CaptureLiveCommand()
        invalid.region = "1,2,3"
        #expect(throws: PeekabooError.self) {
            _ = try invalid.parseRegion()
        }

        var zero = CaptureLiveCommand()
        zero.region = "1,2,0,4"
        #expect(throws: PeekabooError.self) {
            _ = try zero.parseRegion()
        }
    }

    @Test
    func `capture commands reject invalid diff strategy`() {
        var live = CaptureLiveCommand()
        live.diffStrategy = "slow"
        #expect(throws: ValidationError.self) {
            _ = try live.buildOptions()
        }

        var video = CaptureVideoCommand()
        video.diffStrategy = "slow"
        #expect(throws: ValidationError.self) {
            _ = try video.buildOptions()
        }
    }

    @Test
    func `live cadence rejects nonfinite out of range and inverted rates`() {
        for idle in [Double.nan, 0, 0.099, 5.001] {
            var command = CaptureLiveCommand()
            command.idleFps = idle
            #expect(throws: CaptureCadenceValidationError.self) {
                _ = try command.buildOptions()
            }
        }

        for active in [Double.infinity, 0, 0.499, 15.001] {
            var command = CaptureLiveCommand()
            command.activeFps = active
            #expect(throws: CaptureCadenceValidationError.self) {
                _ = try command.buildOptions()
            }
        }

        var inverted = CaptureLiveCommand()
        inverted.idleFps = 5
        inverted.activeFps = 4
        #expect(throws: CaptureCadenceValidationError.self) {
            _ = try inverted.buildOptions()
        }
    }

    @Test
    func `cadence validation maps to a pre-dispatch validation error`() {
        let error = CaptureCadenceValidationError.activeBelowIdle(active: 4, idle: 5)
        #expect(CaptureLiveCommand().mapErrorToCode(error) == .VALIDATION_ERROR)
    }

    @Test
    func `human output preserves nonzero tiny frame deltas`() {
        #expect(CaptureLiveCommand.formatChangePercent(0) == "0.00")
        #expect(CaptureLiveCommand.formatChangePercent(0.004) == "0.004")
        #expect(CaptureLiveCommand.formatChangePercent(0.012) == "0.01")
    }
}
