import Commander
import PeekabooCore
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCLI

@Suite(.tags(.imageCapture, .unit))
@MainActor
struct ImageObservationTargetParityTests {
    @Test(.tags(.fast))
    func `image window selection rejects title and index`() throws {
        let command = try SeeCommand.parse([
            "--mode", "window",
            "--app", "Safari",
            "--window-title", "Inbox",
            "--window-index", "2",
        ])

        #expect(throws: ValidationError.self) {
            try command.observationWindowSelection()
        }
    }

    @Test(.tags(.fast))
    func `image app title target matches MCP parser`() throws {
        let command = try SeeCommand.parse([
            "--mode", "window",
            "--app", "Safari",
            "--window-title", "Inbox",
        ])

        let imageTarget = try command.observationApplicationTargetForWindowCapture()
        let mcpTarget = try ObservationTargetArgument.parse("Safari:Inbox").observationTarget

        #expect(imageTarget.target == mcpTarget)
        #expect(imageTarget.focusIdentifier == "Safari")
        #expect(imageTarget.preferredName == "Safari")
    }

    @Test(.tags(.fast))
    func `image pid target matches MCP parser`() throws {
        let command = try SeeCommand.parse([
            "--mode", "window",
            "--pid", "123",
        ])

        let imageTarget = try command.observationApplicationTargetForWindowCapture()
        let mcpTarget = try ObservationTargetArgument.parse("PID:123").observationTarget

        #expect(imageTarget.target == mcpTarget)
        #expect(imageTarget.focusIdentifier == "PID:123")
        #expect(imageTarget.preferredName == "PID:123")
    }

    @Test(.tags(.fast))
    func `image app PID target maps to pid observation target`() throws {
        let command = try SeeCommand.parse([
            "--mode", "window",
            "--app", "PID:123",
        ])

        let imageTarget = try command.observationApplicationTargetForWindowCapture()

        #expect(imageTarget.target == .pid(123, window: .automatic))
        #expect(imageTarget.focusIdentifier == "PID:123")
    }

    @Test(.tags(.fast))
    func `image exact window preserves owner and rejects conflicting selectors`() throws {
        let appCommand = try SeeCommand.parse([
            "--app", "Safari",
            "--window-id", "42",
        ])
        #expect(try appCommand.observationTargetForExactWindowCapture(42) ==
            .app(identifier: "Safari", window: .id(42)))

        let pidCommand = try SeeCommand.parse([
            "--pid", "123",
            "--window-id", "42",
        ])
        #expect(try pidCommand.observationTargetForExactWindowCapture(42) ==
            .pid(123, window: .id(42)))

        let conflicting = try SeeCommand.parse([
            "--app", "Safari",
            "--window-id", "42",
            "--window-index", "1",
        ])
        #expect(throws: (any Error).self) {
            try conflicting.observationTargetForExactWindowCapture(42)
        }
    }

    @available(macOS 14.0, *)
    @Test(.tags(.fast))
    func `see app PID target maps to pid observation target`() throws {
        let command = try SeeCommand.parse([
            "--mode", "window",
            "--app", "PID:123",
        ])

        let target = try command.observationTargetForCaptureWithDetectionIfPossible()

        #expect(target == .pid(123, window: .automatic))
    }

    @available(macOS 14.0, *)
    @Test(.tags(.fast))
    func `see exact window preserves owner and rejects conflicting title`() throws {
        let appCommand = try SeeCommand.parse([
            "--app", "Safari",
            "--window-id", "42",
        ])
        #expect(try appCommand.observationTargetForCaptureWithDetectionIfPossible() ==
            .app(identifier: "Safari", window: .id(42)))

        let pidCommand = try SeeCommand.parse([
            "--pid", "123",
            "--window-id", "42",
        ])
        #expect(try pidCommand.observationTargetForCaptureWithDetectionIfPossible() ==
            .pid(123, window: .id(42)))

        let conflicting = try SeeCommand.parse([
            "--app", "Safari",
            "--window-id", "42",
            "--window-title", "Inbox",
        ])
        #expect(throws: (any Error).self) {
            try conflicting.observationTargetForCaptureWithDetectionIfPossible()
        }
    }
}
