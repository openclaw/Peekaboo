import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import PeekabooFoundationTestSupport

/// Coherent automation-snapshot and detection-result sources for one exact desktop target.
public struct LinkedSnapshotTargetFixture: Sendable {
    public let snapshotID: String
    public let desktopTarget: LinkedDesktopTargetFixture
    public let automationSnapshot: UIAutomationSnapshot
    public let detectionResult: ElementDetectionResult
    public let coordinateContext: CaptureCoordinateContext

    public var receiptPlan: SnapshotTargetReceiptPlan {
        get throws {
            try SnapshotTargetReceiptPlanner.assemble(
                snapshotID: self.snapshotID,
                automationSnapshot: self.automationSnapshot,
                detectionResult: self.detectionResult)
        }
    }

    public var targetIdentity: DesktopTargetIdentity {
        get throws {
            try self.receiptPlan.receipt.requireIdentity()
        }
    }
}

extension AutomationTestFixtures {
    public static func linkedSnapshotTarget(
        snapshotID: String = SnapshotReferenceFixtures.first.rawValue,
        processIdentity: ApplicationProcessIdentity = Self.processIdentity(),
        bundleIdentifier: String? = "com.example.TestApp",
        applicationName: String = "Test App",
        windowID: Int = 201,
        windowTitle: String = "Test Window",
        bounds: CGRect = CGRect(x: 10, y: 20, width: 640, height: 480),
        focusedElement: FocusedElementIdentity? = nil) -> LinkedSnapshotTargetFixture
    {
        let target = self.linkedDesktopTarget(
            processIdentity: processIdentity,
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            windowID: windowID,
            windowTitle: windowTitle,
            bounds: bounds,
            focusedElement: focusedElement)
        let coordinateContext = self.captureCoordinateContext(
            snapshotID: snapshotID,
            window: target.window)
        let automationSnapshot = UIAutomationSnapshot(
            creatorProcessId: 999,
            uiMap: [:],
            lastUpdateTime: Date(timeIntervalSinceReferenceDate: 1),
            applicationName: target.application.name,
            applicationBundleId: target.application.bundleIdentifier,
            applicationProcessId: target.processIdentity.processIdentifier,
            windowTitle: target.window.title,
            windowBounds: target.window.bounds,
            windowMutationIdentity: target.windowIdentity,
            focusedElement: focusedElement,
            captureCoordinateContext: coordinateContext,
            windowID: CGWindowID(target.window.windowID))
        let detectionResult = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "/tmp/peekaboo-linked-snapshot.png",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 0,
                method: "linked-test-fixture",
                windowContext: target.windowContext,
                truncationInfo: nil,
                captureCoordinateContext: coordinateContext))
        return LinkedSnapshotTargetFixture(
            snapshotID: snapshotID,
            desktopTarget: target,
            automationSnapshot: automationSnapshot,
            detectionResult: detectionResult,
            coordinateContext: coordinateContext)
    }
}
