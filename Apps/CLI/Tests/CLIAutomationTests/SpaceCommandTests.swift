import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomation
@testable import PeekabooCLI
@testable import PeekabooCore

#if !PEEKABOO_SKIP_AUTOMATION

// MARK: - Read-only scenarios

@Suite(
    .serialized,
    .tags(.automation),
    .enabled(if: CLITestEnvironment.runAutomationRead)
)
struct SpaceCommandReadTests {
    @Test
    func `space command exists in help`() async throws {
        let output = try await self.runPeekaboo(["--help"])
        #expect(output.contains("space"))
        #expect(output.contains("Manage macOS Spaces"))
    }

    @Test
    func `space command help shows subcommands`() async throws {
        let output = try await self.runPeekaboo(["space", "--help"])
        #expect(output.contains("Manage macOS Spaces (virtual desktops)"))
        #expect(output.contains("list"))
        #expect(output.contains("switch"))
        #expect(output.contains("move-window"))
    }

    @Test
    func `space switch command help`() async throws {
        let output = try await self.runPeekaboo(["space", "switch", "--help"])
        #expect(output.contains("Switch to a different Space"))
        #expect(output.contains("--to"))
        #expect(output.contains("--foreground"))
    }

    @Test
    func `space list command`() async throws {
        let output = try await self.runPeekaboo(["space", "list"])
        #expect(!output.isEmpty)
    }

    @Test
    func `space list with JSON output`() async throws {
        let output = try await self.runPeekaboo(["space", "list", "--json"])
        let response = try JSONDecoder().decode(CodableJSONResponse<SpaceListData>.self, from: Data(output.utf8))
        #expect(response.success)
    }

    @Test
    func `space list detailed flag`() async throws {
        let output = try await self.runPeekaboo(["space", "list", "--detailed"])
        #expect(output.contains("Space"))
    }

    @Test
    func `space switch requires --to parameter`() {
        #expect(throws: (any Error).self) {
            try CLIOutputCapture.suppressStderr {
                _ = try SwitchSubcommand.parse([])
            }
        }
    }

    @Test
    func `space switch rejects non-numeric parameters`() {
        #expect(throws: (any Error).self) {
            try CLIOutputCapture.suppressStderr {
                _ = try SwitchSubcommand.parse(["--to", "abc"])
            }
        }
    }

    @Test
    func `space move-window requires app parameter`() {
        #expect(throws: (any Error).self) {
            var command = try MoveWindowSubcommand.parse(["--to", "2"])
            try command.validate()
        }
    }

    @Test
    func `space move-window requires destination`() {
        #expect(throws: (any Error).self) {
            var command = try MoveWindowSubcommand.parse(["--app", "Finder"])
            try command.validate()
        }
    }

    @Test
    func `space move-window parses follow option`() throws {
        let command = try MoveWindowSubcommand.parse([
            "--app", "Finder",
            "--to", "3",
            "--follow",
            "--foreground",
        ])

        #expect(command.app == "Finder")
        #expect(command.to == 3)
        #expect(command.follow == true)
        #expect(command.foreground == true)
    }

    @Test
    func `space move-window parses exact window ID without an application`() throws {
        var command = try MoveWindowSubcommand.parse([
            "--window-id", "42",
            "--to-current",
        ])

        try command.validate()
        #expect(command.windowId == 42)
        #expect(command.app == nil)
    }

    private func runPeekaboo(_ arguments: [String]) async throws -> String {
        let context = self.makeTestContext()
        let result = try await InProcessCommandRunner.run(
            arguments,
            services: context.services,
            spaceService: context.spaceService
        )
        return result.stdout
    }

    @MainActor
    func makeTestContext() -> (services: PeekabooServices, spaceService: any SpaceCommandSpaceService) {
        let applications = Self.testApplications()
        let windowsByApp = Self.windowsByApp()

        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: applications, windowsByApp: windowsByApp),
            windows: StubWindowService(windowsByApp: windowsByApp),
            menu: StubMenuService(menusByApp: [:]),
            dialogs: StubDialogService(),
            screens: []
        )

        let spaceInfos = Self.spaceInfos()
        let windowSpaces = Self.windowSpaces(from: spaceInfos)
        let spaceService = StubSpaceService(spaces: spaceInfos, windowSpaces: windowSpaces)

        return (services, spaceService)
    }
}

