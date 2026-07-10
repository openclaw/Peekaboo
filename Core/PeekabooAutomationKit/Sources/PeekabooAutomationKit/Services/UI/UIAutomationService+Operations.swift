import CoreGraphics
import Foundation
import PeekabooFoundation

extension UIAutomationService {
    // MARK: - Element Detection

    /**
     * Detect and analyze UI elements in a captured screen image using AI-powered recognition.
     *
     * This method uses advanced computer vision and AI models to identify interactive UI elements
     * in screenshots. Elements are classified by type (buttons, text fields, etc.) and assigned
     * unique identifiers for subsequent automation operations.
     *
     * - Parameters:
     *   - imageData: PNG or JPEG image data containing the screen capture
     *   - snapshotId: Optional snapshot identifier for element caching and state management
     *   - windowContext: Optional context about the captured window for improved accuracy
     * - Returns: `ElementDetectionResult` containing detected elements and metadata
     * - Throws: `PeekabooError` if detection fails or image data is invalid
     *
     * ## Detection Process
     * 1. **Image Analysis**: AI model analyzes the screenshot for UI patterns
     * 2. **Element Classification**: Elements are categorized (button, textField, image, etc.)
     * 3. **Coordinate Mapping**: Screen coordinates are calculated for each element
     * 4. **Accessibility Correlation**: Elements are matched with accessibility tree data
     * 5. **Session Caching**: Results are stored for quick access in subsequent operations
     *
     * ## Element Types
     * Detected elements include:
     * - `button`: Clickable buttons and controls
     * - `textField`: Text input fields and text areas
     * - `image`: Images and icons
     * - `staticText`: Labels and static text content
     * - `other`: Other interactive elements
     *
     * ## Performance
     * - **Typical Duration**: 200-800ms depending on screen complexity
     * - **Caching**: Results are cached per snapshot to avoid re-detection
     * - **Batch Processing**: Multiple elements detected in single pass
     *
     * ## Example
     * ```swift
     * let captureResult = try await screenCapture.captureScreen()
     * let windowContext = WindowContext(
     *     applicationName: "Safari",
     *     windowTitle: "Apple",
     *     windowBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
     * )
     *
     * let elements = try await automation.detectElements(
     *     in: captureResult.imageData,
     *     snapshotId: "snapshot_123",
     *     windowContext: windowContext
     * )
     *
     * print("Detected \(elements.elements.all.count) elements")
     * for element in elements.elements.buttons {
     *     print("Button: \(element.label ?? "Unlabeled") at \(element.bounds)")
     * }
     * ```
     *
     * - Important: Requires Screen Recording permission for screen capture
     * - Note: Detection accuracy improves with window context information
     */
    public func detectElements(
        in imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?) async throws -> ElementDetectionResult
    {
        self.logger.debug("Delegating element detection to ElementDetectionService")
        let result = try await self.elementDetectionService.detectElements(
            in: imageData,
            snapshotId: snapshotId,
            windowContext: windowContext)
        if let snapshotId {
            try await self.snapshotManager.storeDetectionResult(snapshotId: snapshotId, result: result)
        }
        return result
    }

    public func inspectAccessibilityTree(windowContext: WindowContext?) async throws -> ElementDetectionResult {
        self.logger.debug("Delegating accessibility tree inspection to ElementDetectionService")
        return try await self.elementDetectionService.inspectElements(
            snapshotId: nil,
            windowContext: windowContext)
    }

    // MARK: - Click Operations

