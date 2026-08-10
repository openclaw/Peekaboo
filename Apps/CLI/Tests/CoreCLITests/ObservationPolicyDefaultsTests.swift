import Commander
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(.tags(.fast))
@MainActor
struct ObservationPolicyDefaultsTests {
    @Test
    func `See defaults to read only observation`() throws {
        let command = try SeeCommand.parse([])

        #expect(!command.webFocus)
        #expect(!command.noWebFocus)
        let request = command.makeObservationRequest(target: .frontmost)
        #expect(request.capture.focus == .background)
        #expect(!request.detection.allowWebFocusFallback)
        #expect(request.timeout.overall == 20)
        #expect(request.timeout.detection == 20)
    }

    @Test
    func `See propagates its overall timeout to remote observation`() throws {
        var configured = try SeeCommand.parse([])
        configured.timeout = .seconds(45)
        var analyzed = try SeeCommand.parse([])
        analyzed.analyze = "summarize"

        #expect(configured.makeObservationRequest(target: .frontmost).timeout.overall == 45)
        #expect(configured.makeObservationRequest(target: .frontmost).timeout.detection == 45)
        #expect(analyzed.makeObservationRequest(target: .frontmost).timeout.overall == 60)
    }

    @Test
    func `See web focus fallback is a positive opt in`() throws {
        let enabled = try SeeCommand.parse(["--web-focus"])
        #expect(enabled.webFocus)
        #expect(enabled.makeObservationRequest(target: .frontmost).detection.allowWebFocusFallback)

        let compatibility = try SeeCommand.parse(["--no-web-focus"])
        #expect(compatibility.noWebFocus)
        #expect(!compatibility.makeObservationRequest(target: .frontmost).detection.allowWebFocusFallback)
    }

    @Test
    func `See exposes AX tree inspection without enabling web focus`() throws {
        let command = try SeeCommand.parse(["--tree", "--no-screenshot"])
        #expect(command.tree)
        #expect(command.noScreenshot)
        #expect(!command.webFocus)
    }

    @Test
    func `See pixel capture and live capture default to background focus policy`() throws {
        #expect(try SeeCommand.parse(["--no-elements"]).captureFocus == .background)
        #expect(try CaptureLiveCommand.parse([]).captureFocus == .background)
        #expect(CaptureActionCommand().captureFocus == .background)
    }
}
