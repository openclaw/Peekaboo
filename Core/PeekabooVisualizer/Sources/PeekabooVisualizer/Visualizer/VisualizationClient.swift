//
//  VisualizationClient.swift
//  PeekabooCore
//

import AppKit
import CoreGraphics
import Foundation
import os
import PeekabooFoundation
import PeekabooProtocols

@MainActor
public final class VisualizationClient: @unchecked Sendable {
    private enum ConsoleLogLevel: Int, Comparable {
        case trace = 0
        case verbose = 1
        case debug = 2
        case info = 3
        case notice = 4
        case warning = 5
        case error = 6
        case fault = 7

        static func < (lhs: ConsoleLogLevel, rhs: ConsoleLogLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public static let shared = VisualizationClient()

    private static let macAppBundlePrefix = "boo.peekaboo.mac"

    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "VisualizationClient")
    private let distributedCenter = DistributedNotificationCenter.default()

    private let consoleLogHandler: (String) -> Void
    private var consoleMirroringEnabled: Bool
    private let defaultConsoleLogLevel: ConsoleLogLevel
    private var minimumConsoleLogLevel: ConsoleLogLevel
    private let isRunningInsideMacApp: Bool
    private let cleanupDisabled: Bool // Allows disabling automatic cleanup when deep-debugging transport issues

    private var isEnabled: Bool = true
    private var hasLoggedMissingApp = false
    private var hasPreparedEventStore = false
    private var lastCleanupDate = Date.distantPast
    private let cleanupInterval: TimeInterval = 60

    public init(consoleLogHandler: ((String) -> Void)? = nil) {
        let environment = ProcessInfo.processInfo.environment
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let forcedAppContext = environment["PEEKABOO_VISUALIZER_FORCE_APP"] == "true"
        let isAppBundle = VisualizationClient.isPeekabooMacBundle(identifier: bundleIdentifier)
        self.isRunningInsideMacApp = forcedAppContext || isAppBundle
        self.cleanupDisabled = environment["PEEKABOO_VISUALIZER_DISABLE_CLEANUP"] == "true"

        let envLogLevel = VisualizationClient.parseLogLevel(environment["PEEKABOO_LOG_LEVEL"])
        self.defaultConsoleLogLevel = envLogLevel ?? .warning
        self.minimumConsoleLogLevel = self.defaultConsoleLogLevel

        self.consoleLogHandler = consoleLogHandler ?? VisualizationClient.defaultConsoleLogHandler

        if forcedAppContext, !isAppBundle {
            VisualizationClient.defaultConsoleLogHandler(
                "[Visualizer][INFO] Visualizer client forcing mac-app context via PEEKABOO_VISUALIZER_FORCE_APP")
        }

        let envMirror = VisualizationClient
            .parseBooleanEnvironmentValue(environment["PEEKABOO_VISUALIZER_STDOUT"]) ?? false
        // Default to off unless explicitly enabled via env or the runtime opts in (e.g. --verbose).
        self.consoleMirroringEnabled = envMirror && !self.isRunningInsideMacApp

        if environment["PEEKABOO_VISUAL_FEEDBACK"] == "false" {
            self.isEnabled = false
            self.log(.info, "Visual feedback disabled via environment variable")
        }

        if self.cleanupDisabled {
            self.log(.info, "Visualizer cleanup disabled via PEEKABOO_VISUALIZER_DISABLE_CLEANUP")
        }
    }

    // MARK: - Lifecycle

    public func connect() {
        guard self.isEnabled else { return }
        do {
            try VisualizerEventStore.prepareStorage()
            if !self.hasPreparedEventStore {
                self.hasPreparedEventStore = true
                self.log(.debug, "Visualizer event store prepared")
            }
        } catch {
            self.log(.error, "Failed to prepare visualizer storage: \(error.localizedDescription)")
        }
    }

    public func disconnect() {
        self.log(.debug, "Visualizer client disconnect requested (no-op for notification bridge)")
    }

    public var canDispatchEvents: Bool {
        self.isEnabled && (self.isRunningInsideMacApp || Self.isVisualizerAppRunning())
    }

    // MARK: - Visual Feedback Methods

    public func showScreenshotFlash(in rect: CGRect) async -> Bool {
        guard ProcessInfo.processInfo.environment["PEEKABOO_VISUAL_SCREENSHOTS"] != "false" else {
            self.log(.info, "Screenshot visuals disabled via PEEKABOO_VISUAL_SCREENSHOTS")
            return false
        }

        return self.dispatch(.screenshotFlash(rect: rect))
    }

    public func showWatchCapture(in rect: CGRect) async -> Bool {
        self.dispatch(.watchCapture(rect: rect))
    }

    public func showClickFeedback(at point: CGPoint, type: ClickType) async -> Bool {
        self.dispatch(.clickFeedback(point: point, type: type))
    }

