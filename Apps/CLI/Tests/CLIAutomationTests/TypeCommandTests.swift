import Commander
import Foundation
import PeekabooAutomation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe), .serialized)
struct TypeCommandTests {
    @Test
    func `Type command with text argument`() throws {
        let command = try TypeCommand.parse(["Hello World", "--json"])

        #expect(command.text == "Hello World")
        #expect(command.jsonOutput == true)
        #expect(command.delay.roundedMilliseconds == 0) // default delay
        #expect(command.clear == false)
    }

    @Test
    func `Type command with --text option`() throws {
        let command = try TypeCommand.parse(["--text", "Option Text", "--json"])

        #expect(command.text == nil)
        #expect(command.textOption == "Option Text")
    }

    @Test
    func `Type command rejects positional and option text together`() throws {
        var command = try TypeCommand.parse(["Positional", "--text", "Option", "--foreground"])

        #expect(throws: ValidationError.self) {
            try command.validate()
        }
    }

    @Test
    func `Type command with clear flag`() throws {
        let command = try TypeCommand.parse(["New Text", "--clear", "--json"])

        #expect(command.text == "New Text")
        #expect(command.clear == true)
        #expect(command.delay.roundedMilliseconds == 0) // default delay
    }

    @Test
    func `Type command with custom delay`() throws {
        let command = try TypeCommand.parse(["Fast", "--delay", "0", "--json"])

        #expect(command.text == "Fast")
        #expect(command.delay.roundedMilliseconds == 0)
    }

    @Test
    func `Type command with human typing speed`() throws {
        var command = try TypeCommand.parse(["Message", "--wpm", "140", "--json"])
        #expect(command.wordsPerMinute == 140)
        #expect(command.delay.roundedMilliseconds == 0)
        // Validation should allow the selected range
        try command.validate()
    }

    @Test
    func `Type command with linear profile`() throws {
        var command = try TypeCommand.parse(["Hello", "--profile", "linear", "--delay", "15"])
        #expect(command.profileOption?.lowercased() == "linear")
        #expect(command.delay.roundedMilliseconds == 15)
        #expect(command.wordsPerMinute == nil)
        try command.validate()
    }

    @Test
    func `Type command rejects invalid WPM`() throws {
        var command = try TypeCommand.parse(["Hello", "--wpm", "20"])
        do {
            try command.validate()
            Issue.record("Expected validation failure for WPM outside allowed range")
        } catch {
            let description = String(describing: error)
            #expect(description.contains("--wpm must be between 80 and 220"))
        }
    }

    @Test
    func `Type command rejects WPM with linear profile`() throws {
        var command = try TypeCommand.parse(["Hello", "--profile", "linear", "--wpm", "140"])
        do {
            try command.validate()
            Issue.record("Expected validation failure for linear profile with WPM")
        } catch {
            let description = String(describing: error)
            #expect(description.contains("--wpm is only valid when --profile human"))
        }
    }

    @Test
    func `Type execution defaults to linear cadence`() async throws {
        let automation = await confirmedTypeAutomation(mode: .foreground)
        let context = await self.makeContext(automation: automation)
        let result = try await self.runType(arguments: ["Hello", "--foreground"], context: context)

        #expect(result.exitStatus == 0)
        let call = try #require(await self.automationState(context) { $0.typeActionsCalls.first })
        if case let .fixed(milliseconds) = call.cadence {
            #expect(milliseconds == 0)
        } else {
            Issue.record("Expected linear cadence")
        }
    }

    @Test
    func `Type execution with WPM opts into human cadence`() async throws {
        let automation = await confirmedTypeAutomation(mode: .foreground)
        let context = await self.makeContext(automation: automation)
        let result = try await self.runType(arguments: ["Hello", "--wpm", "140", "--foreground"], context: context)

        #expect(result.exitStatus == 0)
        let call = try #require(await self.automationState(context) { $0.typeActionsCalls.first })
        if case let .human(wordsPerMinute) = call.cadence {
            #expect(wordsPerMinute == 140)
        } else {
            Issue.record("Expected human cadence")
        }
    }

    @Test
    func `Type execution honors linear profile and delay`() async throws {
        let automation = await confirmedTypeAutomation(mode: .foreground)
        let context = await self.makeContext(automation: automation)
        let result = try await self.runType(
            arguments: ["Hello", "--profile", "linear", "--delay", "15", "--foreground"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let call = try #require(await self.automationState(context) { $0.typeActionsCalls.first })
        if case let .fixed(milliseconds) = call.cadence {
            #expect(milliseconds == 15)
        } else {
            Issue.record("Expected linear cadence")
        }
    }

    @Test
    func `Type execution does not implicitly reuse latest snapshot as a keyboard target`() async throws {
        let context = await self.makeContext()
        _ = try await context.snapshots.createSnapshot()

        let result = try await self.runType(arguments: ["Hello", "--no-auto-focus"], context: context)

        #expect(result.exitStatus != 0)
        #expect(await self.automationState(context) { $0.typeActionsCalls }.isEmpty)
    }

    @Test
    func `Type JSON output separates requested text from nonliteral executed actions`() async throws {
        let automation = await confirmedTypeAutomation(mode: .foreground)
        let context = await self.makeContext(automation: automation)
        let result = try await self.runType(
            arguments: ["Line 1\\nLine 2", "--foreground", "--json"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<TypeCommandResult>.self
        )

        #expect(payload.data.requestedText == "Line 1\\nLine 2")
        #expect(payload.data.typedText == nil)
        #expect(payload.data.literalCharactersTyped == 12)
        #expect(payload.data.specialKeyPresses == 1)
        #expect(payload.data.actions.map(\.kind) == ["text", "key", "text"])
        #expect(payload.data.actions[1].value == "return")
    }

    @Test
    func `Type execution does not reuse latest snapshot with explicit app target`() async throws {
        let applicationService = await MainActor.run {
            StubApplicationService(applications: [
                ServiceApplicationInfo(
                    processIdentifier: 2468,
                    processStartIdentity: 71,
                    bundleIdentifier: "com.apple.TextEdit",
                    name: "TextEdit"
                ),
            ])
        }
        let automation = await confirmedTypeAutomation(mode: .background)
        let context = await self.makeContext(
            automation: automation,
            applications: applicationService
        )
        _ = try await context.snapshots.createSnapshot()

        let result = try await self.runType(
            arguments: ["Hello", "--app", "TextEdit", "--no-auto-focus"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let call = try #require(await self.automationState(context) { $0.typeActionsCalls.first })
        #expect(call.snapshotId == nil)
    }

    @Test
    func `Type with app target defaults to background process delivery`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 71,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let applicationService = await MainActor.run {
            StubApplicationService(applications: [app])
        }
        let automation = await confirmedTypeAutomation(mode: .background)
        let context = await self.makeContext(
            automation: automation,
            applications: applicationService
        )

        let result = try await self.runType(
            arguments: ["Hello", "--app", "TextEdit", "--json"],
            context: context
        )
        #expect(result.exitStatus == 0)
        let targetedCall = try #require(await self.automationState(context) { $0.targetedTypeActionsCalls.first })
        #expect(targetedCall.targetProcessIdentifier == 2468)
        #expect(targetedCall.expectedProcessIdentity == ApplicationProcessIdentity(
            processIdentifier: 2468,
            processStartIdentity: 71
        ))
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<TypeCommandResult>.self
        )
        #expect(payload.data.deliveryMode == "background")
        #expect(payload.data.targetPID == 2468)
        let activateCalls = await MainActor.run { applicationService.activateCalls }
        #expect(activateCalls.isEmpty)
    }

    @Test
    @MainActor
    func `Type upgrades one eligible app window to exact receipt-pinned delivery`() async throws {
        let pid: Int32 = 2468
        let bounds = CGRect(x: 20, y: 30, width: 500, height: 400)
        let applicationService = StubApplicationService(applications: [ServiceApplicationInfo(
            processIdentifier: pid,
            processStartIdentity: 71,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )])
        let windows = StubWindowService(windowsByApp: ["TextEdit": [ServiceWindowInfo(
            windowID: 901,
            title: "Untitled",
            bounds: bounds,
            mutationIdentity: WindowMutationIdentity(
                windowID: 901,
                ownerProcessIdentifier: pid,
                ownerProcessStartIdentity: 71,
                capturedBounds: bounds
            )
        )]])
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(delivery: .init(
            mechanism: .windowTargetedEvents,
            mode: .background
        ))
        automation.targetedFocusedElement = UIFocusInfo(
            role: "AXTextArea",
            title: nil,
            value: nil,
            frame: CGRect(x: 40, y: 60, width: 200, height: 100),
            applicationName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit",
            processId: Int(pid),
            windowID: 901,
            identifier: "editor"
        )
        let context = await self.makeContext(
            automation: automation,
            applications: applicationService,
            windows: windows
        )

        let result = try await self.runType(
            arguments: ["Hello", "--app", "TextEdit", "--json"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let call = try #require(automation.exactTypeActionsCalls.first)
        #expect(call.target.windowIdentity.windowID == 901)
        #expect(call.target.focusedElement.identifier == "editor")
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<TypeCommandResult>.self
        )
        #expect(payload.data.targetWindowID == 901)
    }

    @Test
    @MainActor
    func `Type refuses ambiguous app windows before any keyboard dispatch`() async throws {
        let pid: Int32 = 2468
        let applicationService = StubApplicationService(applications: [ServiceApplicationInfo(
            processIdentifier: pid,
            processStartIdentity: 71,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )])
        let windows = StubWindowService(windowsByApp: ["TextEdit": [
            self.window(windowID: 901, pid: pid, generation: 71),
            self.window(windowID: 902, pid: pid, generation: 71),
        ]])
        let automation = OutcomeStubAutomationService()
        let context = await self.makeContext(
            automation: automation,
            applications: applicationService,
            windows: windows
        )

        let result = try await self.runType(
            arguments: ["Hello", "--app", "TextEdit", "--json"],
            context: context
        )

        #expect(result.exitStatus != 0)
        #expect(automation.exactTypeActionsCalls.isEmpty)
        #expect(automation.targetedTypeActionsCalls.isEmpty)
        #expect(result.combinedOutput.contains("multiple eligible windows"))
    }

    @Test
    @MainActor
    func `Foreground type refuses zero or ambiguous partial title matches before focus and input`() async throws {
        let pid: Int32 = 2468
        for title in ["Missing", "Document"] {
            let applicationService = StubApplicationService(applications: [ServiceApplicationInfo(
                processIdentifier: pid,
                processStartIdentity: 71,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"
            )])
            let windows = StubWindowService(windowsByApp: ["TextEdit": [
                self.window(windowID: 901, pid: pid, generation: 71),
                self.window(windowID: 902, pid: pid, generation: 71),
            ]])
            let automation = OutcomeStubAutomationService()
            let context = await self.makeContext(
                automation: automation,
                applications: applicationService,
                windows: windows
            )

            let result = try await self.runType(
                arguments: [
                    "Hello", "--app", "TextEdit", "--window-title", title, "--foreground", "--json",
                ],
                context: context
            )

            #expect(result.exitStatus != 0)
            #expect(result.combinedOutput.contains("must resolve exactly one window"))
            #expect(windows.focusCalls.isEmpty)
            #expect(applicationService.activateCalls.isEmpty)
            #expect(automation.typeActionsCalls.isEmpty)
            #expect(automation.targetedTypeActionsCalls.isEmpty)
            #expect(automation.exactTypeActionsCalls.isEmpty)
        }
    }

    @Test
    func `Type refuses an unpinned background process before delivery`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let applicationService = await MainActor.run {
            StubApplicationService(applications: [app])
        }
        let context = await self.makeContext(applications: applicationService)

        let result = try await self.runType(
            arguments: ["Hello", "--app", "TextEdit", "--json"],
            context: context
        )

        #expect(result.exitStatus != 0)
        #expect(await self.automationState(context) { $0.targetedTypeActionsCalls.isEmpty })
        #expect(result.combinedOutput.contains("could not pin"))
    }

    @Test
    func `Type foreground target refuses when exact focus cannot be proven`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 71,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let applicationService = await MainActor.run {
            StubApplicationService(applications: [app])
        }
        let context = await self.makeContext(applications: applicationService)

        let result = try await self.runType(
            arguments: ["Hello", "--app", "TextEdit", "--foreground", "--json"],
            context: context
        )

        #expect(result.exitStatus == 1)
        let targetedCalls = await self.automationState(context) { $0.targetedTypeActionsCalls }
        #expect(targetedCalls.isEmpty)
        #expect(await self.automationState(context) { $0.typeActionsCalls.isEmpty })
        let payload = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(payload.success == false)
    }

    @Test
    func `Type background delivery refuses an unresolved exact window selector`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 71,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let applicationService = await MainActor.run {
            StubApplicationService(applications: [app])
        }
        let windowService = await MainActor.run {
            StubWindowService(windowsByApp: ["TextEdit": []])
        }
        let context = await self.makeContext(applications: applicationService, windows: windowService)

        let result = try await self.runType(
            arguments: ["Hello", "--app", "TextEdit", "--window-title", "Missing", "--json"],
            context: context
        )

        #expect(result.exitStatus == 1)
        let payload = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(payload.success == false)
        #expect(payload.error?.code == ErrorCode.VALIDATION_ERROR.rawValue)
        #expect(payload.error?.message.contains("no matching window") == true)
        let targetedCalls = await self.automationState(context) { $0.targetedTypeActionsCalls }
        #expect(targetedCalls.isEmpty)
    }

    @Test(arguments: [DesktopActionOutcome.Route.local, .bridge])
    @MainActor
    func `Targeted foreground focus rejects suspected noop on every route`(
        route: DesktopActionOutcome.Route
    ) throws {
        let target = try InputFocusFixtures.targetIdentity()
        let result = UIAutomationActionResult(
            payload: (),
            outcome: .suspectedNoop(
                route: route,
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                unitCount: .one
            ),
            targetIdentity: target
        )

        do {
            _ = try validatedConfirmedForegroundFocusResult(result, operation: "Typing setup focus")
            Issue.record("Expected suspected-noop focus to be rejected")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .suspectedNoop)
            #expect(failure.outcome.route == route)
            #expect(failure.targetReceipt?.windowID == InputFocusFixtures.windowID)
        }
    }

    @Test(arguments: [DesktopActionOutcome.Route.local, .bridge])
    @MainActor
    func `Targeted foreground focus rejects confirmed background dispatch on every route`(
        route: DesktopActionOutcome.Route
    ) throws {
        let target = try InputFocusFixtures.targetIdentity()
        let result = UIAutomationActionResult(
            payload: (),
            outcome: .confirmedChange(
                route: route,
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                unitCount: .one
            ),
            targetIdentity: target
        )

        do {
            _ = try validatedConfirmedForegroundFocusResult(result, operation: "Typing setup focus")
            Issue.record("Expected background-delivered focus to be rejected")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.route == route)
            #expect(failure.targetReceipt?.windowID == InputFocusFixtures.windowID)
        }
    }

    @Test(arguments: [DesktopActionOutcome.Route.local, .bridge])
    @MainActor
    func `Targeted foreground focus accepts confirmed no change for an exact target`(
        route: DesktopActionOutcome.Route
    ) throws {
        let target = try InputFocusFixtures.targetIdentity()
        let result = UIAutomationActionResult(
            payload: (),
            outcome: .confirmedNoChange(route: route),
            targetIdentity: target
        )

        let validated = try validatedConfirmedForegroundFocusResult(
            result,
            operation: "Typing setup focus"
        )

        #expect(validated.outcome?.state == .confirmedNoChange)
        #expect(validated.targetIdentity == target)
    }

    @Test
    @MainActor
    func `Generation-pinned focus bridge rejects substituted returned bounds`() async throws {
        let expectedIdentity = InputFocusFixtures.identity()
        let substitutedBounds = InputFocusFixtures.bounds.offsetBy(dx: 25, dy: 15)
        let substitutedIdentity = WindowMutationIdentity(
            windowID: expectedIdentity.windowID,
            ownerProcessIdentifier: expectedIdentity.ownerProcessIdentifier,
            ownerProcessStartIdentity: expectedIdentity.ownerProcessStartIdentity,
            capturedBounds: substitutedBounds
        )
        let windows = InputFocusWindowService(focusOutcome: InputFocusFixtures.focusOutcome)
        windows.returnedTargetIdentity = try DesktopTargetIdentity(exactWindow: .init(
            identity: substitutedIdentity,
            bounds: substitutedBounds
        ))

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await WindowServiceBridge.focusWindow(
                windows: windows,
                target: .windowId(expectedIdentity.windowID),
                expectedIdentity: expectedIdentity
            )
        }

        #expect(windows.pinnedFocusCalls.count == 1)
    }

    @Test
    @MainActor
    func `Remote targeted foreground type refuses suspected noop before global input`() async throws {
        let windows = InputFocusWindowService(
            focusOutcome: .suspectedNoop(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                unitCount: .one
            )
        )
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: .one
        )
        let services = InputExecutionHostServices(
            host: .remote,
            base: TestServicesFactory.makePeekabooServices(
                windows: windows,
                automation: automation
            )
        )

        let result = try await InProcessCommandRunner.run(
            [
                "type", "Hello",
                "--window-id", String(InputFocusFixtures.windowID),
                "--foreground",
                "--json",
            ],
            services: services
        )
        let payload = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)

        #expect(result.exitStatus == 1)
        #expect(windows.pinnedFocusCalls.count == 1)
        #expect(automation.typeActionsCalls.isEmpty)
        #expect(payload.outcome?.state == .suspectedNoop)
        #expect(payload.target_receipt?.windowID == InputFocusFixtures.windowID)
    }

    @Test
    @MainActor
    func `Remote targeted foreground type stops before input on mismatched focus receipt`() async throws {
        let windows = InputFocusWindowService(focusOutcome: InputFocusFixtures.focusOutcome)
        windows.returnedTargetIdentity = try InputFocusFixtures.targetIdentity(
            windowID: InputFocusFixtures.windowID + 1
        )
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = InputFocusFixtures.typeOutcome
        let services = InputExecutionHostServices(
            host: .remote,
            base: TestServicesFactory.makePeekabooServices(
                windows: windows,
                automation: automation
            )
        )

        let result = try await InProcessCommandRunner.run(
            [
                "type", "Hello",
                "--window-id", String(InputFocusFixtures.windowID),
                "--foreground",
                "--json",
            ],
            services: services
        )

        #expect(result.exitStatus == 1)
        #expect(windows.pinnedFocusCalls.count == 1)
        #expect(automation.typeActionsCalls.isEmpty)
    }

    @Test
    @MainActor
    func `Remote targeted foreground type composes exact focus and leaf receipts`() async throws {
        let windows = InputFocusWindowService(focusOutcome: InputFocusFixtures.focusOutcome)
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = InputFocusFixtures.typeOutcome
        automation.actionOutcomeTargetIdentity = try InputFocusFixtures.targetIdentity()
        let services = InputExecutionHostServices(
            host: .remote,
            base: TestServicesFactory.makePeekabooServices(
                windows: windows,
                automation: automation
            )
        )

        let result = try await InProcessCommandRunner.run(
            [
                "type", "Hello",
                "--window-id", String(InputFocusFixtures.windowID),
                "--foreground",
                "--json",
            ],
            services: services
        )
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<TypeCommandResult>.self
        )

        #expect(result.exitStatus == 0)
        #expect(payload.outcome?.state == .confirmedChange)
        #expect(payload.outcome?.route == .bridge)
        #expect(payload.outcome?.deliveryMechanism == .composite)
        #expect(payload.outcome?.deliveryMode == .foreground)
        #expect(payload.outcome?.dispatchedUnitCount == DesktopActionOutcome.DispatchUnitCount(2))
        #expect(payload.target_receipt?.windowID == InputFocusFixtures.windowID)
    }

    @Test
    @MainActor
    func `Remote targeted foreground type rejects a mismatched leaf target`() async throws {
        let windows = InputFocusWindowService(focusOutcome: InputFocusFixtures.focusOutcome)
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = InputFocusFixtures.typeOutcome
        automation.actionOutcomeTargetIdentity = try InputFocusFixtures.targetIdentity(windowID: 902)
        let services = InputExecutionHostServices(
            host: .remote,
            base: TestServicesFactory.makePeekabooServices(
                windows: windows,
                automation: automation
            )
        )

        let result = try await InProcessCommandRunner.run(
            [
                "type", "Hello",
                "--window-id", String(InputFocusFixtures.windowID),
                "--foreground",
                "--json",
            ],
            services: services
        )
        let payload = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)

        #expect(result.exitStatus == 1)
        #expect(automation.typeActionsCalls.count == 1)
        #expect(payload.outcome?.state == .indeterminate)
        #expect(payload.outcome?.dispatchedUnitCount == DesktopActionOutcome.DispatchUnitCount(2))
        #expect(payload.target_identity == nil)
        #expect(payload.target_receipt == nil)
    }

    @Test
    func `Type command argument parsing`() throws {
        let command = try TypeCommand.parse(["Hello World", "--delay", "10"])

        #expect(command.text == "Hello World")
        #expect(command.delay.roundedMilliseconds == 10)
    }

    @Test
    func `Type command rejects removed key flags`() {
        for flag in ["--return", "--tab", "--escape", "--delete"] {
            #expect(throws: (any Error).self) {
                _ = try TypeCommand.parse(["Test", flag])
            }
        }
    }

    @Test
    func `Process text with escape sequences`() {
        // Test newline escape
        let newlineActions = TypeCommand.processTextWithEscapes("Line 1\\nLine 2")
        #expect(newlineActions.count == 3)
        if case .text("Line 1") = newlineActions[0] { } else {
            Issue.record("Expected text 'Line 1'")
        }
        if case .key(.return) = newlineActions[1] { } else {
            Issue.record("Expected return key")
        }
        if case .text("Line 2") = newlineActions[2] { } else {
            Issue.record("Expected text 'Line 2'")
        }

        // Test tab escape
        let tabActions = TypeCommand.processTextWithEscapes("Name:\\tJohn")
        #expect(tabActions.count == 3)
        if case .text("Name:") = tabActions[0] { } else {
            Issue.record("Expected text 'Name:'")
        }
        if case .key(.tab) = tabActions[1] { } else {
            Issue.record("Expected tab key")
        }
        if case .text("John") = tabActions[2] { } else {
            Issue.record("Expected text 'John'")
        }

        // Test backspace escape
        let backspaceActions = TypeCommand.processTextWithEscapes("ABC\\b")
        #expect(backspaceActions.count == 2)
        if case .text("ABC") = backspaceActions[0] { } else {
            Issue.record("Expected text 'ABC'")
        }
        if case .key(.delete) = backspaceActions[1] { } else {
            Issue.record("Expected delete key")
        }

        // Test escape key
        let escapeActions = TypeCommand.processTextWithEscapes("Cancel\\e")
        #expect(escapeActions.count == 2)
        if case .text("Cancel") = escapeActions[0] { } else {
            Issue.record("Expected text 'Cancel'")
        }
        if case .key(.escape) = escapeActions[1] { } else {
            Issue.record("Expected escape key")
        }

        // Test literal backslash
        let backslashActions = TypeCommand.processTextWithEscapes("Path: C\\\\data")
        #expect(backslashActions.count == 1)
        if case let .text(value) = backslashActions[0] {
            #expect(value == "Path: C\\data", "Value was: \(value)")
        } else {
            Issue.record("Expected text with backslash")
        }
    }

    @Test
    func `Complex escape sequence combinations`() {
        // Test multiple escape sequences
        let complexActions = TypeCommand.processTextWithEscapes("Line 1\\nLine 2\\tTabbed\\bFixed\\eEsc\\\\Path")
        #expect(complexActions.count == 9)

        // Verify the sequence
        if case .text("Line 1") = complexActions[0] { } else {
            Issue.record("Expected 'Line 1'")
        }
        if case .key(.return) = complexActions[1] { } else {
            Issue.record("Expected return")
        }
        if case .text("Line 2") = complexActions[2] { } else {
            Issue.record("Expected 'Line 2'")
        }
        if case .key(.tab) = complexActions[3] { } else {
            Issue.record("Expected tab")
        }
        if case .text("Tabbed") = complexActions[4] { } else {
            Issue.record("Expected 'Tabbed'")
        }
        if case .key(.delete) = complexActions[5] { } else {
            Issue.record("Expected delete")
        }
        if case .text("Fixed") = complexActions[6] { } else {
            Issue.record("Expected 'Fixed'")
        }
        if case .key(.escape) = complexActions[7] { } else {
            Issue.record("Expected escape")
        }
        if case .text("Esc\\Path") = complexActions[8] { } else {
            Issue.record("Expected 'Esc\\Path'")
        }
    }

    @Test
    func `Empty and edge case escape sequences`() {
        // Empty text
        let emptyActions = TypeCommand.processTextWithEscapes("")
        #expect(emptyActions.isEmpty)

        // Only escape sequences
        let onlyEscapes = TypeCommand.processTextWithEscapes("\\n\\t\\b\\e")
        #expect(onlyEscapes.count == 4)

        // Text ending with incomplete escape
        let incompleteEscape = TypeCommand.processTextWithEscapes("Text\\\\")
        #expect(incompleteEscape.count == 1)
        if case .text("Text\\") = incompleteEscape[0] { } else {
            Issue.record("Expected 'Text\\'")
        }

        // Multiple consecutive escapes
        let consecutiveEscapes = TypeCommand.processTextWithEscapes("Text\\n\\n\\t\\t")
        #expect(consecutiveEscapes.count == 5)
        if case .text("Text") = consecutiveEscapes[0] { } else {
            Issue.record("Expected 'Text'")
        }
        if case .key(.return) = consecutiveEscapes[1] { } else {
            Issue.record("Expected return")
        }
        if case .key(.return) = consecutiveEscapes[2] { } else {
            Issue.record("Expected return")
        }
        if case .key(.tab) = consecutiveEscapes[3] { } else {
            Issue.record("Expected tab")
        }
        if case .key(.tab) = consecutiveEscapes[4] { } else {
            Issue.record("Expected tab")
        }
    }

    @Test
    func `Parse type command with escape sequences`() throws {
        // Test parsing text with escape sequences
        // Note: The escape sequences are processed at runtime, not during parsing
        let command = try TypeCommand.parse(["Line 1\\nLine 2", "--delay", "50"])

        #expect(command.text == "Line 1\\nLine 2")
        #expect(command.delay.roundedMilliseconds == 50)
    }

    // MARK: - Helpers

    private func runType(
        arguments: [String],
        context: TestServicesFactory.AutomationTestContext
    ) async throws -> CommandRunResult {
        try await InProcessCommandRunner.run(["type"] + arguments, services: context.services)
    }

    @MainActor
    private func makeContext(
        automation: StubAutomationService = StubAutomationService(),
        applications: any ApplicationServiceProtocol = StubApplicationService(applications: []),
        windows: any WindowManagementServiceProtocol = StubWindowService(windowsByApp: [:]),
        configure: ((StubAutomationService, StubSnapshotManager) -> Void)? = nil
    ) async -> TestServicesFactory
    .AutomationTestContext {
        await MainActor.run {
            let context = TestServicesFactory.makeAutomationTestContext(
                automation: automation,
                applications: applications,
                windows: windows
            )
            configure?(context.automation, context.snapshots)
            return context
        }
    }

    private func window(
        windowID: Int,
        pid: Int32,
        generation: UInt64
    ) -> ServiceWindowInfo {
        let bounds = CGRect(x: windowID * 2, y: 30, width: 500, height: 400)
        return ServiceWindowInfo(
            windowID: windowID,
            title: "Document \(windowID)",
            bounds: bounds,
            mutationIdentity: WindowMutationIdentity(
                windowID: windowID,
                ownerProcessIdentifier: pid,
                ownerProcessStartIdentity: generation,
                capturedBounds: bounds
            )
        )
    }

    @MainActor
    private func automationState<T: Sendable>(
        _ context: TestServicesFactory.AutomationTestContext,
        _ operation: (StubAutomationService) -> T
    ) async -> T {
        await MainActor.run {
            operation(context.automation)
        }
    }
}

