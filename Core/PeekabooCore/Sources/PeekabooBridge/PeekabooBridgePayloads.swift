import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

public struct PeekabooBridgeCaptureScreenRequest: Codable, Sendable {
    public let displayIndex: Int?
    public let visualizerMode: CaptureVisualizerMode
    public let scale: CaptureScalePreference
}

public struct PeekabooBridgeCaptureWindowRequest: Codable, Sendable {
    public let appIdentifier: String
    public let windowIndex: Int?
    public let windowId: Int?
    public let visualizerMode: CaptureVisualizerMode
    public let scale: CaptureScalePreference

    public init(
        appIdentifier: String,
        windowIndex: Int?,
        windowId: Int? = nil,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference)
    {
        self.appIdentifier = appIdentifier
        self.windowIndex = windowIndex
        self.windowId = windowId
        self.visualizerMode = visualizerMode
        self.scale = scale
    }
}

public struct PeekabooBridgeCaptureFrontmostRequest: Codable, Sendable {
    public let visualizerMode: CaptureVisualizerMode
    public let scale: CaptureScalePreference

    public init(visualizerMode: CaptureVisualizerMode, scale: CaptureScalePreference) {
        self.visualizerMode = visualizerMode
        self.scale = scale
    }
}

public struct PeekabooBridgeCaptureAreaRequest: Codable, Sendable {
    public let rect: CGRect
    public let visualizerMode: CaptureVisualizerMode
    public let scale: CaptureScalePreference
}

public struct PeekabooBridgeDetectElementsRequest: Codable, Sendable {
    public let imageData: Data
    public let snapshotId: String?
    public let windowContext: WindowContext?
}

public struct PeekabooBridgeInspectAccessibilityTreeRequest: Codable, Sendable {
    public let windowContext: WindowContext?
}

public struct PeekabooBridgeClickRequest: Codable, Sendable {
    public let target: ClickTarget
    public let clickType: ClickType
    public let snapshotId: String?

    public init(target: ClickTarget, clickType: ClickType, snapshotId: String? = nil) {
        self.target = target
        self.clickType = clickType
        self.snapshotId = snapshotId
    }
}

public struct PeekabooBridgeTypeRequest: Codable, Sendable {
    public let text: String
    public let target: String?
    public let clearExisting: Bool
    public let typingDelay: Int
    public let snapshotId: String?
}

public struct PeekabooBridgeTypeActionsRequest: Codable, Sendable {
    public let actions: [TypeAction]
    public let cadence: TypingCadence
    public let snapshotId: String?
}

public struct PeekabooBridgeTargetedTypeActionsRequest: Codable, Sendable {
    public let actions: [TypeAction]
    public let cadence: TypingCadence
    public let snapshotId: String?
    public let targetProcessIdentifier: Int32

    public init(
        actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: Int32)
    {
        self.actions = actions
        self.cadence = cadence
        self.snapshotId = snapshotId
        self.targetProcessIdentifier = targetProcessIdentifier
    }
}

public struct PeekabooBridgeSetValueRequest: Codable, Sendable {
    public let target: String
    public let value: UIElementValue
    public let snapshotId: String?

    public init(target: String, value: UIElementValue, snapshotId: String?) {
        self.target = target
        self.value = value
        self.snapshotId = snapshotId
    }
}

public struct PeekabooBridgePerformActionRequest: Codable, Sendable {
    public let target: String
    public let actionName: String
    public let snapshotId: String?

    public init(target: String, actionName: String, snapshotId: String?) {
        self.target = target
        self.actionName = actionName
        self.snapshotId = snapshotId
    }
}

public struct PeekabooBridgeScrollRequest: Codable, Sendable {
    public let request: ScrollRequest
}

public struct PeekabooBridgeHotkeyRequest: Codable, Sendable {
    public let keys: String
    public let holdDuration: Int

    public init(keys: String, holdDuration: Int) {
        self.keys = keys
        self.holdDuration = holdDuration
    }
}

public struct PeekabooBridgeTargetedHotkeyRequest: Codable, Sendable {
    public let keys: String
    public let holdDuration: Int
    public let targetProcessIdentifier: Int32

    public init(keys: String, holdDuration: Int, targetProcessIdentifier: Int32) {
        self.keys = keys
        self.holdDuration = holdDuration
        self.targetProcessIdentifier = targetProcessIdentifier
    }
}

public struct PeekabooBridgeTargetedClickRequest: Codable, Sendable {
    public let target: ClickTarget
    public let clickType: ClickType
    public let snapshotId: String?
    public let targetProcessIdentifier: Int32
    public let targetWindowID: Int?