    public func showTypingFeedback(
        keys: [String],
        duration: TimeInterval,
        cadence: TypingCadence? = nil,
        masksTypedText: Bool = false) async -> Bool
    {
        // Product decision: the caption exists to show the user what is being
        // typed on their own screen, so text is verbatim by default — it
        // mirrors content the target app is already displaying. Events are
        // user-local and transient. Secure text fields mask via
        // `masksTypedText` (delivery-focus detection) and
        // PEEKABOO_VISUALIZER_MASK_TYPED_TEXT=true masks everything.
        let mask = masksTypedText || ProcessInfo.processInfo
            .environment["PEEKABOO_VISUALIZER_MASK_TYPED_TEXT"] == "true"
        let safeKeys = Self.maskedTypingKeys(keys, mask: mask)
        return self.dispatch(.typingFeedback(keys: safeKeys, duration: duration, cadence: cadence))
    }

    /// Replaces printable characters with bullets while keeping control-key
    /// glyphs (⏎, ⇥, ⌫…) intact, so the typing HUD shows rhythm without content.
    static func maskedTypingKeys(_ keys: [String], mask: Bool) -> [String] {
        guard mask else { return keys }
        return keys.map { key in
            key.count == 1 ? "•" : key
        }
    }

    public func showScrollFeedback(at point: CGPoint, direction: ScrollDirection, amount: Int) async -> Bool {
        self.dispatch(.scrollFeedback(point: point, direction: direction, amount: amount))
    }

    public func showMouseMovement(from: CGPoint, to: CGPoint, duration: TimeInterval) async -> Bool {
        self.dispatch(.mouseMovement(from: from, to: to, duration: duration))
    }

    public func showSwipeGesture(from: CGPoint, to: CGPoint, duration: TimeInterval) async -> Bool {
        self.dispatch(.swipeGesture(from: from, to: to, duration: duration))
    }

    public func showHotkeyDisplay(keys: [String], duration: TimeInterval = 1.0) async -> Bool {
        self.dispatch(.hotkeyDisplay(keys: keys, duration: duration))
    }

    public func showAppLaunch(appName: String, iconPath: String? = nil) async -> Bool {
        self.dispatch(.appLaunch(name: appName, iconPath: iconPath))
    }

    public func showAppQuit(appName: String, iconPath: String? = nil) async -> Bool {
        self.dispatch(.appQuit(name: appName, iconPath: iconPath))
    }

    public func showWindowOperation(
        _ operation: WindowOperation,
        windowRect: CGRect,
        duration: TimeInterval = 0.5) async -> Bool
    {
        self.dispatch(.windowOperation(operation: operation, rect: windowRect, duration: duration))
    }

    public func showMenuNavigation(menuPath: [String]) async -> Bool {
        self.dispatch(.menuNavigation(path: menuPath))
    }

    public func showDialogInteraction(
        element: DialogElementType,
        elementRect: CGRect,
        action: DialogActionType) async -> Bool
    {
        self.dispatch(.dialogInteraction(elementType: element, rect: elementRect, action: action))
    }

    public func showSpaceSwitch(from: Int, to: Int, direction: SpaceDirection) async -> Bool {
        self.dispatch(.spaceSwitch(from: from, to: to, direction: direction))
    }

    /// Rects must be AppKit screen coordinates (bottom-left origin).
    public func showElementDetection(elements: [String: CGRect], duration: TimeInterval = 2.0) async -> Bool {
        guard ProcessInfo.processInfo.environment["PEEKABOO_VISUAL_ELEMENT_BOXES"] != "false" else {
            self.log(.info, "Element detection visuals disabled via PEEKABOO_VISUAL_ELEMENT_BOXES")
            return false
        }

        return self.dispatch(.elementDetection(elements: elements, duration: duration))
    }

    public func showAnnotatedScreenshot(
        imageData: Data,
        elements: [DetectedElement],
        windowBounds: CGRect,
        duration: TimeInterval = 3.0) async -> Bool
    {
        self.log(.info, "[focus] Client: Annotated screenshot requested with \(elements.count) elements")
        return self.dispatch(
            .annotatedScreenshot(
                imageData: imageData,
                elements: elements,
                windowBounds: windowBounds,
                duration: duration))
    }

    // MARK: - Helpers

    private func dispatch(_ payload: VisualizerEvent.Payload) -> Bool {
        guard self.isEnabled else {
            self.log(.info, "Visualizer disabled, dropping \(payload.eventKindDescription)")
            return false
        }

        guard self.canDispatchEvents else {
            if !self.hasLoggedMissingApp,
               self.consoleMirroringEnabled,
               self.minimumConsoleLogLevel <= .verbose
            {
                self.log(.debug, "Peekaboo.app is not running; visual feedback unavailable until it launches")
                self.hasLoggedMissingApp = true
            }
            return false
        }

        self.hasLoggedMissingApp = false

        do {
            try VisualizerEventStore.prepareStorage()
            let event = VisualizerEvent(payload: payload)
            try VisualizerEventStore.persist(event)
            self.post(event: event)
            self.scheduleCleanupIfNeeded()
            return true
        } catch {
            self.log(.error, "Failed to dispatch visualizer event: \(error.localizedDescription)")
            return false
        }
    }

