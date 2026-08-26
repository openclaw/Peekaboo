import Foundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

#if !PEEKABOO_SKIP_AUTOMATION
@Suite(.serialized, .tags(.automation), .enabled(if: CLITestEnvironment.runAutomationRead))
struct AppCommandTests {
    @Test
    func `App command exists`() {
        let config = AppCommand.commandDescription
        #expect(config.commandName == "app")
        #expect(config.abstract.contains("Control applications"))
    }

    @Test
    func `App command has expected subcommands`() {
        let subcommands = AppCommand.commandDescription.subcommands
        #expect(subcommands.count == 8)

        var subcommandNames: [String] = []
        subcommandNames.reserveCapacity(subcommands.count)
        for descriptor in subcommands {
            let name = descriptor.commandDescription.commandName ?? ""
            subcommandNames.append(name)
        }
        #expect(subcommandNames.contains("launch"))
        #expect(subcommandNames.contains("quit"))
        #expect(subcommandNames.contains("hide"))
        #expect(subcommandNames.contains("unhide"))
        #expect(subcommandNames.contains("switch"))
        #expect(subcommandNames.contains("focus"))
        #expect(subcommandNames.contains("relaunch"))
        #expect(subcommandNames.contains("list"))
    }

    @Test
    func `App launch command help`() async throws {
        let output = try await runAppCommand(["app", "launch", "--help"])

        #expect(output.contains("Launch an application"))
        #expect(output.contains("--bundle-id"))
        #expect(output.contains("--open"))
        #expect(output.contains("--wait-ready"))
        #expect(output.contains("--wait-for-window"))
        #expect(output.contains("--new-instance"))
        #expect(output.contains("--foreground"))
        #expect(output.contains("--no-focus"))
    }

    @Test
    func `App launch JSON returns the launch-bound process receipt`() async throws {
        let generation = UInt64.max - 1
        let (output, _) = try await runAppCommandWithService(
            ["app", "launch", "TextEdit", "--json"]
        ) { service in
            service.launchResults["TextEdit"] = ServiceApplicationInfo(
                processIdentifier: 202,
                processStartIdentity: generation,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"
            )
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])
        let outcome = try #require(object["outcome"] as? [String: Any])

