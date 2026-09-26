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

    @Test(arguments: ["see", "live", "action"])
    func `implicit engine selection preserves see remote and live action caller local routing`(command: String) throws {
        let cliOptions = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["captureEngine": ["cg"]],
                flags: []
            ),
            commandType: Self.commandType(command),
            environment: [:]
        )
        let ambientBase = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: Self.commandType(command),
            environment: [:]
        )
        let ambientOptions = ambientBase.applyingEnvironmentOverrides(environment: [
            "PEEKABOO_CAPTURE_ENGINE": "modern",
        ])

        for options in [cliOptions, ambientOptions] {
            #expect(!options.requiresDesktopObservationInlinePixels)
            #expect(options.transportsCaptureEnginePreference == (command == "see"))
            #expect(options.requiresCaptureEnginePreferenceHost == (command == "see"))
            #expect(!options.remoteIsolationRequested)
            #expect(CommanderRuntimeExecutor.shouldExportCaptureEnginePreference(options) == (command != "see"))
            #expect(RuntimeHostResolver.initialRoutingDecision(
                options: options,
                environment: [:],
                configurationInput: nil,
                knownSnapshotInvalidationRemoteSocketPaths: []
            ) == (command == "see" ? .remote : .local(snapshotInvalidationRemoteSocketPaths: [])))
            #expect(RuntimeHostResolver.shouldResolveKnownRemoteEndpoints(
                options: options,
                environment: [:],
                configurationInput: nil
            ) == (command != "live"))
            #expect(!RuntimeHostResolver.requiresCallerLocalModernOwnerClaim(options: options, environment: [:]))
        }
    }

    @Test(arguments: ["see", "live", "action"])
    func `No remote remains the explicit caller-local capture opt in`(command: String) throws {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["captureEngine": ["cg"]],
                flags: ["no-remote"]
            ),
            commandType: Self.commandType(command),
            environment: [:]
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

    @Test(arguments: ["see", "live", "action"])
    func `Explicit remote capture engine selection refuses silent local fallback`(command: String) throws {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["captureEngine": ["cg"], "bridge-socket": ["/synthetic/capture-host.sock"]],
                flags: []
            ),
            commandType: Self.commandType(command),
            environment: [:]
        )

        let failure = try #require(RuntimeHostResolver.requiredHostFailure(
            explicitSocket: nil,
            options: options
        ))
        #expect(failure.contains("Capture engine 'cg'"))
        if command == "see" {
            #expect(failure.contains("will not switch capture or TCC ownership silently"))
        } else {
            #expect(failure.contains("desktopObservationInlinePixels"))
        }
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
            commandType: SeeCommand.self,
            environment: [:]
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

    private static func commandType(_ command: String) -> any ParsableCommand.Type {
        switch command {
        case "live": CaptureLiveCommand.self
        case "action": CaptureActionCommand.self
        default: SeeCommand.self
        }
    }
}
