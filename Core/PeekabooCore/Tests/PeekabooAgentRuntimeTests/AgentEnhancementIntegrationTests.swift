import CoreGraphics
import Foundation
import PeekabooCore
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime

struct AgentEnhancementIntegrationTests {
    @Test
    @MainActor
    func `desktop context policy merges into existing system prompt`() {
        var messages = [
            ModelMessage.system("Agent system instructions"),
            ModelMessage.user("Use the current desktop"),
        ]

        PeekabooAgentService.upsertDesktopContextPolicy(into: &messages)
        PeekabooAgentService.upsertDesktopContextPolicy(into: &messages)

        let systemMessages = messages.filter { $0.role == .system }
        #expect(systemMessages.count == 1)

        let systemText = systemMessages
            .flatMap(\.content)
            .compactMap { part -> String? in
                if case let .text(text) = part {
                    return text
                }
                return nil
            }
            .joined(separator: "\n")

        #expect(systemText.contains("Agent system instructions"))
        #expect(systemText.contains("[DESKTOP_STATE POLICY]"))
        #expect(systemText.components(separatedBy: "[DESKTOP_STATE POLICY]").count == 2)
        #expect(messages[1].role == .user)
    }

    @Test
    func `desktop context fingerprint tracks prompt-relevant state`() {
        let focusedWindow = FocusedWindowInfo(
            appName: "Notes",
            title: "Draft",
            bounds: CGRect(x: 10, y: 20, width: 300, height: 200),
            processId: 42)
        let base = DesktopContext(
            focusedWindow: focusedWindow,
            cursorPosition: CGPoint(x: 1, y: 2),
            clipboardPreview: "clip",
            recentApps: ["Notes"],
            timestamp: Date(timeIntervalSince1970: 1))

        let timestampOnlyChange = DesktopContext(
            focusedWindow: focusedWindow,
            cursorPosition: CGPoint(x: 1, y: 2),
            clipboardPreview: "clip",
            recentApps: ["Notes"],
            timestamp: Date(timeIntervalSince1970: 2))

        let cursorChange = DesktopContext(
            focusedWindow: focusedWindow,
            cursorPosition: CGPoint(x: 500, y: 600),
            clipboardPreview: "clip",
            recentApps: ["Notes"],
            timestamp: Date(timeIntervalSince1970: 1))
        let recentAppsChange = DesktopContext(
            focusedWindow: focusedWindow,
            cursorPosition: CGPoint(x: 1, y: 2),
            clipboardPreview: "clip",
            recentApps: ["Safari", "Notes"],
            timestamp: Date(timeIntervalSince1970: 1))

        let clipboardChange = DesktopContext(
            focusedWindow: focusedWindow,
            cursorPosition: CGPoint(x: 1, y: 2),
            clipboardPreview: "new clip",
            recentApps: ["Notes"],
            timestamp: Date(timeIntervalSince1970: 1))
        let movedWindow = FocusedWindowInfo(
            appName: "Notes",
            title: "Draft",
            bounds: CGRect(x: 80, y: 120, width: 640, height: 480),
            processId: 42)
        let boundsChange = DesktopContext(
            focusedWindow: movedWindow,
            cursorPosition: CGPoint(x: 1, y: 2),
            clipboardPreview: "clip",
            recentApps: ["Notes"],
            timestamp: Date(timeIntervalSince1970: 1))

        #expect(DesktopContextFingerprint(context: base) == DesktopContextFingerprint(context: timestampOnlyChange))
        #expect(DesktopContextFingerprint(context: base) != DesktopContextFingerprint(context: cursorChange))
        #expect(DesktopContextFingerprint(context: base) != DesktopContextFingerprint(context: recentAppsChange))
        #expect(DesktopContextFingerprint(context: base) != DesktopContextFingerprint(context: clipboardChange))
        #expect(DesktopContextFingerprint(context: base) != DesktopContextFingerprint(context: boundsChange))
    }

