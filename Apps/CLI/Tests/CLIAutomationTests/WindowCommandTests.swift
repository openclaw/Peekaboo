import CoreGraphics
import Foundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

#if !PEEKABOO_SKIP_AUTOMATION
private enum WindowCommandLocalIntegrationTestConfig {
    @preconcurrency
    nonisolated static func enabled() -> Bool {
        ProcessInfo.processInfo.environment["RUN_WINDOW_LOCAL_INTEGRATION_TESTS"]?.lowercased() == "true"
    }
}

@Suite(.serialized, .tags(.automation), .enabled(if: CLITestEnvironment.runAutomationRead))
struct WindowCommandTests {
    @Test
    func `window command help`() async throws {
        let output = try await runPeekabooCommand(["window", "--help"])

        #expect(output.contains("Manipulate application windows"))
        #expect(output.contains("close"))
        #expect(output.contains("minimize"))
        #expect(output.contains("restore"))
        #expect(output.contains("maximize"))
        #expect(output.contains("move"))
        #expect(output.contains("resize"))
        #expect(output.contains("set-bounds"))
        #expect(output.contains("focus"))
        #expect(output.contains("list"))
    }

    @Test
    func `window restore targets a minimized exact PID window and reports success`() async throws {
        let appName = "TextEdit"
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 7,
            bundleIdentifier: "com.apple.TextEdit",
            name: appName
        )
        let window = ServiceWindowInfo(
            windowID: 101,
            title: "Fixture",
            bounds: CGRect(x: 10, y: 20, width: 640, height: 480),
            isMinimized: true
        )
        let context = await MainActor.run {
            self.makeWindowContext(appInfo: appInfo, windows: [appName: [window]])
        }

        let result = try await self.runWindowCommand([
            "window", "restore",
            "--pid", "42",
            "--window-id", "101",
            "--json",
        ], context: context)
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        let response = try JSONDecoder().decode(
            CodableJSONResponse<WindowActionResult>.self,
            from: Data(output.utf8)
        )

