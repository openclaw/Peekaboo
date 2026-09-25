import CoreGraphics
import Foundation
import PeekabooAutomation
import PeekabooAutomationKitTestSupport
import PeekabooCore
import PeekabooFoundation
import Tachikoma
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAgentRuntime

@MainActor
struct AgentDesktopContextPolicyTests {
    @Test(arguments: [false, true])
    func `disabled context skips every automatic desktop read`(clipboardToolAvailable: Bool) async throws {
        let sessionDirectory = Self.sessionDirectory()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let services = DesktopContextPolicyServices()
        let agent = try Self.agent(services: services, sessionDirectory: sessionDirectory)
        let options = AgentEnhancementOptions(
            contextAware: false,
            verifyActions: true,
            maxVerificationRetries: 3,
            verifyActionTypes: [.click, .type],
            smartCapture: true,
            changeThreshold: 0.25,
            regionFocusAfterAction: true,
            regionCaptureRadius: 123)
        var messages = Self.messages()
        var state = DesktopContextRefreshState()

        for _ in 0..<2 {
            let refreshed = await agent.refreshDesktopContextIfNeeded(
                into: &messages,
                options: options,
                tools: Self.tools(includeClipboard: clipboardToolAvailable),
                state: &state,
                eventHandler: nil)
            #expect(!refreshed)
        }

        Self.expectReads(services, count: 0, clipboardCount: 0)
        #expect(services.requestedServices.isEmpty)
        #expect(messages.map(\.role) == [.system, .user])
        #expect(messages.map(Self.text) == ["Synthetic system instructions", "A text-only task"])
        #expect(state.lastFingerprint == nil)
        #expect(!state.policyInjected)
        #expect(agent.cachedSmartCaptureService == nil)
        #expect(options.verifyActions)
        #expect(options.verifyActionTypes == [.click, .type])
        #expect(options.maxVerificationRetries == 3)
        #expect(options.smartCapture)
        #expect(options.changeThreshold == 0.25)
        #expect(options.regionFocusAfterAction)
        #expect(options.regionCaptureRadius == 123)
    }

    @Test(arguments: [false, true])
    func `default context gathers synthetic desktop state and gates clipboard`(
        clipboardToolAvailable: Bool) async throws
    {
        let sessionDirectory = Self.sessionDirectory()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let services = DesktopContextPolicyServices()
        let agent = try Self.agent(services: services, sessionDirectory: sessionDirectory)
        let options = AgentEnhancementOptions.default
        var messages = Self.messages()
        var state = DesktopContextRefreshState()

        let refreshed = await agent.refreshDesktopContextIfNeeded(
            into: &messages,
            options: options,
            tools: Self.tools(includeClipboard: clipboardToolAvailable),
            state: &state,
            eventHandler: nil)

        #expect(options.contextAware)
        #expect(!options.verifyActions)
        #expect(!options.smartCapture)
        #expect(!options.regionFocusAfterAction)
        #expect(refreshed)
        Self.expectReads(services, count: 1, clipboardCount: clipboardToolAvailable ? 1 : 0)
        let expectedServices = ["applications", "applications", "windows", "automation"] +
            (clipboardToolAvailable ? ["clipboard"] : [])
        #expect(services.requestedServices.sorted() == expectedServices.sorted())
        #expect(state.policyInjected)
        let fingerprint = try #require(state.lastFingerprint)
        #expect(fingerprint.appName == "Synthetic Editor")
        #expect(fingerprint.windowTitle == "Synthetic Draft")
        #expect(fingerprint.cursorPosition == CGPoint(x: 123, y: 456))
        #expect(fingerprint.recentApps == ["Synthetic Editor", "Synthetic Browser"])
        #expect(fingerprint.clipboardPreview == (clipboardToolAvailable ? "synthetic clipboard" : nil))
        let observedContextMessage = messages.first { $0.isDesktopContextDataMessage }
        let contextMessage = try #require(observedContextMessage)
        let contextText = Self.text(contextMessage)
        #expect(contextText.contains("Synthetic Editor"))
        #expect(contextText.contains("Synthetic Draft"))
        #expect(contextText.contains("123, 456"))
        #expect(contextText.contains("Synthetic Browser"))
        #expect(contextText.contains("synthetic clipboard") == clipboardToolAvailable)
        #expect(try Self.text(#require(messages.last)) == "A text-only task")
        #expect(agent.cachedSmartCaptureService == nil)
    }

