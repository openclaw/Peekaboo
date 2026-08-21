import AppKit
import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

#if !PEEKABOO_SKIP_AUTOMATION
private enum SeeCommandPlaygroundTestConfig {
    @preconcurrency
    nonisolated static func enabled() -> Bool {
        ProcessInfo.processInfo.environment["RUN_LOCAL_TESTS"]?.lowercased() == "true"
    }

    @MainActor
    static func playgroundURL() -> URL? {
        if let path = ProcessInfo.processInfo.environment["PEEKABOO_PLAYGROUND_APP"],
           path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "boo.peekaboo.playground.debug") ??
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "boo.peekaboo.playground")
    }
}

private enum SeeCommandPlaygroundHarness {
    enum HarnessError: LocalizedError {
        case windowReadinessTimedOut(pid: Int32)

        var errorDescription: String? {
            switch self {
            case let .windowReadinessTimedOut(pid):
                "Playground process \(pid) did not publish a window before the readiness deadline."
            }
        }
    }

    struct Launch {
        let pid: Int32
        let processStartIdentity: UInt64
    }

    @MainActor
    static func launchBackgroundApplication() async throws -> Launch {
        let applicationURL = try #require(SeeCommandPlaygroundTestConfig.playgroundURL())
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        let application = try await NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        )
        let pid = application.processIdentifier
        var processStartIdentity: UInt64?
        do {
            let identity = try #require(SystemIdentityResolver.processStartIdentity(pid))
            processStartIdentity = identity
            let launch = Launch(pid: pid, processStartIdentity: identity)
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if application.isFinishedLaunching,
                   let output = try? self.run([
                       "window", "list", "--pid", String(pid), "--no-remote", "--json",
                   ]),
                   self.hasWindow(output) {
                    return launch
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw HarnessError.windowReadinessTimedOut(pid: pid)
        } catch {
            if let cleanupArguments = self.cleanupArguments(
                pid: pid,
                processStartIdentity: processStartIdentity
            ) {
                _ = try? self.run(cleanupArguments)
            }
            if !application.isTerminated {
                _ = application.forceTerminate()
            }
            throw error
        }
    }

    static func hasWindow(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["success"] as? Bool == true,
              let payload = root["data"] as? [String: Any],
              let windows = payload["windows"] as? [Any]
        else { return false }
        return !windows.isEmpty
    }

    static func cleanupArguments(for launch: Launch) -> [String] {
        [
            "app", "quit", "--pid", String(launch.pid),
            "--expected-process-start-identity", String(launch.processStartIdentity),
            "--force", "--no-remote", "--json",
        ]
    }

    static func cleanupArguments(
        pid: Int32,
        processStartIdentity: UInt64?
    ) -> [String]? {
        guard let processStartIdentity else { return nil }
        return self.cleanupArguments(for: Launch(
            pid: pid,
            processStartIdentity: processStartIdentity
        ))
    }

    static func run(
        _ arguments: [String],
        allowedExitStatuses: Set<Int32> = [0],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let result = try ExternalCommandRunner.runPeekabooCLI(
            arguments,
            allowedExitCodes: allowedExitStatuses,
            environment: environment
        )
        return result.combinedOutput
    }
}

struct SeeCommandPlaygroundHarnessContractTests {
    @Test
    func `Harness command failures throw instead of being swallowed`() {
        #expect(throws: CommandExecutionError.self) {
            _ = try SeeCommandPlaygroundHarness.run(
                ["app", "launch", "Playground"],
                environment: ["PEEKABOO_CLI_PATH": "/usr/bin/false"]
            )
        }
    }

    @Test
    func `Launch readiness requires a successful nonempty window inventory`() {
        #expect(SeeCommandPlaygroundHarness.hasWindow(
            #"{"success":true,"data":{"windows":[{"window_id":42}]}}"#
        ))
        #expect(!SeeCommandPlaygroundHarness.hasWindow(
            #"{"success":true,"data":{"windows":[]}}"#
        ))
        #expect(!SeeCommandPlaygroundHarness.hasWindow(
            #"{"success":false,"data":{"windows":[{"window_id":42}]}}"#
        ))
    }

    @Test
    func `Launch cleanup is exact-generation pinned`() {
        #expect(SeeCommandPlaygroundHarness.cleanupArguments(
            for: .init(pid: 42, processStartIdentity: 9001)
        ) == [
            "app", "quit", "--pid", "42",
            "--expected-process-start-identity", "9001",
            "--force", "--no-remote", "--json",
        ])
        #expect(SeeCommandPlaygroundHarness.cleanupArguments(
            pid: 42,
            processStartIdentity: nil
        ) == nil)
    }
}

