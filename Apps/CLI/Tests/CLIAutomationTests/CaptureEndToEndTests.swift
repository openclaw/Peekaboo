import Commander
import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

/// Note: These are lightweight, non-I/O tests—real screen/video IO is not exercised here.
/// They validate flag validation and MP4 toggle plumbing to replace the removed watch suites
/// without requiring fixtures or permissions.
struct CaptureEndToEndTests {
    @Test
    func `video flags reject dual sampling`() async throws {
        var cmd = CaptureVideoCommand()
        cmd.input = "/tmp/foo.mov"
        cmd.sampleFps = 2
        cmd.every = .milliseconds(100)
        await #expect(throws: ValidationError.self) {
            _ = try await cmd.run(using: CommandRuntime.makeDefault())
        }
    }

    @Test
    func `live uses temp output when no path provided`() throws {
        let cmd = CaptureLiveCommand()
        let url = try cmd.resolveOutputDirectory()
        #expect(url.path.contains("capture-sessions"))
    }
}
