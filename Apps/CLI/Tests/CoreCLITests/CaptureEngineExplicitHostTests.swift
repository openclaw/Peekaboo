import Commander
import Foundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct CaptureEngineExplicitHostTests {
    private static let socket = "/synthetic/capture-host.sock"

    @Test(arguments: ["live", "action"], [
        "auto", "modern", "modern-only", "sckit", "sc", "screen-capture-kit", "sck",
        "classic", "cg", "legacy", "legacy-only", "false", "0", "no", " CG ",
    ])
    func `live capture transports engine and explicit host from either source`(
        command: String,
        engine: String
    ) throws {
        for engineInEnvironment in [false, true] {
            for socketInEnvironment in [false, true] {
                var options: [String: [String]] = [:]
                var environment: [String: String] = [:]
                if engineInEnvironment {
                    environment["PEEKABOO_CAPTURE_ENGINE"] = engine
                } else {
                    options["captureEngine"] = [engine]
                }
                if socketInEnvironment {
                    environment["PEEKABOO_BRIDGE_SOCKET"] = Self.socket
                } else {
                    options["bridge-socket"] = [Self.socket]
                }

                let runtimeOptions = try Self.bind(command: command, options: options, environment: environment)
                #expect(runtimeOptions.captureEnginePreference == engine
                    .trimmingCharacters(in: .whitespacesAndNewlines))
                #expect(runtimeOptions.preferRemote)
                #expect(runtimeOptions.requiresDesktopObservation)
                #expect(runtimeOptions.transportsCaptureEnginePreference)
                #expect(runtimeOptions.requiresCaptureEnginePreferenceHost)
                #expect(runtimeOptions.requiresDesktopObservationInlinePixels)
                #expect(runtimeOptions.requiresCaptureEnginePreferenceCapability == (engine != "auto"))
                #expect(runtimeOptions.requiresScreenCaptureKitOwnerCapability)
                #expect(!CommanderRuntimeExecutor.shouldExportCaptureEnginePreference(runtimeOptions))
                #expect(BridgeSocketResolver.explicitBridgeSocket(
                    options: runtimeOptions,
                    environment: environment
                ) == Self.socket)
                #expect(RuntimeHostResolver.initialRoutingDecision(
                    options: runtimeOptions,
                    environment: environment,
                    configurationInput: nil,
                    knownSnapshotInvalidationRemoteSocketPaths: []
                ) == .remote)
            }
        }
    }

    @Test(arguments: ["live", "action"])
    func `explicit remote isolation retains precedence over engine and socket`(command: String) throws {
        for isolation in ["flag", "", "0", "false", "1"] {
            var environment = ["PEEKABOO_CAPTURE_ENGINE": "modern", "PEEKABOO_BRIDGE_SOCKET": Self.socket]
            if isolation != "flag" {
                environment["PEEKABOO_NO_REMOTE"] = isolation
            }
            let options = try Self.bind(
                command: command,
                options: ["captureEngine": ["cg"], "bridge-socket": [Self.socket]],
                flags: isolation == "flag" ? ["no-remote"] : [],
                environment: environment
            )

            #expect(options.captureEnginePreference == "cg")
            #expect(!options.preferRemote)
            #expect(!options.requiresDesktopObservationInlinePixels)
            #expect(!options.requiresCaptureEnginePreferenceHost)
            #expect(CommanderRuntimeExecutor.shouldExportCaptureEnginePreference(options))
            #expect(RuntimeHostResolver.initialRoutingDecision(
                options: options,
                environment: environment,
                configurationInput: nil,
                knownSnapshotInvalidationRemoteSocketPaths: [Self.socket]
            ) == .local(snapshotInvalidationRemoteSocketPaths: []))
        }
    }

    @Test(arguments: ["live", "action"], ["", " \n "])
    func `empty engine values preserve default remote capture`(command: String, empty: String) throws {
        let environment = ["PEEKABOO_CAPTURE_ENGINE": empty, "PEEKABOO_BRIDGE_SOCKET": Self.socket]
        let options = try Self.bind(
            command: command,
            options: ["captureEngine": [empty]],
            environment: environment
        )

        #expect(options.captureEnginePreference == nil)
        #expect(options.preferRemote)
        #expect(!options.requiresDesktopObservationInlinePixels)
        #expect(!options.requiresCaptureEnginePreferenceHost)
        #expect(!options.requiresCaptureEnginePreferenceCapability)
        #expect(RuntimeHostResolver.initialRoutingDecision(
            options: options,
            environment: environment,
            configurationInput: nil,
            knownSnapshotInvalidationRemoteSocketPaths: []
        ) == .remote)
    }

    @Test(arguments: ["live", "action"], ["", " \n "])
    func `empty CLI values do not hide ambient engine or socket`(command: String, empty: String) throws {
        let environment = ["PEEKABOO_CAPTURE_ENGINE": "auto", "PEEKABOO_BRIDGE_SOCKET": Self.socket]
        let options = try Self.bind(
            command: command,
            options: ["captureEngine": [empty], "bridge-socket": [empty]],
            environment: environment
        )

        #expect(options.captureEnginePreference == "auto")
        #expect(options.preferRemote)
        #expect(options.requiresDesktopObservation)
        #expect(options.transportsCaptureEnginePreference)
        #expect(options.requiresCaptureEnginePreferenceHost)
        #expect(options.requiresDesktopObservationInlinePixels)
        #expect(!options.requiresCaptureEnginePreferenceCapability)
        #expect(BridgeSocketResolver.explicitBridgeSocket(options: options, environment: environment) == Self.socket)
    }

    @Test(arguments: ["live", "action"])
    func `a CLI engine still takes precedence over an invalid ambient value`(command: String) throws {
        let options = try Self.bind(
            command: command,
            options: ["captureEngine": ["auto"], "bridge-socket": [Self.socket]],
            environment: ["PEEKABOO_CAPTURE_ENGINE": "invalid-ambient-engine"]
        )

        #expect(options.captureEnginePreference == "auto")
        #expect(options.preferRemote)
        #expect(options.requiresDesktopObservationInlinePixels)
        #expect(!options.requiresCaptureEnginePreferenceCapability)
    }

    @Test(arguments: ["live", "action"], ["auto", "modern", "cg"])
    func `an engine without an effective socket preserves caller local compatibility`(
        command: String,
        engine: String
    ) throws {
        for engineInEnvironment in [false, true] {
            for socket in [nil, "", " \n "] as [String?] {
                var arguments = ["captureEngine": [engineInEnvironment ? "" : engine]]
                var environment = ["PEEKABOO_CAPTURE_ENGINE": engineInEnvironment ? engine : ""]
                if let socket {
                    arguments["bridge-socket"] = [socket]
                    environment["PEEKABOO_BRIDGE_SOCKET"] = socket
                }
                let options = try Self.bind(command: command, options: arguments, environment: environment)

                #expect(options.captureEnginePreference == engine)
                #expect(!options.preferRemote)
                #expect(!options.requiresDesktopObservation)
                #expect(!options.transportsCaptureEnginePreference)
                #expect(!options.requiresCaptureEnginePreferenceHost)
                #expect(!options.requiresDesktopObservationInlinePixels)
                #expect(!options.requiresScreenCaptureKitOwnerCapability)
                #expect(!options.remoteIsolationRequested)
                #expect(CommanderRuntimeExecutor.shouldExportCaptureEnginePreference(options))
                #expect(RuntimeHostResolver.requiredHostFailure(explicitSocket: nil, options: options) == nil)
                #expect(RuntimeHostResolver.initialRoutingDecision(
                    options: options,
                    environment: environment,
                    configurationInput: nil,
                    knownSnapshotInvalidationRemoteSocketPaths: [Self.socket]
                ) == .local(snapshotInvalidationRemoteSocketPaths: command == "action" ? [Self.socket] : []))
            }
        }
    }

    @Test(arguments: ["live", "action"])
    func `environment socket can opt an already bound CLI engine into inline transport`(command: String) throws {
        let local = try Self.bind(command: command, options: ["captureEngine": ["cg"]])
        let literalSocket = "\(Self.socket) \n"
        let environment = ["PEEKABOO_BRIDGE_SOCKET": literalSocket, "PEEKABOO_CAPTURE_ENGINE": "invalid"]
        let remote = local.applyingEnvironmentOverrides(environment: environment)
        let repeated = remote.applyingEnvironmentOverrides(environment: environment)

        for options in [remote, repeated] {
            #expect(options.captureEnginePreference == "cg")
            #expect(options.preferRemote)
            #expect(options.requiresDesktopObservationInlinePixels)
            #expect(options.transportsCaptureEnginePreference)
            #expect(BridgeSocketResolver
                .explicitBridgeSocket(options: options, environment: environment) == literalSocket)
            #expect(!CommanderRuntimeExecutor.shouldExportCaptureEnginePreference(options))
        }
        let localAgain = remote.applyingEnvironmentOverrides(environment: [:])
        #expect(!localAgain.preferRemote)
        #expect(!localAgain.requiresDesktopObservationInlinePixels)
        #expect(!localAgain.requiresCaptureEnginePreferenceHost)
    }

    @Test(arguments: ["/synthetic/host.sock ", "/synthetic/host.sock\n", " \n "])
    func `nonblank socket presence preserves selected path bytes and precedence`(literalSocket: String) {
        var options = CommandRuntimeOptions()
        let environment = ["PEEKABOO_BRIDGE_SOCKET": literalSocket]
        let isNonblank = !literalSocket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        #expect(BridgeSocketResolver.explicitBridgeSocket(options: options, environment: environment) == literalSocket)
        #expect(BridgeSocketResolver
            .hasNonblankExplicitBridgeSocket(options: options, environment: environment) == isNonblank)
        options.bridgeSocketPath = literalSocket
        let otherEnvironment = ["PEEKABOO_BRIDGE_SOCKET": Self.socket]
        #expect(BridgeSocketResolver
            .explicitBridgeSocket(options: options, environment: otherEnvironment) == literalSocket)
        #expect(BridgeSocketResolver
            .hasNonblankExplicitBridgeSocket(options: options, environment: otherEnvironment) == isNonblank)
    }

    @Test(arguments: ["live", "action"])
    func `CLI socket binding retains its established trimming over a literal environment socket`(
        command: String
    ) throws {
        let environment = ["PEEKABOO_BRIDGE_SOCKET": "\(Self.socket) "]
        let options = try Self.bind(
            command: command,
            options: ["captureEngine": ["cg"], "bridge-socket": [" \(Self.socket) \n"]],
            environment: environment
        )

        #expect(options.bridgeSocketPath == Self.socket)
        #expect(options.requiresDesktopObservationInlinePixels)
        #expect(BridgeSocketResolver.explicitBridgeSocket(options: options, environment: environment) == Self.socket)
    }

    @Test
    func `transported see engines and local video ingestion remain valid`() throws {
        let environment = ["PEEKABOO_CAPTURE_ENGINE": "modern", "PEEKABOO_BRIDGE_SOCKET": Self.socket]
        for commandType in [SeeCommand.self, CaptureVideoCommand.self] as [any ParsableCommand.Type] {
            let options = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(positional: [], options: [:], flags: []),
                commandType: commandType,
                environment: environment
            ).applyingEnvironmentOverrides(environment: environment)

            #expect(options.preferRemote == (commandType == SeeCommand.self))
            #expect(options.transportsCaptureEnginePreference == (commandType == SeeCommand.self))
            #expect(options.requiresScreenCapturePermission == (commandType == SeeCommand.self))
            #expect(!options.requiresDesktopObservationInlinePixels)
        }
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["PEEKABOO_NO_REMOTE"] == nil),
        arguments: ["live", "action"]
    )
    func `selected engine and explicit host reach runtime capability preflight`(command: String) async throws {
        var arguments = [
            "peekaboo", "capture", command,
            "--capture-engine", "cg", "--bridge-socket", Self.socket,
            "--capture-focus", "foreground", "--path", "/synthetic/must-not-create",
        ]
        if command == "action" {
            arguments += ["--", "/synthetic/must-not-execute"]
        }
        var runtimeConstructions = 0
        let error = await #expect(throws: RuntimeProbe.self) {
            try await CommanderRuntimeExecutor.resolveAndRun(
                arguments: arguments,
                runtimeFactory: .init { options in
                    runtimeConstructions += 1
                    #expect(options.captureEnginePreference == "cg")
                    #expect(options.preferRemote)
                    #expect(options.requiresDesktopObservation)
                    #expect(options.requiresCaptureEnginePreferenceHost)
                    #expect(options.requiresDesktopObservationInlinePixels)
                    throw RuntimeProbe.reached
                }
            )
        }

        #expect(error == .reached)
        #expect(runtimeConstructions == 1)
    }

    private static func bind(
        command: String,
        options: [String: [String]],
        flags: Set<String> = [],
        environment: [String: String] = [:]
    ) throws -> CommandRuntimeOptions {
        try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: options, flags: flags),
            commandType: command == "live" ? CaptureLiveCommand.self : CaptureActionCommand.self,
            environment: environment
        ).applyingEnvironmentOverrides(environment: environment)
    }

    private enum RuntimeProbe: Error, Equatable {
        case reached
    }
}
