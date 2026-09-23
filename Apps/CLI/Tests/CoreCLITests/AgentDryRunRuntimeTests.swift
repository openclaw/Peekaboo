import Commander
import Darwin
import Foundation
import PeekabooBridge
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
@MainActor
struct AgentDryRunRuntimeTests {
    @Test(arguments: [["agent"], ["agent", "run"]], [false, true])
    func `text previews skip runtime and Bridge probes`(command: [String], foreground: Bool) async throws {
        for transport in [[], ["--no-remote"], ["--bridge-socket", "/synthetic/unavailable.sock"]] {
            for json in [false, true] {
                let probe = RuntimeProbe()
                let output = try await captureStandardOutputText {
                    try await CommanderRuntimeExecutor.resolveAndRun(
                        arguments: ["peekaboo"] + command + [
                            "  Inspect the synthetic Playground window  ", "--dry-run", "--no-cache",
                            "--max-steps", "1",
                        ] + transport + (foreground ? ["--allow-foreground"] : []) + (json ? ["--json"] : []),
                        runtimeFactory: probe.factory
                    )
                }
                #expect(probe.runtimeConstructions == 0)
                #expect(probe.bridgeProbes == 0)
                if json {
                    let response = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
                    let result = try #require(response["result"] as? [String: Any])
                    let authority = try #require(result["uiAuthority"] as? [String: Any])
                    #expect(response["success"] as? Bool == true)
                    #expect(result["instruction"] as? String == "Inspect the synthetic Playground window")
                    #expect(result["modelExecution"] as? String == "skipped")
                    #expect(result["sessionId"] is NSNull)
                    #expect((result["toolCalls"] as? [Any])?.isEmpty == true)
                    #expect(authority["requestedForeground"] as? Bool == foreground)
                    #expect(authority["backgroundOnly"] as? Bool == !foreground)
                } else {
                    #expect(output.contains("Requested foreground UI: \(foreground ? "yes" : "no")"))
                    #expect(output.contains("Tool calls: 0\nSession saved: no"))
                }
            }
        }
    }

    @Test(arguments: [
        ([], "Task argument is required for --dry-run."),
        (["  \n  "], "Task argument is required for --dry-run."),
        (["Inspect", "--audio"], "audio input would require transcription"),
        (["Inspect", "--audio-file", "/synthetic/missing.wav"], "audio input would require transcription"),
        (["Inspect", "--max-steps", "0"], "between 1 and 100"),
        (["Inspect", "--max-steps", "101"], "between 1 and 100"),
        (["Inspect", "--max-steps", "invalid"], "Invalid value"),
    ])
    func `invalid previews refuse before runtime or Bridge probes`(options: [String], message: String) async throws {
        let probe = RuntimeProbe()
        var caught: (any Error)?
        let output = try await captureStandardOutputText {
            do {
                try await CommanderRuntimeExecutor.resolveAndRun(
                    arguments: ["peekaboo", "agent", "run"] + options + [
                        "--dry-run", "--bridge-socket", "/synthetic/unavailable.sock", "--json",
                    ],
                    runtimeFactory: probe.factory
                )
            } catch {
                caught = error
            }
        }
        #expect(caught != nil)
        #expect(output.contains(message) || caught?.localizedDescription.contains(message) == true)
        #expect(probe.runtimeConstructions == 0)
        #expect(probe.bridgeProbes == 0)
    }

    @Test
    func `disabled Agent still refuses a text preview without runtime`() async throws {
        let previous = getenv("PEEKABOO_DISABLE_AGENT").map { String(cString: $0) }
        setenv("PEEKABOO_DISABLE_AGENT", "1", 1)
        defer {
            if let previous {
                setenv("PEEKABOO_DISABLE_AGENT", previous, 1)
            } else {
                unsetenv("PEEKABOO_DISABLE_AGENT")
            }
        }
        let probe = RuntimeProbe()
        let output = try await captureStandardOutputText {
            await #expect(throws: ExitCode.self) {
                try await CommanderRuntimeExecutor.resolveAndRun(
                    arguments: ["peekaboo", "agent", "Inspect", "--dry-run", "--json"],
                    runtimeFactory: probe.factory
                )
            }
        }
        #expect(output.contains("AGENT_ERROR"))
        #expect(output.contains("PEEKABOO_DISABLE_AGENT"))
        #expect(probe.runtimeConstructions == 0)
        #expect(probe.bridgeProbes == 0)
    }

    @Test
    func `preview still skips model and queue resolution`() async throws {
        let probe = RuntimeProbe()
        let output = try await captureStandardOutputText {
            try await CommanderRuntimeExecutor.resolveAndRun(
                arguments: [
                    "peekaboo", "agent", "Inspect", "--dry-run", "--model", "unsupported-model",
                    "--queue-mode", "unsupported-queue", "--json",
                ],
                runtimeFactory: probe.factory
            )
        }
        #expect(output.contains("not_invoked"))
        #expect(probe.runtimeConstructions == 0)
        #expect(probe.bridgeProbes == 0)
    }

    @Test(arguments: [
        ["agent", "run", "Inspect"],
        ["agent", "chat", "--dry-run"],
        ["agent", "resume", "--dry-run"],
        ["agent", "sessions"],
    ])
    func `other Agent modes retain runtime and Bridge admission`(command: [String]) async throws {
        let probe = RuntimeProbe()
        await #expect(throws: (any Error).self) {
            try await CommanderRuntimeExecutor.resolveAndRun(
                arguments: ["peekaboo"] + command + ["--bridge-socket", "/synthetic/unavailable.sock"],
                runtimeFactory: probe.factory
            )
        }
        #expect(probe.runtimeConstructions == 1)
        #expect(probe.bridgeProbes == 1)
    }
}

@MainActor
private final class RuntimeProbe {
    var runtimeConstructions = 0
    var bridgeProbes = 0

    var factory: CommanderRuntimeExecutor.RuntimeFactory {
        .init { options in
            self.runtimeConstructions += 1
            _ = try await RuntimeHostResolver.resolveServices(
                options: options,
                environment: [:],
                configurationInput: nil,
                dependencies: ScreenCaptureKitOwnerRuntimeTests.inertDependencies(
                    makeLocalServices: { _ in OwnerPolicyFixtureServices(ownerAware: true) },
                    claimScreenCaptureKitOwner: { throw ProbeError.reached },
                    inspectScreenCaptureKitOwner: { nil },
                    makeRemoteHandshakeCache: {
                        RuntimeHostResolver.RemoteHandshakeCache(
                            identity: .init(
                                bundleIdentifier: "boo.peekaboo.test",
                                teamIdentifier: nil,
                                processIdentifier: getpid()
                            ),
                            handshakeProvider: { _, _ in
                                self.bridgeProbes += 1
                                throw ProbeError.reached
                            }
                        )
                    }
                )
            )
            throw ProbeError.reached
        }
    }

    private enum ProbeError: Error {
        case reached
    }
}