private func confirmedTypeAutomation(
    mode: DesktopActionOutcome.Delivery.Mode
) async -> OutcomeStubAutomationService {
    await MainActor.run {
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(delivery: .init(
            mechanism: mode == .foreground ? .globalEvents : .processTargetedEvents,
            mode: mode
        ))
        return automation
    }
}

@MainActor
enum InputFocusFixtures {
    static let windowID = 901
    static let processIdentifier: Int32 = 4201
    static let processStartIdentity: UInt64 = 71
    static let bounds = CGRect(x: 20, y: 30, width: 500, height: 400)

    static let focusOutcome = DesktopActionOutcome.confirmedChange(
        route: .bridge,
        delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
        unitCount: .one
    )
    static let typeOutcome = DesktopActionOutcome.confirmedChange(
        route: .bridge,
        delivery: .init(mechanism: .globalEvents, mode: .foreground),
        unitCount: .one
    )

    static func window(windowID: Int = InputFocusFixtures.windowID) -> ServiceWindowInfo {
        let identity = self.identity(windowID: windowID)
        return ServiceWindowInfo(
            windowID: windowID,
            title: "Input Fixture",
            bounds: identity.capturedBounds ?? self.bounds,
            mutationIdentity: identity
        )
    }

    static func identity(windowID: Int = InputFocusFixtures.windowID) -> WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: self.processIdentifier,
            ownerProcessStartIdentity: self.processStartIdentity,
            capturedBounds: self.bounds
        )
    }

    static func targetIdentity(windowID: Int = InputFocusFixtures.windowID) throws -> DesktopTargetIdentity {
        try DesktopTargetIdentity(exactWindow: .init(
            identity: self.identity(windowID: windowID),
            bounds: self.bounds
        ))
    }
}