    @Test
    @MainActor
    func `desktop context data stays before active user turn`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices(), defaultModel: .openai(.gpt55))
        var messages = [
            ModelMessage.system("Agent system instructions"),
            ModelMessage.user("Click the current OK button"),
        ]
        var state = DesktopContextRefreshState()
        let eventHandler: EventHandler? = nil

        _ = await service.refreshDesktopContextIfNeeded(
            into: &messages,
            options: AgentEnhancementOptions(contextAware: true),
            tools: [],
            state: &state,
            eventHandler: eventHandler)

        let dataIndex = try #require(messages.firstIndex { Self.text(in: $0).contains("<DESKTOP_STATE ") })
        let userIndex = try #require(messages.lastIndex { Self.text(in: $0).contains("Click the current OK button") })

        #expect(dataIndex < userIndex)
        #expect(messages.last?.role == .user)
    }

    @Test
    @MainActor
    func `desktop context data stays after completed tool turns`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices(), defaultModel: .openai(.gpt55))
        var messages = [
            ModelMessage.system("Agent system instructions"),
            ModelMessage.user("Click the current OK button"),
            ModelMessage.assistant("I will click it."),
            ModelMessage(role: .tool, content: [.text("click succeeded")]),
        ]
        var state = DesktopContextRefreshState()
        let eventHandler: EventHandler? = nil

        _ = await service.refreshDesktopContextIfNeeded(
            into: &messages,
            options: AgentEnhancementOptions(contextAware: true),
            tools: [],
            state: &state,
            eventHandler: eventHandler)

        let dataIndex = try #require(messages.firstIndex { Self.text(in: $0).contains("<DESKTOP_STATE ") })
        let toolIndex = try #require(messages.lastIndex { $0.role == .tool })

        #expect(dataIndex > toolIndex)
        #expect(messages.last.map { Self.text(in: $0).contains("<DESKTOP_STATE ") } == true)
    }

    @Test
    func `verification options can target accessibility mutation tools`() {
        let options = AgentEnhancementOptions(
            verifyActions: true,
            verifyActionTypes: [.setValue, .performAction])

        #expect(options.verifyActionTypes.contains(.setValue))
        #expect(options.verifyActionTypes.contains(.performAction))
        #expect(VerifiableActionType.setValue.isMutating)
        #expect(VerifiableActionType.performAction.isMutating)
    }

    @Test
    func `broad verification skips observation tools but includes mutating tools`() {
        let options = AgentEnhancementOptions(verifyActions: true)

        let readOnlyTools = [
            "clipboard",
            "inspect_ui",
            "see",
            "done",
            "need_info",
            "list_screens",
            "list_apps",
            "shell",
            "sleep",
        ]
        let mutatingTools = [
            "app",
            "browser",
            "click",
            "dock",
            "drag",
            "hotkey",
            "launch_app",
            "paste",
            "perform_action",
            "scroll",
            "set_value",
            "space",
            "swipe",
            "type",
            "window",
        ]

        for toolName in readOnlyTools {
            #expect(!ActionVerifier.shouldVerify(toolName: toolName, options: options))
        }

        for toolName in mutatingTools {
            #expect(ActionVerifier.shouldVerify(toolName: toolName, options: options))
        }
    }

    @Test
    func `broad verification uses action arguments to skip read-only subcommands`() {
        let options = AgentEnhancementOptions(verifyActions: true)

        #expect(!ActionVerifier.shouldVerify(toolName: "app", arguments: ["action": "list"], options: options))
        #expect(ActionVerifier.shouldVerify(toolName: "app", arguments: ["action": "launch"], options: options))
        #expect(!ActionVerifier.shouldVerify(toolName: "clipboard", arguments: ["action": "set"], options: options))
        #expect(!ActionVerifier.shouldVerify(toolName: "dialog", arguments: ["action": "list"], options: options))
        #expect(ActionVerifier.shouldVerify(toolName: "dialog", arguments: ["action": "click"], options: options))
        #expect(!ActionVerifier.shouldVerify(toolName: "dock", arguments: ["action": "list"], options: options))
        #expect(ActionVerifier.shouldVerify(toolName: "dock", arguments: ["action": "hide"], options: options))
        #expect(!ActionVerifier.shouldVerify(toolName: "menu", arguments: ["action": "list"], options: options))
        #expect(!ActionVerifier.shouldVerify(toolName: "menu", arguments: ["action": "list-all"], options: options))
        #expect(ActionVerifier.shouldVerify(toolName: "menu", arguments: ["action": "click"], options: options))
        #expect(!ActionVerifier.shouldVerify(toolName: "move", arguments: ["to": "100,100"], options: options))
        #expect(!ActionVerifier.shouldVerify(toolName: "space", arguments: ["action": "list"], options: options))
        #expect(ActionVerifier.shouldVerify(toolName: "space", arguments: ["action": "switch"], options: options))
        #expect(!ActionVerifier.shouldVerify(toolName: "browser", arguments: ["action": "snapshot"], options: options))
        #expect(!ActionVerifier.shouldVerify(toolName: "browser", arguments: ["action": "wait_for"], options: options))
        #expect(ActionVerifier.shouldVerify(toolName: "browser", arguments: ["action": "click"], options: options))
    }

    @Test
    func `tool argument stringification handles primitive values`() {
        let strings = AgentToolArguments([
            "flag": true,
            "count": 2,
            "ratio": 1.5,
            "name": "button",
        ]).stringDictionary

        #expect(strings["flag"] == "true")
        #expect(strings["count"] == "2")
        #expect(strings["ratio"] == "1.5")
        #expect(strings["name"] == "button")
    }

    @Test
    @MainActor
    func `verification capture failure preserves successful tool result`() async throws {
        let service = try PeekabooAgentService(
            services: CaptureOverrideServices(screenCapture: VerificationFailingScreenCaptureService()),
            defaultModel: .openai(.gpt55))
        let tool = AgentTool(
            name: "click",
            description: "test click",
            parameters: AgentToolParameters())
        { _ in
            AnyAgentToolValue(object: [
                "success": AnyAgentToolValue(bool: true),
                "clicked": AnyAgentToolValue(bool: true),
            ])
        }

        let execution = try await service.executeToolWithVerification(
            tool,
            arguments: AgentToolArguments([:]),
            executionContext: ToolExecutionContext(),
            options: AgentEnhancementOptions(verifyActions: true))

        let payload = try #require(try execution.result.toJSON() as? [String: Any])
        #expect(payload["success"] as? Bool == true)
        #expect(payload["clicked"] as? Bool == true)
        #expect(execution.verification?.success == true)
        #expect(execution.verification?.confidence == 0)
        #expect(execution.verification?.observation.contains("verification was unavailable") == true)
    }

    @Test
    @MainActor
    func `encoded tool errors skip verification capture`() async throws {
        let screenCapture = RecordingRegionScreenCaptureService()
        let service = try PeekabooAgentService(
            services: CaptureOverrideServices(screenCapture: screenCapture),
            defaultModel: .openai(.gpt55))
        let tool = AgentTool(
            name: "click",
            description: "test click",
            parameters: AgentToolParameters())
        { _ in
            AnyAgentToolValue(string: "Error: Missing required parameter")
        }

        let execution = try await service.executeToolWithVerification(
            tool,
            arguments: AgentToolArguments([:]),
            executionContext: ToolExecutionContext(),
            options: AgentEnhancementOptions(verifyActions: true))

        #expect(screenCapture.capturedScreenCount == 0)
        #expect(screenCapture.capturedArea == nil)
        #expect(execution.verification == nil)
    }

    @Test
    @MainActor
    func `verification capture rethrows cancellation`() async throws {
        let service = try PeekabooAgentService(
            services: CaptureOverrideServices(screenCapture: CancellationScreenCaptureService()),
            defaultModel: .openai(.gpt55))
        let tool = AgentTool(
            name: "click",
            description: "test click",
            parameters: AgentToolParameters())
        { _ in
            AnyAgentToolValue(object: [
                "success": AnyAgentToolValue(bool: true),
            ])
        }

        var cancelled = false
        do {
            _ = try await service.executeToolWithVerification(
                tool,
                arguments: AgentToolArguments([:]),
                executionContext: ToolExecutionContext(),
                options: AgentEnhancementOptions(verifyActions: true))
        } catch is CancellationError {
            cancelled = true
        }

        #expect(cancelled)
    }

    @Test
    @MainActor
    func `region focused verification parses pointer coordinates`() async throws {
        let screenCapture = RecordingRegionScreenCaptureService()
        let service = try PeekabooAgentService(
            services: CaptureOverrideServices(screenCapture: screenCapture),
            defaultModel: .openai(.gpt55))
        let tool = AgentTool(
            name: "click",
            description: "test click",
            parameters: AgentToolParameters())
        { _ in
            AnyAgentToolValue(object: [
                "success": AnyAgentToolValue(bool: true),
            ])
        }

        let execution = try await service.executeToolWithVerification(
            tool,
            arguments: AgentToolArguments(["coords": "100,200"]),
            executionContext: ToolExecutionContext(),
            options: AgentEnhancementOptions(
                verifyActions: true,
                regionFocusAfterAction: true,
                regionCaptureRadius: 10))

        #expect(screenCapture.capturedScreenCount == 0)
        let rect = try #require(screenCapture.capturedArea)
        #expect(rect.origin.x == 90)
        #expect(rect.origin.y == 190)
        #expect(rect.width == 20)
        #expect(rect.height == 20)
        #expect(execution.verification?.observation.contains("verification was unavailable") == true)
    }

    private static func text(in message: ModelMessage) -> String {
        message.content.compactMap { part -> String? in
            if case let .text(text) = part {
                return text
            }
            return nil
        }.joined(separator: "\n")
    }
}

