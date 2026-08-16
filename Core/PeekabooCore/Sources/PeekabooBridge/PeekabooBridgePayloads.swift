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

public struct PeekabooBridgeFocusedElementRequest: Codable, Sendable {
    public let targetProcessIdentifier: Int32
    public let expectedProcessIdentity: ApplicationProcessIdentity?

    public init(
        targetProcessIdentifier: Int32,
        expectedProcessIdentity: ApplicationProcessIdentity? = nil)
    {
        self.targetProcessIdentifier = targetProcessIdentifier
        self.expectedProcessIdentity = expectedProcessIdentity
    }
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
    public let expectedProcessIdentity: ApplicationProcessIdentity?

    public init(
        actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: Int32,
        expectedProcessIdentity: ApplicationProcessIdentity? = nil)
    {
        self.actions = actions
        self.cadence = cadence
        self.snapshotId = snapshotId
        self.targetProcessIdentifier = targetProcessIdentifier
        self.expectedProcessIdentity = expectedProcessIdentity
    }
}

public struct PeekabooBridgeExactWindowTypeActionsRequest: Codable, Sendable {
    public let actions: [TypeAction]
    public let cadence: TypingCadence
    public let snapshotId: String?
    public let expectedWindowIdentity: WindowMutationIdentity
    public let expectedWindowBounds: CGRect
    public let expectedFocusedElement: FocusedElementIdentity?

    public init(
        actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect,
        expectedFocusedElement: FocusedElementIdentity? = nil)
    {
        self.actions = actions
        self.cadence = cadence
        self.snapshotId = snapshotId
        self.expectedWindowIdentity = expectedWindowIdentity
        self.expectedWindowBounds = expectedWindowBounds
        self.expectedFocusedElement = expectedFocusedElement
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

    public init(request: ScrollRequest) {
        self.request = request
    }
}

public struct PeekabooBridgeHotkeyRequest: Codable, Sendable {
    public let keys: String
    public let holdDuration: Int

    public init(keys: String, holdDuration: Int) {
        self.keys = keys
        self.holdDuration = holdDuration
    }
}

public struct PeekabooBridgeBeginHeldPointerRequest: Codable, Equatable, Sendable {
    public let owner: ExactWindowHeldPointerOwner
    public let request: ExactWindowHeldPointerRequest

    public init(owner: ExactWindowHeldPointerOwner, request: ExactWindowHeldPointerRequest) {
        self.owner = owner
        self.request = request
    }
}

public struct PeekabooBridgeFinishHeldPointerRequest: Codable, Equatable, Sendable {
    public let owner: ExactWindowHeldPointerOwner
    public let receipt: ExactWindowHeldPointerReceipt

    public init(owner: ExactWindowHeldPointerOwner, receipt: ExactWindowHeldPointerReceipt) {
        self.owner = owner
        self.receipt = receipt
    }
}

public struct PeekabooBridgeHeldPointerOwnerRequest: Codable, Equatable, Sendable {
    public let owner: ExactWindowHeldPointerOwner

    public init(owner: ExactWindowHeldPointerOwner) {
        self.owner = owner
    }
}

public struct PeekabooBridgeTargetedHotkeyRequest: Codable, Sendable {
    public let keys: String
    public let holdDuration: Int
    public let targetProcessIdentifier: Int32
    public let expectedProcessIdentity: ApplicationProcessIdentity?

    public init(
        keys: String,
        holdDuration: Int,
        targetProcessIdentifier: Int32,
        expectedProcessIdentity: ApplicationProcessIdentity? = nil)
    {
        self.keys = keys
        self.holdDuration = holdDuration
        self.targetProcessIdentifier = targetProcessIdentifier
        self.expectedProcessIdentity = expectedProcessIdentity
    }
}

public struct PeekabooBridgeExactWindowHotkeyRequest: Codable, Sendable {
    public let keys: String
    public let holdDuration: Int
    public let expectedWindowIdentity: WindowMutationIdentity
    public let expectedWindowBounds: CGRect
    public let expectedFocusedElement: FocusedElementIdentity?

