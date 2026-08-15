import Foundation
import PeekabooFoundation

/// Builds typed element detection output from the flat AX traversal result.
@_spi(Testing) public enum ElementDetectionResultBuilder {
    public static func makeResult(
        snapshotId: String,
        screenshotPath: String = "",
        elements: [DetectedElement],
        usedCache: Bool,
        windowContext: WindowContext?,
        isDialog: Bool,
        detectionTime: TimeInterval = 0.0,
        truncationInfo: DetectionTruncationInfo? = nil) -> ElementDetectionResult
    {
        var warnings: [String] = []
        if usedCache {
            warnings.append("ax_cache_hit")
        }
        if truncationInfo?.maxDepthReached == true {
            warnings.append("ax_truncated_depth")
        }
        if truncationInfo?.maxElementCountReached == true {
            warnings.append("ax_truncated_count")
        }
        if truncationInfo?.maxChildrenPerNodeReached == true {
            warnings.append("ax_truncated_children")
        }
        if truncationInfo?.deadlineReached == true {
            warnings.append("ax_truncated_deadline")
        }
        if truncationInfo?.incompleteAccessibilityRead == true {
            warnings.append("ax_incomplete_read")
        }

        let resolvedWindowContext = usedCache ? FocusedElementReceiptResolver.clearingObservedFocus(
            from: windowContext) : FocusedElementReceiptResolver.attachingObservedFocus(
            to: windowContext,
            elements: elements)
        return ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: screenshotPath,
            elements: self.group(elements),
            metadata: DetectionMetadata(
                detectionTime: detectionTime,
                elementCount: elements.count,
                method: usedCache ? "AXorcist (cached)" : "AXorcist",
                warnings: warnings,
                windowContext: resolvedWindowContext,
                isDialog: isDialog || DialogElementClassifier.containsDialog(in: elements),
                truncationInfo: truncationInfo))
    }

    public static func group(_ elements: [DetectedElement]) -> DetectedElements {
        DetectedElements(
            buttons: elements.filter { $0.type == .button },
            textFields: elements.filter { $0.type == .textField },
            links: elements.filter { $0.type == .link },
            images: elements.filter { $0.type == .image },
            groups: elements.filter { $0.type == .group },
            sliders: elements.filter { $0.type == .slider },
            checkboxes: elements.filter { $0.type == .checkbox },
            menus: elements.filter { $0.type == .menu },
            other: elements.filter { element in
                ![ElementType.button, .textField, .link, .image, .group, .slider, .checkbox, .menu]
                    .contains(element.type)
            })
    }
}