extension SpaceCommandReadTests {
    fileprivate static func testApplications() -> [ServiceApplicationInfo] {
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

    fileprivate static func windowsByApp() -> [String: [ServiceWindowInfo]] {
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
            screenName: "Built-in",
            mutationIdentity: WindowMutationIdentity(
                windowID: 1,
                ownerProcessIdentifier: 101,
                ownerProcessStartIdentity: 1001,
                capturedBounds: CGRect(x: 0, y: 0, width: 800, height: 600)
            )
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
            screenName: "Built-in",
            mutationIdentity: WindowMutationIdentity(
                windowID: 2,
                ownerProcessIdentifier: 202,
                ownerProcessStartIdentity: 2002,
                capturedBounds: CGRect(x: 100, y: 100, width: 700, height: 500)
            )
        )
    }

    fileprivate static func spaceInfos() -> [SpaceInfo] {
        [
            SpaceInfo(
                id: 1,
                type: .user,
                isActive: true,
                displayID: 1,
                name: "Desktop 1",
                ownerPIDs: [101]
            ),
            SpaceInfo(
                id: 2,
                type: .user,
                isActive: false,
                displayID: 1,
                name: "Desktop 2",
                ownerPIDs: [202]
            ),
        ]
    }

    fileprivate static func windowSpaces(from infos: [SpaceInfo]) -> [Int: [SpaceInfo]] {
        [
            1: [infos[0]],
            2: [infos[1]],
        ]
    }
}

// MARK: - Actions that mutate Spaces

@Suite(
    .serialized,
    .tags(.automation),
    .enabled(if: CLITestEnvironment.runAutomationActions)
)
struct SpaceCommandActionTests {
    @Test
    func `space switch with valid number`() async throws {
        let context = await self.makeSpaceContext()
        let result = try await self.runSpaceCommand([
            "space", "switch",
            "--to", "1",
            "--foreground",
            "--json",
        ], context: context)
        #expect(result.exitStatus == 0)
        let response = try JSONDecoder().decode(
            SpaceActionResponse.self,
            from: Data(self.output(from: result).utf8)
        )
        #expect(response.success)
        let outcome = try #require(response.outcome)
        #expect(outcome.state == .dispatchedUnverified)
        #expect(outcome.deliveryMechanism == .nativeFramework)
        #expect(outcome.deliveryMode == .foreground)
        #expect(outcome.dispatchState == .dispatched(unitCount: .one))
        #expect(outcome.retrySafety == .unsafe)
        #expect(outcome.mutationDispatched)
        #expect(!outcome.retrySafe)
        let switchCalls = await self.spaceState(context) { $0.switchCalls }
        #expect(switchCalls.contains(1))
    }

    @Test
    func `space switch post-dispatch failure preserves indeterminate JSON receipt`() async throws {
        let context = await self.makeSpaceContext()
        await MainActor.run {
            context.spaceService.switchFailure = .indeterminate(
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Space switch was dispatched, but post-dispatch settling failed."
            )
        }

        let result = try await self.runSpaceCommand([
            "space", "switch",
            "--to", "1",
            "--foreground",
            "--json",
        ], context: context)

        #expect(result.exitStatus == 1)
        let response = try JSONDecoder().decode(
            SpaceActionResponse.self,
            from: Data(self.output(from: result).utf8)
        )
        #expect(!response.success)
        let outcome = try #require(response.outcome)
        #expect(outcome.state == .indeterminate)
        #expect(outcome.deliveryMechanism == .nativeFramework)
        #expect(outcome.deliveryMode == .foreground)
        #expect(outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
        #expect(outcome.retrySafety == .unsafe)
        #expect(outcome.mutationDispatched)
        #expect(!outcome.retrySafe)
        #expect(response.error?.mutation_dispatched == true)
        #expect(response.error?.retry_safe == false)
    }