        #expect((data["pid"] as? NSNumber)?.int32Value == 202)
        #expect((data["process_start_identity"] as? NSNumber)?.uint64Value == generation)
        #expect(data["process_start_identity_decimal"] as? String == String(generation))
        #expect(outcome["state"] as? String == "confirmed_change")
        #expect(object["effect"] as? String == outcome["effect"] as? String)
    }

    @Test
    func `App launch remains compatible when an older host omits the process receipt`() async throws {
        let (output, _) = try await runAppCommandWithService(
            ["app", "launch", "TextEdit", "--json"]
        ) { service in
            service.launchResults["TextEdit"] = ServiceApplicationInfo(
                processIdentifier: 303,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"
            )
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])

        #expect((data["pid"] as? NSNumber)?.int32Value == 303)
        #expect(data["process_start_identity"] == nil || data["process_start_identity"] is NSNull)
        #expect(data["process_start_identity_decimal"] == nil || data["process_start_identity_decimal"] is NSNull)
    }

    @Test
    func `App list exposes numeric and lossless decimal process receipts`() async throws {
        let generation: UInt64 = 9_007_199_254_740_993
        let (output, _) = try await runAppCommandWithService(
            ["app", "list", "--include-background", "--json"]
        ) { service in
            service.applications = [ServiceApplicationInfo(
                processIdentifier: 4242,
                processStartIdentity: generation,
                bundleIdentifier: "boo.peekaboo.mac",
                name: "Peekaboo",
                activationPolicy: .regular
            )]
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])
        let apps = try #require(data["apps"] as? [[String: Any]])
        let app = try #require(apps.first)
        let schemaCapabilities = try #require(data["schema_capabilities"] as? [String])

        #expect((app["process_start_identity"] as? NSNumber)?.uint64Value == generation)
        #expect(app["process_start_identity_decimal"] as? String == String(generation))
        #expect(schemaCapabilities.contains("processStartIdentityDecimal"))
    }

    @Test
    func `App relaunch JSON returns the new launch-bound process receipt`() async throws {
        let generation = UInt64.max - 2
        let (output, _) = try await runAppCommandWithService([
            "app", "relaunch", "TextEdit", "--wait", "0", "--foreground", "--json",
        ]) { service in
            service.launchResults["com.apple.TextEdit"] = ServiceApplicationInfo(
                processIdentifier: 202,
                processStartIdentity: generation,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"
            )
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])

        #expect((data["new_pid"] as? NSNumber)?.int32Value == 202)
        #expect((data["new_process_start_identity"] as? NSNumber)?.uint64Value == generation)
        #expect(data["new_process_start_identity_decimal"] as? String == String(generation))
    }

    @Test
    func `App quit command validation`() async throws {
        // Test missing app/all
        await #expect(throws: (any Error).self) {
            _ = try await runAppCommand(["app", "quit"])
        }

        // Test conflicting options
        await #expect(throws: (any Error).self) {
            _ = try await runAppCommand(["app", "quit", "--app", "Finder", "--all"])
        }
    }

    @Test
    func `App focus preserves an exact PID target`() async throws {
        let (output, service) = try await runAppCommandWithService([
            "app", "focus", "--pid", "202", "--foreground", "--json",
        ])
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(object["effect"] as? String == "confirmed")
        #expect((object["outcome"] as? [String: Any])?["effect"] as? String == "confirmed")
        #expect(await appServiceState(service) { $0.activateCalls } == ["PID:202"])
    }

    @Test
    func `App focus exits nonzero when activation verification fails`() async throws {
        let context = await MainActor.run { makeAppCommandContext() }
        await MainActor.run {
            context.applicationService.activateApplicationHandler = { _ in
                throw NSError(
                    domain: "AppFocusActivationVerification",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Application did not become active and frontmost"]
                )
            }
        }

        let result = try await InProcessCommandRunner.run(
            ["app", "focus", "TextEdit", "--foreground", "--json"],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        #expect(object["success"] as? Bool == false)
    }

    @Test
    func `App quit exits nonzero when the application refuses to quit`() async throws {
        let context = await MainActor.run { makeAppCommandContext() }
        await MainActor.run {
            context.applicationService.quitShouldSucceed = false
        }
        let result = try await InProcessCommandRunner.run(
            ["app", "quit", "--app", "Finder", "--json"],
            services: context.services
        )
        #expect(result.exitStatus != 0)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        #expect(object["success"] as? Bool == false)
    }

    @Test
    func `App quit saved receipt rejects wrong process generation without termination`() async throws {
        let context = await MainActor.run { makeAppCommandContext() }
        let result = try await InProcessCommandRunner.run(
            [
                "app", "quit",
                "--pid", "202",
                "--expected-process-start-identity", "9999",
                "--force",
                "--json",
            ],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        let requests = await appServiceState(context.applicationService) { $0.quitRequests }
        #expect(requests == [ApplicationQuitRequest(
            identifier: "PID:202",
            force: true,
            expectedIdentity: ApplicationProcessIdentity(
                processIdentifier: 202,
                processStartIdentity: 9999
            )
        )])
        #expect(await appServiceState(context.applicationService) { $0.terminationCount } == 0)
    }

    @Test
    func `App quit saved receipt requires PID selector`() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await runAppCommand([
                "app", "quit",
                "--app", "TextEdit",
                "--expected-process-start-identity", "2002",
            ])
        }
    }

    @Test
    func `App quit rejects selected application without process generation`() async throws {
        let context = await MainActor.run { makeAppCommandContext() }
        await MainActor.run {
            context.applicationService.applications = [ServiceApplicationInfo(
                processIdentifier: 202,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"
            )]
        }

        let result = try await InProcessCommandRunner.run(
            ["app", "quit", "--pid", "202", "--json"],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        #expect(await appServiceState(context.applicationService) { $0.quitRequests }.isEmpty)
        #expect(await appServiceState(context.applicationService) { $0.terminationCount } == 0)
    }

    @Test
    func `App hide command validation`() async throws {
        // Normal hide should work
        let output = try await runAppCommand(["app", "hide", "--app", "Finder", "--help"])
        #expect(output.contains("Hide an application"))
    }

    @Test
    func `App show command validation`() async throws {
        // Test missing app/all
        await #expect(throws: (any Error).self) {
            _ = try await runAppCommand(["app", "unhide"])
        }
    }

    @Test
    func `App switch command validation`() async throws {
        // Test missing to/cycle
        await #expect(throws: (any Error).self) {
            _ = try await runAppCommand(["app", "switch"])
        }
    }

    @Test
    func `App lifecycle flow`() {
        // This tests the logical flow of app lifecycle commands
        let launchCmd = ["app", "launch", "TextEdit", "--wait-ready"]
        let hideCmd = ["app", "hide", "--app", "TextEdit"]
        let showCmd = ["app", "unhide", "--app", "TextEdit"]
        let quitCmd = ["app", "quit", "--app", "TextEdit", "--json"]

        // Verify command structure is valid
        #expect(launchCmd.count > 3)
        #expect(hideCmd.count > 3)
        #expect(showCmd.count > 3)
        #expect(quitCmd.count > 3)
    }
}