        #expect(response.data.action == "restore")
        #expect(response.outcome == context.windowService.actionOutcome?.projection)
        #expect(response.effect == context.windowService.actionOutcome?.effect)
        #expect(await MainActor.run {
            context.windowService.windowsByApp[appName]?.first?.isMinimized
        } == false)
    }

    @Test
    func `window mutations reject every conflicting selector pair before dispatch`() async throws {
        let selectorPairs = [
            ["--window-id", "101", "--window-title", "Draft"],
            ["--window-id", "101", "--window-index", "0"],
            ["--window-title", "Draft", "--window-index", "0"],
        ]

        for selectors in selectorPairs {
            let context = await MainActor.run {
                self.makeStrictSelectionContext(titles: ["Draft", "Notes"])
            }
            let result = try await self.runWindowCommand(
                ["window", "move", "--app", "Fixture"] + selectors + ["--x", "20", "--y", "30", "--json"],
                context: context,
                allowedExitStatuses: [1]
            )

            #expect((result.stdout + result.stderr).contains("Provide only one of"))
            #expect(await MainActor.run { context.windowService.moveCalls.isEmpty })
        }
    }

    @Test
    func `window mutation rejects duplicate exact titles before dispatch`() async throws {
        let context = await MainActor.run {
            self.makeStrictSelectionContext(titles: ["Draft", "Draft"])
        }

        let result = try await self.runWindowCommand(
            [
                "window", "move", "--app", "Fixture", "--window-title", "Draft",
                "--x", "20", "--y", "30", "--json",
            ],
            context: context,
            allowedExitStatuses: [1]
        )

        #expect((result.stdout + result.stderr).localizedCaseInsensitiveContains("ambiguous"))
        #expect(await MainActor.run { context.windowService.moveCalls.isEmpty })
    }

    @Test
    func `window mutation rejects duplicate partial titles before dispatch`() async throws {
        let context = await MainActor.run {
            self.makeStrictSelectionContext(titles: ["Draft One", "Draft Two"])
        }

        let result = try await self.runWindowCommand(
            [
                "window", "move", "--app", "Fixture", "--window-title", "Draft",
                "--x", "20", "--y", "30", "--json",
            ],
            context: context,
            allowedExitStatuses: [1]
        )

        #expect((result.stdout + result.stderr).localizedCaseInsensitiveContains("ambiguous"))
        #expect(await MainActor.run { context.windowService.moveCalls.isEmpty })
    }

    @Test
    func `window mutation refuses a fuzzy application selector before window lookup`() async throws {
        let context = await MainActor.run {
            self.makeStrictSelectionContext(titles: ["Draft"])
        }

        let result = try await self.runWindowCommand(
            [
                "window", "move", "--app", "Fixt", "--window-title", "Draft",
                "--x", "20", "--y", "30", "--json",
            ],
            context: context,
            allowedExitStatuses: [1]
        )

        #expect((result.stdout + result.stderr).contains("not allowed for mutation"))
        #expect(await MainActor.run { context.windowService.moveCalls.isEmpty })
    }

    @Test
    func `window mutation dispatches to the unique partial title match`() async throws {
        let context = await MainActor.run {
            self.makeStrictSelectionContext(titles: ["Draft One", "Release Notes"])
        }

        let result = try await self.runWindowCommand(
            [
                "window", "move", "--app", "Fixture", "--window-title", "Notes",
                "--x", "20", "--y", "30", "--json",
            ],
            context: context
        )

        #expect(result.exitStatus == 0)
        #expect(await MainActor.run { context.windowService.moveCalls.map(\.description) } == [
            "windowId(102)",
        ])
    }

    @Test
    func `window focus verify refuses when focused-window readback is absent`() async throws {
        let context = await MainActor.run {
            self.makeStrictSelectionContext(titles: ["Draft"])
        }

        let result = try await self.runWindowCommand(
            ["window", "focus", "--app", "Fixture", "--verify", "--json"],
            context: context,
            allowedExitStatuses: [1]
        )

        let response = try JSONDecoder().decode(
            JSONResponse.self,
            from: Data((result.stdout + result.stderr).utf8)
        )
        #expect(!response.success)
        #expect(response.error?.mutation_dispatched == true)
        #expect(await MainActor.run { context.windowService.focusCalls.map(\.description) } == [
            "windowId(101)",
        ])
    }

    @Test
    func `minimized exact close reports restore or foreground guidance`() async throws {
        let appName = "TextEdit"
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 7,
            bundleIdentifier: "com.apple.TextEdit",
            name: appName
        )
        let window = ServiceWindowInfo(
            windowID: 101,
            title: "Fixture",
            bounds: CGRect(x: 10, y: 20, width: 640, height: 480),
            isMinimized: true
        )
        let context = await MainActor.run {
            self.makeWindowContext(appInfo: appInfo, windows: [appName: [window]])
        }

        let result = try await self.runWindowCommand(
            [
                "window", "close",
                "--pid", "42",
                "--window-id", "101",
                "--json",
            ],
            context: context,
            allowedExitStatuses: [1]
        )
        let output = result.stdout + result.stderr

        #expect(output.localizedCaseInsensitiveContains("restore"))
        #expect(output.contains("--foreground") || output.localizedCaseInsensitiveContains("foreground fallback"))
        #expect(!output.contains("WINDOW_NOT_FOUND"))
        #expect(await MainActor.run { context.windowService.closeFallbackRequests } == [false])
    }

    @Test
    func `window list hides non-shareable overlays`() async throws {
        let appName = "OverlayApp"
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 5555,
            bundleIdentifier: "dev.overlay",
            name: appName
        )

        let overlay = ServiceWindowInfo(
            windowID: 10,
            title: "HUD",
            bounds: CGRect(x: 0, y: 0, width: 200, height: 120),
            layer: 8,
            sharingState: WindowSharingState.none
        )
        let mainWindow = ServiceWindowInfo(
            windowID: 11,
            title: "Document",
            bounds: CGRect(x: 50, y: 50, width: 1200, height: 800),
            index: 1,
            sharingState: .readWrite
        )

        let context = await MainActor.run {
            self.makeWindowContext(
                appInfo: appInfo,
                windows: [appName: [overlay, mainWindow]]
            )
        }

        let result = try await self.runWindowCommand([
            "window", "list",
            "--app", appName,
            "--json",
        ], context: context)

        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        let response = try JSONDecoder().decode(
            CodableJSONResponse<WindowListData>.self,
            from: Data(output.utf8)
        )

        let windows = response.data.windows
        #expect(response.data.inventory_completeness == "partial")
        #expect(response.data.inventory_warnings?.contains(where: {
            $0.contains("omitted 1 non-renderable or duplicate inventory row")
        }) == true)
        #expect(windows.count == 1)
        let window = try #require(windows.first)
        #expect(window.window_title == "Document")
        #expect(window.window_index == mainWindow.index)
    }

    @Test
    func `window list preserves partial inventory authority in JSON`() async throws {
        let appName = "PartialApp"
        let context = await MainActor.run {
            self.makeWindowContext(
                appInfo: ServiceApplicationInfo(
                    processIdentifier: 5556,
                    bundleIdentifier: "dev.partial",
                    name: appName
                ),
                windows: [
                    appName: [
                        ServiceWindowInfo(
                            windowID: 12,
                            title: "Document",
                            bounds: CGRect(x: 50, y: 50, width: 1200, height: 800),
                            index: 0
                        ),
                    ],
                ]
            )
        }
        await MainActor.run {
            context.windowService.inventoryCompleteness = .partial
            context.windowService.inventoryWarnings = ["Accessibility omitted one unmatched window row"]
        }

        let result = try await self.runWindowCommand([
            "window", "list", "--app", appName, "--json",
        ], context: context)
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        let response = try JSONDecoder().decode(
            CodableJSONResponse<WindowListData>.self,
            from: Data(output.utf8)
        )

        #expect(response.data.windows.count == 1)
        #expect(response.data.inventory_completeness == "partial")
        #expect(response.data.inventory_warnings == ["Accessibility omitted one unmatched window row"])
    }

    @Test
    func `window close help`() async throws {
        let output = try await runPeekabooCommand(["window", "close", "--help"])

        #expect(output.contains("Close a window"))
        #expect(output.contains("--app"))
        #expect(output.contains("--window-title"))
        #expect(output.contains("--window-index"))
        #expect(output.contains("--foreground"))
    }

    @Test
    func `window close only enables global fallback explicitly`() async throws {
        let appName = "Finder"
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 1234,
            processStartIdentity: 7,
            bundleIdentifier: "com.apple.finder",
            name: appName
        )
        let window = ServiceWindowInfo(
            windowID: 1,
            title: "Finder Window",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMainWindow: true,
            index: 0
        )
        let context = await MainActor.run {
            self.makeWindowContext(appInfo: appInfo, windows: [appName: [window]])
        }

        _ = try await self.runWindowCommand(
            ["window", "close", "--app", appName, "--json"],
            context: context
        )
        _ = try await self.runWindowCommand(
            ["window", "close", "--app", appName, "--foreground", "--json"],
            context: context
        )

        #expect(context.windowService.closeFallbackRequests == [false, true])
    }

    @Test
    func `window list command`() async throws {
        // Test that window list delegates to list windows command (via stubbed services)
        let appName = "Finder"
        let context = await MainActor.run {
            self.makeWindowContext(
                appInfo: ServiceApplicationInfo(
                    processIdentifier: 1234,
                    bundleIdentifier: "com.apple.finder",
                    name: appName
                ),
                windows: [
                    appName: [
                        ServiceWindowInfo(
                            windowID: 1,
                            title: "Finder Window",
                            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                            isMainWindow: true,
                            isKeyWindow: true,
                            isFrontmost: true,
                            subrole: "AXStandardWindow",
                            windowLevel: 0,
                            index: 0
                        ),
                    ],
                ]
            )
        }

        let result = try await self.runWindowCommand([
            "window", "list",
            "--app", appName,
            "--json",
        ], context: context)

        #expect(result.exitStatus == 0)
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        let response = try JSONDecoder().decode(
            CodableJSONResponse<WindowListData>.self,
            from: Data(output.utf8)
        )
        #expect(response.success == true)
        let window = try #require(response.data.windows.first)
        #expect(window.is_frontmost == true)
        #expect(window.is_key == true)
        #expect(window.layer == 0)
        #expect(window.subrole == "AXStandardWindow")
    }

    @Test
    func `window command without app`() async throws {
        // Test that window commands require --app
        let commands = ["close", "minimize", "maximize", "focus"]

        for command in commands {
            await #expect(throws: (any Error).self) {
                _ = try await self.runPeekabooCommand(["window", command])
            }
        }
    }

    @Test
    func `window move requires coordinates`() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await self.runPeekabooCommand(["window", "move", "--app", "Finder"])
        }
    }

    @Test
    func `window resize requires dimensions`() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await self.runPeekabooCommand(["window", "resize", "--app", "Finder"])
        }
    }

    @Test
    func `window set bounds requires all parameters`() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await self.runPeekabooCommand([
                "window",
                "set-bounds",
                "--app",
                "Finder",
                "--x",
                "100",
                "--y",
                "100",
            ])
        }
    }

    @Test
    func `set-bounds reports refreshed bounds`() async throws {
        let appName = "TextEdit"
        let bundleID = "com.apple.TextEdit"
        let initialBounds = CGRect(x: 10, y: 20, width: 320, height: 240)
        let updatedBounds = CGRect(x: 400, y: 500, width: 640, height: 480)

        let context = await MainActor.run {
            self.makeWindowContext(
                appInfo: ServiceApplicationInfo(
                    processIdentifier: 42,
                    processStartIdentity: 7,
                    bundleIdentifier: bundleID,
                    name: appName
                ),
                windows: [
                    appName: [
                        ServiceWindowInfo(
                            windowID: 101,
                            title: "Untitled",
                            bounds: initialBounds,
                            isMinimized: false,
                            isMainWindow: true,
                            windowLevel: 0,
                            alpha: 1.0,
                            index: 0
                        ),
                    ],
                ]
            )
        }

        let args = [
            "window", "set-bounds",
            "--app", appName,
            "--x", String(Int(updatedBounds.origin.x)),
            "--y", String(Int(updatedBounds.origin.y)),
            "--width", String(Int(updatedBounds.size.width)),
            "--height", String(Int(updatedBounds.size.height)),
            "--json",
        ]

        let result = try await self.runWindowCommand(args, context: context)
        #expect(result.exitStatus == 0)
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        let response = try JSONDecoder().decode(
            CodableJSONResponse<WindowActionResult>.self,
            from: Data(output.utf8)
        )

        #expect(response.success == true)
        let bounds = try #require(response.data.new_bounds)
        #expect(bounds.x == Int(updatedBounds.origin.x))
        #expect(bounds.y == Int(updatedBounds.origin.y))
        #expect(bounds.width == Int(updatedBounds.size.width))
        #expect(bounds.height == Int(updatedBounds.size.height))

        let storedBounds = await MainActor.run {
            context.windowService.windowsByApp[appName]?.first?.bounds
        }
        let refreshed = try #require(storedBounds)
        #expect(Int(refreshed.origin.x) == Int(updatedBounds.origin.x))
        #expect(Int(refreshed.origin.y) == Int(updatedBounds.origin.y))
        #expect(Int(refreshed.size.width) == Int(updatedBounds.size.width))
        #expect(Int(refreshed.size.height) == Int(updatedBounds.size.height))
        #expect(await MainActor.run { context.windowService.setBoundsCalls.map(\.description) } == [
            "windowId(101)",
        ])
    }

    @Test
    func `resize reports refreshed bounds`() async throws {
        let appName = "TextEdit"
        let bundleID = "com.apple.TextEdit"
        let initialBounds = CGRect(x: 50, y: 60, width: 200, height: 150)
        let updatedSize = CGSize(width: 880, height: 540)

        let context = await MainActor.run {
            self.makeWindowContext(
                appInfo: ServiceApplicationInfo(
                    processIdentifier: 99,
                    processStartIdentity: 7,
                    bundleIdentifier: bundleID,
                    name: appName
                ),
                windows: [
                    appName: [
                        ServiceWindowInfo(
                            windowID: 202,
                            title: "Draft",
                            bounds: initialBounds,
                            isMinimized: false,
                            isMainWindow: true,
                            windowLevel: 0,
                            alpha: 1.0,
                            index: 0
                        ),
                    ],
                ]
            )
        }

        let args = [
            "window", "resize",
            "--app", appName,
            "--width", String(Int(updatedSize.width)),
            "--height", String(Int(updatedSize.height)),
            "--json",
        ]

        let result = try await self.runWindowCommand(args, context: context)
        #expect(result.exitStatus == 0)
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        let response = try JSONDecoder().decode(
            CodableJSONResponse<WindowActionResult>.self,
            from: Data(output.utf8)
        )

        #expect(response.success == true)
        let bounds = try #require(response.data.new_bounds)
        #expect(bounds.x == Int(initialBounds.origin.x))
        #expect(bounds.y == Int(initialBounds.origin.y))
        #expect(bounds.width == Int(updatedSize.width))
        #expect(bounds.height == Int(updatedSize.height))
        #expect(await MainActor.run { context.windowService.resizeCalls.map(\.description) } == [
            "windowId(202)",
        ])
    }

    @Test
    func `window move accepts window id without app`() async throws {
        let appName = "TextEdit"
        let windowID = 303
        let initialBounds = CGRect(x: 50, y: 60, width: 200, height: 150)
        let updatedOrigin = CGPoint(x: 300, y: 320)

        let context = await MainActor.run {
            self.makeWindowContext(
                appInfo: ServiceApplicationInfo(
                    processIdentifier: 99,
                    processStartIdentity: 7,
                    bundleIdentifier: "com.apple.TextEdit",
                    name: appName
                ),
                windows: [
                    appName: [
                        ServiceWindowInfo(
                            windowID: windowID,
                            title: "Draft",
                            bounds: initialBounds,
                            isMinimized: false,
                            isMainWindow: true,
                            windowLevel: 0,
                            alpha: 1.0,
                            index: 0
                        ),
                    ],
                ]
            )
        }

        let result = try await self.runWindowCommand([
            "window", "move",
            "--window-id", "\(windowID)",
            "--x", String(Int(updatedOrigin.x)),
            "--y", String(Int(updatedOrigin.y)),
            "--json",
        ], context: context)

        #expect(result.exitStatus == 0)
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        let response = try JSONDecoder().decode(
            CodableJSONResponse<WindowActionResult>.self,
            from: Data(output.utf8)
        )

        #expect(response.success == true)
        let bounds = try #require(response.data.new_bounds)
        #expect(bounds.x == Int(updatedOrigin.x))
        #expect(bounds.y == Int(updatedOrigin.y))
        #expect(bounds.width == Int(initialBounds.width))
        #expect(bounds.height == Int(initialBounds.height))
        #expect(await MainActor.run { context.windowService.moveCalls.map(\.description) } == [
            "windowId(303)",
        ])
    }

    /// Helper function to run peekaboo commands
    private func runPeekabooCommand(
        _ arguments: [String],
        allowedExitStatuses: Set<Int32> = [0, 64]
    ) async throws -> String {
        do {
            let result = try await InProcessCommandRunner.runShared(
                arguments,
                allowedExitCodes: allowedExitStatuses
            )
            return result.combinedOutput
        } catch let error as CommandExecutionError {
            let output = error.stdout.isEmpty ? error.stderr : error.stdout
            throw TestError.commandFailed(status: error.status, output: output)
        }
    }

    enum TestError: Error, LocalizedError {
        case commandFailed(status: Int32, output: String)
        case binaryMissing

        var errorDescription: String? {
            switch self {
            case let .commandFailed(status, output):
                "Command failed with exit status: \(status). Output: \(output)"
            case .binaryMissing:
                "Peekaboo binary missing"
            }
        }
    }

    private func runWindowCommand(
        _ arguments: [String],
        context: WindowHarnessContext,
        allowedExitStatuses: Set<Int32> = [0]
    ) async throws -> CommandRunResult {
        let result = try await InProcessCommandRunner.run(arguments, services: context.services)
        try result.validateExitStatus(allowedExitCodes: allowedExitStatuses, arguments: arguments)
        return result
    }

    @MainActor
    private func makeWindowContext(
        appInfo: ServiceApplicationInfo,
        windows: [String: [ServiceWindowInfo]]
    ) -> WindowHarnessContext {
        let pinnedWindows = windows.mapValues { windows in
            windows.map {
                $0.withMutationIdentityForTesting(
                    ownerProcessIdentifier: appInfo.processIdentifier,
                    ownerProcessStartIdentity: appInfo.processStartIdentity ?? 7
                )
            }
        }
        let applicationService = StubApplicationService(applications: [appInfo], windowsByApp: pinnedWindows)
        let windowService = OutcomeStubWindowService(windowsByApp: pinnedWindows)
        let services = TestServicesFactory.makePeekabooServices(
            applications: applicationService,
            windows: windowService
        )
        return WindowHarnessContext(
            services: services,
            windowService: windowService,
            applicationService: applicationService
        )
    }

    @MainActor
    private func makeStrictSelectionContext(titles: [String]) -> WindowHarnessContext {
        let appName = "Fixture"
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 7,
            bundleIdentifier: "dev.fixture",
            name: appName
        )
        let windows = titles.enumerated().map { offset, title in
            let position = CGFloat(offset * 20)
            return ServiceWindowInfo(
                windowID: 101 + offset,
                title: title,
                bounds: CGRect(x: position, y: position, width: 640, height: 480),
                isMainWindow: offset == 0,
                index: offset
            )
        }
        return self.makeWindowContext(appInfo: appInfo, windows: [appName: windows])
    }

    private struct WindowHarnessContext {
        let services: PeekabooServices
        let windowService: OutcomeStubWindowService
        let applicationService: StubApplicationService
    }
}

