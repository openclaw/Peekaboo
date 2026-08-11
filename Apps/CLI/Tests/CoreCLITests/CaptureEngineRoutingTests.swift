import Commander
import PeekabooAutomation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct CaptureEngineRoutingTests {
    @Test
    func `Capture engine validation is reusable before runtime host resolution`() {
        #expect(throws: Never.self) {
            try ObservationCommandSupport.validateCaptureEngineValue(" modern ")
        }
        #expect(throws: ValidationError.self) {
            try ObservationCommandSupport.validateCaptureEngineValue("warp-drive")
        }
    }

    @Test
    func `See capture engine selection preserves Bridge routing`() throws {
        let cliOptions = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["captureEngine": ["cg"]],
                flags: []
            ),
            commandType: SeeCommand.self
        )
        let ambientBase = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: SeeCommand.self
        )
        let ambientOptions = ambientBase.applyingEnvironmentOverrides(environment: [
            "PEEKABOO_CAPTURE_ENGINE": "modern",
        ])

        for options in [cliOptions, ambientOptions] {
            #expect(RuntimeHostResolver.initialRoutingDecision(
                options: options,
                environment: [:],
                configurationInput: nil,
                knownSnapshotInvalidationRemoteSocketPaths: []
            ) == .remote)
            #expect(RuntimeHostResolver.shouldResolveKnownRemoteEndpoints(
                options: options,
                environment: [:],
                configurationInput: nil
            ))
        }
    }

    @Test
    func `No remote remains the explicit caller-local capture opt in`() throws {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["captureEngine": ["cg"]],
                flags: ["no-remote"]
            ),
            commandType: SeeCommand.self
        )

        #expect(options.remoteIsolationRequested)
        #expect(RuntimeHostResolver.initialRoutingDecision(
            options: options,
            environment: [:],
            configurationInput: nil,
            knownSnapshotInvalidationRemoteSocketPaths: ["/tmp/gui.sock"]
        ) == .local(
            snapshotInvalidationRemoteSocketPaths: []
        ))
        #expect(!RuntimeHostResolver.shouldResolveKnownRemoteEndpoints(
            options: options,
            environment: [:],
            configurationInput: nil
        ))
    }

    @Test
    func `Capture engine selection refuses silent local fallback`() throws {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: ["captureEngine": ["cg"]], flags: []),
            commandType: SeeCommand.self
        )

        let failure = try #require(RuntimeHostResolver.requiredHostFailure(
            explicitSocket: nil,
            options: options
        ))
        #expect(failure.contains("Capture engine 'cg'"))
        #expect(failure.contains("will not switch capture or TCC ownership silently"))
        #expect(failure.contains("--no-remote"))

        var defaultOptions = options
        defaultOptions.captureEnginePreference = nil
        defaultOptions.requiresCaptureEnginePreferenceHost = false
        #expect(RuntimeHostResolver.requiredHostFailure(explicitSocket: nil, options: defaultOptions) == nil)
    }

    @Test
    func `Ambient capture engine cannot reroute AX only see`() throws {
        let base = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: ["noScreenshot"]),
            commandType: SeeCommand.self
        )
        let options = base.applyingEnvironmentOverrides(environment: [
            "PEEKABOO_CAPTURE_ENGINE": "cg",
        ])

        #expect(options.ignoresCaptureEnginePreference)
        #expect(options.captureEnginePreference == nil)
        #expect(options.preferRemote)
        #expect(RuntimeHostResolver.initialRoutingDecision(
            options: options,
            environment: ["PEEKABOO_CAPTURE_ENGINE": "cg"],
            configurationInput: nil,
            knownSnapshotInvalidationRemoteSocketPaths: []
        ) == .remote)
    }
}