    public init(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: Int32,
        targetWindowID: Int? = nil)
    {
        self.target = target
        self.clickType = clickType
        self.snapshotId = snapshotId
        self.targetProcessIdentifier = targetProcessIdentifier
        self.targetWindowID = targetWindowID
    }

    /// Whether a legacy (protocol <= 1.8) host would deliver this request via the synthetic
    /// pid-routed event path. Current hosts deliver every targeted click through accessibility;
    /// this remains only so clients can refuse these variants against old hosts, whose synthetic
    /// path mis-delivers positioned clicks at the window corner.
    public var requiresPostEventPermission: Bool {
        Self.requiresPostEventPermission(target: self.target, clickType: self.clickType)
    }

    public static func requiresPostEventPermission(target: ClickTarget, clickType: ClickType) -> Bool {
        switch (target, clickType) {
        case (.coordinates, _), (_, .double):
            true
        case (_, .single), (_, .right):
            false
        }
    }
}

public struct PeekabooBridgeSwipeRequest: Codable, Sendable {
    public let from: CGPoint
    public let to: CGPoint
    public let duration: Int
    public let steps: Int
    public let profile: MouseMovementProfile
}

public struct PeekabooBridgeDragRequest: Codable, Sendable {
    public let from: CGPoint
    public let to: CGPoint
    public let duration: Int
    public let steps: Int
    public let modifiers: String?
    public let profile: MouseMovementProfile

    public init(_ request: DragOperationRequest) {
        self.from = request.from
        self.to = request.to
        self.duration = request.duration
        self.steps = request.steps
        self.modifiers = request.modifiers
        self.profile = request.profile
    }

    public var automationRequest: DragOperationRequest {
        DragOperationRequest(
            from: self.from,
            to: self.to,
            duration: self.duration,
            steps: self.steps,
            modifiers: self.modifiers,
            profile: self.profile)
    }
}

public struct PeekabooBridgeMoveMouseRequest: Codable, Sendable {
    public let to: CGPoint
    public let duration: Int
    public let steps: Int
    public let profile: MouseMovementProfile
}

public struct PeekabooBridgeWaitRequest: Codable, Sendable {
    public let target: ClickTarget
    public let timeout: TimeInterval
    public let snapshotId: String?
}

public struct PeekabooBridgeWindowTargetRequest: Codable, Sendable {
    public let target: WindowTarget
}

public struct PeekabooBridgeWindowMoveRequest: Codable, Sendable {
    public let target: WindowTarget
    public let position: CGPoint
}

public struct PeekabooBridgeWindowResizeRequest: Codable, Sendable {
    public let target: WindowTarget
    public let size: CGSize
}

public struct PeekabooBridgeWindowBoundsRequest: Codable, Sendable {
    public let target: WindowTarget
    public let bounds: CGRect
}

public struct PeekabooBridgeAppIdentifierRequest: Codable, Sendable {
    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }
}

public struct PeekabooBridgeQuitAppRequest: Codable, Sendable {
    public let identifier: String
    public let force: Bool
}

public struct PeekabooBridgeMenuListRequest: Codable, Sendable {
    public let appIdentifier: String

    public init(appIdentifier: String) {
        self.appIdentifier = appIdentifier
    }
}

public struct PeekabooBridgeMenuClickRequest: Codable, Sendable {
    public let appIdentifier: String
    public let itemPath: String
}

public struct PeekabooBridgeMenuClickByNameRequest: Codable, Sendable {
    public let appIdentifier: String
    public let itemName: String
}

public struct PeekabooBridgeMenuBarClickByNameRequest: Codable, Sendable {
    public let name: String
}

public struct PeekabooBridgeMenuBarClickByIndexRequest: Codable, Sendable {
    public let index: Int
}

public struct PeekabooBridgeMenuExtraOpenRequest: Codable, Sendable {
    public let title: String
    public let ownerPID: pid_t?
}

public struct PeekabooBridgeDockListRequest: Codable, Sendable {
    public let includeAll: Bool
}

public struct PeekabooBridgeDockLaunchRequest: Codable, Sendable {
    public let appName: String
}

public struct PeekabooBridgeDockRightClickRequest: Codable, Sendable {
    public let appName: String
    public let menuItem: String?
}

public struct PeekabooBridgeDockFindRequest: Codable, Sendable {
    public let name: String
}

public struct PeekabooBridgeDialogFindRequest: Codable, Sendable {
    public let windowTitle: String?
    public let appName: String?
}

public struct PeekabooBridgeDialogClickButtonRequest: Codable, Sendable {
    public let buttonText: String
    public let windowTitle: String?
    public let appName: String?
}

