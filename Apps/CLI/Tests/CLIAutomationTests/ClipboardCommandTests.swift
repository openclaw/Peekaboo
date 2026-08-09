import Foundation
import PeekabooAutomationKit
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe), .serialized)
struct ClipboardCommandTests {
    @Test
    func `Clipboard rejects conflicting action spellings as validation JSON`() async throws {
        let result = try await InProcessCommandRunner.runShared(
            ["clipboard", "get", "--action", "set", "--json"],
            allowedExitCodes: [1]
        )

        #expect(result.stderr.isEmpty)
        let data = try #require(result.stdout.data(using: .utf8))
        let payload = try JSONDecoder().decode(JSONResponse.self, from: data)
        #expect(payload.success == false)
        #expect(payload.error?.code == ErrorCode.VALIDATION_ERROR.rawValue)
    }

    @Test
    @MainActor
    func `Clipboard set invalidates implicit latest only after marking the mutation`() async throws {
        let snapshots = StubSnapshotManager()
        let originalSnapshot = try await snapshots.createSnapshot()
        let clipboard = StubClipboardService()
        let tracker = InteractionMutationTracker()
        var mutationWasMarkedBeforeWrite = false
        clipboard.beforeMutation = {
            mutationWasMarkedBeforeWrite = tracker.mutationStartedAt != nil
        }
        let services = TestServicesFactory.makePeekabooServices(
            snapshots: snapshots,
            clipboard: clipboard
        )
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: true,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: services,
            interactionMutationTracker: tracker
        )
        var command = try ClipboardCommand.SetSubcommand.parse(["--text", "updated", "--json"])

        try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
            using: runtime,
            required: true,
            requiresCallerBarrier: true
        ) {
            try await command.run(using: runtime)
        }

        #expect(mutationWasMarkedBeforeWrite)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
        #expect(try await snapshots.listSnapshots().map(\.id) == [originalSnapshot])
    }

    @Test
    @MainActor
    func `Clipboard get leaves implicit latest unchanged`() async throws {
        let snapshots = StubSnapshotManager()
        let originalSnapshot = try await snapshots.createSnapshot()
        let clipboard = StubClipboardService()
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("current".utf8),
            textPreview: "current"
        )
        let services = TestServicesFactory.makePeekabooServices(
            snapshots: snapshots,
            clipboard: clipboard
        )
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: true,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: services
        )
        var command = try ClipboardCommand.GetSubcommand.parse(["--json"])

        try await command.run(using: runtime)

        #expect(await snapshots.getMostRecentSnapshot() == originalSnapshot)
        #expect(snapshots.invalidationCutoffs.isEmpty)
    }
}
