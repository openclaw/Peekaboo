//
//  VisualizerEventStore.swift
//  PeekabooCore
//

import CoreGraphics
import Foundation
import os

#if VISUALIZER_VERBOSE_LOGS
@inline(__always)
private func visualizerDebugLog(_ message: @autoclosure () -> String) {
    NSLog("%@", message())
}
#else
@inline(__always)
private func visualizerDebugLog(_ message: @autoclosure () -> String) {}
#endif
import PeekabooFoundation
import PeekabooProtocols

public enum VisualizerEventKind: String, Codable, Sendable {
    case screenshotFlash
    case watchCapture
    case clickFeedback
    case typingFeedback
    case scrollFeedback
    case mouseMovement
    case swipeGesture
    case hotkeyDisplay
    case appLaunch
    case appQuit
    case windowOperation
    case menuNavigation
    case dialogInteraction
    case spaceSwitch
    case elementDetection
    case annotatedScreenshot
}

public struct VisualizerEvent: Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let payload: Payload

    public init(id: UUID = UUID(), createdAt: Date = Date(), payload: Payload) {
        self.id = id
        self.createdAt = createdAt
        self.payload = payload
    }

    public var kind: VisualizerEventKind {
        switch self.payload {
        case .screenshotFlash:
            .screenshotFlash
        case .watchCapture:
            .watchCapture
        case .clickFeedback:
            .clickFeedback
        case .typingFeedback:
            .typingFeedback
        case .scrollFeedback:
            .scrollFeedback
        case .mouseMovement:
            .mouseMovement
        case .swipeGesture:
            .swipeGesture
        case .hotkeyDisplay:
            .hotkeyDisplay
        case .appLaunch:
            .appLaunch
        case .appQuit:
            .appQuit
        case .windowOperation:
            .windowOperation
        case .menuNavigation:
            .menuNavigation
        case .dialogInteraction:
            .dialogInteraction
        case .spaceSwitch:
            .spaceSwitch
        case .elementDetection:
            .elementDetection
        case .annotatedScreenshot:
            .annotatedScreenshot
        }
    }

    public enum Payload: Codable, Sendable {
        case screenshotFlash(rect: CGRect)
        case watchCapture(rect: CGRect)
        case clickFeedback(point: CGPoint, type: ClickType)
        case typingFeedback(keys: [String], duration: TimeInterval, cadence: TypingCadence? = nil)
        case scrollFeedback(point: CGPoint, direction: ScrollDirection, amount: Int)
        case mouseMovement(from: CGPoint, to: CGPoint, duration: TimeInterval)
        case swipeGesture(from: CGPoint, to: CGPoint, duration: TimeInterval)
        case hotkeyDisplay(keys: [String], duration: TimeInterval)
        case appLaunch(name: String, iconPath: String?)
        case appQuit(name: String, iconPath: String?)
        case windowOperation(operation: WindowOperation, rect: CGRect, duration: TimeInterval)
        case menuNavigation(path: [String])
        case dialogInteraction(elementType: DialogElementType, rect: CGRect, action: DialogActionType)
        case spaceSwitch(from: Int, to: Int, direction: SpaceDirection)
        // Rects are AppKit screen coordinates; senders convert from
        // accessibility space before dispatch.
        case elementDetection(elements: [String: CGRect], duration: TimeInterval)
        case annotatedScreenshot(
            imageData: Data,
            elements: [DetectedElement],
            windowBounds: CGRect,
            duration: TimeInterval)
    }
}

public enum VisualizerEventStore {
    public static let notificationName = Notification.Name("boo.peekaboo.visualizer.event")

    private static let logger = Logger(subsystem: "boo.peekaboo.core", category: "VisualizerEventStore")

    private static let storageEnvKey = "PEEKABOO_VISUALIZER_STORAGE"
    private static let appGroupEnvKey = "PEEKABOO_VISUALIZER_APP_GROUP"
    private static let storageRootName = "PeekabooShared"
    private static let eventsFolderName = "VisualizerEvents"
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    @discardableResult
    public static func prepareStorage() throws -> URL {
        try self.eventsDirectory()
    }