    public init(
        keys: String,
        holdDuration: Int,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect,
        expectedFocusedElement: FocusedElementIdentity? = nil)
    {
        self.keys = keys
        self.holdDuration = holdDuration
        self.expectedWindowIdentity = expectedWindowIdentity
        self.expectedWindowBounds = expectedWindowBounds
        self.expectedFocusedElement = expectedFocusedElement
    }
}

public struct PeekabooBridgeTargetedClickRequest: Codable, Sendable {
    public let target: ClickTarget
    public let clickType: ClickType
    public let snapshotId: String?
    public let targetProcessIdentifier: Int32
    public let expectedProcessIdentity: ApplicationProcessIdentity?
    public let targetWindowID: Int?
    public let expectedWindowIdentity: WindowMutationIdentity?
    public let expectedWindowBounds: CGRect?

    public init(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: Int32,
        expectedProcessIdentity: ApplicationProcessIdentity? = nil,
        targetWindowID: Int? = nil,
        expectedWindowIdentity: WindowMutationIdentity? = nil,
        expectedWindowBounds: CGRect? = nil)
    {
        self.target = target
        self.clickType = clickType
        self.snapshotId = snapshotId
        self.targetProcessIdentifier = targetProcessIdentifier
        self.expectedProcessIdentity = expectedProcessIdentity
        self.targetWindowID = targetWindowID
        self.expectedWindowIdentity = expectedWindowIdentity
        self.expectedWindowBounds = expectedWindowBounds
    }

    /// Whether this request's concrete click route needs native event synthesis.
    /// Single clicks and semantic right-clicks can stay in Accessibility; multi-clicks,
    /// middle-clicks, and coordinate right-clicks use exact-window routed events.
    public var requiresPostEventPermission: Bool {
        Self.requiresPostEventPermission(target: self.target, clickType: self.clickType)
    }

