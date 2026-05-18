import CoreGraphics
import Foundation
import PeekabooFoundation

/// Extension to integrate GameBridge detection into the observation pipeline.
///
/// When the target window belongs to a game-bridge app (e.g. Firestaff),
/// elements are read from the app's JSON accessibility manifest instead of
/// the macOS Accessibility API. This works for SDL/GPU-rendered windows
/// that don't expose AXUIElement trees.
@available(macOS 14.0, *)
public extension GameBridgeDetectionService {

    /// Try game-bridge detection for a window context.
    /// Returns nil if the app is not a known game-bridge app or has no manifest.
    /// - Parameters:
    ///   - windowContext: Resolved window context with app name and bounds.
    ///   - snapshotId: Caller-provided snapshot ID to preserve in the result.
    static func tryDetect(windowContext: WindowContext?,
                          snapshotId: String? = nil) -> ElementDetectionResult? {
        guard let appName = windowContext?.applicationName,
              isGameBridgeApp(appName: appName) else {
            return nil
        }

        guard let manifest = readManifest(appName: appName) else {
            return nil
        }

        let bridgeElements = detectElements(
            from: manifest,
            windowBounds: windowContext?.windowBounds
        )

        // Convert to Peekaboo DetectedElements
        var buttons: [DetectedElement] = []
        var textFields: [DetectedElement] = []
        var images: [DetectedElement] = []
        var groups: [DetectedElement] = []
        var other: [DetectedElement] = []

        for ge in bridgeElements {
            let element = DetectedElement(
                id: ge.id,
                type: mapToElementType(ge.type),
                label: ge.label,
                value: ge.value,
                bounds: ge.bounds,
                isEnabled: ge.enabled,
                attributes: [
                    "source": "gameBridge",
                    "gameState": ge.gameState,
                    "fbX": "\(Int(ge.framebufferBounds.origin.x))",
                    "fbY": "\(Int(ge.framebufferBounds.origin.y))",
                    "fbW": "\(Int(ge.framebufferBounds.width))",
                    "fbH": "\(Int(ge.framebufferBounds.height))"
                ]
            )

            switch ge.type {
            case "button":
                buttons.append(element)
            case "staticText":
                textFields.append(element)
            case "image":
                images.append(element)
            case "group":
                groups.append(element)
            default:
                other.append(element)
            }
        }

        let elements = DetectedElements(
            buttons: buttons,
            textFields: textFields,
            images: images,
            groups: groups,
            other: other
        )

        return ElementDetectionResult(
            snapshotId: snapshotId ?? UUID().uuidString,
            screenshotPath: "",
            elements: elements,
            metadata: DetectionMetadata(
                detectionTime: 0.001, // Near-instant: just reading a file
                elementCount: bridgeElements.count,
                method: "gameBridge",
                warnings: [],
                windowContext: windowContext,
                isDialog: false
            )
        )
    }

    private static func mapToElementType(_ type: String) -> ElementType {
        switch type {
        case "button": return .button
        case "staticText": return .staticText
        case "image": return .image
        case "group": return .group
        default: return .other
        }
    }
}