@MainActor
final class InputFocusWindowService: StubWindowService, WindowManagementPinnedFocusActionResultProviding {
    let focusOutcome: DesktopActionOutcome
    var returnedTargetIdentity: DesktopTargetIdentity?
    private(set) var pinnedFocusCalls: [(WindowTarget, WindowMutationIdentity)] = []

    init(focusOutcome: DesktopActionOutcome) {
        self.focusOutcome = focusOutcome
        super.init(windowsByApp: ["InputFixture": [InputFocusFixtures.window()]])
    }

    @MainActor
    func focusWindowActionResult(target: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        let windows = try await self.listWindows(target: target)
        guard let identity = windows.first?.mutationIdentity else {
            throw PeekabooError.windowNotFound(criteria: target.description)
        }
        return try await self.focusWindowActionResult(target: .windowId(identity.windowID), expectedIdentity: identity)
    }

    @MainActor
    func focusWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity
    ) async throws -> UIAutomationActionResult<Void> {
        self.pinnedFocusCalls.append((target, expectedIdentity))
        return try UIAutomationActionResult(
            payload: (),
            outcome: self.focusOutcome,
            targetIdentity: self.returnedTargetIdentity ?? InputFocusFixtures.targetIdentity()
        )
    }
}

@MainActor
final class InputExecutionHostServices: PeekabooServiceProviding {
    let executionHost: PeekabooServiceExecutionHost
    private let base: PeekabooServices