public struct PeekabooBridgeDialogEnterTextRequest: Codable, Sendable {
    public let text: String
    public let fieldIdentifier: String?
    public let clearExisting: Bool
    public let windowTitle: String?
    public let appName: String?
}

public struct PeekabooBridgeDialogHandleFileRequest: Codable, Sendable {
    public let path: String?
    public let filename: String?
    public let actionButton: String?
    public let ensureExpanded: Bool?
    public let appName: String?
}

public struct PeekabooBridgeDialogDismissRequest: Codable, Sendable {
    public let force: Bool
    public let windowTitle: String?
    public let appName: String?
}

public struct PeekabooBridgeCreateSnapshotRequest: Codable, Sendable {
    public let pendingAt: Date?

    public init(pendingAt: Date? = nil) {
        self.pendingAt = pendingAt
    }

    private enum CodingKeys: String, CodingKey {
        case pendingAtReferenceDateSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pendingAt = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .pendingAtReferenceDateSeconds).map(Date.init(timeIntervalSinceReferenceDate:))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(
            self.pendingAt?.timeIntervalSinceReferenceDate,
            forKey: .pendingAtReferenceDateSeconds)
    }
}

public struct PeekabooBridgeStoreDetectionRequest: Codable, Sendable {
    public let snapshotId: String
    public let result: ElementDetectionResult
}

public struct PeekabooBridgeGetDetectionRequest: Codable, Sendable {
    public let snapshotId: String
}

public struct PeekabooBridgeStoreScreenshotRequest: Codable, Sendable {
    public let snapshotId: String
    public let screenshotPath: String
    public let applicationBundleId: String?
    public let applicationProcessId: Int32?
    public let applicationName: String?
    public let windowTitle: String?
    public let windowBounds: CGRect?

    public init(_ request: SnapshotScreenshotRequest) {
        self.snapshotId = request.snapshotId
        self.screenshotPath = request.screenshotPath
        self.applicationBundleId = request.applicationBundleId
        self.applicationProcessId = request.applicationProcessId
        self.applicationName = request.applicationName
        self.windowTitle = request.windowTitle
        self.windowBounds = request.windowBounds
    }

    public var snapshotRequest: SnapshotScreenshotRequest {
        SnapshotScreenshotRequest(
            snapshotId: self.snapshotId,
            screenshotPath: self.screenshotPath,
            applicationBundleId: self.applicationBundleId,
            applicationProcessId: self.applicationProcessId,
            applicationName: self.applicationName,
            windowTitle: self.windowTitle,
            windowBounds: self.windowBounds)
    }
}

public struct PeekabooBridgeStoreAnnotatedScreenshotRequest: Codable, Sendable {
    public let snapshotId: String
    public let annotatedScreenshotPath: String
}

public struct PeekabooBridgeGetMostRecentSnapshotRequest: Codable, Sendable {
    public let applicationBundleId: String?

    public init(applicationBundleId: String?) {
        self.applicationBundleId = applicationBundleId
    }
}

public struct PeekabooBridgeInvalidateImplicitLatestSnapshotRequest: Codable, Sendable {
    public let cutoff: Date
    public let preservingSnapshotId: String?
    public let preservedAt: Date?

    public init(cutoff: Date, preservingSnapshotId: String? = nil, preservedAt: Date? = nil) {
        self.cutoff = cutoff
        self.preservingSnapshotId = preservingSnapshotId
        self.preservedAt = preservedAt
    }

    private enum CodingKeys: String, CodingKey {
        case cutoffReferenceDateSeconds
        case preservingSnapshotId
        case preservedAtReferenceDateSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cutoff = try Date(timeIntervalSinceReferenceDate: container.decode(
            TimeInterval.self,
            forKey: .cutoffReferenceDateSeconds))
        self.preservingSnapshotId = try container.decodeIfPresent(String.self, forKey: .preservingSnapshotId)
        self.preservedAt = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .preservedAtReferenceDateSeconds).map(Date.init(timeIntervalSinceReferenceDate:))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.cutoff.timeIntervalSinceReferenceDate, forKey: .cutoffReferenceDateSeconds)
        try container.encodeIfPresent(self.preservingSnapshotId, forKey: .preservingSnapshotId)
        try container.encodeIfPresent(
            self.preservedAt?.timeIntervalSinceReferenceDate,
            forKey: .preservedAtReferenceDateSeconds)
    }
}

public struct PeekabooBridgeCleanSnapshotRequest: Codable, Sendable {
    public let snapshotId: String
}

public struct PeekabooBridgeCleanSnapshotsOlderRequest: Codable, Sendable {
    public let days: Int
}