@Suite(
    .serialized,
    .tags(.automation),
    .enabled(if: SeeCommandPlaygroundTestConfig.enabled())
)
struct SeeCommandPlaygroundTests {
    @Test
    @MainActor
    func `Hidden web-style fields are detected in Playground`() async throws {
        let launch = try await SeeCommandPlaygroundHarness.launchBackgroundApplication()
        let cleanupArguments = SeeCommandPlaygroundHarness.cleanupArguments(for: launch)

        do {
            let output = try SeeCommandPlaygroundHarness.run([
                "see", "--pid", String(launch.pid), "--no-remote", "--json",
            ])
            let data = try #require(output.data(using: .utf8))
            let envelope = try JSONDecoder().decode(CodableJSONResponse<SeeResult>.self, from: data)
            let result = envelope.data

            let identifiers = Set(result.ui_elements.compactMap(\.identifier))
            #expect(identifiers.contains("hidden-email-field"))
            #expect(identifiers.contains("hidden-password-field"))

            let roles = Dictionary(grouping: result.ui_elements, by: { $0.identifier ?? "" })
            #expect(roles["hidden-email-field"]?.first?.role == "textField")
            #expect(roles["hidden-password-field"]?.first?.role == "textField")

            #expect(identifiers.contains("permission-allow-button"))
            #expect(identifiers.contains("permission-deny-button"))
            #expect(roles["permission-allow-button"]?.first?.label == "Allow")
            #expect(roles["permission-deny-button"]?.first?.label == "Don't Allow")
        } catch {
            _ = try? SeeCommandPlaygroundHarness.run(cleanupArguments)
            throw error
        }

        _ = try SeeCommandPlaygroundHarness.run(cleanupArguments)
    }

    @Test
    @MainActor
    func `Semantic witnesses survive the live detached AX reader`() async throws {
        struct Window: Codable {
            let window_title: String
            let window_id: UInt32
        }

        struct WindowList: Codable {
            let windows: [Window]
        }

        struct FailureResponse: Codable {
            struct Failure: Codable {
                let code: String
                let message: String
            }

            let success: Bool
            let error: Failure
        }

        let launch = try await SeeCommandPlaygroundHarness.launchBackgroundApplication()
        let cleanupArguments = SeeCommandPlaygroundHarness.cleanupArguments(for: launch)

        do {
            let fixtures: [(title: String, values: [(identifier: String, expected: String?)])] = [
                ("Text Fixture", [("basic-text-last-submitted", "")]),
                ("Click Fixture", [("single-click-count", "0"), ("secondary-click-count", "0")]),
                ("Scroll Fixture", [("vertical-scroll-offset", nil)]),
            ]
            for fixture in fixtures {
                _ = try SeeCommandPlaygroundHarness.run([
                    "menu", "click", "--pid", String(launch.pid),
                    "--path", "Fixtures > Open \(fixture.title)", "--no-remote", "--json",
                ])
            }

            let windowOutput = try SeeCommandPlaygroundHarness.run([
                "window", "list", "--pid", String(launch.pid), "--no-remote", "--json",
            ])
            let windowData = try #require(windowOutput.data(using: .utf8))
            let windows = try JSONDecoder().decode(CodableJSONResponse<WindowList>.self, from: windowData).data.windows

            for fixture in fixtures {
                let window = try #require(windows.first(where: { $0.window_title == fixture.title }))
                let output = try SeeCommandPlaygroundHarness.run([
                    "see", "--pid", String(launch.pid),
                    "--window-id", String(window.window_id),
                    // Witness overlays are root-adjacent; keep the subprocess JSON below pipe capacity.
                    "--max-elements", "20", "--timeout", "5s", "--no-remote", "--json",
                ])
                let data = try #require(output.data(using: .utf8))
                let result = try JSONDecoder().decode(CodableJSONResponse<SeeResult>.self, from: data).data
                let byIdentifier = Dictionary(
                    grouping: result.ui_elements,
                    by: { $0.identifier ?? "" }
                )

                for (identifier, expectedValue) in fixture.values {
                    let elements = try #require(byIdentifier[identifier])
                    #expect(elements.count == 1)
                    let element = try #require(elements.first)
                    #expect(element.ax_role == "AXStaticText")
                    #expect(element.bounds.width > 5)
                    #expect(element.bounds.height > 5)
                    if let expectedValue {
                        #expect(element.value == expectedValue)
                    } else {
                        #expect(element.value.flatMap(Double.init)?.isFinite == true)
                    }

                    if identifier == "basic-text-last-submitted" {
                        let snapshotID = try #require(result.snapshot_id)
                        let actionOutput = try SeeCommandPlaygroundHarness.run([
                            "action", "AXIncrement", "--on", element.id,
                            "--snapshot", snapshotID, "--no-remote", "--json",
                        ], allowedExitStatuses: [1])
                        let actionData = try #require(actionOutput.data(using: .utf8))
                        let failure = try JSONDecoder().decode(FailureResponse.self, from: actionData)
                        #expect(!failure.success)
                        #expect(failure.error.code == "INVALID_INPUT")
                        #expect(failure.error.message.contains("not supported by \(element.id) staticText"))
                        #expect(!failure.error.message.localizedCaseInsensitiveContains("not found"))
                    }
                }
            }
        } catch {
            _ = try? SeeCommandPlaygroundHarness.run(cleanupArguments)
            throw error
        }

        _ = try SeeCommandPlaygroundHarness.run(cleanupArguments)
    }
}
#endif
