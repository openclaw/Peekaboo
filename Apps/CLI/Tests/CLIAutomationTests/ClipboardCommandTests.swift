import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
import UniformTypeIdentifiers
@testable import PeekabooCLI

@Suite(.tags(.safe), .serialized)
struct ClipboardCommandTests {
    @Test
    @MainActor
    func `Clipboard status reports caller policy without reading or changing contents`() async throws {
        let clipboard = StubClipboardService()
        clipboard.readAccess = ClipboardReadAccessStatus(policy: .ask)
        let snapshots = StubSnapshotManager()
        let snapshot = try await snapshots.createSnapshot()
        let services = TestServicesFactory.makePeekabooServices(snapshots: snapshots, clipboard: clipboard)

        let result = try await InProcessCommandRunner.run(["clipboard", "status", "--json"], services: services)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let data = try #require(payload["data"] as? [String: Any])

        #expect(result.exitStatus == 0)
        #expect(data["policy"] as? String == "ask")
        #expect(data["reader_context"] as? String == "caller_local")
        #expect(data["read_admitted"] as? Bool == false)
        #expect(data["contents_read"] as? Bool == false)
        #expect(clipboard.readAccessStatusCallCount == 1)
        #expect(clipboard.getCallCount == 0)
        #expect(clipboard.saveCallCount == 0)
        #expect(clipboard.setCallCount == 0)
        #expect(clipboard.clearCallCount == 0)
        #expect(await snapshots.getMostRecentSnapshot() == snapshot)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `Manual clipboard prompt permission is explicit for get save and verify`(allowPrompt: Bool) async throws {
        for action in ["get", "save", "set"] {
            let clipboard = StubClipboardService()
            clipboard.current = Self.result("synthetic")
            let services = TestServicesFactory.makePeekabooServices(clipboard: clipboard)
            var arguments = ["clipboard", action, "--json"]
            if action == "set" {
                arguments += ["--data-base64", "dXBkYXRlZA==", "--uti", "public.data", "--verify"]
            }
            if allowPrompt {
                arguments.append("--allow-prompt")
            }

            let result = try await InProcessCommandRunner.run(arguments, services: services)

            #expect(result.exitStatus == 0)
            if action == "save" {
                #expect(clipboard.savePromptOptions == (allowPrompt ? [true] : []))
                #expect(clipboard.readPromptOptions.isEmpty)
            } else {
                #expect(!allowPrompt || !clipboard.readPromptOptions.isEmpty)
                #expect(!clipboard.readPromptOptions.contains(false))
                #expect(allowPrompt || clipboard.readPromptOptions.isEmpty)
            }
        }
    }

    @Test
    @MainActor
    func `Clipboard prompt opt in without requested verification refuses before writing`() async throws {
        let clipboard = StubClipboardService()
        let services = TestServicesFactory.makePeekabooServices(clipboard: clipboard)

        let result = try await InProcessCommandRunner.run(
            ["clipboard", "set", "--text", "synthetic", "--allow-prompt", "--json"], services: services
        )

        #expect(result.exitStatus != 0)
        #expect(result.stdout.contains("--allow-prompt requires --verify"))
        #expect(clipboard.setCallCount == 0)
        #expect(clipboard.readPromptOptions.isEmpty)
    }

    @Test
    @MainActor
    func `Clipboard verify permission refusal preserves the accepted write`() async throws {
        let clipboard = StubClipboardService()
        clipboard.getError = DesktopActionFailure.preDispatchRefusal(
            reason: .permissionDenied, message: "Synthetic silent read refusal"
        )
        let services = TestServicesFactory.makePeekabooServices(clipboard: clipboard)
        let result = try await InProcessCommandRunner.run(
            ["clipboard", "set", "--text", "synthetic", "--verify", "--json"], services: services
        )

        let envelope = try ActionEnvelopeTestProbe.decode(result.stdout)
        #expect(result.exitStatus != 0)
        ActionEnvelopeTestAssertions.expectCanonicalOutcome(
            .indeterminate(delivery: ClipboardMutationResultSemantics.delivery, evidence: .completionUnknown),
            in: envelope
        )
        #expect(clipboard.setCallCount == 1)
        #expect(clipboard.getCallCount == 1)
        #expect(clipboard.readPromptOptions.isEmpty)
    }

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
        #expect(payload.error?.code == ErrorCode.INVALID_ARGUMENT.rawValue)
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

    @Test
    @MainActor
    func `Clipboard mutation JSON publishes canonical foreground transaction outcomes`() async throws {
        let clipboard = ClipboardOutcomeService()
        let expected = DesktopActionOutcome.confirmedChange(
            delivery: ClipboardMutationResultSemantics.delivery
        )
        clipboard.outcome = expected
        clipboard.slots["fixture"] = Self.result("restored")
        let services = TestServicesFactory.makePeekabooServices(clipboard: clipboard)
        let cases = [
            ["clipboard", "set", "--text", "updated", "--json"],
            ["clipboard", "clear", "--json"],
            ["clipboard", "restore", "--slot", "fixture", "--json"],
        ]

        for arguments in cases {
            let result = try await InProcessCommandRunner.run(arguments, services: services)
            try result.validateExitStatus(allowedExitCodes: [0], arguments: arguments)
            let envelope = try ActionEnvelopeTestProbe.decode(result.stdout)
            #expect(envelope.success)
            ActionEnvelopeTestAssertions.expectCanonicalOutcome(expected, in: envelope)
        }

        #expect(clipboard.setCallCount == 1)
        #expect(clipboard.clearCallCount == 1)
        #expect(clipboard.restoreCallCount == 1)
    }