    /**
     * Perform precise click operations on UI elements or screen coordinates.
     *
     * This method handles all types of mouse click interactions with intelligent targeting,
     * accessibility API integration, and visual feedback. It supports both element-based
     * and coordinate-based clicking with multiple click types.
     *
     * - Parameters:
     *   - target: The click target (element ID, query, or coordinates)
     *   - clickType: Type of click to perform (single, double, right-click, etc.)
     *   - snapshotId: Optional snapshot ID for element resolution and state tracking
     * - Throws: `PeekabooError` if the target cannot be found or click fails
     *
     * ## Click Targeting
     * Three targeting modes are supported:
     * - **Element ID**: Click on a specific element using its opaque detected ID
     * - **Query**: Find element by text content or accessibility label
     * - **Coordinates**: Click at exact screen coordinates
     *
     * ## Click Types
     * - `.single`: Standard left click
     * - `.double`: Double-click for opening/selecting
     * - `.right`: Right-click for context menus
     * - `.middle`: Middle-click (wheel button)
     *
     * ## Visual Feedback
     * When visualizer is connected, shows:
     * - Animated cursor gliding to the click location
     * - Visible single, double, or right-button press
     * - Subtle click ring centered on the cursor hotspot
     *
     * ## Performance
     * - **Element Resolution**: 10-50ms for cached elements
     * - **Accessibility Lookup**: 50-200ms for query-based targeting
     * - **Click Execution**: 5-20ms for coordinate-based clicks
     *
     * ## Example
     * ```swift
     * // Click on detected element
     * try await automation.click(
     *     target: .elementId(detectedElement.id),
     *     clickType: .single,
     *     snapshotId: "snapshot_123"
     * )
     *
     * // Click by searching for text
     * try await automation.click(
     *     target: .query("Submit"),
     *     clickType: .single,
     *     snapshotId: "snapshot_123"
     * )
     *
     * // Click at specific coordinates
     * try await automation.click(
     *     target: .coordinates(CGPoint(x: 100, y: 200)),
     *     clickType: .right,
     *     snapshotId: nil
     * )
     * ```
     *
     * - Important: Requires Accessibility permission for element-based clicking
     * - Note: Visual feedback is automatically shown if visualizer is connected
     */
    public func click(target: ClickTarget, clickType: ClickType, snapshotId: String?) async throws {
        self.logger.debug("Delegating click to ClickService")
        let result = try await self.normalizingSnapshotErrors {
            try await self.clickService.click(target: target, clickType: clickType, snapshotId: snapshotId)
        }

        // Show visual feedback if available
        let fallbackPoint = try await self.getClickPoint(for: target, snapshotId: snapshotId)
        if let clickPoint = Self.visualFeedbackPoint(actionAnchor: result.anchorPoint, fallbackPoint: fallbackPoint) {
            _ = await self.feedbackClient.showClickFeedback(at: clickPoint, type: clickType)
        }
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws
    {
        self.logger.debug("Delegating background click to ClickService")
        let result = try await self.normalizingSnapshotErrors {
            try await self.clickService.click(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                targetProcessIdentifier: targetProcessIdentifier)
        }

        let fallbackPoint = try await self.getClickPoint(for: target, snapshotId: snapshotId)
        if let clickPoint = Self.visualFeedbackPoint(actionAnchor: result.anchorPoint, fallbackPoint: fallbackPoint) {
            _ = await self.feedbackClient.showClickFeedback(at: clickPoint, type: clickType)
        }
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t,
        targetWindowID: Int) async throws
    {
        self.logger.debug("Delegating exact-window background click to ClickService")
        let result = try await self.normalizingSnapshotErrors {
            try await self.clickService.click(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                targetProcessIdentifier: targetProcessIdentifier,
                targetWindowID: targetWindowID)
        }

        let fallbackPoint = try await self.getClickPoint(for: target, snapshotId: snapshotId)
        if let clickPoint = Self.visualFeedbackPoint(actionAnchor: result.anchorPoint, fallbackPoint: fallbackPoint) {
            _ = await self.feedbackClient.showClickFeedback(at: clickPoint, type: clickType)
        }
    }

    func normalizingSnapshotErrors<T>(
        _ operation: () async throws -> T) async throws -> T
    {
        do {
            return try await operation()
        } catch let error as ActionInputError where error == .staleElement {
            throw PeekabooError.snapshotStale("target element is no longer available")
        }
    }

    private func getClickPoint(for target: ClickTarget, snapshotId: String?) async throws -> CGPoint? {
        switch target {
        case let .coordinates(point):
            return point
        case let .elementId(id):
            if let snapshotId,
               let result = try? await snapshotManager.getDetectionResult(snapshotId: snapshotId),
               let element = result.elements.findById(id)
            {
                return CGPoint(x: element.bounds.midX, y: element.bounds.midY)
            }
        case .query:
            // For queries, we don't have easy access to the clicked element's position
            // The click service would need to expose this information
            return nil
        }
        return nil
    }

    nonisolated static func visualFeedbackPoint(actionAnchor: CGPoint?, fallbackPoint: CGPoint?) -> CGPoint? {
        actionAnchor ?? fallbackPoint
    }
}