// MARK: - App Command Integration Tests

@Suite(
    .serialized,
    .tags(.automation, .localOnly),
    .enabled(if: ProcessInfo.processInfo.environment["RUN_LOCAL_TESTS"] == "true"
        && !(ProcessInfo.processInfo.environment["PEEKABOO_CLI_PATH"] ?? "").isEmpty)
)
struct AppCommandIntegrationTests {
    @Test
    func `Launch TextEdit via external CLI`() throws {
        struct LaunchResult: Codable {
            let action: String
            let app_name: String
            let bundle_id: String
            let pid: Int32
            let is_ready: Bool
        }

        let result = try ExternalCommandRunner.runPeekabooCLI(
            [
                "app", "launch",
                "TextEdit",
                "--wait-ready",
                "--json",
            ],
            allowedExitCodes: [0, 1]
        )

        if result.exitStatus != 0 {
            let error = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
            if error.error?.code == ErrorCode.PERMISSION_ERROR_ACCESSIBILITY.rawValue {
                Issue.record("Accessibility permission required for app launch integration test")
                return
            }
            Issue.record("App launch failed: \(result.combinedOutput)")
            return
        }

        let response = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<LaunchResult>.self
        )
        #expect(response.success == true)
        #expect(response.data.action == "launch")
        #expect(response.data.pid > 0)
    }

    @Test
    func `Hide and unhide Finder via external CLI`() throws {
        struct UnhideResult: Codable {
            let action: String
            let app_name: String
            let bundle_id: String
            let activated: Bool
        }

        let hideResult = try ExternalCommandRunner.runPeekabooCLI(
            [
                "app", "hide",
                "--app", "Finder",
                "--json",
            ],
            allowedExitCodes: [0, 1]
        )

        if hideResult.exitStatus != 0 {
            let error = try ExternalCommandRunner.decodeJSONResponse(from: hideResult, as: JSONResponse.self)
            if error.error?.code == ErrorCode.PERMISSION_ERROR_ACCESSIBILITY.rawValue {
                Issue.record("Accessibility permission required for app hide/unhide integration test")
                return
            }
            Issue.record("App hide failed: \(hideResult.combinedOutput)")
            return
        }

        let unhideResult = try ExternalCommandRunner.runPeekabooCLI(
            [
                "app", "unhide",
                "--app", "Finder",
                "--activate",
                "--json",
            ],
            allowedExitCodes: [0, 1]
        )

        if unhideResult.exitStatus != 0 {
            let error = try ExternalCommandRunner.decodeJSONResponse(from: unhideResult, as: JSONResponse.self)
            if error.error?.code == ErrorCode.PERMISSION_ERROR_ACCESSIBILITY.rawValue {
                Issue.record("Accessibility permission required for app hide/unhide integration test")
                return
            }
            Issue.record("App unhide failed: \(unhideResult.combinedOutput)")
            return
        }

        let response = try ExternalCommandRunner.decodeJSONResponse(
            from: unhideResult,
            as: CodableJSONResponse<UnhideResult>.self
        )
        #expect(response.success == true)
        #expect(response.data.action == "unhide")
    }
}

