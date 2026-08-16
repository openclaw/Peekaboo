import Darwin
import Foundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

@Suite(.tags(.safe), .serialized)
struct PasteCommandTests {
    @Test
    @MainActor
    func `Literally bare paste invocation fails instead of injecting globally`() async throws {
        let automation = StubAutomationService()
        let clipboard = StubClipboardService()
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("current".utf8),
            textPreview: "current"
        )
        let services = TestServicesFactory.makePeekabooServices(
            clipboard: clipboard,
            automation: automation
        )

        let result = try await InProcessCommandRunner.run(["paste"], services: services)

        #expect(result.exitStatus != 0)
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(!result.stdout.contains("Usage"))
    }

    @Test
    @MainActor
    func `Malformed payload flags fail validation instead of pasting the clipboard`() async throws {
        // Regression: `paste --uti public.rtf` (payload modifier, no payload) previously
        // reached makeWriteRequest() and failed; the bare-paste branch must not swallow
        // it into an unintended Cmd+V of whatever is on the clipboard.
        let automation = StubAutomationService()
        let clipboard = StubClipboardService()
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("sensitive".utf8),
            textPreview: "sensitive"
        )
        let services = TestServicesFactory.makePeekabooServices(
            clipboard: clipboard,
            automation: automation
        )

        for argv in [
            ["paste", "--uti", "public.rtf", "--json", "--no-remote"],
            ["paste", "--also-text", "fallback", "--json", "--no-remote"],
            ["paste", "--allow-large", "--json", "--no-remote"],
        ] {
            let result = try await InProcessCommandRunner.run(argv, services: services)
            #expect(result.exitStatus != 0, "expected validation failure for \(argv)")
            #expect(automation.hotkeyCalls.isEmpty, "unexpected paste for \(argv)")
            #expect(automation.targetedHotkeyCalls.isEmpty, "unexpected targeted paste for \(argv)")
        }
    }

    @Test
    @MainActor
    func `Bare background paste reports unverified receiver consumption`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 71,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let automation = StubAutomationService()
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [app]),
            automation: automation
        )

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--app", "TextEdit",
                "--json",
                "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus != 0)
        #expect(result.stdout.contains("Background paste delivery could not be verified"))
        #expect(result.stdout.contains("may have pasted; do not retry"))
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: JSONResponse.self
        )
        #expect(payload.effect == .unverifiable)
        #expect(payload.outcome?.state == .dispatchedUnverified)
        #expect(payload.outcome?.route == .local)
        #expect(payload.outcome?.deliveryMechanism == .processTargetedEvents)
        #expect(payload.outcome?.deliveryMode == .background)
        #expect(payload.outcome?.dispatchedUnitCount == .one)
        #expect(payload.outcome?.mutationDispatched == true)
        #expect(payload.outcome?.retrySafe == false)
        #expect(payload.error?.mutation_dispatched == true)
        #expect(payload.error?.retry_safe == false)
        #expect(payload.target_receipt?.processIdentifier == 2468)
        #expect(payload.target_receipt?.processStartIdentity == 71)
        #expect(payload.target_receipt?.windowID == nil)
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(automation.targetedHotkeyCalls.map(\.keys) == ["cmd,v"])
        #expect(automation.targetedHotkeyCalls.first?.targetProcessIdentifier == 2468)
        #expect(automation.targetedHotkeyCalls.first?.expectedProcessIdentity == ApplicationProcessIdentity(
            processIdentifier: 2468,
            processStartIdentity: 71
        ))
    }

    @Test
    @MainActor
    func `Paste with app target defaults to background process delivery`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 71,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            unitCount: .one
        )
        let clipboard = StubClipboardService()
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("prior".utf8),
            textPreview: "prior"
        )
        let applications = StubApplicationService(applications: [app])
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            clipboard: clipboard,
            automation: automation
        )

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--app", "TextEdit",
                "--text", "smoke",
                "--restore-delay", "0",
                "--json",
                "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus == 0)
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(automation.hotkeyCalls.isEmpty)
        let typeCall = try #require(automation.targetedTypeActionsCalls.first)
        #expect(typeCall.targetProcessIdentifier == 2468)
        #expect(typeCall.expectedProcessIdentity == ApplicationProcessIdentity(
            processIdentifier: 2468,
            processStartIdentity: 71
        ))
        #expect(typeCall.actions.count == 1)
        if case .text("smoke") = typeCall.actions[0] {} else {
            Issue.record("Expected background paste text to be delivered through targeted typing")
        }
        #expect(applications.activateCalls.isEmpty)
        #expect(clipboard.current?.textPreview == "prior")
        #expect(clipboard.slots.isEmpty)
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<PasteResult>.self
        )
        #expect(payload.data.deliveryMode == "background")
        #expect(payload.data.targetPID == 2468)
        #expect(payload.effect == .confirmed)
        #expect(payload.outcome?.state == .confirmedChange)
        #expect(payload.outcome?.deliveryMechanism == .processTargetedEvents)
        #expect(payload.outcome?.deliveryMode == .background)
        #expect(payload.target_identity?.kind == .process)
        #expect(payload.target_identity?.pid == 2468)
        #expect(payload.target_identity?.process_start_identity_decimal == "71")
    }

    @Test
    @MainActor
    func `Paste positional text uses background process delivery`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 71,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            unitCount: .one
        )
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [app]),
            automation: automation
        )

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "positional smoke",
                "--app", "TextEdit",
                "--restore-delay", "0",
                "--json",
                "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus == 0)
        let typeCall = try #require(automation.targetedTypeActionsCalls.first)
        if case .text("positional smoke") = typeCall.actions[0] {} else {
            Issue.record("Expected positional text to be delivered through targeted typing")
        }
        #expect(typeCall.targetProcessIdentifier == 2468)
    }

    @Test
    @MainActor
    func `Paste UTF8 data uses proven background text delivery`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 71,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            unitCount: .one
        )
        let clipboard = StubClipboardService()
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("prior".utf8),
            textPreview: "prior"
        )
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [app]),
            clipboard: clipboard,
            automation: automation
        )

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--app", "TextEdit",
                "--data-base64", Data("decoded text".utf8).base64EncodedString(),
                "--uti", "public.utf8-plain-text",
                "--json",
                "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus == 0)
        let typeCall = try #require(automation.targetedTypeActionsCalls.first)
        if case .text("decoded text")? = typeCall.actions.first {} else {
            Issue.record("Expected UTF-8 clipboard data to use targeted text delivery")
        }
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(clipboard.current?.textPreview == "prior")
        #expect(clipboard.restoreCallCount == 0)
    }

    @Test
    @MainActor
    func `Paste binary payload preserves transaction but never claims background consumption`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 71,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let automation = StubAutomationService()
        let clipboard = StubClipboardService()
        let priorClipboard = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("prior".utf8),
            textPreview: "prior"
        )
        clipboard.current = priorClipboard
        let applications = StubApplicationService(applications: [app])
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            clipboard: clipboard,
            automation: automation
        )

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--app", "TextEdit",
                "--data-base64", "aGVsbG8=",
                "--uti", "public.data",
                "--restore-delay", "0",
                "--json",
                "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus != 0)
        #expect(result.stdout.contains("Background paste delivery could not be verified"))
        #expect(result.stdout.contains("may have pasted; do not retry"))
        #expect(result.stdout.contains("\"code\" : \"INTERACTION_FAILED\""))
        #expect(automation.targetedTypeActionsCalls.isEmpty)
        #expect(automation.targetedHotkeyCalls.map(\.keys) == ["cmd,v"])
        #expect(automation.targetedHotkeyCalls.first?.targetProcessIdentifier == 2468)
        #expect(applications.activateCalls.isEmpty)
        #expect(clipboard.current?.utiIdentifier == priorClipboard.utiIdentifier)
        #expect(clipboard.current?.data == priorClipboard.data)
        #expect(clipboard.current?.textPreview == priorClipboard.textPreview)
        #expect(clipboard.restoreCallCount == 1)
    }

    @Test
    @MainActor
    func `Paste warns without inviting retry when clipboard restoration fails`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 71,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let automation = StubAutomationService()
        let clipboard = StubClipboardService()
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("prior".utf8),
            textPreview: "prior"
        )
        clipboard.restoreError = ClipboardServiceError.writeFailed("simulated restore failure")
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [app]),
            clipboard: clipboard,
            automation: automation
        )

        let jsonResult = try await InProcessCommandRunner.run(
            [
                "paste",
                "--foreground",
                "--no-auto-focus",
                "--data-base64", "aGVsbG8=",
                "--uti", "public.data",
                "--restore-delay", "0",
                "--json",
                "--no-remote",
            ],
            services: services
        )

        #expect(jsonResult.exitStatus == 0)
        #expect(automation.hotkeyCalls.map(\.keys) == ["cmd,v"])
        #expect(clipboard.restoreCallCount == 1)
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: jsonResult,
            as: CodableJSONResponse<PasteResult>.self
        )
        #expect(!payload.data.restoreSucceeded)
        #expect(payload.data.restoreError == "Failed to write to clipboard: simulated restore failure")
        #expect(payload.effect == .partial)
        #expect(payload.outcome?.state == .partial)
        #expect(payload.outcome?.deliveryMechanism == .globalEvents)
        #expect(payload.outcome?.deliveryMode == .foreground)
        #expect(payload.outcome?.mutationDispatched == true)
        #expect(payload.outcome?.retrySafe == false)

        let plainClipboard = StubClipboardService()
        plainClipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("prior".utf8),
            textPreview: "prior"
        )
        plainClipboard.restoreError = ClipboardServiceError.writeFailed("simulated restore failure")
        let plainResult = try await InProcessCommandRunner.run(
            [
                "paste",
                "--foreground",
                "--no-auto-focus",
                "--data-base64", "aGVsbG8=",
                "--uti", "public.data",
                "--restore-delay", "0",
                "--no-remote",
            ],
            services: TestServicesFactory.makePeekabooServices(
                applications: StubApplicationService(applications: [app]),
                clipboard: plainClipboard,
                automation: StubAutomationService()
            )
        )

        #expect(plainResult.exitStatus == 0)
        #expect(plainResult.stdout.contains("clipboard restoration failed"))
        #expect(plainResult.stdout.contains("Do not retry the paste"))
    }

    @Test
    @MainActor
    func `Targeted foreground paste refuses disabled exact focus before clipboard mutation`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 71,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let automation = StubAutomationService()
        let clipboard = StubClipboardService()
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [app]),
            clipboard: clipboard,
            automation: automation
        )

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--app", "TextEdit",
                "--text", "smoke",
                "--foreground",
                "--no-auto-focus",
                "--restore-delay", "0",
                "--json",
                "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus != 0)
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(clipboard.setCallCount == 0)
        let payload = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(payload.outcome?.state == .refused)
        #expect(payload.outcome?.mutationDispatched == false)
        #expect(payload.outcome?.retrySafe == true)
        #expect(payload.error?.message.contains("automatic foreground focus is disabled") == true)
    }

    @Test
    @MainActor
    func `Paste fails before mutating clipboard when explicit app target is missing`() async throws {
        let automation = StubAutomationService()
        let clipboard = StubClipboardService()
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: []),
            clipboard: clipboard,
            automation: automation
        )

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--app", "NoSuchPeekabooApp",
                "--text", "smoke",
                "--json",
                "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus == 1)
        #expect(result.stdout.contains("\"success\" : false"))
        #expect(result.stdout.contains("\"code\" : \"APP_NOT_FOUND\""))
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(try clipboard.get(prefer: nil) == nil)
    }

    @Test
    @MainActor
    func `Clipboard-backed paste re-resolves its process after lock contention`() async throws {
        let heldFD = try await self.holdPasteTransactionLock()
        var lockHeld = true
        defer {
            if lockHeld {
                flock(heldFD, LOCK_UN)
            }
            close(heldFD)
        }

        let context = self.makeTransactionGateContext()
        let command = Task { @MainActor in
            try await InProcessCommandRunner.run(
                [
                    "paste",
                    "--app", "TextEdit",
                    "--data-base64", "cGF5bG9hZA==",
                    "--uti", "public.data",
                    "--restore-delay", "0",
                    "--json",
                    "--no-remote",
                ],
                services: context.services
            )
        }

        try await Task.sleep(for: .milliseconds(75))
        #expect(context.clipboard.current?.textPreview == "prior")
        #expect(context.automation.targetedHotkeyCalls.isEmpty)
        context.applications.applications = [
            ServiceApplicationInfo(
                processIdentifier: 9753,
                processStartIdentity: 72,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"
            ),
        ]

        #expect(flock(heldFD, LOCK_UN) == 0)
        lockHeld = false

        let result = try await command.value
        #expect(result.exitStatus != 0)
        #expect(result.stdout.contains("Background paste delivery could not be verified"))
        #expect(context.automation.targetedHotkeyCalls.map(\.keys) == ["cmd,v"])
        #expect(context.automation.targetedHotkeyCalls.first?.targetProcessIdentifier == 9753)
        #expect(context.clipboard.current?.textPreview == "prior")
        #expect(context.clipboard.restoreCallCount == 1)
    }

    @Test
    @MainActor
    func `Targeted text paste remains lock-free`() async throws {
        let heldFD = try await self.holdPasteTransactionLock()
        defer {
            flock(heldFD, LOCK_UN)
            close(heldFD)
        }

        let context = self.makeTransactionGateContext()
        let command = Task { @MainActor in
            let result = try await InProcessCommandRunner.run(
                [
                    "paste",
                    "--app", "TextEdit",
                    "--text", "direct text",
                    "--json",
                    "--no-remote",
                ],
                services: context.services
            )
            return result.exitStatus
        }
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            command.cancel()
        }
        let exitStatus = try await command.value
        timeout.cancel()

        #expect(exitStatus == 0)
        #expect(context.automation.targetedHotkeyCalls.isEmpty)
        let typeCall = try #require(context.automation.targetedTypeActionsCalls.first)
        #expect(typeCall.targetProcessIdentifier == 2468)
        #expect(context.clipboard.current?.textPreview == "prior")
        #expect(context.clipboard.restoreCallCount == 0)
    }

    @Test
    @MainActor
    func `Clipboard capability refusal never reads or mutates the clipboard`() async throws {
        let context = self.makeTransactionGateContext()
        context.automation.supportsTargetedHotkeys = false

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--app", "TextEdit",
                "--data-base64", "cGF5bG9hZA==",
                "--uti", "public.data",
                "--json",
                "--no-remote",
            ],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        #expect(context.clipboard.getCallCount == 0)
        #expect(context.clipboard.saveCallCount == 0)
        #expect(context.clipboard.setCallCount == 0)
        #expect(context.clipboard.clearCallCount == 0)
        #expect(context.clipboard.restoreCallCount == 0)
        #expect(context.clipboard.current?.textPreview == "prior")
        #expect(context.automation.targetedHotkeyCalls.isEmpty)
    }

    @Test
    @MainActor
    func `Exact window capability refusal happens before clipboard access`() async throws {
        let pid: Int32 = 2468
        let bounds = CGRect(x: 20, y: 30, width: 500, height: 400)
        let clipboard = StubClipboardService()
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("prior".utf8),
            textPreview: "prior"
        )
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [ServiceApplicationInfo(
                processIdentifier: pid,
                processStartIdentity: 71,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"
            )]),
            windows: StubWindowService(windowsByApp: ["TextEdit": [ServiceWindowInfo(
                windowID: 901,
                title: "Untitled",
                bounds: bounds,
                mutationIdentity: WindowMutationIdentity(
                    windowID: 901,
                    ownerProcessIdentifier: pid,
                    ownerProcessStartIdentity: 71,
                    capturedBounds: bounds
                )
            )]]),
            clipboard: clipboard,
            automation: StubAutomationService()
        )

        let result = try await InProcessCommandRunner.run(
            [
                "paste", "--app", "TextEdit", "--window-id", "901",
                "--data-base64", "cGF5bG9hZA==", "--uti", "public.data",
                "--json", "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus != 0)
        #expect(clipboard.getCallCount == 0)
        #expect(clipboard.saveCallCount == 0)
        #expect(clipboard.setCallCount == 0)
        #expect(clipboard.restoreCallCount == 0)
    }

    @Test
    @MainActor
    func `Clipboard read failure is not treated as an empty clipboard`() async throws {
        let context = self.makeTransactionGateContext()
        context.clipboard.getError = ClipboardServiceError.writeFailed("simulated read failure")

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--app", "TextEdit",
                "--data-base64", "cGF5bG9hZA==",
                "--uti", "public.data",
                "--json",
                "--no-remote",
            ],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        #expect(result.stdout.contains("simulated read failure"))
        #expect(context.clipboard.getCallCount == 1)
        #expect(context.clipboard.saveCallCount == 0)
        #expect(context.clipboard.setCallCount == 0)
        #expect(context.clipboard.clearCallCount == 0)
        #expect(context.clipboard.restoreCallCount == 0)
        #expect(context.clipboard.current?.textPreview == "prior")
        #expect(context.automation.targetedHotkeyCalls.isEmpty)
    }

    @Test
    @MainActor
    func `Current clipboard read failure aborts before Cmd V`() async throws {
        let context = self.makeTransactionGateContext()
        context.clipboard.getError = ClipboardServiceError.writeFailed("simulated current read failure")

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--foreground",
                "--json",
                "--no-remote",
            ],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        #expect(result.stdout.contains("simulated current read failure"))
        #expect(context.clipboard.getCallCount == 1)
        #expect(context.clipboard.setCallCount == 0)
        #expect(context.clipboard.clearCallCount == 0)
        #expect(context.clipboard.restoreCallCount == 0)
        #expect(context.automation.hotkeyCalls.isEmpty)
        #expect(context.automation.targetedHotkeyCalls.isEmpty)
    }

    @Test
    @MainActor
    func `Cancellation after snapshot but before write never restores or clears`() async throws {
        let context = self.makeTransactionGateContext()
        context.clipboard.afterSave = {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        let command = Task { @MainActor in
            try await InProcessCommandRunner.run(
                [
                    "paste",
                    "--app", "TextEdit",
                    "--data-base64", "cGF5bG9hZA==",
                    "--uti", "public.data",
                    "--json",
                    "--no-remote",
                ],
                services: context.services
            )
        }

        let result = try await command.value

        #expect(result.exitStatus != 0)
        #expect(context.clipboard.saveCallCount == 1)
        #expect(context.clipboard.setCallCount == 0)
        #expect(context.clipboard.clearCallCount == 0)
        #expect(context.clipboard.restoreCallCount == 0)
        #expect(context.clipboard.current?.textPreview == "prior")
        #expect(context.automation.targetedHotkeyCalls.isEmpty)
    }

    @Test
    @MainActor
    func `Cancellation during clipboard write restores before dispatch`() async throws {
        let context = self.makeTransactionGateContext()
        context.clipboard.afterSet = {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        let command = Task { @MainActor in
            try await InProcessCommandRunner.run(
                [
                    "paste",
                    "--app", "TextEdit",
                    "--data-base64", "cGF5bG9hZA==",
                    "--uti", "public.data",
                    "--json",
                    "--no-remote",
                ],
                services: context.services
            )
        }

        let result = try await command.value

        #expect(result.exitStatus != 0)
        #expect(context.clipboard.setCallCount == 1)
        #expect(context.clipboard.restoreCallCount == 1)
        #expect(context.clipboard.current?.textPreview == "prior")
        #expect(context.automation.targetedHotkeyCalls.isEmpty)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `Set failure restores exact prior clipboard before dispatch`(mutatesBeforeThrow: Bool) async throws {
        let context = self.makeTransactionGateContext()
        context.clipboard.setError = ClipboardServiceError.writeFailed("simulated set failure")
        context.clipboard.setMutatesBeforeThrow = mutatesBeforeThrow

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--app", "TextEdit",
                "--data-base64", "cGF5bG9hZA==",
                "--uti", "public.data",
                "--json",
                "--no-remote",
            ],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        #expect(result.stdout.contains("simulated set failure"))
        #expect(context.clipboard.saveCallCount == 1)
        #expect(context.clipboard.setCallCount == 1)
        #expect(context.clipboard.clearCallCount == 0)
        #expect(context.clipboard.restoreCallCount == 1)
        #expect(context.clipboard.current?.textPreview == "prior")
        #expect(context.automation.targetedHotkeyCalls.isEmpty)
    }

    @Test
    @MainActor
    func `Set and restoration failure reports clipboard integrity risk without dispatch`() async throws {
        let context = self.makeTransactionGateContext()
        context.clipboard.setError = ClipboardServiceError.writeFailed("simulated partial set failure")
        context.clipboard.setMutatesBeforeThrow = true
        context.clipboard.restoreError = ClipboardServiceError.writeFailed("simulated restore failure")

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--app", "TextEdit",
                "--data-base64", "cGF5bG9hZA==",
                "--uti", "public.data",
                "--json",
                "--no-remote",
            ],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        #expect(result.stdout.contains("Paste payload setup failed"))
        #expect(result.stdout.contains("restoring the prior clipboard also failed"))
        #expect(context.clipboard.setCallCount == 1)
        #expect(context.clipboard.restoreCallCount == 1)
        #expect(context.automation.targetedHotkeyCalls.isEmpty)
    }

    @Test
    @MainActor
    func `Partial set failure restores a genuinely empty clipboard by clearing`() async throws {
        let context = self.makeTransactionGateContext()
        context.clipboard.current = nil
        context.clipboard.setError = ClipboardServiceError.writeFailed("simulated partial set failure")
        context.clipboard.setMutatesBeforeThrow = true

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--app", "TextEdit",
                "--data-base64", "cGF5bG9hZA==",
                "--uti", "public.data",
                "--json",
                "--no-remote",
            ],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        #expect(context.clipboard.getCallCount == 1)
        #expect(context.clipboard.saveCallCount == 0)
        #expect(context.clipboard.setCallCount == 1)
        #expect(context.clipboard.clearCallCount == 1)
        #expect(context.clipboard.restoreCallCount == 0)
        #expect(context.clipboard.current == nil)
        #expect(context.automation.targetedHotkeyCalls.isEmpty)
    }

    @Test
    @MainActor
    func `Current clipboard paste waits for an active transaction`() async throws {
        let heldFD = try await self.holdPasteTransactionLock()
        var lockHeld = true
        defer {
            if lockHeld {
                flock(heldFD, LOCK_UN)
            }
            close(heldFD)
        }

        let context = self.makeTransactionGateContext()
        let command = Task { @MainActor in
            try await InProcessCommandRunner.run(
                [
                    "paste",
                    "--app", "TextEdit",
                    "--json",
                    "--no-remote",
                ],
                services: context.services
            )
        }

        try await Task.sleep(for: .milliseconds(75))
        #expect(context.automation.targetedHotkeyCalls.isEmpty)

        #expect(flock(heldFD, LOCK_UN) == 0)
        lockHeld = false

        let result = try await command.value
        #expect(result.exitStatus != 0)
        #expect(result.stdout.contains("Background paste delivery could not be verified"))
        #expect(context.automation.targetedHotkeyCalls.map(\.keys) == ["cmd,v"])
        #expect(context.clipboard.current?.textPreview == "prior")
        #expect(context.clipboard.restoreCallCount == 0)
    }

    @Test
    @MainActor
    func `Foreground target is revalidated only after the transaction lock is acquired`() async throws {
        let heldFD = try await self.holdPasteTransactionLock()
        var lockHeld = true
        defer {
            if lockHeld {
                flock(heldFD, LOCK_UN)
            }
            close(heldFD)
        }

        let context = self.makeTransactionGateContext()
        let command = Task { @MainActor in
            try await InProcessCommandRunner.run(
                [
                    "paste",
                    "--pid", "2468",
                    "--foreground",
                    "--data-base64", "cGF5bG9hZA==",
                    "--uti", "public.data",
                    "--restore-delay", "0",
                    "--json",
                    "--no-remote",
                ],
                services: context.services
            )
        }

        try await Task.sleep(for: .milliseconds(75))
        #expect(context.applications.activateCalls.isEmpty)
        #expect(context.clipboard.current?.textPreview == "prior")
        context.applications.applications.removeAll()

        #expect(flock(heldFD, LOCK_UN) == 0)
        lockHeld = false

        let result = try await command.value
        #expect(result.exitStatus != 0)
        #expect(context.automation.hotkeyCalls.isEmpty)
        #expect(context.clipboard.current?.textPreview == "prior")
        #expect(context.clipboard.restoreCallCount == 0)
    }

    @Test
    @MainActor
    func `Current clipboard paste holds the lock through its consumption delay`() async throws {
        let context = self.makeTransactionGateContext()
        let command = Task { @MainActor in
            try await InProcessCommandRunner.run(
                [
                    "paste",
                    "--app", "TextEdit",
                    "--restore-delay", "250ms",
                    "--json",
                    "--no-remote",
                ],
                services: context.services
            )
        }

        for _ in 0..<100 where context.automation.targetedHotkeyCalls.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(context.automation.targetedHotkeyCalls.map(\.keys) == ["cmd,v"])

        let contenderFD = try self.openPasteTransactionLock()
        defer { close(contenderFD) }
        let contentionResult = flock(contenderFD, LOCK_EX | LOCK_NB)
        let contentionError = errno
        #expect(contentionResult != 0)
        #expect(contentionError == EWOULDBLOCK || contentionError == EAGAIN)

        let result = try await command.value
        #expect(result.exitStatus != 0)
        #expect(result.stdout.contains("Background paste delivery could not be verified"))
        #expect(flock(contenderFD, LOCK_EX | LOCK_NB) == 0)
        #expect(flock(contenderFD, LOCK_UN) == 0)
    }

    @Test
    @MainActor
    func `Cancellation after paste waits for consumption before restoring`() async throws {
        let context = self.makeTransactionGateContext()
        let command = Task { @MainActor in
            try await InProcessCommandRunner.run(
                [
                    "paste",
                    "--app", "TextEdit",
                    "--data-base64", "cGF5bG9hZA==",
                    "--uti", "public.data",
                    "--restore-delay", "250ms",
                    "--json",
                    "--no-remote",
                ],
                services: context.services
            )
        }

        for _ in 0..<100 where context.automation.targetedHotkeyCalls.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(context.automation.targetedHotkeyCalls.map(\.keys) == ["cmd,v"])
        let clock = ContinuousClock()
        let canceledAt = clock.now
        command.cancel()

        try await Task.sleep(for: .milliseconds(75))
        #expect(context.clipboard.current?.utiIdentifier == "public.data")
        #expect(context.clipboard.restoreCallCount == 0)

        let result = try await command.value
        #expect(result.exitStatus != 0)
        #expect(result.stdout.contains("Paste outcome is indeterminate"))
        #expect(result.stdout.contains("may have pasted; do not retry"))
        #expect(clock.now - canceledAt >= .milliseconds(150))
        #expect(context.clipboard.current?.textPreview == "prior")
        #expect(context.clipboard.restoreCallCount == 1)
    }

    @Test
    @MainActor
    func `Foreground PID paste fails closed when process identity changes while queued`() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let heldFD = try await self.holdPasteTransactionLock()
        var lockHeld = true
        defer {
            if lockHeld {
                flock(heldFD, LOCK_UN)
            }
            close(heldFD)
        }

        let processIdentifier = process.processIdentifier
        let context = self.makeTransactionGateContext(processIdentifier: processIdentifier)
        let command = Task { @MainActor in
            try await InProcessCommandRunner.run(
                [
                    "paste",
                    "--pid", String(processIdentifier),
                    "--foreground",
                    "--no-auto-focus",
                    "--data-base64", "cGF5bG9hZA==",
                    "--uti", "public.data",
                    "--restore-delay", "0",
                    "--json",
                    "--no-remote",
                ],
                services: context.services
            )
        }

        try await Task.sleep(for: .milliseconds(75))
        #expect(context.automation.hotkeyCalls.isEmpty)
        process.terminate()
        process.waitUntilExit()

        #expect(flock(heldFD, LOCK_UN) == 0)
        lockHeld = false

        let result = try await command.value
        #expect(result.exitStatus != 0)
        #expect(context.automation.hotkeyCalls.isEmpty)
        #expect(context.clipboard.current?.textPreview == "prior")
        #expect(context.clipboard.restoreCallCount == 0)
    }

    @Test
    @MainActor
    func `Throwing paste dispatch settles before restore and unlock`() async throws {
        let context = self.makeTransactionGateContext()
        context.automation.targetedHotkeyError = ExpectedPasteDispatchError.afterPosting
        let command = Task { @MainActor in
            try await InProcessCommandRunner.run(
                [
                    "paste",
                    "--app", "TextEdit",
                    "--data-base64", "cGF5bG9hZA==",
                    "--uti", "public.data",
                    "--restore-delay", "250ms",
                    "--json",
                    "--no-remote",
                ],
                services: context.services
            )
        }

        for _ in 0..<100 where context.automation.targetedHotkeyCalls.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let clock = ContinuousClock()
        let dispatchedAt = clock.now
        try await Task.sleep(for: .milliseconds(75))
        #expect(context.clipboard.current?.utiIdentifier == "public.data")
        #expect(context.clipboard.restoreCallCount == 0)

        let contenderFD = try self.openPasteTransactionLock()
        defer { close(contenderFD) }
        #expect(flock(contenderFD, LOCK_EX | LOCK_NB) != 0)

        let result = try await command.value
        #expect(result.exitStatus != 0)
        #expect(result.stdout.contains("Paste outcome is indeterminate"))
        #expect(result.stdout.contains("may have pasted; do not retry"))
        #expect(result.stdout.contains("Paste outcome is indeterminate"))
        #expect(result.stdout.contains("may have pasted; do not retry"))
        #expect(clock.now - dispatchedAt >= .milliseconds(150))
        #expect(context.clipboard.current?.textPreview == "prior")
        #expect(context.clipboard.restoreCallCount == 1)
        #expect(flock(contenderFD, LOCK_EX | LOCK_NB) == 0)
        #expect(flock(contenderFD, LOCK_UN) == 0)
    }

    @Test
    @MainActor
    func `Throwing current clipboard dispatch keeps the gate through consumption`() async throws {
        let context = self.makeTransactionGateContext()
        context.automation.targetedHotkeyError = ExpectedPasteDispatchError.afterPosting
        let command = Task { @MainActor in
            try await InProcessCommandRunner.run(
                [
                    "paste",
                    "--app", "TextEdit",
                    "--restore-delay", "250ms",
                    "--json",
                    "--no-remote",
                ],
                services: context.services
            )
        }

        for _ in 0..<100 where context.automation.targetedHotkeyCalls.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let clock = ContinuousClock()
        let dispatchedAt = clock.now
        let contenderFD = try self.openPasteTransactionLock()
        defer { close(contenderFD) }
        #expect(flock(contenderFD, LOCK_EX | LOCK_NB) != 0)

        let result = try await command.value
        #expect(result.exitStatus != 0)
        #expect(result.stdout.contains("Paste outcome is indeterminate"))
        #expect(result.stdout.contains("may have pasted; do not retry"))
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: JSONResponse.self
        )
        #expect(payload.outcome?.state == .indeterminate)
        #expect(payload.outcome?.deliveryMechanism == .processTargetedEvents)
        #expect(payload.outcome?.deliveryMode == .background)
        #expect(payload.outcome?.dispatchedUnitCount == .one)
        #expect(payload.outcome?.mutationDispatched == true)
        #expect(payload.outcome?.retrySafe == false)
        #expect(payload.error?.mutation_dispatched == true)
        #expect(payload.error?.retry_safe == false)
        #expect(payload.target_receipt?.processIdentifier == 2468)
        #expect(payload.target_receipt?.processStartIdentity == 71)
        #expect(clock.now - dispatchedAt >= .milliseconds(150))
        #expect(context.clipboard.current?.textPreview == "prior")
        #expect(context.clipboard.restoreCallCount == 0)
        #expect(flock(contenderFD, LOCK_EX | LOCK_NB) == 0)
        #expect(flock(contenderFD, LOCK_UN) == 0)
    }

    @Test
    @MainActor
    func `Throwing foreground payload dispatch is indeterminate after restore`() async throws {
        let context = self.makeTransactionGateContext()
        context.automation.hotkeyError = ExpectedPasteDispatchError.afterPosting

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--foreground",
                "--no-auto-focus",
                "--data-base64", "cGF5bG9hZA==",
                "--uti", "public.data",
                "--restore-delay", "0",
                "--json",
                "--no-remote",
            ],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        #expect(result.stdout.contains("Paste outcome is indeterminate"))
        #expect(result.stdout.contains("may have pasted; do not retry"))
        #expect(context.automation.hotkeyCalls.map(\.keys) == ["cmd,v"])
        #expect(context.clipboard.current?.textPreview == "prior")
        #expect(context.clipboard.restoreCallCount == 1)
    }

    @Test
    @MainActor
    func `Cancelled foreground current clipboard dispatch settles and is indeterminate`() async throws {
        let context = self.makeTransactionGateContext()
        let command = Task { @MainActor in
            try await InProcessCommandRunner.run(
                [
                    "paste",
                    "--foreground",
                    "--no-auto-focus",
                    "--restore-delay", "250ms",
                    "--json",
                    "--no-remote",
                ],
                services: context.services
            )
        }

        for _ in 0..<100 where context.automation.hotkeyCalls.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        command.cancel()

        let result = try await command.value
        #expect(result.exitStatus != 0)
        #expect(result.stdout.contains("Paste outcome is indeterminate"))
        #expect(result.stdout.contains("may have pasted; do not retry"))
        #expect(context.clipboard.current?.textPreview == "prior")
        #expect(context.clipboard.restoreCallCount == 0)
    }
}

private enum ExpectedPasteDispatchError: Error {
    case afterPosting
}
