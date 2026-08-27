import CoreGraphics
import Darwin
import Foundation
import MCP
import PeekabooAutomationKit
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserNativeWindowBindingCoordinatorTests {
    private static let nativeTarget = BrowserNativeWindowTarget(
        processIdentifier: 4242,
        processStartIdentity: 9001,
        windowID: 313)
    private static let nativeBounds = CGRect(x: -1200, y: 80, width: 1200, height: 800)
    private static let detectedBrowser = DetectedBrowser(
        name: "Google Chrome",
        bundleIdentifier: "com.google.Chrome",
        processIdentifier: nativeTarget.processIdentifier,
        processStartIdentity: nativeTarget.processStartIdentity,
        version: "151.0",
        channel: .stable)

    @Test
    func `Exact bind stores private ids only in caller capability and revalidates`() async throws {
        let fixture = try await Self.fixture()

        let proof = try await BrowserNativeWindowBindingCoordinator.bind(
            pageReference: fixture.pageReference,
            nativeTarget: Self.nativeTarget,
            context: fixture.context,
            dependencies: Self.dependencies())

        #expect(proof.pageReference == fixture.pageReference)
        #expect(proof.nativeWindowReceipt.target == Self.nativeTarget)
        #expect(proof.quality == .exact)
        let binding = try await fixture.capabilities.nativeWindowBinding(
            pageReference: fixture.pageReference,
            sessionBinding: fixture.sessionBinding)
        #expect(binding.privateTargetID == "target-a")
        #expect(binding.privateBrowserWindowID == BrowserMCPDevToolsWindowID(rawValue: 41))
        try await BrowserNativeWindowBindingCoordinator.withRevalidatedMutation(
            pageReference: fixture.pageReference,
            context: fixture.context,
            receiptProviders: Self.providers(),
            mutation: { receipt in
                #expect(receipt == proof.nativeWindowReceipt)
            })
        #expect(fixture.opener.openCount == 1)
        await fixture.control.close()
    }

    @Test
    func `manager owned bound mutation uses one capability and execution gate`() async throws {
        let fixture = try await Self.fixture()
        let proof = try await BrowserNativeWindowBindingCoordinator.bind(
            pageReference: fixture.pageReference,
            nativeTarget: Self.nativeTarget,
            context: fixture.context,
            dependencies: Self.dependencies())
        fixture.provider.executeHandler = { toolName, _ in
            switch toolName {
            case "take_snapshot":
                ToolResponse(
                    content: [.text(
                        text: "uid=1_0 button \"Continue\"",
                        annotations: nil,
                        _meta: nil)],
                    structuredContent: .object([
                        "snapshot": .object([
                            "id": .string("1_0"),
                            "role": .string("button"),
                            "name": .string("Continue"),
                        ]),
                    ]))
            case "click":
                ToolResponse.text("clicked")
            default:
                ToolResponse.error("unexpected bound tool")
            }
        }
        let validationsBefore = try fixture.transport.sentCommands()
            .map(BrowserMCPDevToolsControlSessionTests.decodeCommand)
            .count(where: { $0.method == "Target.getTargets" })

        let execution = try await fixture.capabilities.withExclusiveOperation {
            try await fixture.manager.executeNativeWindowBoundSequence(
                .init(
                    calls: [BrowserMCPMappedCall(
                        toolName: "click",
                        arguments: ["pageId": 7, "uid": "1_0"])],
                    channel: .stable,
                    sessionBinding: fixture.sessionBinding,
                    elementPreflight: .init(providerPageID: 7, providerUIDs: ["1_0"]),
                    pageReference: fixture.pageReference,
                    deadline: Self.deadline),
                capabilities: fixture.capabilities,
                receiptProviders: Self.providers())
        }

        #expect(!execution.result.response.isError)
        #expect(execution.nativeWindowReceipt == proof.nativeWindowReceipt)
        #expect(fixture.provider.executedTools.suffix(2) == ["take_snapshot", "click"])
        let validationsAfter = try fixture.transport.sentCommands()
            .map(BrowserMCPDevToolsControlSessionTests.decodeCommand)
            .count(where: { $0.method == "Target.getTargets" })
        #expect(validationsAfter == validationsBefore + 1)
        await fixture.control.close()
    }

    @Test
    func `bound multi call mutation revalidates immediately before every provider leaf`() async throws {
        let fixture = try await Self.fixture()
        _ = try await BrowserNativeWindowBindingCoordinator.bind(
            pageReference: fixture.pageReference,
            nativeTarget: Self.nativeTarget,
            context: fixture.context,
            dependencies: Self.dependencies())
        fixture.provider.executeHandler = { _, _ in ToolResponse.text("ok") }
        let validationsBefore = try fixture.transport.sentCommands()
            .map(BrowserMCPDevToolsControlSessionTests.decodeCommand)
            .count(where: { $0.method == "Target.getTargets" })

        let execution = try await fixture.capabilities.withExclusiveOperation {
            try await fixture.manager.executeNativeWindowBoundSequence(
                .init(
                    calls: [
                        BrowserMCPMappedCall(toolName: "click", arguments: ["pageId": 7, "uid": "1_0"]),
                        BrowserMCPMappedCall(toolName: "type_text", arguments: ["pageId": 7, "text": "value"]),
                    ],
                    channel: .stable,
                    sessionBinding: fixture.sessionBinding,
                    elementPreflight: nil,
                    pageReference: fixture.pageReference,
                    deadline: Self.deadline),
                capabilities: fixture.capabilities,
                receiptProviders: Self.providers())
        }

        let validationsAfter = try fixture.transport.sentCommands()
            .map(BrowserMCPDevToolsControlSessionTests.decodeCommand)
            .count(where: { $0.method == "Target.getTargets" })
        #expect(validationsAfter == validationsBefore + 2)
        #expect(execution.result.completedCallCount == 2)
        #expect(execution.result.dispatchedCallCount == 2)
        #expect(fixture.provider.executedTools.suffix(2) == ["click", "type_text"])
        await fixture.control.close()
    }

    @Test
    func `target drift between bound calls preserves the completed prefix and skips the second leaf`() async throws {
        let moved = LockedBoolean()
        let fixture = try await Self.fixture(windowID: { moved.value ? 42 : 41 })
        _ = try await BrowserNativeWindowBindingCoordinator.bind(
            pageReference: fixture.pageReference,
            nativeTarget: Self.nativeTarget,
            context: fixture.context,
            dependencies: Self.dependencies())
        fixture.provider.executeHandler = { toolName, _ in
            if toolName == "click" {
                moved.value = true
            }
            return ToolResponse.text("ok")
        }

        let execution = try await fixture.capabilities.withExclusiveOperation {
            try await fixture.manager.executeNativeWindowBoundSequence(
                .init(
                    calls: [
                        BrowserMCPMappedCall(toolName: "click", arguments: ["pageId": 7, "uid": "1_0"]),
                        BrowserMCPMappedCall(toolName: "type_text", arguments: ["pageId": 7, "text": "value"]),
                    ],
                    channel: .stable,
                    sessionBinding: fixture.sessionBinding,
                    elementPreflight: nil,
                    pageReference: fixture.pageReference,
                    deadline: Self.deadline),
                capabilities: fixture.capabilities,
                receiptProviders: Self.providers())
        }

        #expect(execution.result.completedCallCount == 1)
        #expect(execution.result.dispatchedCallCount == 1)
        #expect(execution.result.actionFailure?.outcome.state == .partial)
        #expect(execution.result.actionFailure?.outcome.retrySafety == .unsafe)
        #expect(fixture.provider.executedTools.suffix(1) == ["click"])
        await #expect(throws: BrowserToolNativeWindowBindingError.stalePageReference) {
            _ = try await fixture.capabilities.nativeWindowBinding(
                pageReference: fixture.pageReference,
                sessionBinding: fixture.sessionBinding)
        }
        await fixture.control.close()
    }

    @Test
    func `bound provider cancellation remains indeterminate after dispatch`() async throws {
        let fixture = try await Self.fixture()
        let proof = try await BrowserNativeWindowBindingCoordinator.bind(
            pageReference: fixture.pageReference,
            nativeTarget: Self.nativeTarget,
            context: fixture.context,
            dependencies: Self.dependencies())
        fixture.provider.executeHandler = { toolName, _ in
            #expect(toolName == "navigate_page")
            throw CancellationError()
        }

        let execution = try await fixture.capabilities.withExclusiveOperation {
            try await fixture.manager.executeNativeWindowBoundSequence(
                .init(
                    calls: [BrowserMCPMappedCall(
                        toolName: "navigate_page",
                        arguments: ["pageId": 7, "type": "url", "url": "https://next.test/"])],
                    channel: .stable,
                    sessionBinding: fixture.sessionBinding,
                    elementPreflight: nil,
                    pageReference: fixture.pageReference,
                    deadline: Self.deadline),
                capabilities: fixture.capabilities,
                receiptProviders: Self.providers())
        }

        #expect(execution.result.completedCallCount == 0)
        #expect(execution.result.dispatchedCallCount == 1)
        #expect(execution.result.actionFailure?.outcome.state == .indeterminate)
        #expect(execution.result.actionFailure?.outcome.retrySafety == .unsafe)
        #expect(execution.nativeWindowReceipt == proof.nativeWindowReceipt)
    }

    @Test
    func `Unrelated stale page and window candidates do not revoke exact binding`() async throws {
        let fixture = try await Self.fixture(includeStaleUnrelatedCandidates: true)
        let proof = try await BrowserNativeWindowBindingCoordinator.bind(
            pageReference: fixture.pageReference,
            nativeTarget: Self.nativeTarget,
            context: fixture.context,
            dependencies: Self.dependencies())

        try await BrowserNativeWindowBindingCoordinator.withRevalidatedMutation(
            pageReference: fixture.pageReference,
            context: fixture.context,
            receiptProviders: Self.providers(),
            mutation: { receipt in
                #expect(receipt == proof.nativeWindowReceipt)
            })

        #expect(await fixture.control.state() == .open)
        await fixture.control.close()
    }

    @Test
    func `Revalidated mutation holds provider and capability teardown gates through dispatch`() async throws {
        let fixture = try await Self.fixture()
        _ = try await BrowserNativeWindowBindingCoordinator.bind(
            pageReference: fixture.pageReference,
            nativeTarget: Self.nativeTarget,
            context: fixture.context,
            dependencies: Self.dependencies())
        let barrier = BindingMutationBarrier()
        let mutationRan = LockedBoolean()
        let mutation = Task { @MainActor in
            try await BrowserNativeWindowBindingCoordinator.withRevalidatedMutation(
                pageReference: fixture.pageReference,
                context: fixture.context,
                receiptProviders: Self.providers())
            { _ in
                await barrier.block()
                mutationRan.value = true
            }
        }
        await barrier.waitUntilBlocked()
        let managerEnded = LockedBoolean()
        let capabilityEnded = LockedBoolean()
        let endManager = Task { @MainActor in
            await fixture.manager.endSession()
            managerEnded.value = true
        }
        let endCapabilities = Task {
            await fixture.capabilities.end()
            capabilityEnded.value = true
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(!managerEnded.value)
        #expect(!capabilityEnded.value)
        await barrier.release()
        try await mutation.value
        await endManager.value
        await endCapabilities.value

        #expect(mutationRan.value)
        #expect(managerEnded.value)
        #expect(capabilityEnded.value)
        #expect(await fixture.control.state() == .closed)
    }

    @Test
    func `Moved tab refuses before mutation and clears the page binding`() async throws {
        let moved = LockedBoolean()
        let fixture = try await Self.fixture(windowID: { moved.value ? 42 : 41 })
        _ = try await BrowserNativeWindowBindingCoordinator.bind(
            pageReference: fixture.pageReference,
            nativeTarget: Self.nativeTarget,
            context: fixture.context,
            dependencies: Self.dependencies())
        moved.value = true
        let mutationRan = LockedBoolean()

        await #expect(throws: BrowserNativeWindowBindingCoordinatorError.correlationRefused) {
            try await BrowserNativeWindowBindingCoordinator.withRevalidatedMutation(
                pageReference: fixture.pageReference,
                context: fixture.context,
                receiptProviders: Self.providers(),
                mutation: { _ in mutationRan.value = true })
        }
        #expect(!mutationRan.value)
        await #expect(throws: BrowserToolNativeWindowBindingError.stalePageReference) {
            _ = try await fixture.capabilities.nativeWindowBinding(
                pageReference: fixture.pageReference,
                sessionBinding: fixture.sessionBinding)
        }
        #expect(fixture.opener.openCount == 1)
        await fixture.control.close()
    }

    @Test
    func `Tab move after correlation refuses at the final authorization boundary`() async throws {
        let windowLookups = LockedInteger()
        let fixture = try await Self.fixture(windowID: {
            windowLookups.increment()
            return windowLookups.value == 6 ? 42 : 41
        })
        _ = try await BrowserNativeWindowBindingCoordinator.bind(
            pageReference: fixture.pageReference,
            nativeTarget: Self.nativeTarget,
            context: fixture.context,
            dependencies: Self.dependencies())
        let mutationRan = LockedBoolean()

        await #expect(throws: BrowserNativeWindowBindingCoordinatorError.correlationRefused) {
            try await BrowserNativeWindowBindingCoordinator.withRevalidatedMutation(
                pageReference: fixture.pageReference,
                context: fixture.context,
                receiptProviders: Self.providers(),
                mutation: { _ in mutationRan.value = true })
        }

        #expect(!mutationRan.value)
        #expect(windowLookups.value == 6)
        await fixture.control.close()
    }

    @Test
    func `Expired bind deadline refuses before private provider lookup`() async throws {
        let fixture = try await Self.fixture()
        let expiredContext = BrowserNativeWindowBindingCoordinator.Context(
            sessionBinding: fixture.sessionBinding,
            capabilities: fixture.capabilities,
            manager: fixture.manager,
            deadline: ContinuousClock.now.advanced(by: .milliseconds(-1)))

        await #expect(throws: BrowserNativeWindowBindingCoordinatorError.deadlineExceeded) {
            _ = try await BrowserNativeWindowBindingCoordinator.bind(
                pageReference: fixture.pageReference,
                nativeTarget: Self.nativeTarget,
                context: expiredContext,
                dependencies: Self.dependencies())
        }

        #expect(fixture.provider.executedTools == ["list_pages"])
        await fixture.control.close()
    }

    @Test
    func `Invalid native receipt keeps its exact bind error classification`() async throws {
        let fixture = try await Self.fixture()
        let invalidProviders = BrowserNativeWindowReceiptResolver.Providers(
            processStartIdentity: { _ in nil },
            windowIdentity: { _ in nil },
            windowMutationIdentity: { _ in nil },
            validateWindowMutationIdentity: { _ in false })

        await #expect(throws: BrowserNativeWindowBindingCoordinatorError.invalidNativeWindow) {
            _ = try await BrowserNativeWindowBindingCoordinator.bind(
                pageReference: fixture.pageReference,
                nativeTarget: Self.nativeTarget,
                context: fixture.context,
                dependencies: .init(receiptProviders: invalidProviders))
        }

        #expect(fixture.provider.executedTools == ["list_pages"])
        await fixture.control.close()
    }

    @Test
    func `Stalled private provider lookup is cancelled at the bind deadline`() async throws {
        let fixture = try await Self.fixture()
        let firstProof = try await BrowserNativeWindowBindingCoordinator.bind(
            pageReference: fixture.pageReference,
            nativeTarget: Self.nativeTarget,
            context: fixture.context,
            dependencies: Self.dependencies())
        let listed = try await fixture.capabilities.project(
            Self.twoPageResponse,
            calls: [BrowserMCPMappedCall(toolName: "list_pages", arguments: [:])],
            resolved: nil,
            sessionBinding: fixture.sessionBinding)
        let pageReferences = try #require(listed.structuredContent?.objectValue?["pages"]?.arrayValue)
            .compactMap { $0.objectValue?["id"]?.stringValue }
        let secondPageReference = try #require(pageReferences.first { $0 != fixture.pageReference })
        try await fixture.capabilities.bindNativeWindow(
            pageReference: secondPageReference,
            sessionBinding: fixture.sessionBinding,
            privateTargetID: "target-b",
            privateBrowserWindowID: .init(rawValue: 41),
            nativeWindowReceipt: firstProof.nativeWindowReceipt)
        fixture.provider.executeHandler = { toolName, _ in
            guard toolName == "get_tab_id" else { return Self.pageResponse }
            try await Task.sleep(for: .seconds(30))
            return ToolResponse.error("unreachable")
        }
        let deadlineContext = BrowserNativeWindowBindingCoordinator.Context(
            sessionBinding: fixture.sessionBinding,
            capabilities: fixture.capabilities,
            manager: fixture.manager,
            deadline: ContinuousClock.now.advanced(by: .milliseconds(40)))
        let startedAt = ContinuousClock.now

        await #expect(throws: BrowserNativeWindowBindingCoordinatorError.deadlineExceeded) {
            _ = try await BrowserNativeWindowBindingCoordinator.bind(
                pageReference: fixture.pageReference,
                nativeTarget: Self.nativeTarget,
                context: deadlineContext,
                dependencies: Self.dependencies())
        }

        #expect(startedAt.duration(to: .now) < .seconds(1))
        #expect(fixture.provider.executedTools.suffix(1) == ["get_tab_id"])
        #expect(await fixture.control.state() == .closed)
        await #expect(throws: BrowserToolNativeWindowBindingError.stalePageReference) {
            _ = try await fixture.capabilities.nativeWindowBinding(
                pageReference: secondPageReference,
                sessionBinding: fixture.sessionBinding)
        }
    }

    @Test
    func `Native control timeout remains deadline exceeded and skips mutation`() async throws {
        let stallTargets = LockedBoolean()
        let fixture = try await Self.fixture(stallTargets: stallTargets)
        _ = try await BrowserNativeWindowBindingCoordinator.bind(
            pageReference: fixture.pageReference,
            nativeTarget: Self.nativeTarget,
            context: fixture.context,
            dependencies: Self.dependencies())
        stallTargets.value = true
        let deadlineContext = BrowserNativeWindowBindingCoordinator.Context(
            sessionBinding: fixture.sessionBinding,
            capabilities: fixture.capabilities,
            manager: fixture.manager,
            deadline: ContinuousClock.now.advanced(by: .milliseconds(40)))
        let mutationRan = LockedBoolean()

        await #expect(throws: BrowserNativeWindowBindingCoordinatorError.deadlineExceeded) {
            try await BrowserNativeWindowBindingCoordinator.withRevalidatedMutation(
                pageReference: fixture.pageReference,
                context: deadlineContext,
                receiptProviders: Self.providers(),
                mutation: { _ in mutationRan.value = true })
        }

        #expect(!mutationRan.value)
        #expect(await fixture.control.state() == .failed(.timedOut(method: "Target.getTargets")))
        await #expect(throws: BrowserToolNativeWindowBindingError.stalePageReference) {
            _ = try await fixture.capabilities.nativeWindowBinding(
                pageReference: fixture.pageReference,
                sessionBinding: fixture.sessionBinding)
        }
    }

    @Test
    func `Control death invalidates every private page binding without reopen`() async throws {
        let fixture = try await Self.fixture()
        _ = try await BrowserNativeWindowBindingCoordinator.bind(
            pageReference: fixture.pageReference,
            nativeTarget: Self.nativeTarget,
            context: fixture.context,
            dependencies: Self.dependencies())
        fixture.transport.inject(.failure(FakeControlTransportError.connectionLost))
        try await Self.waitForControlDeath(fixture.control)
        let mutationRan = LockedBoolean()

        await #expect(throws: BrowserNativeWindowBindingCoordinatorError.controlUnavailable) {
            try await BrowserNativeWindowBindingCoordinator.withRevalidatedMutation(
                pageReference: fixture.pageReference,
                context: fixture.context,
                receiptProviders: Self.providers(),
                mutation: { _ in mutationRan.value = true })
        }
        #expect(!mutationRan.value)
        await #expect(throws: BrowserToolNativeWindowBindingError.stalePageReference) {
            _ = try await fixture.capabilities.nativeWindowBinding(
                pageReference: fixture.pageReference,
                sessionBinding: fixture.sessionBinding)
        }
        #expect(fixture.opener.openCount == 1)
    }

    private struct Fixture {
        let capabilities: BrowserToolCapabilitySession
        let pageReference: String
        let sessionBinding: BrowserMCPExecutionSessionBinding
        let manager: BrowserMCPSessionManager
        let provider: MockBrowserMCPManager
        let control: BrowserMCPDevToolsControlSession
        let transport: FakeControlTransport
        let opener: FakeControlTransportOpener

        var context: BrowserNativeWindowBindingCoordinator.Context {
            .init(
                sessionBinding: self.sessionBinding,
                capabilities: self.capabilities,
                manager: self.manager,
                deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        }
    }

    private static func fixture(
        windowID: @escaping @Sendable () -> Int = { 41 },
        stallTargets: LockedBoolean? = nil,
        includeStaleUnrelatedCandidates: Bool = false) async throws -> Fixture
    {
        let nativeBounds = self.nativeBounds
        let transport = FakeControlTransport { command in
            let request = try BrowserMCPDevToolsControlSessionTests.decodeCommand(command)
            switch request.method {
            case "Browser.getVersion":
                return [.success(BrowserMCPDevToolsControlSessionTests.response(
                    id: request.id,
                    result: ["product": "Chrome/151.0", "protocolVersion": "1.3"]))]
            case "Target.getTargets":
                if stallTargets?.value == true {
                    return []
                }
                var targetInfos: [[String: Any]] = [[
                    "targetId": "page-a",
                    "type": "page",
                    "title": "Example",
                    "url": "https://example.test/",
                ]]
                if includeStaleUnrelatedCandidates {
                    targetInfos.append([
                        "targetId": "page-dead-target",
                        "type": "page",
                        "title": "Closed target",
                        "url": "https://closed-target.test/",
                    ])
                    targetInfos.append([
                        "targetId": "page-dead-window",
                        "type": "page",
                        "title": "Closed window",
                        "url": "https://closed-window.test/",
                    ])
                }
                return [.success(BrowserMCPDevToolsControlSessionTests.response(
                    id: request.id,
                    result: ["targetInfos": targetInfos]))]
            case "Browser.getWindowForTarget":
                let targetID = request.params["targetId"] as? String
                if targetID == "page-dead-target" {
                    return [.success(BrowserMCPDevToolsControlSessionTests.errorResponse(
                        id: request.id,
                        code: -32000,
                        message: "No target with given id"))]
                }
                if targetID == "page-dead-window" {
                    return [.success(BrowserMCPDevToolsControlSessionTests.response(
                        id: request.id,
                        result: ["windowId": 99]))]
                }
                return [.success(BrowserMCPDevToolsControlSessionTests.response(
                    id: request.id,
                    result: ["windowId": windowID()]))]
            case "Browser.getWindowBounds":
                if request.params["windowId"] as? Int == 99 {
                    return [.success(BrowserMCPDevToolsControlSessionTests.errorResponse(
                        id: request.id,
                        code: -32000,
                        message: "Browser window not found"))]
                }
                return [.success(BrowserMCPDevToolsControlSessionTests.response(
                    id: request.id,
                    result: ["bounds": [
                        "left": Int(nativeBounds.origin.x),
                        "top": Int(nativeBounds.origin.y),
                        "width": Int(nativeBounds.width),
                        "height": Int(nativeBounds.height),
                        "windowState": "normal",
                    ]]))]
            default:
                Issue.record("Unexpected CDP method \(request.method)")
                return []
            }
        }
        let opener = FakeControlTransportOpener(transport: transport)
        let connection = try await BrowserMCPDevToolsControlSession.connect(
            BrowserMCPDevToolsControlSessionTests.webSocketURL,
            expectedBrowserID: "browser-a",
            deadline: Self.deadline,
            transportFactory: opener.factory)
        let provider = MockBrowserMCPManager()
        provider.executeHandler = { toolName, arguments in
            switch toolName {
            case "list_pages":
                return Self.pageResponse
            case "get_tab_id":
                #expect(arguments["pageId"] as? Int == 7)
                return ToolResponse(
                    content: [.text(text: "private target", annotations: nil, _meta: nil)],
                    structuredContent: .object(["tabId": .string("target-a")]))
            default:
                return ToolResponse.error("unexpected tool")
            }
        }
        let endpointResolver = BrowserMCPChannelEndpointResolver(
            resolveInitial: { _, _ in
                BrowserMCPDevToolsEndpoint(
                    browserURL: "http://127.0.0.1:9222/",
                    webSocketDebuggerURL: BrowserMCPDevToolsControlSessionTests.webSocketURL.absoluteString,
                    browserID: "browser-a",
                    browserVersion: connection.version.browserVersion,
                    protocolVersion: connection.version.protocolVersion,
                    retainedControlSession: connection.session)
            },
            revalidate: { _, _ in })
        let detectedBrowser = Self.detectedBrowser
        let processStartIdentity = Self.nativeTarget.processStartIdentity
        let manager = BrowserMCPSessionManager(
            serverName: "native-window-binding-test",
            manager: provider,
            detectedBrowsers: { _ in [detectedBrowser] },
            processStartIdentity: { _ in processStartIdentity },
            processBundleIdentifier: { _ in "com.google.Chrome" },
            processCodeSignatureValidator: { _, _, channel in .browserTestIdentity(channel: channel) },
            channelEndpointResolver: endpointResolver,
            environment: [:])
        let connected = try await manager.connect(channel: .stable)
        let sessionBinding = try BrowserMCPExecutionSessionBinding(
            connectionReceipt: #require(connected.connectionReceipt),
            providerSessionEpoch: #require(connected.providerSessionEpoch))
        #expect(sessionBinding.connectionReceipt == Self.connectionReceipt)
        let capabilities = BrowserToolCapabilitySession()
        let listed = try await capabilities.project(
            Self.pageResponse,
            calls: [BrowserMCPMappedCall(toolName: "list_pages", arguments: [:])],
            resolved: nil,
            sessionBinding: sessionBinding)
        let pageReference = try #require(
            listed.structuredContent?.objectValue?["pages"]?.arrayValue?.first?.objectValue?["id"]?.stringValue)
        return Fixture(
            capabilities: capabilities,
            pageReference: pageReference,
            sessionBinding: sessionBinding,
            manager: manager,
            provider: provider,
            control: connection.session,
            transport: transport,
            opener: opener)
    }

    private static func dependencies() -> BrowserNativeWindowBindingCoordinator.Dependencies {
        BrowserNativeWindowBindingCoordinator.Dependencies(receiptProviders: self.providers())
    }

    private static func providers() -> BrowserNativeWindowReceiptResolver.Providers {
        let nativeTarget = self.nativeTarget
        let nativeBounds = self.nativeBounds
        return BrowserNativeWindowReceiptResolver.Providers(
            processStartIdentity: { _ in nativeTarget.processStartIdentity },
            windowIdentity: { windowID in
                SystemWindowIdentity(
                    windowID: windowID,
                    ownerProcessIdentifier: nativeTarget.processIdentifier,
                    ownerProcessStartIdentity: nativeTarget.processStartIdentity,
                    title: "Example",
                    bounds: nativeBounds,
                    layer: 0,
                    alpha: 1,
                    isOnScreen: true,
                    sharingState: .readOnly)
            },
            windowMutationIdentity: { _ in
                WindowMutationIdentity(
                    windowID: Int(nativeTarget.windowID),
                    ownerProcessIdentifier: nativeTarget.processIdentifier,
                    ownerProcessStartIdentity: nativeTarget.processStartIdentity,
                    capturedBounds: nativeBounds,
                    isMinimized: false)
            },
            validateWindowMutationIdentity: { _ in true })
    }

    private static func waitForControlDeath(_ control: BrowserMCPDevToolsControlSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while case .open = await control.state() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            await Task.yield()
        }
    }

    private static var deadline: ContinuousClock.Instant {
        ContinuousClock.now.advanced(by: .seconds(2))
    }

    private static let connectionReceipt = BrowserMCPConnectionReceipt(
        channel: .stable,
        processIdentifier: nativeTarget.processIdentifier,
        processStartIdentity: nativeTarget.processStartIdentity,
        bundleIdentifier: "com.google.Chrome",
        browserURL: "http://127.0.0.1:9222/",
        webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
        devToolsBrowserID: "browser-a",
        browserVersion: "Chrome/151.0",
        protocolVersion: "1.3")
    private static let pageResponse = ToolResponse(
        content: [.text(
            text: "## Pages\n7: Example (https://example.test/) [selected]",
            annotations: nil,
            _meta: nil)],
        structuredContent: .object(["pages": .array([.object([
            "id": .int(7),
            "url": .string("https://example.test/"),
            "title": .string("Example"),
            "selected": .bool(true),
        ])])]))
    private static let twoPageResponse = ToolResponse(
        content: [.text(
            text: "## Pages\n7: Example (https://example.test/) [selected]\n8: Other (https://other.test/)",
            annotations: nil,
            _meta: nil)],
        structuredContent: .object(["pages": .array([
            .object([
                "id": .int(7),
                "url": .string("https://example.test/"),
                "title": .string("Example"),
                "selected": .bool(true),
            ]),
            .object([
                "id": .int(8),
                "url": .string("https://other.test/"),
                "title": .string("Other"),
                "selected": .bool(false),
            ]),
        ])]))
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get { self.lock.withLock { self.storage } }
        set { self.lock.withLock { self.storage = newValue } }
    }
}

private final class LockedInteger: @unchecked Sendable {
    private let lock = NSLock()
    private var integer = 0

    var value: Int {
        self.lock.withLock { self.integer }
    }

    func increment() {
        self.lock.withLock { self.integer += 1 }
    }
}

private actor BindingMutationBarrier {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        self.blocked = true
        self.blockedWaiters.forEach { $0.resume() }
        self.blockedWaiters.removeAll()
        guard !self.released else { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func waitUntilBlocked() async {
        guard !self.blocked else { return }
        await withCheckedContinuation { continuation in
            self.blockedWaiters.append(continuation)
        }
    }

    func release() {
        self.released = true
        self.releaseWaiters.forEach { $0.resume() }
        self.releaseWaiters.removeAll()
    }
}