    @Test
    func `disabling context after an earlier refresh leaves history intact without new reads`() async throws {
        let sessionDirectory = Self.sessionDirectory()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let services = DesktopContextPolicyServices()
        let agent = try Self.agent(services: services, sessionDirectory: sessionDirectory)
        let tools = Self.tools(includeClipboard: true)
        var messages = Self.messages()
        var state = DesktopContextRefreshState()
        _ = await agent.refreshDesktopContextIfNeeded(
            into: &messages, options: .default, tools: tools, state: &state, eventHandler: nil)
        let priorFingerprint = try #require(state.lastFingerprint)
        let priorMessages = messages.map(Self.text)
        let priorRoles = messages.map(\.role)
        let priorServiceRequests = services.requestedServices

        let refreshed = await agent.refreshDesktopContextIfNeeded(
            into: &messages,
            options: AgentEnhancementOptions(contextAware: false),
            tools: tools,
            state: &state,
            eventHandler: nil)

        #expect(!refreshed)
        Self.expectReads(services, count: 1, clipboardCount: 1)
        #expect(services.requestedServices == priorServiceRequests)
        #expect(messages.map(Self.text) == priorMessages)
        #expect(messages.map(\.role) == priorRoles)
        #expect(state.lastFingerprint == priorFingerprint)
        #expect(state.policyInjected)
    }

    private static func sessionDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agent-desktop-context-\(UUID())")
    }

    private static func agent(
        services: DesktopContextPolicyServices,
        sessionDirectory: URL) throws -> PeekabooAgentService
    {
        try PeekabooAgentService(
            services: services,
            defaultModel: .openai(.gpt55),
            sessionManager: AgentSessionManager(sessionDirectory: sessionDirectory))
    }

    private static func messages() -> [ModelMessage] {
        [.system("Synthetic system instructions"), .user("A text-only task")]
    }

    private static func tools(includeClipboard: Bool) -> [AgentTool] {
        guard includeClipboard else { return [] }
        let clipboard = AgentTool(
            name: "clipboard",
            description: "Synthetic clipboard tool",
            parameters: AgentToolParameters())
        { _ in
            fatalError("Automatic desktop context must not execute a tool")
        }
        return [clipboard]
    }

    private static func text(_ message: ModelMessage) -> String {
        message.content.compactMap { part in
            if case let .text(value) = part {
                return value
            }
            return nil
        }.joined(separator: "\n")
    }

    private static func expectReads(_ services: DesktopContextPolicyServices, count: Int, clipboardCount: Int) {
        #expect(services.applicationStub.frontmostApplicationCallCount == count)
        #expect(services.applicationStub.listApplicationsCallCount == count)
        #expect(services.windowStub.focusedWindowCallCount == count)
        #expect(services.automationStub.cursorReadCount == count)
        #expect(services.clipboardStub.readCount == clipboardCount)
        #expect(services.applicationStub.activationIdentifiers.isEmpty)
        #expect(services.windowStub.focusRequests.isEmpty)
    }
}

/// Only the five automatic context reads are available; all other service access fails without native work.
@MainActor
private final class DesktopContextPolicyServices: PeekabooServiceProviding {
    let applicationStub = ScriptedApplicationInventoryService(applications: [
        ServiceApplicationInfo(
            processIdentifier: 41,
            bundleIdentifier: "com.example.synthetic-browser",
            name: "Synthetic Browser",
            activationPolicy: .regular),
        ServiceApplicationInfo(
            processIdentifier: 42,
            bundleIdentifier: "com.example.synthetic-editor",
            name: "Synthetic Editor",
            isActive: true,
            activationPolicy: .regular),
    ])
    let windowStub = ScriptedWindowInventoryService(focusedWindow: ServiceWindowInfo(
        windowID: 77, title: "Synthetic Draft", bounds: CGRect(x: 10, y: 20, width: 300, height: 200)))
    let automationStub = DesktopContextCursorStub()
    let clipboardStub = DesktopContextClipboardStub()
    private(set) var requestedServices: [String] = []

    var applications: any ApplicationServiceProtocol {
        self.requestedServices.append("applications")
        return self.applicationStub
    }

    var windows: any WindowManagementServiceProtocol {
        self.requestedServices.append("windows")
        return self.windowStub
    }

    var automation: any UIAutomationServiceProtocol {
        self.requestedServices.append("automation")
        return self.automationStub
    }

    var clipboard: any ClipboardServiceProtocol {
        self.requestedServices.append("clipboard")
        return self.clipboardStub
    }

    var agent: (any AgentServiceProtocol)? {
        nil
    }

    var logging: any LoggingServiceProtocol {
        fatalError("Unexpected logging service")
    }

