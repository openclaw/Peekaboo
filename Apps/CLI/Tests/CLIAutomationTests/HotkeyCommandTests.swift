import Commander
import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe), .serialized) struct HotkeyCommandTests {
    @Test func `hotkey parsing`() throws {
        // Test comma-separated format
        let command1 = try HotkeyCommand.parse(["--keys", "cmd,c"])
        #expect(command1.resolvedKeys == "cmd,c")
        #expect(command1.holdDuration == 50) // Default

        // Test space-separated format
        let command2 = try HotkeyCommand.parse(["--keys", "cmd a"])
        #expect(command2.resolvedKeys == "cmd a")

        // Test plus-separated format
        let commandPlus = try HotkeyCommand.parse(["--keys", "cmd+s"])
        #expect(commandPlus.resolvedKeys == "cmd+s")

        // Test with custom hold duration
        let command3 = try HotkeyCommand.parse(["--keys", "cmd,v", "--hold-duration", "100"])
        #expect(command3.resolvedKeys == "cmd,v")
        #expect(command3.holdDuration == 100)

        // Test with snapshot ID
        let command4 = try HotkeyCommand.parse(["--keys", "cmd,z", "--snapshot", "test-snapshot"])
        #expect(command4.snapshot == "test-snapshot")

        // Test with app
        let command5 = try HotkeyCommand.parse(["--keys", "cmd,c", "--app", "TextEdit"])
        #expect(command5.target.app == "TextEdit")

        // Test background delivery through the hotkey-specific flag
        let command6 = try HotkeyCommand.parse(["--keys", "cmd,l", "--app", "Safari", "--focus-background"])
        #expect(command6.target.app == "Safari")
        #expect(command6.focusBackground)
        #expect(command6.focusOptions.focusBackground)
        #expect(command6.focusOptions.autoFocus == true)
    }

    @Test func `invalid input handling`() throws {
        // Test missing keys
        #expect(throws: (any Error).self) {
            try CLIOutputCapture.suppressStderr {
                _ = try HotkeyCommand.parse([])
            }
        }

        // Test empty keys
        #expect(throws: ValidationError.self) {
            try CLIOutputCapture.suppressStderr {
                _ = try HotkeyCommand.parse(["--keys", ""])
            }
        }
    }

    @Test func `key format normalization`() throws {
        // Test that both formats work
        let command1 = try HotkeyCommand.parse(["--keys", "cmd,shift,t"])
        #expect(command1.resolvedKeys == "cmd,shift,t")

        let command2 = try HotkeyCommand.parse(["--keys", "cmd shift t"])
        #expect(command2.resolvedKeys == "cmd shift t")

        // Test mixed case handling
        let command3 = try HotkeyCommand.parse(["--keys", "CMD,C"])
        #expect(command3.resolvedKeys == "CMD,C") // Original case preserved

        let command4 = try HotkeyCommand.parse(["--keys", "cmd+shift+t"])
        #expect(command4.resolvedKeys == "cmd+shift+t")
    }

    @Test func `complex hotkeys`() throws {
        // Test function keys
        let command1 = try HotkeyCommand.parse(["--keys", "f1"])
        #expect(command1.resolvedKeys == "f1")

        // Test multiple modifiers
        let command2 = try HotkeyCommand.parse(["--keys", "cmd,alt,shift,n"])
        #expect(command2.resolvedKeys == "cmd,alt,shift,n")

        // Test special keys
        let command3 = try HotkeyCommand.parse(["--keys", "cmd,space"])
        #expect(command3.resolvedKeys == "cmd,space")
    }

    @Test func `positional hotkey parsing`() throws {
        let positionalComma = try HotkeyCommand.parse(["cmd,shift,t"])
        #expect(positionalComma.resolvedKeys == "cmd,shift,t")

        let positionalSpace = try HotkeyCommand.parse(["cmd shift t"])
        #expect(positionalSpace.resolvedKeys == "cmd shift t")

        let positionalPlus = try HotkeyCommand.parse(["cmd+shift+t"])
        #expect(positionalPlus.resolvedKeys == "cmd+shift+t")
    }

    @Test func `positional overrides option`() throws {
        let command = try HotkeyCommand.parse(["cmd,space", "--keys", "cmd,c"])
        #expect(command.resolvedKeys == "cmd,space")
    }

    @Test func `background hotkey forwards to targeted automation and reports sent`() async throws {
        let context = await self.makeContext()

        let result = try await self.runHotkey(
            arguments: ["cmd,l", "--app", "Safari"],
            context: context
        )

        #expect(result.exitStatus == 0)
        #expect(self.output(from: result).contains("Hotkey sent"))

        let calls = await self.automationState(context) { $0.targetedHotkeyCalls }
        let call = try #require(calls.first)
        #expect(call.keys == "cmd,l")
        #expect(call.holdDuration == 50)
        #expect(call.targetProcessIdentifier == 4321)
    }

    @Test func `background hotkey JSON reports delivery mode and pid`() async throws {
        let context = await self.makeContext()

        let result = try await self.runHotkey(
            arguments: ["cmd,l", "--app", "Safari", "--json"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<HotkeyResult>.self
        )
        #expect(payload.success)
        #expect(payload.data.deliveryMode == "background")
        #expect(payload.data.targetPID == 4321)
    }

    @Test func `foreground flag opts hotkey out of targeted delivery`() async throws {
        let context = await self.makeContext()

        let result = try await self.runHotkey(
            arguments: ["cmd,l", "--app", "Safari", "--foreground", "--json"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let targetedCalls = await self.automationState(context) { $0.targetedHotkeyCalls }
        #expect(targetedCalls.isEmpty)
        let foregroundCalls = await self.automationState(context) { $0.hotkeyCalls }
        #expect(foregroundCalls.map(\.keys) == ["cmd,l"])
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<HotkeyResult>.self
        )
        #expect(payload.data.deliveryMode == "foreground")
        #expect(payload.data.targetPID == nil)
    }

    @Test func `background lifecycle hotkeys fail closed with semantic guidance`() async throws {
        let context = await self.makeContext()
        let cases = [
            (keys: "command+w", chord: "Cmd+W", alternative: "peekaboo window close"),
            (keys: "cmd,q", chord: "Cmd+Q", alternative: "peekaboo app quit"),
            (keys: "cmd h", chord: "Cmd+H", alternative: "peekaboo app hide"),
            (keys: "CMD,M", chord: "Cmd+M", alternative: "peekaboo window minimize"),
        ]

        for testCase in cases {
            let result = try await self.runHotkey(
                arguments: [testCase.keys, "--app", "Safari"],
                context: context
            )

            #expect(result.exitStatus != 0)
            let output = self.output(from: result)
            #expect(output.contains(testCase.chord))
            #expect(output.contains(testCase.alternative))
            #expect(output.contains("--foreground"))
        }

        let targetedCalls = await self.automationState(context) { $0.targetedHotkeyCalls }
        #expect(targetedCalls.isEmpty)
    }

    @Test func `explicit foreground allows lifecycle hotkeys`() async throws {
        let context = await self.makeContext()

        let result = try await self.runHotkey(
            arguments: ["cmd,w", "--app", "Safari", "--foreground"],
            context: context
        )

        #expect(result.exitStatus == 0)
        #expect(await self.automationState(context) { $0.targetedHotkeyCalls }.isEmpty)
        #expect(await self.automationState(context) { $0.hotkeyCalls.map(\.keys) } == ["cmd,w"])
    }

    @Test func `background hotkey can target pid`() async throws {
        let context = await self.makeContext()

        let result = try await self.runHotkey(
            arguments: ["cmd,l", "--pid", "4321", "--focus-background"],
            context: context
        )

        #expect(result.exitStatus == 0)
        #expect(self.output(from: result).contains("Hotkey sent"))

        let calls = await self.automationState(context) { $0.targetedHotkeyCalls }
        let call = try #require(calls.first)
        #expect(call.keys == "cmd,l")
        #expect(call.targetProcessIdentifier == 4321)
    }

    @Test func `plus separated hotkey is normalized before automation`() async throws {
        let context = await self.makeContext()

        let result = try await self.runHotkey(
            arguments: ["cmd+s", "--pid", "4321", "--focus-background"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let calls = await self.automationState(context) { $0.targetedHotkeyCalls }
        let call = try #require(calls.first)
        #expect(call.keys == "cmd,s")
    }

    @Test func `background hotkey pid does not require app lookup`() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        let context = await MainActor.run {
            TestServicesFactory.makeAutomationTestContext(
                applications: StubApplicationService(applications: [])
            )
        }

        let result = try await self.runHotkey(
            arguments: ["cmd,l", "--pid", "\(process.processIdentifier)", "--focus-background"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let calls = await self.automationState(context) { $0.targetedHotkeyCalls }
        let call = try #require(calls.first)
        #expect(call.targetProcessIdentifier == process.processIdentifier)
    }

    @Test func `background hotkey JSON maps missing event synthesizing permission`() async throws {
        let context = await self.makeContext()
        await MainActor.run {
            context.automation.supportsTargetedHotkeys = false
            context.automation.targetedHotkeyRequiresEventSynthesizingPermission = true
            context.automation.targetedHotkeyUnavailableReason =
                "Remote bridge host supports background hotkeys, but current permissions are missing: " +
                "Event Synthesizing"
        }

        let result = try await self.runHotkey(
            arguments: ["cmd,l", "--app", "Safari", "--focus-background", "--json"],
            context: context
        )

        #expect(result.exitStatus != 0)
        let payload = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(payload.success == false)
        #expect(payload.error?.code == ErrorCode.PERMISSION_ERROR_EVENT_SYNTHESIZING.rawValue)
    }

    @Test func `background hotkey validates explicit snapshot before delivery`() async throws {
        let context = await self.makeContext()

        let result = try await self.runHotkey(
            arguments: ["cmd,l", "--app", "Safari", "--focus-background", "--snapshot", "missing"],
            context: context
        )

        #expect(result.exitStatus != 0)
        #expect(self.output(from: result).contains("Snapshot not found") ||
            self.output(from: result).contains("No detection data found"))

        let calls = await self.automationState(context) { $0.targetedHotkeyCalls }
        #expect(calls.isEmpty)
    }

    @Test func `background hotkey rejects foreground focus options`() async throws {
        let context = await self.makeContext()

        let result = try await self.runHotkey(
            arguments: ["cmd,l", "--app", "Safari", "--focus-background", "--no-auto-focus"],
            context: context
        )

        #expect(result.exitStatus != 0)
        #expect(self.output(from: result).contains("--focus-background cannot be combined with focus options"))

        let calls = await self.automationState(context) { $0.targetedHotkeyCalls }
        #expect(calls.isEmpty)
    }

    @Test func `background hotkey rejects app and pid together`() async throws {
        let context = await self.makeContext()

        let result = try await self.runHotkey(
            arguments: ["cmd,l", "--app", "Safari", "--pid", "1234", "--focus-background"],
            context: context
        )

        #expect(result.exitStatus != 0)
        #expect(self.output(from: result).contains("Background hotkey accepts one process target"))

        let calls = await self.automationState(context) { $0.targetedHotkeyCalls }
        #expect(calls.isEmpty)
    }

    private func runHotkey(
        arguments: [String],
        context: TestServicesFactory.AutomationTestContext
    ) async throws -> CommandRunResult {
        try await InProcessCommandRunner.run(["hotkey"] + arguments, services: context.services)
    }

    private func makeContext() async -> TestServicesFactory.AutomationTestContext {
        await MainActor.run {
            let app = ServiceApplicationInfo(
                processIdentifier: 4321,
                bundleIdentifier: "com.apple.Safari",
                name: "Safari"
            )
            return TestServicesFactory.makeAutomationTestContext(
                applications: StubApplicationService(applications: [app])
            )
        }
    }

    private func automationState<T: Sendable>(
        _ context: TestServicesFactory.AutomationTestContext,
        _ read: @MainActor (StubAutomationService) -> T
    ) async -> T {
        await MainActor.run { read(context.automation) }
    }

    private func output(from result: CommandRunResult) -> String {
        result.stdout.isEmpty ? result.stderr : result.stdout
    }
}
