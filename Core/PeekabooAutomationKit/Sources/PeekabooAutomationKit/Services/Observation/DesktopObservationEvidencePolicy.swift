import PeekabooFoundation

/// Validates that a screenshot-backed accessibility observation contains usable semantic evidence.
public enum DesktopObservationEvidencePolicy {
    public static func requireFreshAccessibilityEvidence(
        _ metadata: DetectionMetadata?,
        requested: Bool) throws
    {
        if let error = self.freshAccessibilityEvidenceError(metadata, requested: requested) {
            throw error
        }
    }

    public static func freshAccessibilityEvidenceError(
        _ metadata: DetectionMetadata?,
        requested: Bool) -> PeekabooError?
    {
        guard requested else { return nil }
        guard metadata?.usedAccessibilityCache == false,
              metadata?.windowContext?.requiresFreshAccessibilityTree == true
        else {
            return .accessibilityIncomplete(
                "Fresh Accessibility was requested, but the host did not prove an uncached AX traversal. " +
                    "Update the runtime host or observe again; cached or unproven results cannot satisfy this request.")
        }
        return nil
    }

    public static func requireUsableAccessibilityEvidence(
        _ elements: ElementDetectionResult?,
        target: ResolvedObservationTarget,
        capture: CaptureResult,
        request: DesktopObservationRequest) throws
    {
        if let error = self.accessibilityEvidenceError(
            elements,
            target: target,
            capture: capture,
            request: request)
        {
            throw error
        }
    }

    public static func accessibilityEvidenceError(
        _ elements: ElementDetectionResult?,
        target: ResolvedObservationTarget,
        capture: CaptureResult,
        request: DesktopObservationRequest) -> PeekabooError?
    {
        if let freshnessError = self.freshAccessibilityEvidenceError(
            elements?.metadata,
            requested: request.detection.requiresFreshAccessibilityTree)
        {
            return freshnessError
        }
        guard request.detection.mode != .none else { return nil }

        let exactWindowID = elements?.metadata.windowContext?.windowID ??
            target.detectionContext?.windowID ??
            target.window?.windowID ??
            capture.metadata.windowInfo?.windowID
        guard let exactWindowID else { return nil }

        guard let elements else {
            return PeekabooError.accessibilityIncomplete(
                self.emptyExactWindowMessage(windowID: exactWindowID, budget: request.detection.traversalBudget))
        }
        guard elements.elements.all.isEmpty else { return nil }

        if let truncationInfo = elements.metadata.truncationInfo, truncationInfo.isTruncated {
            let message = truncationInfo.remediationMessage(
                budget: elements.metadata.windowContext?.traversalBudget ?? request.detection.traversalBudget,
                applicationScopedFallback: elements.metadata.isApplicationScopedAccessibilityFallback)
            if truncationInfo.deadlineReached {
                return PeekabooError.timeout(message)
            }
            if truncationInfo.incompleteAccessibilityRead {
                return PeekabooError.accessibilityIncomplete(message)
            }
            return PeekabooError.operationError(message: message)
        }

        // Older Bridge hosts could lose the incomplete-read marker while still returning an exact, empty AX map.
        // An exact combined observation cannot call that complete; callers that only need pixels request `.none`.
        return PeekabooError.accessibilityIncomplete(
            self.emptyExactWindowMessage(windowID: exactWindowID, budget: request.detection.traversalBudget))
    }

    private static func emptyExactWindowMessage(windowID: Int, budget: AXTraversalBudget?) -> String {
        let guidance = DetectionTruncationInfo(incompleteAccessibilityRead: true)
            .remediationMessage(budget: budget)
        return "Exact window \(windowID) returned no usable Accessibility elements. \(guidance)"
    }
}
