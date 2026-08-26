import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import PeekabooFoundationTestSupport

/// Canonical deterministic builders for automation tests.
public enum AutomationTestFixtures {
    public static func uiActionReceipt(
        outcome: DesktopActionOutcome = .dispatchedUnverified(
            delivery: DesktopActionOutcome.Delivery(
                mechanism: .accessibilityAction,
                mode: .background),
            evidence: .deliveryAccepted),
        actionName: String? = nil,
        anchorPoint: CGPoint? = nil,
        elementRole: String? = nil) -> UIInputExecutionResult.Action
    {
        UIInputExecutionResult.Action(
            outcome: outcome,
            actionName: actionName,
            anchorPoint: anchorPoint,
            elementRole: elementRole)
    }

    public static func processIdentity(
        processIdentifier: Int32 = 101,
        processStartIdentity: UInt64 = 1001) -> ApplicationProcessIdentity
    {
        ApplicationProcessIdentity(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity)
    }

    public static func windowIdentity(
        windowID: Int = 201,
        processIdentity: ApplicationProcessIdentity = Self.processIdentity(),
        bounds: CGRect? = CGRect(x: 10, y: 20, width: 640, height: 480),
        isMinimized: Bool = false) -> WindowMutationIdentity
    {
        WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: processIdentity.processIdentifier,
            ownerProcessStartIdentity: processIdentity.processStartIdentity,
            capturedBounds: bounds,
            isMinimized: isMinimized)
    }

    public static func application(
        processIdentifier: Int32 = 101,
        processStartIdentity: UInt64? = 1001,
        bundleIdentifier: String? = "com.example.TestApp",
        name: String = "Test App",
        isActive: Bool = false,
        isHidden: Bool = false,
        isHiddenKnown: Bool? = nil,
        windowCount: Int = 0,
        windowIDs: [Int]? = nil,
        activationPolicy: ServiceApplicationActivationPolicy? = nil) -> ServiceApplicationInfo
    {
        ServiceApplicationInfo(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            bundleIdentifier: bundleIdentifier,
            name: name,
            isActive: isActive,
            isHidden: isHidden,
            isHiddenKnown: isHiddenKnown,
            windowCount: windowCount,
            windowIDs: windowIDs,
            activationPolicy: activationPolicy)
    }

    public static func duplicateApplications() -> [ServiceApplicationInfo] {
        [
            self.application(
                processIdentifier: 101,
                processStartIdentity: 1001,
                bundleIdentifier: "com.example.Shared",
                name: "Shared App"),
            self.application(
                processIdentifier: 202,
                processStartIdentity: 2002,
                bundleIdentifier: "com.example.Shared",
                name: "Shared App"),
        ]
    }

    public static func window(
        windowID: Int = 201,
        title: String = "Test Window",
        bounds: CGRect = CGRect(x: 10, y: 20, width: 640, height: 480),
        processIdentity: ApplicationProcessIdentity = Self.processIdentity(),
        includesMutationIdentity: Bool = true,
        isMinimized: Bool = false,
        isMainWindow: Bool = true,
        isKeyWindow: Bool? = true,
        isFrontmost: Bool? = false,
        index: Int = 0) -> ServiceWindowInfo
    {
        ServiceWindowInfo(
            windowID: windowID,
            title: title,
            bounds: bounds,
            isMinimized: isMinimized,
            isMainWindow: isMainWindow,
            isKeyWindow: isKeyWindow,
            isFrontmost: isFrontmost,
            index: index,
            mutationIdentity: includesMutationIdentity
                ? self.windowIdentity(
                    windowID: windowID,
                    processIdentity: processIdentity,
                    bounds: bounds,
                    isMinimized: isMinimized)
                : nil)
    }

    public static func duplicateTitleWindows(
        processIdentity: ApplicationProcessIdentity = Self.processIdentity()) -> [ServiceWindowInfo]
    {
        [
            self.window(
                windowID: 201,
                title: "Shared Document",
                processIdentity: processIdentity,
                index: 0),
            self.window(
                windowID: 202,
                title: "Shared Document Copy",
                processIdentity: processIdentity,
                index: 1),
        ]
    }

    public static func wrongGenerationApplication() -> ServiceApplicationInfo {
        self.application(processStartIdentity: 9999)
    }

    public static func focusedElement(
        processIdentity: ApplicationProcessIdentity = Self.processIdentity(),
        windowID: Int = 201,
        role: String = "AXTextField",
        identifier: String? = "editor",
        frame: CGRect = CGRect(x: 30, y: 40, width: 200, height: 32)) -> FocusedElementIdentity
    {
        FocusedElementIdentity(
            processIdentifier: processIdentity.processIdentifier,
            windowID: windowID,
            role: role,
            identifier: identifier,
            frame: frame)
    }

    public static func captureCoordinateContext(
        snapshotID: String = SnapshotReferenceFixtures.first.rawValue,
        window: ServiceWindowInfo = Self.window(),
        deliveredImageSize: CGSize? = nil,
        viewport: CaptureViewport? = nil) -> CaptureCoordinateContext
    {
        CaptureCoordinateContext(
            metadata: CaptureMetadata(
                size: deliveredImageSize ?? window.bounds.size,
                mode: .window,
                windowInfo: window,
                viewport: viewport),
            referenceID: snapshotID)
    }

    public static func detectedElement(
        id: String = "element-1",
        type: ElementType = .textField,
        label: String? = "Test Element",
        value: String? = nil,
        bounds: CGRect = CGRect(x: 30, y: 40, width: 200, height: 32),
        isEnabled: Bool = true,
        isSelected: Bool? = nil,
        attributes: [String: String] = [:]) -> DetectedElement
    {
        DetectedElement(
            id: id,
            type: type,
            label: label,
            value: value,
            bounds: bounds,
            isEnabled: isEnabled,
            isSelected: isSelected,
            attributes: attributes)
    }

    public static func storedElement(
        id: String = "element-1",
        role: String = "AXTextField",
        title: String? = "Test Element",
        label: String? = nil,
        value: String? = nil,
        description: String? = nil,
        help: String? = nil,
        roleDescription: String? = nil,
        identifier: String? = nil,
        frame: CGRect = CGRect(x: 30, y: 40, width: 200, height: 32),
        isActionable: Bool = true,
        isEnabled: Bool? = true,
        isSelected: Bool? = nil,
        isValueSettable: Bool? = true) -> UIElement
    {
        UIElement(
            id: id,
            elementId: id,
            role: role,
            title: title,
            label: label,
            value: value,
            description: description,
            help: help,
            roleDescription: roleDescription,
            identifier: identifier,
            frame: frame,
            isActionable: isActionable,
            isEnabled: isEnabled,
            isSelected: isSelected,
            isValueSettable: isValueSettable)
    }

    public static func windowContext(
        application: ServiceApplicationInfo = Self.application(),
        window: ServiceWindowInfo = Self.window(),
        focusedElement: FocusedElementIdentity? = nil,
        requiresFreshAccessibilityTree: Bool = true) -> WindowContext
    {
        if let receipt = window.mutationIdentity {
            precondition(
                receipt.ownerProcessIdentifier == application.processIdentifier &&
                    receipt.ownerProcessStartIdentity == application.processStartIdentity,
                "Window and application fixtures must describe the same process generation")
        }
        return WindowContext(
            applicationName: application.name,
            applicationBundleId: application.bundleIdentifier,
            applicationProcessId: application.processIdentifier,
            windowTitle: window.title,
            windowID: window.windowID,
            windowBounds: window.bounds,
            windowMutationIdentity: window.mutationIdentity,
            focusedElement: focusedElement,
            requiresFreshAccessibilityTree: requiresFreshAccessibilityTree)
    }

    public static func detectionResult(
        snapshotID: String = SnapshotReferenceFixtures.first.rawValue,
        screenshotPath: String = "/tmp/peekaboo-test.png",
        elements: DetectedElements = DetectedElements(),
        windowContext: WindowContext? = nil,
        warnings: [String] = []) -> ElementDetectionResult
    {
        ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: screenshotPath,
            elements: elements,
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: elements.all.count,
                method: "test-fixture",
                warnings: warnings,
                windowContext: windowContext))
    }

    public static func snapshot(
        creatorProcessID: Int32 = 999,
        elements: [String: UIElement] = [:],
        application: ServiceApplicationInfo = Self.application(),
        window: ServiceWindowInfo = Self.window()) -> UIAutomationSnapshot
    {
        if let receipt = window.mutationIdentity {
            precondition(
                receipt.ownerProcessIdentifier == application.processIdentifier &&
                    receipt.ownerProcessStartIdentity == application.processStartIdentity,
                "Window and application fixtures must describe the same process generation")
        }
        return UIAutomationSnapshot(
            creatorProcessId: creatorProcessID,
            uiMap: elements,
            lastUpdateTime: Date(timeIntervalSinceReferenceDate: 1),
            applicationName: application.name,
            applicationBundleId: application.bundleIdentifier,
            applicationProcessId: application.processIdentifier,
            windowTitle: window.title,
            windowBounds: window.bounds,
            windowMutationIdentity: window.mutationIdentity,
            windowID: CGWindowID(window.windowID))
    }
}

/// Small lock-backed cell for deterministic `@Sendable` test providers.
public final class AutomationTestLockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    public init(_ value: Value) {
        self.storedValue = value
    }

    public var value: Value {
        get { self.lock.withLock { self.storedValue } }
        set { self.lock.withLock { self.storedValue = newValue } }
    }

    @discardableResult
    public func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try self.lock.withLock { try body(&self.storedValue) }
    }
}
