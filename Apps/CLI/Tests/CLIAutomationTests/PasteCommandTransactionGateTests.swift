import Commander
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
extension PasteCommandTests {
    @Test(arguments: [false, true])
    func `Admission timeout preserves observations and a later clipboard paste recovers`(
        binaryPayload: Bool
    ) async throws {
        try await Self.verifyAdmissionRecovery(binaryPayload: binaryPayload)
    }

    private static func verifyAdmissionRecovery(binaryPayload: Bool) async throws {
        let snapshots = StubSnapshotManager()
        let snapshotID = try await snapshots.createSnapshot()
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: .one
        )
        let clipboard = StubClipboardService()
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("prior".utf8),
            textPreview: "prior"
        )
        let services = TestServicesFactory.makePeekabooServices(
            snapshots: snapshots,
            clipboard: clipboard,
            automation: automation
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-admission-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tracker = InteractionMutationTracker(
            desktopMutationWatermarkStore: DesktopMutationWatermarkStore(directoryURL: directory)
        )
        let gate = OneRefusalPasteTransactionGate()
        var command = PasteCommand()
        command.transactionGate = gate
        command.focusOptions.foreground = true
        command.focusOptions.noAutoFocus = true
        command.restoreDelay = .milliseconds(0)
        command.runtimeOptions.jsonOutput = true
        if binaryPayload {
            command.dataBase64 = Data("payload".utf8).base64EncodedString()
            command.uti = "public.data"
        }
        let runtime = CommandRuntime(
            configuration: command.runtimeOptions.makeConfiguration(),
            services: services,
            selectedRemoteSocketPath: nil,
            snapshotInvalidationRemoteSocketPaths: [],
            interactionMutationTracker: tracker
        )

        let refused = try await InProcessCommandRunner.captureCommandOutput { @MainActor in
            try await command.run(using: runtime)
        }
        #expect(refused.exitStatus == ExitCode.failure.rawValue)
        let refusal = try JSONDecoder().decode(JSONResponse.self, from: Data(refused.stdout.utf8))
        #expect(refusal.error?.code == "TIMEOUT")
        #expect(refusal.error?.retry_safe == true)
        #expect(refusal.error?.mutation_dispatched == false)
        #expect(refusal.outcome?.requiresFreshObservation == false)

        #expect(gate.admissionCalls == 1)
        #expect(gate.operationCalls == 0)
        #expect(tracker.mutationSequence == 0)
        #expect(tracker.mutationStartedAt == nil)
        #expect(!tracker.hasPendingDurableMutation)
        #expect(snapshots.invalidationCutoffs.isEmpty)
        #expect(await snapshots.getMostRecentSnapshot() == snapshotID)
        #expect(clipboard.getCallCount == 0)
        #expect(clipboard.saveCallCount == 0)
        #expect(clipboard.setCallCount == 0)
        #expect(clipboard.clearCallCount == 0)
        #expect(clipboard.restoreCallCount == 0)
        #expect(clipboard.current?.textPreview == "prior")
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(automation.uiAutomationOutcomeScript.totalCallCount == 0)

        let recovered = try await InProcessCommandRunner.captureCommandOutput { @MainActor in
            try await command.run(using: runtime)
        }
        #expect(recovered.exitStatus == 0)
        let recovery = try JSONDecoder().decode(JSONResponse.self, from: Data(recovered.stdout.utf8))
        #expect(recovery.success)

        #expect(gate.admissionCalls == 2)
        #expect(gate.operationCalls == 1)
        #expect(tracker.mutationSequence > 0)
        #expect(tracker.mutationStartedAt == nil)
        #expect(!tracker.hasPendingDurableMutation)
        #expect(snapshots.invalidationCutoffs.count == 1)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
        #expect(snapshots.snapshotInfos[snapshotID] != nil)
        #expect(automation.hotkeyCalls.map(\.keys) == ["cmd,v"])
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(automation.uiAutomationOutcomeScript.totalCallCount == 1)
        #expect(clipboard.getCallCount == 1)
        #expect(clipboard.saveCallCount == (binaryPayload ? 1 : 0))
        #expect(clipboard.setCallCount == (binaryPayload ? 1 : 0))
        #expect(clipboard.restoreCallCount == (binaryPayload ? 1 : 0))
        #expect(clipboard.clearCallCount == 0)
        #expect(clipboard.current?.textPreview == "prior")
        #expect(clipboard.current?.data == Data("prior".utf8))
    }

    func holdPasteTransactionLock() async throws -> Int32 {
        let fd = try self.openPasteTransactionLock()
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                close(fd)
                throw error
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return fd
    }

    func openPasteTransactionLock() throws -> Int32 {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = applicationSupport.appendingPathComponent("Peekaboo", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("clipboard-paste-transaction.lock").path
        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    func makeTransactionGateContext(processIdentifier: pid_t = 2468) -> (
        services: PeekabooServices,
        automation: OutcomeStubAutomationService,
        clipboard: StubClipboardService,
        applications: StubApplicationService
    ) {
        let app = ServiceApplicationInfo(
            processIdentifier: processIdentifier,
            processStartIdentity: 71,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            unitCount: .one
        )
        let clipboard = StubClipboardService()
        let applications = StubApplicationService(applications: [app])
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("prior".utf8),
            textPreview: "prior"
        )
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            clipboard: clipboard,
            automation: automation
        )
        return (services, automation, clipboard, applications)
    }
}

@MainActor
private final class OneRefusalPasteTransactionGate: ClipboardPasteTransactionGating {
    private(set) var admissionCalls = 0
    private(set) var operationCalls = 0

    func withExclusiveTransaction<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        self.admissionCalls += 1
        if self.admissionCalls == 1 {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Synthetic clipboard admission timeout",
                standardErrorCode: .timeout
            )
        }
        self.operationCalls += 1
        return try await operation()
    }
}