    @Test
    func `space move-window to current Space`() async throws {
        let context = await self.makeSpaceContext()
        let result = try await self.runSpaceCommand([
            "space", "move-window",
            "--app", "Finder",
            "--to-current",
            "--json",
        ], context: context)
        #expect(result.exitStatus == 0)
        let response = try JSONDecoder().decode(
            WindowSpaceActionResponse.self,
            from: Data(self.output(from: result).utf8)
        )
        #expect(response.success)
        let moveCalls = await self.spaceState(context) { $0.moveToCurrentCalls }
        #expect(!moveCalls.isEmpty)
    }

    @Test
    func `space move-window with follow option`() async throws {
        let context = await self.makeSpaceContext()
        let result = try await self.runSpaceCommand([
            "space", "move-window",
            "--app", "TextEdit",
            "--to", "1",
            "--follow",
            "--foreground",
            "--json",
        ], context: context)
        #expect(result.exitStatus == 0)
        let response = try JSONDecoder().decode(
            WindowSpaceActionResponse.self,
            from: Data(self.output(from: result).utf8)
        )
        #expect(response.success)
        let moveCalls = await self.spaceState(context) { $0.moveWindowCalls }
        #expect(moveCalls.contains { $0.spaceID == 1 })
    }

    @Test
    func `space move-window rejects a returned non-success move outcome`() async throws {
        let context = await self.makeSpaceContext()
        await MainActor.run {
            context.spaceService.moveOutcome = .refused(reason: .targetUnavailable)
        }

        let result = try await self.runSpaceCommand([
            "space", "move-window", "--app", "Finder", "--to-current", "--json",
        ], context: context)

        #expect(result.exitStatus == 1)
        let response = try JSONDecoder().decode(JSONResponse.self, from: Data(self.output(from: result).utf8))
        #expect(!response.success)
        #expect(response.outcome?.state == .refused)
    }

    @Test
    func `space move-window rejects a contradictory foreground service receipt`() async throws {
        let context = await self.makeSpaceContext()
        await MainActor.run {
            context.spaceService.moveOutcome = .confirmedChange(
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                unitCount: .one
            )
        }

        let result = try await self.runSpaceCommand([
            "space", "move-window", "--app", "Finder", "--to-current", "--json",
        ], context: context)

        #expect(result.exitStatus == 1)
        let response = try JSONDecoder().decode(JSONResponse.self, from: Data(self.output(from: result).utf8))
        #expect(response.outcome?.state == .indeterminate)
        #expect(response.outcome?.deliveryMode == .foreground)
        #expect(response.outcome?.dispatchedUnitCount == .one)
        #expect(response.error?.mutation_dispatched == true)
        #expect(response.error?.retry_safe == false)
    }

    @Test
    func `space move-window follow rejects a returned non-success switch outcome`() async throws {
        let context = await self.makeSpaceContext()
        await MainActor.run {
            context.spaceService.switchOutcome = .refused(reason: .targetUnavailable)
        }

        let result = try await self.runSpaceCommand([
            "space", "move-window", "--app", "TextEdit", "--to", "1", "--follow", "--foreground", "--json",
        ], context: context)

        #expect(result.exitStatus == 1)
        let response = try JSONDecoder().decode(JSONResponse.self, from: Data(self.output(from: result).utf8))
        #expect(!response.success)
        #expect(response.error?.mutation_dispatched == true)
        #expect(response.outcome?.state == .indeterminate)
        #expect(response.outcome?.dispatchedUnitCount == .one)
        let moveCalls = await self.spaceState(context) { $0.moveWindowCalls }
        let switchCalls = await self.spaceState(context) { $0.switchCalls }
        #expect(moveCalls.count == 1)
        #expect(switchCalls == [1])
    }