// MARK: - Local Integration Tests

@Suite(
    .serialized,
    .tags(.automation),
    .enabled(if: CLITestEnvironment.runAutomationActions && WindowCommandLocalIntegrationTestConfig.enabled())
)
struct WindowCommandLocalIntegrationTests {
    @Test
    func `window minimize text edit`() async throws {
        // This test requires TextEdit to be running and local permissions

        // First, ensure TextEdit is running and has a window
        let launchResult = try await runPeekabooCommand(["image", "--app", "TextEdit", "--json"])
        let launchData = try JSONDecoder().decode(JSONResponse.self, from: Data(launchResult.utf8))

        guard launchData.success else {
            Issue.record("TextEdit must be running for this test")
            return
        }

        // Try to minimize TextEdit window
        let result = try await runPeekabooCommand(["window", "minimize", "--app", "TextEdit", "--json"])
        let data = try JSONDecoder().decode(JSONResponse.self, from: Data(result.utf8))

        if let error = data.error {
            if error.code == "PERMISSION_ERROR_ACCESSIBILITY" {
                Issue.record("Accessibility permission required for window manipulation")
                return
            }
        }

        #expect(data.success == true)

        // Wait a bit for the animation
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
    }

    @Test
    func `window move text edit`() async throws {
        // This test requires TextEdit to be running and local permissions

        // Try to move TextEdit window
        let result = try await runPeekabooCommand([
            "window", "move",
            "--app", "TextEdit",
            "--x", "200",
            "--y", "200",
            "--json",
        ])

        let jsonResponse = try JSONDecoder().decode(JSONResponse.self, from: Data(result.utf8))

        if let error = jsonResponse.error {
            if error.code == "PERMISSION_ERROR_ACCESSIBILITY" {
                Issue.record("Accessibility permission required for window manipulation")
                return
            }
        }

        #expect(jsonResponse.success == true)

        let typedResponse = try JSONDecoder().decode(
            CodableJSONResponse<WindowActionResult>.self,
            from: Data(result.utf8)
        )
        let newBounds = try #require(typedResponse.data.new_bounds)
        #expect(newBounds.x == 200)
        #expect(newBounds.y == 200)
    }

