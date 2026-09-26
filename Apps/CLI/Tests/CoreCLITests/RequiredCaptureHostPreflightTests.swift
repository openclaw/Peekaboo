import PeekabooBridge
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
@MainActor
struct RequiredCaptureHostPreflightTests {
    @Test
    func `Compatible host preflight is a no op without a required host failure`() {
        let runtime = self.makeRuntime(requiredHostFailure: nil)

        #expect(throws: Never.self) {
            try runtime.requireCompatibleHost()
        }
    }

    @Test
    func `Required host preflight preserves the structured capability refusal`() {
        let message = "A host with desktopObservationInlinePixels is required; use --no-remote for local capture."
        let runtime = self.makeRuntime(requiredHostFailure: message)

        let error = #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try runtime.requireCompatibleHost()
        }
        #expect(error?.code == .operationNotSupported)
        #expect(error?.message == message)
        if let error {
            #expect(CaptureLiveCommand().mapErrorToCode(error) == .VALIDATION_ERROR)
        }
    }

    @Test
    func `Capture action refuses the required host before resolving its capture scope`() async {
        let message = "Missing desktopObservationInlinePixels support"
        var command = CaptureActionCommand()
        command.runtime = self.makeRuntime(requiredHostFailure: message)
        command.command = ["/usr/bin/true"]
        command.mode = "invalid-unreachable-after-host-refusal"
        command.childCommandDispatched = true
        command.childCommandCompleted = true

        let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await command.executeActionCapture()
        }

        #expect(error?.code == .operationNotSupported)
        #expect(error?.message == message)
        #expect(command.captureFocusOutcome == nil)
        #expect(!command.childCommandDispatched)
        #expect(!command.childCommandCompleted)
    }

    private func makeRuntime(requiredHostFailure: String?) -> CommandRuntime {
        CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: OwnerPolicyFixtureServices(ownerAware: true),
            requiredHostFailure: requiredHostFailure
        )
    }
}