    @Test
    func `space move-window follow preserves a partial switch outcome and both dispatch units`() async throws {
        let context = await self.makeSpaceContext()
        await MainActor.run {
            context.spaceService.switchOutcome = .partial(
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                unitCount: .one
            )
        }

        let result = try await self.runSpaceCommand([
            "space", "move-window", "--app", "TextEdit", "--to", "1", "--follow", "--foreground", "--json",
        ], context: context)

        #expect(result.exitStatus == 1)
        let response = try JSONDecoder().decode(JSONResponse.self, from: Data(self.output(from: result).utf8))
        #expect(!response.success)
        #expect(response.outcome?.state == .partial)
        #expect(response.outcome?.dispatchedUnitCount == DesktopActionOutcome.DispatchUnitCount(2))
        #expect(response.error?.mutation_dispatched == true)
        #expect(response.error?.retry_safe == false)
    }

    @Test
    func `space move-window rejects every conflicting selector pair before dispatch`() async throws {
        let selectorPairs = [
            ["--window-id", "301", "--window-title", "Draft"],
            ["--window-id", "301", "--window-index", "0"],
            ["--window-title", "Draft", "--window-index", "0"],
        ]

        for selectors in selectorPairs {
            let context = await self.makeSpaceSelectionContext(titles: ["Draft", "Notes"])
            let result = try await self.runSpaceCommand(
                ["space", "move-window", "--app", "Fixture"] + selectors + ["--to-current", "--json"],
                context: context
            )

            #expect(result.exitStatus == 1)
            #expect((result.stdout + result.stderr).contains("Provide only one of"))
            let moveCalls = await self.spaceState(context) { $0.moveToCurrentCalls }
            #expect(moveCalls.isEmpty)
        }
    }

    @Test
    func `space move-window rejects duplicate exact titles before dispatch`() async throws {
        let context = await self.makeSpaceSelectionContext(titles: ["Draft", "Draft"])

        let result = try await self.runSpaceCommand([
            "space", "move-window", "--app", "Fixture", "--window-title", "Draft",
            "--to-current", "--json",
        ], context: context)

        #expect(result.exitStatus == 1)
        #expect((result.stdout + result.stderr).localizedCaseInsensitiveContains("ambiguous"))
        let moveCalls = await self.spaceState(context) { $0.moveToCurrentCalls }
        #expect(moveCalls.isEmpty)
    }

    @Test
    func `space move-window rejects duplicate partial titles before dispatch`() async throws {
        let context = await self.makeSpaceSelectionContext(titles: ["Draft One", "Draft Two"])

        let result = try await self.runSpaceCommand([
            "space", "move-window", "--app", "Fixture", "--window-title", "Draft",
            "--to-current", "--json",
        ], context: context)

        #expect(result.exitStatus == 1)
        #expect((result.stdout + result.stderr).localizedCaseInsensitiveContains("ambiguous"))
        let moveCalls = await self.spaceState(context) { $0.moveToCurrentCalls }
        #expect(moveCalls.isEmpty)
    }

    @Test
    func `space move-window dispatches to a unique partial title match`() async throws {
        let context = await self.makeSpaceSelectionContext(titles: ["Draft One", "Release Notes"])

        let result = try await self.runSpaceCommand([
            "space", "move-window", "--app", "Fixture", "--window-title", "Notes",
            "--to-current", "--json",
        ], context: context)

        #expect(result.exitStatus == 0)
        let moveCalls = await self.spaceState(context) { $0.moveToCurrentCalls }
        #expect(moveCalls == [302])
    }