@MainActor
private final class CaptureOverrideServices: PeekabooServiceProviding {
    private let base = PeekabooServices()
    private let screenCaptureOverride: any ScreenCaptureServiceProtocol

    init(screenCapture: any ScreenCaptureServiceProtocol) {
        self.screenCaptureOverride = screenCapture
    }

    var logging: any LoggingServiceProtocol {
        self.base.logging
    }

    var desktopObservation: any DesktopObservationServiceProtocol {
        self.base.desktopObservation
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        self.screenCaptureOverride
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

    var configuration: ConfigurationManager {
        self.base.configuration
    }

    var process: any ProcessServiceProtocol {
        self.base.process
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

    func ensureVisualizerConnection() {}
}

@MainActor
private final class VerificationFailingScreenCaptureService: ScreenCaptureServiceProtocol {
    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw VerificationCaptureTestError.captureFailed
    }

    func captureWindow(
        appIdentifier _: String,
        windowIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw VerificationCaptureTestError.captureFailed
    }

    func captureWindow(
        windowID _: CGWindowID,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw VerificationCaptureTestError.captureFailed
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw VerificationCaptureTestError.captureFailed
    }

    func captureArea(
        _: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw VerificationCaptureTestError.captureFailed
    }

    func hasScreenRecordingPermission() async -> Bool {
        false
    }
}

private enum VerificationCaptureTestError: Error {
    case captureFailed
}

@MainActor
private final class RecordingRegionScreenCaptureService: ScreenCaptureServiceProtocol {
    var capturedArea: CGRect?
    var capturedScreenCount = 0

    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.capturedScreenCount += 1
        throw VerificationCaptureTestError.captureFailed
    }

    func captureWindow(
        appIdentifier _: String,
        windowIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw VerificationCaptureTestError.captureFailed
    }

    func captureWindow(
        windowID _: CGWindowID,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw VerificationCaptureTestError.captureFailed
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw VerificationCaptureTestError.captureFailed
    }

    func captureArea(
        _ rect: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.capturedArea = rect
        throw VerificationCaptureTestError.captureFailed
    }

    func hasScreenRecordingPermission() async -> Bool {
        false
    }
}

@MainActor
private final class CancellationScreenCaptureService: ScreenCaptureServiceProtocol {
    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw CancellationError()
    }

    func captureWindow(
        appIdentifier _: String,
        windowIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw CancellationError()
    }

    func captureWindow(
        windowID _: CGWindowID,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw CancellationError()
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw CancellationError()
    }

    func captureArea(
        _: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw CancellationError()
    }

    func hasScreenRecordingPermission() async -> Bool {
        false
    }
}