    init(host: PeekabooServiceExecutionHost, base: PeekabooServices) {
        self.executionHost = host
        self.base = base
    }

    var logging: any LoggingServiceProtocol {
        self.base.logging
    }

    var desktopObservation: any DesktopObservationServiceProtocol {
        self.base.desktopObservation
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        self.base.screenCapture
    }

    var applications: any ApplicationServiceProtocol {
        self.base.applications
    }

    var automation: any UIAutomationServiceProtocol {
        self.base.automation
    }

    var windows: any WindowManagementServiceProtocol {
        self.base.windows
    }

    var menu: any MenuServiceProtocol {
        self.base.menu
    }

    var dock: any DockServiceProtocol {
        self.base.dock
    }

    var dialogs: any DialogServiceProtocol {
        self.base.dialogs
    }

    var snapshots: any SnapshotManagerProtocol {
        self.base.snapshots
    }

    var files: any FileServiceProtocol {
        self.base.files
    }

    var clipboard: any ClipboardServiceProtocol {
        self.base.clipboard
    }

    var configuration: PeekabooAutomation.ConfigurationManager {
        self.base.configuration
    }

    var permissions: PermissionsService {
        self.base.permissions
    }

    var audioInput: AudioInputService {
        self.base.audioInput
    }

    var screens: any ScreenServiceProtocol {
        self.base.screens
    }

    var browser: any BrowserMCPClientProviding {
        self.base.browser
    }

    var agent: (any AgentServiceProtocol)? {
        self.base.agent
    }

    func ensureVisualizerConnection() {
        self.base.ensureVisualizerConnection()
    }
}
