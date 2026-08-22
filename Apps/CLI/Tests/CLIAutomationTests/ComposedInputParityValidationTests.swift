import Commander
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
struct ComposedInputParityValidationTests {
    @Test
    func `pixel focus type requires one explicit background snapshot target`() throws {
        let invalidArguments = [
            ["hello", "--at", "10,20"],
            ["hello", "--at", "10,20", "--snapshot", "latest"],
            ["hello", "--at", "10,20", "--snapshot", "snap", "--foreground"],
            ["hello", "--at", "10,20", "--snapshot", "snap", "--app", "TextEdit"],
        ]

        for arguments in invalidArguments {
            #expect(throws: (any Error).self) {
                var command = try TypeCommand.parse(arguments)
                try command.validate()
            }
        }

        var accepted = try TypeCommand.parse([
            "hello", "--at", "10,20", "--coordinate-space", "image_pixels", "--snapshot", "snap",
        ])
        try accepted.validate()
    }

    @Test
    func `modifier click requires explicit foreground and exact snapshot authority`() throws {
        let invalidArguments = [
            ["--on", "B1", "--modifiers", "cmd", "--snapshot", "snap"],
            ["--on", "B1", "--modifiers", "cmd", "--foreground"],
            ["--on", "B1", "--modifiers", "cmd", "--foreground", "--snapshot", "latest"],
            ["--on", "B1", "--modifiers", "fn", "--foreground", "--snapshot", "snap"],
            ["--on", "B1", "--modifiers", "ctrl", "--foreground", "--snapshot", "snap"],
            ["--on", "B1", "--modifiers", "cmd", "--right", "--foreground", "--snapshot", "snap"],
            ["--on", "B1", "--modifiers", "cmd", "--foreground", "--snapshot", "snap", "--app", "Safari"],
            ["--on", "B1", "--modifiers", "cmd", "--foreground", "--snapshot", "snap", "--space-switch"],
        ]

        for arguments in invalidArguments {
            #expect(throws: (any Error).self) {
                var command = try ClickCommand.parse(arguments)
                try command.validate()
            }
        }

        var accepted = try ClickCommand.parse([
            "--on", "B1", "--modifiers", "cmd,shift", "--foreground", "--snapshot", "snap",
        ])
        try accepted.validate()
    }

    @Test
    @MainActor
    func `pixel focus receipt planning preserves cancellation without consuming snapshot`() async throws {
        let snapshots = StubSnapshotManager()
        let snapshotID = try await snapshots.createSnapshot()
        snapshots.uiAutomationSnapshotCancellation = true

        await #expect(throws: CancellationError.self) {
            _ = try await TypeCommand.planPixelFocusReceipt(
                snapshotID: snapshotID,
                snapshots: snapshots
            )
        }
        #expect(snapshots.invalidationCutoffs.isEmpty)
        let lease = try await snapshots.beginSnapshotMutation(snapshotId: snapshotID)
        try await snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    @MainActor
    func `modifier click receipt planning preserves cancellation without consuming snapshot`() async throws {
        let snapshots = StubSnapshotManager()
        let snapshotID = try await snapshots.createSnapshot()
        snapshots.uiAutomationSnapshotCancellation = true

        await #expect(throws: CancellationError.self) {
            _ = try await ClickCommand.modifierClickCoordinateAuthority(
                snapshotID: snapshotID,
                snapshots: snapshots
            )
        }
        #expect(snapshots.invalidationCutoffs.isEmpty)
        let lease = try await snapshots.beginSnapshotMutation(snapshotId: snapshotID)
        try await snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }
}