    @Test
    func `space move-window dispatches an exact ID without application lookup`() async throws {
        let context = await self.makeSpaceSelectionContext(titles: ["Draft One", "Release Notes"])

        let result = try await self.runSpaceCommand([
            "space", "move-window", "--window-id", "302", "--to-current", "--json",
        ], context: context)

        #expect(result.exitStatus == 0)
        let moveCalls = await self.spaceState(context) { $0.moveToCurrentCalls }
        #expect(moveCalls == [302])
    }

    private func runSpaceCommand(
        _ arguments: [String],
        context: SpaceHarnessContext
    ) async throws -> CommandRunResult {
        try await SpaceCommandEnvironment.withSpaceService(context.spaceService) {
            try await InProcessCommandRunner.run(
                arguments,
                services: context.services,
                spaceService: context.spaceService
            )
        }
    }

    @MainActor
    private func makeSpaceContext() async -> SpaceHarnessContext {
        let base = SpaceCommandReadTests().makeTestContext()
        let spaces = await base.spaceService.getAllSpaces()
        let spaceService = StubSpaceService(spaces: spaces, windowSpaces: [:])
        let services = base.services
        return SpaceHarnessContext(services: services, spaceService: spaceService)
    }

    @MainActor
    private func makeSpaceSelectionContext(titles: [String]) async -> SpaceHarnessContext {
        let appName = "Fixture"
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 101,
            processStartIdentity: 1001,
            bundleIdentifier: "dev.fixture",
            name: appName
        )
        let windows = titles.enumerated().map { offset, title in
            let bounds = CGRect(x: CGFloat(offset * 20), y: CGFloat(offset * 20), width: 640, height: 480)
            return ServiceWindowInfo(
                windowID: 301 + offset,
                title: title,
                bounds: bounds,
                isMainWindow: offset == 0,
                index: offset,
                mutationIdentity: WindowMutationIdentity(
                    windowID: 301 + offset,
                    ownerProcessIdentifier: 101,
                    ownerProcessStartIdentity: 1001,
                    capturedBounds: bounds
                )
            )
        }
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(
                applications: [appInfo],
                windowsByApp: [appName: windows]
            ),
            windows: StubWindowService(windowsByApp: [appName: windows])
        )
        let spaceService = StubSpaceService(spaces: SpaceCommandReadTests.spaceInfos())
        return SpaceHarnessContext(services: services, spaceService: spaceService)
    }

    private func output(from result: CommandRunResult) -> String {
        result.stdout.isEmpty ? result.stderr : result.stdout
    }

    private func spaceState<T: Sendable>(
        _ context: SpaceHarnessContext,
        _ operation: @MainActor (StubSpaceService) -> T
    ) async -> T {
        await MainActor.run {
            operation(context.spaceService)
        }
    }
}

private struct SpaceHarnessContext {
    let services: PeekabooServices
    let spaceService: StubSpaceService
}

// MARK: - Response types shared by tests

private struct SpaceListResponse: Codable {
    let success: Bool
    let data: SpaceListData?
    let error: String?
}

private struct SpaceListData: Codable {
    let spaces: [SpaceData]
}

private struct SpaceData: Codable {
    let id: UInt64
    let type: String
    let is_active: Bool?
    let display_id: UInt32?
}

private struct SpaceActionResponse: Codable {
    let success: Bool
    let effect: ActionEffect?
    let outcome: DesktopActionOutcome.Projection?
    let data: SpaceActionData?
    let error: ErrorInfo?
}

private struct SpaceActionData: Codable {
    let action: String
    let success: Bool
    let space_id: UInt64
    let space_number: Int
}

private struct WindowSpaceActionResponse: Codable {
    let success: Bool
    let data: WindowSpaceActionData?
    let error: String?
}

private struct WindowSpaceActionData: Codable {
    let action: String
    let success: Bool
    let window_id: UInt32
    let window_title: String
    let space_id: UInt64?
    let space_number: Int?
    let moved_to_current: Bool?
    let followed: Bool?
}
#endif