    @Test
    @MainActor
    func `Clipboard set validation refusal is zero dispatch in JSON`() async throws {
        let clipboard = ClipboardOutcomeService()
        let services = TestServicesFactory.makePeekabooServices(clipboard: clipboard)
        let arguments = ["clipboard", "set", "--json"]

        let result = try await InProcessCommandRunner.run(arguments, services: services)

        try result.validateExitStatus(allowedExitCodes: [1], arguments: arguments)
        let envelope = try ActionEnvelopeTestProbe.decode(result.stdout)
        ActionEnvelopeTestAssertions.expectCanonicalRefusal(reason: .invalidRequest, in: envelope)
        #expect(clipboard.setCallCount == 0)
        #expect(clipboard.clearCallCount == 0)
        #expect(clipboard.restoreCallCount == 0)
    }

    @Test
    @MainActor
    func `Clipboard post-write processing failure is indeterminate in JSON`() async throws {
        let clipboard = ClipboardOutcomeService()
        clipboard.postWriteError = ClipboardCommandOutcomeTestError.processing
        let services = TestServicesFactory.makePeekabooServices(clipboard: clipboard)
        let arguments = ["clipboard", "set", "--text", "updated", "--json"]

        let result = try await InProcessCommandRunner.run(arguments, services: services)

        try result.validateExitStatus(allowedExitCodes: [1], arguments: arguments)
        let envelope = try ActionEnvelopeTestProbe.decode(result.stdout)
        let expected = DesktopActionOutcome.indeterminate(
            delivery: ClipboardMutationResultSemantics.delivery,
            evidence: .completionUnknown
        )
        #expect(!envelope.success)
        ActionEnvelopeTestAssertions.expectCanonicalOutcome(expected, in: envelope)
        #expect(envelope.error?.retry_safe == false)
        #expect(envelope.error?.mutation_dispatched == true)
        #expect(clipboard.setCallCount == 1)
        #expect(clipboard.current?.textPreview == "updated")
    }

    @Test
    @MainActor
    func `Clipboard get and save JSON stay read-only`() async throws {
        let clipboard = ClipboardOutcomeService()
        clipboard.current = Self.result("current")
        let services = TestServicesFactory.makePeekabooServices(clipboard: clipboard)
        let cases = [
            ["clipboard", "get", "--json"],
            ["clipboard", "save", "--slot", "fixture", "--json"],
        ]

        for arguments in cases {
            let result = try await InProcessCommandRunner.run(arguments, services: services)
            try result.validateExitStatus(allowedExitCodes: [0], arguments: arguments)
            let envelope = try ActionEnvelopeTestProbe.decode(result.stdout)
            #expect(envelope.success)
            #expect(envelope.effect == nil)
            #expect(envelope.outcome == nil)
        }
        #expect(clipboard.saveCallCount == 1)
    }

    private static func result(_ text: String) -> ClipboardReadResult {
        ClipboardReadResult(
            utiIdentifier: UTType.utf8PlainText.identifier,
            data: Data(text.utf8),
            textPreview: text
        )
    }
}

@MainActor
private final class ClipboardOutcomeService: ClipboardServiceActionResultProviding {
    var current: ClipboardReadResult?
    var slots: [String: ClipboardReadResult] = [:]
    var outcome: DesktopActionOutcome = .dispatchedUnverified(
        delivery: ClipboardMutationResultSemantics.delivery,
        evidence: .deliveryAccepted
    )
    var postWriteError: (any Error)?
    private(set) var setCallCount = 0
    private(set) var clearCallCount = 0
    private(set) var saveCallCount = 0
    private(set) var restoreCallCount = 0

    func get(prefer _: UTType?) throws -> ClipboardReadResult? {
        self.current
    }

    func set(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult {
        guard let representation = request.representations.first else {
            throw ClipboardServiceError.writeFailed("No representations provided.")
        }
        let text = request.alsoText ?? String(data: representation.data, encoding: .utf8)
        let result = ClipboardReadResult(
            utiIdentifier: representation.utiIdentifier,
            data: representation.data,
            textPreview: text
        )
        self.setCallCount += 1
        self.current = result
        return result
    }

    func clear() {
        self.clearCallCount += 1
        self.current = nil
    }

    func save(slot: String) throws {
        guard let current else { throw ClipboardServiceError.empty }
        self.saveCallCount += 1
        self.slots[slot] = current
    }

    func restore(slot: String) throws -> ClipboardReadResult {
        self.restoreCallCount += 1
        guard let result = self.slots[slot] else {
            throw ClipboardServiceError.slotNotFound(slot)
        }
        self.current = result
        return result
    }

    func setActionResult(_ request: ClipboardWriteRequest) throws -> DesktopActionResult<ClipboardReadResult> {
        let payload = try self.set(request)
        try self.throwPostWriteErrorIfNeeded()
        return DesktopActionResult(payload: payload, outcome: self.outcome)
    }

    func clearActionResult() throws -> DesktopActionResult<Void> {
        self.clear()
        try self.throwPostWriteErrorIfNeeded()
        return DesktopActionResult(outcome: self.outcome)
    }

    func restoreActionResult(slot: String) throws -> DesktopActionResult<ClipboardReadResult> {
        let payload = try self.restore(slot: slot)
        try self.throwPostWriteErrorIfNeeded()
        return DesktopActionResult(payload: payload, outcome: self.outcome)
    }

    private func throwPostWriteErrorIfNeeded() throws {
        if let postWriteError {
            throw ClipboardMutationResultSemantics.postWriteFailure(
                postWriteError,
                operation: "Clipboard mutation"
            )
        }
    }
}

private enum ClipboardCommandOutcomeTestError: Error {
    case processing
}