    private func post(event: VisualizerEvent) {
        let descriptor = "\(event.id.uuidString)|\(event.kind.rawValue)"
        self.log(.debug, "Dispatching visualizer event \(event.kind.rawValue)")
        self.distributedCenter.post(name: .visualizerEventDispatched, object: descriptor)
    }

    private func scheduleCleanupIfNeeded() {
        guard !self.cleanupDisabled else { return }
        let now = Date()
        guard now.timeIntervalSince(self.lastCleanupDate) >= self.cleanupInterval else { return }
        self.lastCleanupDate = now

        Task.detached(priority: .background) {
            try? VisualizerEventStore.cleanup(olderThan: 600)
        }
    }

    private func log(_ level: ConsoleLogLevel, _ message: String) {
        let osLogType: OSLogType = switch level {
        case .trace: .debug
        case .verbose: .debug
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .warning: .default
        case .error: .error
        case .fault: .fault
        }

        self.logger.log(level: osLogType, "\(message, privacy: .public)")

        guard self.consoleMirroringEnabled, level >= self.minimumConsoleLogLevel else { return }

        let emoji = switch level {
        case .trace: "TRACE"
        case .verbose: "VERBOSE"
        case .debug: "DEBUG"
        case .info: "INFO"
        case .notice: "NOTICE"
        case .warning: "WARN"
        case .error: "ERROR"
        case .fault: "FAULT"
        }

        self.consoleLogHandler("[Visualizer][\(emoji)] \(message)")
    }

    private static func parseLogLevel(_ rawValue: String?) -> ConsoleLogLevel? {
        guard let rawValue else { return nil }
        switch rawValue.lowercased() {
        case "trace": return .trace
        case "verbose": return .verbose
        case "debug": return .debug
        case "info": return .info
        case "notice": return .notice
        case "warning", "warn": return .warning
        case "error": return .error
        case "critical", "fault": return .fault
        default: return nil
        }
    }

    private static func consoleLogLevel(from logLevel: LogLevel) -> ConsoleLogLevel {
        switch logLevel {
        case .trace: .trace
        case .debug: .debug
        case .info: .info
        case .warning: .warning
        case .error: .error
        case .critical: .fault
        }
    }

    @MainActor
    public func setConsoleLogLevelOverride(_ newLevel: LogLevel?) {
        if let newLevel {
            self.minimumConsoleLogLevel = Self.consoleLogLevel(from: newLevel)
        } else {
            self.minimumConsoleLogLevel = self.defaultConsoleLogLevel
        }
    }

    /// Enable or disable mirroring visualizer logs to the console. The CLI runtime calls this based on `--verbose`.
    @MainActor
    public func setConsoleMirroringEnabled(_ enabled: Bool) {
        // Never mirror inside the mac app bundle unless explicitly forced via env.
        if self.isRunningInsideMacApp, !self.consoleMirroringEnabled {
            return
        }
        self.consoleMirroringEnabled = enabled || self.consoleMirroringEnabled
    }

    private static func parseBooleanEnvironmentValue(_ rawValue: String?) -> Bool? {
        guard let rawValue else { return nil }
        switch rawValue.lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        case "0", "false", "no", "n", "off":
            return false
        default:
            return nil
        }
    }

    private static func isPeekabooMacBundle(identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier.hasPrefix(Self.macAppBundlePrefix)
    }

    private static func defaultConsoleLogHandler(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }

    private static func isVisualizerAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let identifier = app.bundleIdentifier else { return false }
            return identifier.hasPrefix(Self.macAppBundlePrefix)
        }
    }
}

extension VisualizerEvent.Payload {
    fileprivate var eventKindDescription: String {
        switch self {
        case .screenshotFlash: "screenshotFlash"
        case .watchCapture: "watchCapture"
        case .clickFeedback: "clickFeedback"
        case .typingFeedback: "typingFeedback"
        case .scrollFeedback: "scrollFeedback"
        case .mouseMovement: "mouseMovement"
        case .swipeGesture: "swipeGesture"
        case .hotkeyDisplay: "hotkeyDisplay"
        case .appLaunch: "appLaunch"
        case .appQuit: "appQuit"
        case .windowOperation: "windowOperation"
        case .menuNavigation: "menuNavigation"
        case .dialogInteraction: "dialogInteraction"
        case .spaceSwitch: "spaceSwitch"
        case .elementDetection: "elementDetection"
        case .annotatedScreenshot: "annotatedScreenshot"
        }
    }
}

public enum WindowOperation: String, Sendable, Codable {
    case move
    case resize
    case minimize
    case close
    case maximize
    case setBounds
    case focus
}

public enum SpaceDirection: String, Sendable, Codable {
    case left
    case right
    case up
    case down
}