    var desktopObservation: any DesktopObservationServiceProtocol {
        fatalError("Unexpected observation")
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        fatalError("Unexpected capture")
    }

    var menu: any MenuServiceProtocol {
        fatalError("Unexpected menu")
    }

    var dock: any DockServiceProtocol {
        fatalError("Unexpected Dock")
    }

    var dialogs: any DialogServiceProtocol {
        fatalError("Unexpected dialogs")
    }

    var snapshots: any SnapshotManagerProtocol {
        fatalError("Unexpected snapshots")
    }

    var files: any FileServiceProtocol {
        fatalError("Unexpected files")
    }

    var configuration: ConfigurationManager {
        fatalError("Unexpected configuration")
    }

    var permissions: PermissionsService {
        fatalError("Unexpected permissions")
    }

    var audioInput: AudioInputService {
        fatalError("Unexpected audio")
    }

    var screens: any ScreenServiceProtocol {
        fatalError("Unexpected screens")
    }

    var browser: any BrowserMCPClientProviding {
        fatalError("Unexpected browser")
    }

    func permissionsStatus() async throws -> PermissionsStatus {
        fatalError("Unexpected permission probe")
    }

    func ensureVisualizerConnection() {
        fatalError("Unexpected visualizer connection")
    }
}

@MainActor
private final class DesktopContextClipboardStub: ClipboardServiceProtocol {
    private(set) var readCount = 0

    func get(prefer uti: UTType?) throws -> ClipboardReadResult? {
        self.readCount += 1
        #expect(uti == .plainText)
        return ClipboardReadResult(
            utiIdentifier: UTType.plainText.identifier,
            data: Data("synthetic clipboard".utf8),
            textPreview: "synthetic clipboard")
    }

    func set(_: ClipboardWriteRequest) throws -> ClipboardReadResult {
        fatalError("Unexpected clipboard write")
    }

    func clear() {
        fatalError("Unexpected clipboard clear")
    }

    func save(slot _: String) throws {
        fatalError("Unexpected clipboard save")
    }

    func restore(slot _: String) throws -> ClipboardReadResult {
        fatalError("Unexpected clipboard restore")
    }
}

@MainActor
private final class DesktopContextCursorStub: UIAutomationServiceProtocol {
    private(set) var cursorReadCount = 0

    func currentMouseLocation() -> CGPoint? {
        self.cursorReadCount += 1
        return CGPoint(x: 123, y: 456)
    }

    func detectElements(in _: Data, snapshotId _: String?, windowContext _: WindowContext?) async throws
        -> ElementDetectionResult
    {
        fatalError("Unexpected element detection")
    }

    func click(target _: ClickTarget, clickType _: ClickType, snapshotId _: String?) async throws {
        fatalError("Unexpected click")
    }

    func type(text _: String, target _: String?, clearExisting _: Bool, typingDelay _: Int, snapshotId _: String?) async
    throws {
        fatalError("Unexpected typing")
    }

    func typeActions(_: [TypeAction], cadence _: TypingCadence, snapshotId _: String?) async throws -> TypeResult {
        fatalError("Unexpected typing")
    }

    func scroll(_: ScrollRequest) async throws {
        fatalError("Unexpected scrolling")
    }

    func hotkey(keys _: String, holdDuration _: Int) async throws {
        fatalError("Unexpected hotkey")
    }

    func swipe(
        from _: CGPoint,
        to _: CGPoint,
        duration _: Int,
        steps _: Int,
        profile _: MouseMovementProfile) async throws
    {
        fatalError("Unexpected swipe")
    }

    func hasAccessibilityPermission() async -> Bool {
        fatalError("Unexpected Accessibility probe")
    }

    func waitForElement(target _: ClickTarget, timeout _: TimeInterval, snapshotId _: String?) async throws
        -> WaitForElementResult
    {
        fatalError("Unexpected element wait")
    }

    func drag(_: DragOperationRequest) async throws {
        fatalError("Unexpected drag")
    }

    func moveMouse(to _: CGPoint, duration _: Int, steps _: Int, profile _: MouseMovementProfile) async throws {
        fatalError("Unexpected cursor move")
    }

    func getFocusedElement() -> UIFocusInfo? {
        fatalError("Unexpected focused element read")
    }

    func findElement(matching _: UIElementSearchCriteria, in _: String?) async throws -> DetectedElement {
        fatalError("Unexpected element lookup")
    }

    func inspectAccessibilityTree(windowContext _: WindowContext?) async throws -> ElementDetectionResult {
        fatalError("Unexpected Accessibility inspection")
    }
}