    @discardableResult
    public static func persist(_ event: VisualizerEvent) throws -> URL {
        let directory = try eventsDirectory()
        let url = directory.appendingPathComponent("\(event.id.uuidString).json", isDirectory: false)
        // Shared JSON is the handoff contract between CLI/MCP processes and Peekaboo.app
        let data = try self.encoder.encode(event)
        try data.write(to: url, options: [.atomic])
        #if DEBUG
        let proc = ProcessInfo.processInfo.processName
        visualizerDebugLog("[VisualizerEventStore][\(proc)] persisted event \(event.id) at \(url.path)")
        #endif
        return url
    }

    public static func loadEvent(id: UUID) throws -> VisualizerEvent {
        let url = try eventURL(for: id)
        #if DEBUG
        if !FileManager.default.fileExists(atPath: url.path) {
            self.logger.error("Visualizer event file missing at \(url.path, privacy: .public)")
            let proc = ProcessInfo.processInfo.processName
            visualizerDebugLog("[VisualizerEventStore][\(proc)] missing event file: \(url.path)")
        }
        #endif
        let data = try Data(contentsOf: url)
        return try self.decoder.decode(VisualizerEvent.self, from: data)
    }

    public static func removeEvent(id: UUID) throws {
        let url = try eventURL(for: id)
        try FileManager.default.removeItem(at: url)
    }

    public static func cleanup(olderThan age: TimeInterval) throws {
        let directory = try eventsDirectory()
        let resources: [URLResourceKey] = [.contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resources,
            options: [.skipsHiddenFiles])

        let cutoff = Date().addingTimeInterval(-age)
        for file in files where file.pathExtension == "json" {
            let values = try file.resourceValues(forKeys: Set(resources))
            let modified = values.contentModificationDate ?? Date()
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
                #if DEBUG
                let proc = ProcessInfo.processInfo.processName
                let cleanupMessage = """
                [VisualizerEventStore][\(proc)] cleanup removed \(file.path)
                (modified \(modified))
                """
                visualizerDebugLog(cleanupMessage)
                #endif
            }
        }
    }

    // MARK: - Helpers

    private static func eventsDirectory() throws -> URL {
        let directory = self.baseDirectory().appendingPathComponent(self.eventsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.logger.debug("Visualizer events directory: \(directory.path)")
        #if DEBUG
        let proc = ProcessInfo.processInfo.processName
        visualizerDebugLog("[VisualizerEventStore][\(proc)] events directory: \(directory.path)")
        #endif
        return directory
    }

    private static func eventURL(for id: UUID) throws -> URL {
        try self.eventsDirectory().appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private static func baseDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment

        if let override = environment[storageEnvKey], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            self.logger.debug("Visualizer storage override via \(self.storageEnvKey): \(url.path, privacy: .public)")
            #if DEBUG
            let proc = ProcessInfo.processInfo.processName
            visualizerDebugLog("[VisualizerEventStore][\(proc)] storage override: \(url.path)")
            #endif
            return url
        }

        if let appGroup = environment[appGroupEnvKey],
           !appGroup.isEmpty,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        {
            let appGroupLog = """
            Visualizer storage using app group \(appGroup):
            \(container.path)
            """
            self.logger.debug("\(appGroupLog)")
            #if DEBUG
            let proc = ProcessInfo.processInfo.processName
            let debugMessage = """
            [VisualizerEventStore][\(proc)] storage app group (\(appGroup)):
            \(container.path)
            """
            visualizerDebugLog(debugMessage)
            #endif
            return container
        }

        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(self.storageRootName, isDirectory: true)
        // Default to ~/Library/... so both CLI and app can share without extra env setup
        self.logger.debug("Visualizer storage default path: \(url.path)")
        #if DEBUG
        let proc = ProcessInfo.processInfo.processName
        visualizerDebugLog("[VisualizerEventStore][\(proc)] storage default: \(url.path)")
        #endif
        return url
    }
}

extension Notification.Name {
    public static let visualizerEventDispatched = VisualizerEventStore.notificationName
}
