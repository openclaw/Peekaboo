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
        truncationInfo: DetectionTruncationInfo? = nil,
        applicationScopedAccessibilityFallbackOrigin: ApplicationScopedAccessibilityFallbackOrigin? = nil,
        corroboratedFocusedElementID: String? = nil,
        additionalWarnings: [String] = []) -> ElementDetectionResult
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
        warnings.append(contentsOf: additionalWarnings)

        let resolvedWindowContext = if usedCache || applicationScopedAccessibilityFallbackOrigin != nil {
            FocusedElementReceiptResolver.clearingObservedFocus(from: windowContext)
        } else {
            FocusedElementReceiptResolver.attachingObservedFocus(
                to: windowContext,
                elements: elements,
                corroboratedElementID: truncationInfo?.isTruncated == true ||
                    warnings.contains(DetectionMetadata.applicationScopedAccessibilityFallbackWarning)
                    ? nil : corroboratedFocusedElementID)
        }
        let focusedSelectionAvailable = !usedCache && truncationInfo?.isTruncated != true &&
            applicationScopedAccessibilityFallbackOrigin == nil &&
            !warnings.contains(DetectionMetadata.applicationScopedAccessibilityFallbackWarning)
        let selectedElements = elements.map { element in
            guard element.selectedTextRange != nil, focusedSelectionAvailable, let context = resolvedWindowContext,
                  let focused = context.focusedElement, element.isFocused == true,
                  let identity = try? FocusedElementReceiptResolver.receipt(element: element, context: context),
                  FocusedElementReceiptResolver.matches(identity, expected: focused)
            else { return element.replacingSelectedTextRange(nil) }
            return element
        }
        return ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: screenshotPath,
            elements: self.group(selectedElements),
            metadata: DetectionMetadata(
                detectionTime: detectionTime,
                elementCount: elements.count,
                method: usedCache ? "AXorcist (cached)" : "AXorcist",
                warnings: warnings,
                windowContext: resolvedWindowContext,
                isDialog: isDialog || DialogElementClassifier.containsDialog(in: elements),
                truncationInfo: truncationInfo,
                applicationScopedAccessibilityFallbackOrigin: applicationScopedAccessibilityFallbackOrigin))
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