    public static func requiresPostEventPermission(target: ClickTarget, clickType: ClickType) -> Bool {
        switch (target, clickType) {
        case (_, .double), (_, .middle), (_, .triple), (_, .longPress), (.coordinates, .right):
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
    public let button: String?
    public let profile: MouseMovementProfile

    public init(_ request: DragOperationRequest) {
        self.from = request.from
        self.to = request.to
        self.duration = request.duration
        self.steps = request.steps
        self.modifiers = request.modifiers
        self.button = request.button.rawValue
        self.profile = request.profile
    }

    public var automationRequest: DragOperationRequest {
        DragOperationRequest(
            from: self.from,
            to: self.to,
            duration: self.duration,
            steps: self.steps,
            modifiers: self.modifiers,
            button: self.button.flatMap(DragButton.init(rawValue:)) ?? .left,
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
    public let expectedIdentity: WindowMutationIdentity?

    public init(target: WindowTarget, expectedIdentity: WindowMutationIdentity? = nil) {
        self.target = target
        self.expectedIdentity = expectedIdentity
    }
}

public struct PeekabooBridgeWindowMoveRequest: Codable, Sendable {
    public let target: WindowTarget
    public let expectedIdentity: WindowMutationIdentity?
    public let position: CGPoint

    public init(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity? = nil,
        position: CGPoint)
    {
        self.target = target
        self.expectedIdentity = expectedIdentity
        self.position = position
    }
}

public struct PeekabooBridgeWindowResizeRequest: Codable, Sendable {
    public let target: WindowTarget
    public let expectedIdentity: WindowMutationIdentity?
    public let size: CGSize

    public init(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity? = nil,
        size: CGSize)
    {
        self.target = target
        self.expectedIdentity = expectedIdentity
        self.size = size
    }
}

public struct PeekabooBridgeWindowBoundsRequest: Codable, Sendable {
    public let target: WindowTarget
    public let expectedIdentity: WindowMutationIdentity?
    public let bounds: CGRect

    public init(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity? = nil,
        bounds: CGRect)
    {
        self.target = target
        self.expectedIdentity = expectedIdentity
        self.bounds = bounds
    }
}

public struct PeekabooBridgeAppIdentifierRequest: Codable, Sendable {
    public let identifier: String
    public let expectedIdentity: ApplicationProcessIdentity?

    public init(
        identifier: String,
        expectedIdentity: ApplicationProcessIdentity? = nil)
    {
        self.identifier = identifier
        self.expectedIdentity = expectedIdentity
    }

    public init(_ request: ApplicationHideRequest) {
        self.init(
            identifier: request.identifier,
            expectedIdentity: request.expectedIdentity)
    }
}

public struct PeekabooBridgeQuitAppRequest: Codable, Sendable {
    public let identifier: String
    public let force: Bool
    public let expectedIdentity: ApplicationProcessIdentity?

    public init(
        identifier: String,
        force: Bool,
        expectedIdentity: ApplicationProcessIdentity? = nil)
    {
        self.identifier = identifier
        self.force = force
        self.expectedIdentity = expectedIdentity
    }

    public init(_ request: ApplicationQuitRequest) {
        self.init(
            identifier: request.identifier,
            force: request.force,
            expectedIdentity: request.expectedIdentity)
    }
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
    public let expectedIdentity: ApplicationProcessIdentity?
    public let deliveryMode: DesktopActionOutcome.Delivery.Mode?

    public init(
        appIdentifier: String,
        itemPath: String,
        expectedIdentity: ApplicationProcessIdentity? = nil,
        deliveryMode: DesktopActionOutcome.Delivery.Mode = .background)
    {
        self.appIdentifier = appIdentifier
        self.itemPath = itemPath
        self.expectedIdentity = expectedIdentity
        self.deliveryMode = deliveryMode
    }

    public init(_ request: MenuItemActionRequest) {
        self.init(
            appIdentifier: request.appIdentifier,
            itemPath: request.itemPath,
            expectedIdentity: request.expectedIdentity,
            deliveryMode: request.deliveryMode)
    }

    static func legacyReceiptless(appIdentifier: String, itemPath: String) -> Self {
        Self(
            legacyAppIdentifier: appIdentifier,
            itemPath: itemPath)
    }

    private init(legacyAppIdentifier: String, itemPath: String) {
        self.appIdentifier = legacyAppIdentifier
        self.itemPath = itemPath
        self.expectedIdentity = nil
        self.deliveryMode = nil
    }
}

public struct PeekabooBridgeMenuClickByNameRequest: Codable, Sendable {
    public let appIdentifier: String
    public let itemName: String
    public let expectedIdentity: ApplicationProcessIdentity?
    public let deliveryMode: DesktopActionOutcome.Delivery.Mode?

    public init(
        appIdentifier: String,
        itemName: String,
        expectedIdentity: ApplicationProcessIdentity? = nil,
        deliveryMode: DesktopActionOutcome.Delivery.Mode = .background)
    {
        self.appIdentifier = appIdentifier
        self.itemName = itemName
        self.expectedIdentity = expectedIdentity
        self.deliveryMode = deliveryMode
    }

    public init(_ request: MenuItemByNameActionRequest) {
        self.init(
            appIdentifier: request.appIdentifier,
            itemName: request.itemName,
            expectedIdentity: request.expectedIdentity,
            deliveryMode: request.deliveryMode)
    }

    static func legacyReceiptless(appIdentifier: String, itemName: String) -> Self {
        Self(
            legacyAppIdentifier: appIdentifier,
            itemName: itemName)
    }

    private init(legacyAppIdentifier: String, itemName: String) {
        self.appIdentifier = legacyAppIdentifier
        self.itemName = itemName
        self.expectedIdentity = nil
        self.deliveryMode = nil
    }
}

public struct PeekabooBridgeMenuBarClickByNameRequest: Codable, Sendable {
    public let name: String
    public let expectedLeafEvidence: DesktopSelectedLeafEvidence?

    public init(name: String, expectedLeafEvidence: DesktopSelectedLeafEvidence? = nil) {
        self.name = name
        self.expectedLeafEvidence = expectedLeafEvidence
    }
}

public struct PeekabooBridgeMenuBarClickByIndexRequest: Codable, Sendable {
    public let index: Int
    public let expectedLeafEvidence: DesktopSelectedLeafEvidence?

    public init(index: Int, expectedLeafEvidence: DesktopSelectedLeafEvidence? = nil) {
        self.index = index
        self.expectedLeafEvidence = expectedLeafEvidence
    }
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
    public let focus: DialogForegroundFocusPolicy?
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
    public let explicitOnly: Bool?

    public init(pendingAt: Date? = nil, explicitOnly: Bool? = nil) {
        self.pendingAt = pendingAt
        self.explicitOnly = explicitOnly
    }

    private enum CodingKeys: String, CodingKey {
        case pendingAtReferenceDateSeconds
        case explicitOnly
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pendingAt = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .pendingAtReferenceDateSeconds).map(Date.init(timeIntervalSinceReferenceDate:))
        self.explicitOnly = try container.decodeIfPresent(Bool.self, forKey: .explicitOnly)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(
            self.pendingAt?.timeIntervalSinceReferenceDate,
            forKey: .pendingAtReferenceDateSeconds)
        try container.encodeIfPresent(self.explicitOnly, forKey: .explicitOnly)
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
    public let windowID: Int?
    public let windowMutationIdentity: WindowMutationIdentity?
    public let captureCoordinateContext: CaptureCoordinateContext?

    public init(_ request: SnapshotScreenshotRequest) {
        self.snapshotId = request.snapshotId
        self.screenshotPath = request.screenshotPath
        self.applicationBundleId = request.applicationBundleId
        self.applicationProcessId = request.applicationProcessId
        self.applicationName = request.applicationName
        self.windowTitle = request.windowTitle
        self.windowBounds = request.windowBounds
        self.windowID = request.windowID
        self.windowMutationIdentity = request.windowMutationIdentity
        self.captureCoordinateContext = request.captureCoordinateContext
    }

    public var snapshotRequest: SnapshotScreenshotRequest {
        SnapshotScreenshotRequest(
            snapshotId: self.snapshotId,
            screenshotPath: self.screenshotPath,
            applicationBundleId: self.applicationBundleId,
            applicationProcessId: self.applicationProcessId,
            applicationName: self.applicationName,
            windowTitle: self.windowTitle,
            windowBounds: self.windowBounds,
            windowID: self.windowID,
            windowMutationIdentity: self.windowMutationIdentity,
            captureCoordinateContext: self.captureCoordinateContext)
    }
}

public struct PeekabooBridgeStoreObservationSnapshotRequest: Codable, Sendable {
    public let screenshot: PeekabooBridgeStoreScreenshotRequest
    public let detectionResult: ElementDetectionResult?
    public let annotatedScreenshotPath: String?

    public init(_ request: SnapshotObservationPublicationRequest) {
        self.screenshot = PeekabooBridgeStoreScreenshotRequest(request.screenshot)
        self.detectionResult = request.detectionResult
        self.annotatedScreenshotPath = request.annotatedScreenshotPath
    }

    public var publicationRequest: SnapshotObservationPublicationRequest {
        SnapshotObservationPublicationRequest(
            screenshot: self.screenshot.snapshotRequest,
            detectionResult: self.detectionResult,
            annotatedScreenshotPath: self.annotatedScreenshotPath)
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

public struct PeekabooBridgeBeginSnapshotMutationRequest: Codable, Sendable {
    public let snapshotId: String

    public init(snapshotId: String) {
        self.snapshotId = snapshotId
    }
}

public struct PeekabooBridgeFinishSnapshotMutationRequest: Codable, Sendable {
    public let lease: SnapshotMutationLease
    public let requiresFreshObservation: Bool

    public init(lease: SnapshotMutationLease, requiresFreshObservation: Bool) {
        self.lease = lease
        self.requiresFreshObservation = requiresFreshObservation
    }
}

public struct PeekabooBridgeCleanSnapshotRequest: Codable, Sendable {
    public let snapshotId: String
}

public struct PeekabooBridgeCleanSnapshotsOlderRequest: Codable, Sendable {
    public let days: Int
}