    @Test
    func `window focus text edit`() async throws {
        // This test requires TextEdit to be running

        // Try to focus TextEdit window
        let result = try await runPeekabooCommand([
            "window", "focus",
            "--app", "TextEdit",
            "--json",
        ])

        let data = try JSONDecoder().decode(JSONResponse.self, from: Data(result.utf8))

        if let error = data.error {
            if error.code == "PERMISSION_ERROR_ACCESSIBILITY" {
                Issue.record("Accessibility permission required for window manipulation")
                return
            }
        }

        #expect(data.success == true)
    }

    /// Helper function for local tests
    private func runPeekabooCommand(
        _ arguments: [String],
        allowedExitStatuses: Set<Int32> = [0, 1, 64]
    ) async throws -> String {
        do {
            let result = try await InProcessCommandRunner.runShared(
                arguments,
                allowedExitCodes: allowedExitStatuses
            )
            return result.combinedOutput
        } catch let error as CommandExecutionError {
            let output = error.stdout.isEmpty ? error.stderr : error.stdout
            throw TestError.commandFailed(status: error.status, output: output)
        }
    }

    enum TestError: Error, LocalizedError {
        case commandFailed(status: Int32, output: String)
        case binaryMissing

        var errorDescription: String? {
            switch self {
            case let .commandFailed(status, _):
                "Exit status: \(status)"
            case .binaryMissing:
                "Peekaboo binary missing"
            }
        }
    }
}
#endif
