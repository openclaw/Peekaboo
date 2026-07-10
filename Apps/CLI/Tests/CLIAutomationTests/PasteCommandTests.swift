import Foundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

@Suite(.tags(.safe), .serialized)
struct PasteCommandTests {
    @Test
    @MainActor
    func `Literally bare paste invocation executes instead of printing help`() async throws {
        // Regression: with showHelpOnEmptyInvocation the router intercepted the
        // exact argv ["paste"] and printed help, so the documented default
        // invocation never sent Cmd+V. Flagged variants like ["paste", "--json"]
        // bypass that interception and cannot catch this.
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

        #expect(result.exitStatus == 0)
        #expect(automation.hotkeyCalls.map(\.keys) == ["cmd,v"])
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
            ["paste", "--restore-delay-ms", "150", "--json", "--no-remote"],
            ["paste", "--restore-delay-ms", "500", "--json", "--no-remote"],
        ] {
            let result = try await InProcessCommandRunner.run(argv, services: services)
            #expect(result.exitStatus != 0, "expected validation failure for \(argv)")
            #expect(automation.hotkeyCalls.isEmpty, "unexpected paste for \(argv)")
            #expect(automation.targetedHotkeyCalls.isEmpty, "unexpected targeted paste for \(argv)")
        }
    }

    @Test
    @MainActor
    func `Bare paste sends current clipboard without mutating clipboard`() async throws {
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

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--json",
                "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus == 0)
        #expect(automation.hotkeyCalls.map(\.keys) == ["cmd,v"])
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(clipboard.current?.textPreview == "current")
        #expect(clipboard.restoreCallCount == 0)
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<PasteResult>.self
        )
        #expect(payload.data.deliveryMode == "foreground")
        // Ambient clipboard content must not leak into structured output.
        #expect(payload.data.pastedTextPreview == nil)
        #expect(payload.data.previousClipboardPresent == true)
        #expect(payload.data.restoreSucceeded == true)
    }

    @Test
    @MainActor
    func `Bare paste with app target uses background hotkey`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
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

        #expect(result.exitStatus == 0)
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(automation.targetedHotkeyCalls.map(\.keys) == ["cmd,v"])
        #expect(automation.targetedHotkeyCalls.first?.targetProcessIdentifier == 2468)
    }

    @Test
    @MainActor
    func `Paste with app target defaults to background process delivery`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
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
                "--restore-delay-ms", "0",
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
    }

    @Test
    @MainActor
    func `Paste positional text uses background process delivery`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
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
                "positional smoke",
                "--app", "TextEdit",
                "--restore-delay-ms", "0",
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
    func `Paste binary payload keeps background hotkey delivery`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
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
                "--restore-delay-ms", "0",
                "--json",
                "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus == 0)
        #expect(automation.targetedTypeActionsCalls.isEmpty)
        #expect(automation.targetedHotkeyCalls.map(\.keys) == ["cmd,v"])
        #expect(automation.targetedHotkeyCalls.first?.targetProcessIdentifier == 2468)
        #expect(applications.activateCalls.isEmpty)
        #expect(clipboard.current?.utiIdentifier == priorClipboard.utiIdentifier)
        #expect(clipboard.current?.data == priorClipboard.data)
        #expect(clipboard.current?.textPreview == priorClipboard.textPreview)
        #expect(clipboard.restoreCallCount == 1)
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<PasteResult>.self
        )
        #expect(payload.data.restoreSucceeded)
        #expect(payload.data.restoreError == nil)
        #expect(payload.data.restoredUti == priorClipboard.utiIdentifier)
        #expect(payload.data.restoredSize == priorClipboard.data.count)
    }

    @Test
    @MainActor
    func `Paste warns without inviting retry when clipboard restoration fails`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
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
                "--app", "TextEdit",
                "--data-base64", "aGVsbG8=",
                "--uti", "public.data",
                "--restore-delay-ms", "0",
                "--json",
                "--no-remote",
            ],
            services: services
        )

        #expect(jsonResult.exitStatus == 0)
        #expect(automation.targetedHotkeyCalls.map(\.keys) == ["cmd,v"])
        #expect(clipboard.restoreCallCount == 1)
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: jsonResult,
            as: CodableJSONResponse<PasteResult>.self
        )
        #expect(payload.data.success)
        #expect(!payload.data.restoreSucceeded)
        #expect(payload.data.restoreError == "Failed to write to clipboard: simulated restore failure")

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
                "--app", "TextEdit",
                "--data-base64", "aGVsbG8=",
                "--uti", "public.data",
                "--restore-delay-ms", "0",
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
    func `Paste foreground flag opts out of background process delivery`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
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
                "--restore-delay-ms", "0",
                "--json",
                "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus == 0)
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(automation.hotkeyCalls.map(\.keys) == ["cmd,v"])
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<PasteResult>.self
        )
        #expect(payload.data.deliveryMode == "foreground")
        #expect(payload.data.targetPID == nil)
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
}
