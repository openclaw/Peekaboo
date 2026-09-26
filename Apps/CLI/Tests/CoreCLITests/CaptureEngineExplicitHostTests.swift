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
    func `live capture refuses engine and explicit host from either source`(command: String, engine: String) {
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

                let error = #expect(throws: ValidationError.self) {
                    try Self.bind(command: command, options: options, environment: environment)
                }
                #expect(error?.localizedDescription.contains("explicit Bridge socket") == true)
                #expect(error?.localizedDescription.contains("Omit --capture-engine") == true)
                #expect(error?.localizedDescription.contains("unset PEEKABOO_CAPTURE_ENGINE") == true)
                #expect(error?.localizedDescription.contains("--no-remote") == true)
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
            ).applyingEnvironmentOverrides(environment: environment)

            #expect(options.captureEnginePreference == "cg")
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
        ).applyingEnvironmentOverrides(environment: environment)

        #expect(options.captureEnginePreference == nil)
        #expect(options.preferRemote)
        #expect(RuntimeHostResolver.initialRoutingDecision(
            options: options,
            environment: environment,
            configurationInput: nil,
            knownSnapshotInvalidationRemoteSocketPaths: []
        ) == .remote)
    }

    @Test(arguments: ["live", "action"])
    func `empty CLI values do not hide ambient engine or socket`(command: String) {
        #expect(throws: ValidationError.self) {
            try Self.bind(
                command: command,
                options: ["captureEngine": [""], "bridge-socket": [""]],
                environment: ["PEEKABOO_CAPTURE_ENGINE": "auto", "PEEKABOO_BRIDGE_SOCKET": Self.socket]
            )
        }
    }

    @Test(arguments: ["live", "action"])
    func `a CLI engine still takes precedence over an invalid ambient value`(command: String) {
        let error = #expect(throws: ValidationError.self) {
            try Self.bind(
                command: command,
                options: ["captureEngine": ["auto"], "bridge-socket": [Self.socket]],
                environment: ["PEEKABOO_CAPTURE_ENGINE": "invalid-ambient-engine"]
            )
        }
        #expect(error?.localizedDescription.contains("explicit Bridge socket") == true)
    }

    @Test(arguments: ["live", "action"])
    func `an engine without a selected socket keeps caller local capture`(command: String) throws {
        for engineInEnvironment in [false, true] {
            let environment = [
                "PEEKABOO_CAPTURE_ENGINE": engineInEnvironment ? "modern" : "",
                "PEEKABOO_BRIDGE_SOCKET": "",
            ]
            let options = try Self.bind(
                command: command,
                options: ["captureEngine": [engineInEnvironment ? "" : "modern"], "bridge-socket": [""]],
                environment: environment
            ).applyingEnvironmentOverrides(environment: environment)

            #expect(options.captureEnginePreference == "modern")
            #expect(!options.preferRemote)
            #expect(!options.remoteIsolationRequested)
        }
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
        }
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["PEEKABOO_NO_REMOTE"] == nil),
        arguments: ["live", "action"]
    )
    func `conflicting selectors refuse before runtime construction or command execution`(command: String) async throws {
        var arguments = [
            "peekaboo", "capture", command,
            "--capture-engine", "cg", "--bridge-socket", Self.socket,
            "--capture-focus", "foreground", "--path", "/synthetic/must-not-create",
        ]
        if command == "action" {
            arguments += ["--", "/synthetic/must-not-execute"]
        }
        var runtimeConstructions = 0
        let error = await #expect(throws: ValidationError.self) {
            try await CommanderRuntimeExecutor.resolveAndRun(
                arguments: arguments,
                runtimeFactory: .init { _ in
                    runtimeConstructions += 1
                    throw RuntimeProbe.reached
                }
            )
        }

        #expect(error?.localizedDescription.contains("explicit Bridge socket") == true)
        #expect(runtimeConstructions == 0)
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
        )
    }

    private enum RuntimeProbe: Error {
        case reached
    }
}