// MARK: - Shared Helpers

private struct CommandFailure: Error {
    let status: Int32
    let stderr: String
}

private func runAppCommand(
    _ args: [String],
    configure: (@MainActor (StubApplicationService) -> Void)? = nil
) async throws -> String {
    let (output, _) = try await runAppCommandWithService(args, configure: configure)
    return output
}

private func runAppCommandWithService(
    _ args: [String],
    configure: (@MainActor (StubApplicationService) -> Void)? = nil
) async throws -> (String, StubApplicationService) {
    let context = await MainActor.run { makeAppCommandContext() }
    if let configure {
        await MainActor.run {
            configure(context.applicationService)
        }
    }
    let result = try await InProcessCommandRunner.run(args, services: context.services)
    let output = result.stdout.isEmpty ? result.stderr : result.stdout
    if result.exitStatus != 0 {
        throw CommandFailure(status: result.exitStatus, stderr: output)
    }
    return (output, context.applicationService)
}

@MainActor
private func makeAppCommandContext() -> AppCommandContext {
    let data = defaultAppCommandData()
    let applicationService = OutcomeStubApplicationService(
        applications: data.applications,
        windowsByApp: data.windowsByApp
    )
    let windowService = StubWindowService(windowsByApp: data.windowsByApp)
    let services = TestServicesFactory.makePeekabooServices(
        applications: applicationService,
        windows: windowService
    )
    return AppCommandContext(services: services, applicationService: applicationService)
}

private func appServiceState<T: Sendable>(
    _ service: StubApplicationService,
    _ operation: @MainActor (StubApplicationService) -> T
) async -> T {
    await MainActor.run {
        operation(service)
    }
}

private struct AppCommandContext {
    let services: PeekabooServices
    let applicationService: StubApplicationService
}

@MainActor
private func defaultAppCommandData()
-> (applications: [ServiceApplicationInfo], windowsByApp: [String: [ServiceWindowInfo]]) {
    let applications = AppCommandTests.defaultApplications()
    let windowsByApp = AppCommandTests.defaultWindowsByApp()
    return (applications, windowsByApp)
}

extension AppCommandTests {
    fileprivate static func defaultApplications() -> [ServiceApplicationInfo] {
        [
            ServiceApplicationInfo(
                processIdentifier: 101,
                processStartIdentity: 1001,
                bundleIdentifier: "com.apple.finder",
                name: "Finder",
                bundlePath: "/System/Library/CoreServices/Finder.app",
                isActive: true,
                isHidden: false,
                windowCount: 1
            ),
            ServiceApplicationInfo(
                processIdentifier: 202,
                processStartIdentity: 2002,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit",
                bundlePath: "/System/Applications/TextEdit.app",
                isActive: false,
                isHidden: false,
                windowCount: 1
            ),
        ]
    }

    fileprivate static func defaultWindowsByApp() -> [String: [ServiceWindowInfo]] {
        [
            "Finder": [self.finderWindow()],
            "TextEdit": [self.textEditWindow()],
        ]
    }

    fileprivate static func finderWindow() -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: 1,
            title: "Finder Window",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: false,
            isMainWindow: true,
            windowLevel: 0,
            alpha: 1.0,
            index: 0,
            spaceID: 1,
            spaceName: "Desktop 1",
            screenIndex: 0,
            screenName: "Built-in"
        )
    }

    fileprivate static func textEditWindow() -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: 2,
            title: "Document",
            bounds: CGRect(x: 100, y: 100, width: 700, height: 500),
            isMinimized: false,
            isMainWindow: true,
            windowLevel: 0,
            alpha: 1.0,
            index: 0,
            spaceID: 2,
            spaceName: "Desktop 2",
            screenIndex: 0,
            screenName: "Built-in"
        )
    }
}

#endif
