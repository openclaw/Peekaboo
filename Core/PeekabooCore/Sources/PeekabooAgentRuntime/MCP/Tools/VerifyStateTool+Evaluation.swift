import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKit

enum VerifyStateAccessibilityEvidence: Sendable {
    case complete([DetectedElement])
    case incompleteTraversal([DetectedElement], reason: String)
    case unavailable(String)
}

extension VerifyStateTool {
    static func evaluate(
        request: VerifyStateRequest,
        application: ServiceApplicationInfo,
        window: ServiceWindowInfo,
        accessibilityEvidence: VerifyStateAccessibilityEvidence?) -> VerifyStateSample
    {
        let results = request.predicates.map { predicate in
            self.evaluate(
                predicate,
                window: window,
                accessibilityEvidence: accessibilityEvidence)
        }
        return VerifyStateSample(
            status: self.aggregate(results),
            application: application,
            window: window,
            predicates: results,
            reason: results.first(where: { $0.status == .unknown })?.detail)
    }

    static func evaluateMissingTarget(
        request: VerifyStateRequest,
        application: ServiceApplicationInfo? = nil,
        reason: String) -> VerifyStateSample
    {
        let results = request.predicates.map { predicate -> VerifyStatePredicateResult in
            switch predicate {
            case let .windowExists(expected):
                return self.booleanResult(
                    kind: predicate.kind,
                    expected: expected,
                    actual: false,
                    detail: reason)
            case let .elementExists(selector, expected):
                return self.booleanResult(
                    kind: predicate.kind,
                    expected: expected,
                    actual: false,
                    detail: "\(selector.description): \(reason)",
                    observed: "count=0")
            case .windowBounds, .elementValue, .elementEnabled, .elementSelected:
                return VerifyStatePredicateResult(
                    kind: predicate.kind,
                    status: .unsatisfied,
                    detail: reason,
                    observed: nil)
            }
        }
        return VerifyStateSample(
            status: self.aggregate(results),
            application: application,
            window: nil,
            predicates: results,
            reason: reason)
    }

    static func unknownSample(
        request: VerifyStateRequest,
        application: ServiceApplicationInfo? = nil,
        reason: String) -> VerifyStateSample
    {
        VerifyStateSample(
            status: .unknown,
            application: application,
            window: nil,
            predicates: request.predicates.map {
                VerifyStatePredicateResult(kind: $0.kind, status: .unknown, detail: reason, observed: nil)
            },
            reason: reason)
    }

    private static func evaluate(
        _ predicate: VerifyStatePredicate,
        window: ServiceWindowInfo,
        accessibilityEvidence: VerifyStateAccessibilityEvidence?) -> VerifyStatePredicateResult
    {
        switch predicate {
        case let .windowExists(expected):
            return self.booleanResult(
                kind: predicate.kind,
                expected: expected,
                actual: true,
                detail: "window_id=\(window.windowID)")
        case let .windowBounds(expected, tolerance):
            let actual = VerifyStateBounds(window.bounds)
            return VerifyStatePredicateResult(
                kind: predicate.kind,
                status: expected.matches(window.bounds, tolerance: tolerance) ? .satisfied : .unsatisfied,
                detail: "expected \(expected.description) ±\(String(format: "%.2f", tolerance))",
                observed: actual.description)
        case let .elementExists(selector, expected):
            guard case let .complete(elements) = accessibilityEvidence else {
                return self.axUnknown(predicate, reason: accessibilityEvidence?.unknownReason)
            }
            let count = elements.count(where: selector.matches)
            return self.booleanResult(
                kind: predicate.kind,
                expected: expected,
                actual: count > 0,
                detail: selector.description,
                observed: "count=\(count)")
        case let .elementValue(selector, expected):
            return self.elementValueState(
                predicate,
                selector: selector,
                expected: expected,
                accessibilityEvidence: accessibilityEvidence)
        case let .elementEnabled(selector, expected):
            return self.elementState(
                predicate,
                selector: selector,
                accessibilityEvidence: accessibilityEvidence)
            { element in
                guard element.attributes["axEnabledKnown"] == "true" else {
                    return (.unknown, "<AXEnabled unavailable>")
                }
                return (element.isEnabled == expected ? .satisfied : .unsatisfied, String(element.isEnabled))
            }
        case let .elementSelected(selector, expected):
            return self.elementState(
                predicate,
                selector: selector,
                accessibilityEvidence: accessibilityEvidence)
            { element in
                guard let selected = element.isSelected else {
                    return (.unknown, "<AXSelected unavailable>")
                }
                return (selected == expected ? .satisfied : .unsatisfied, String(selected))
            }
        }
    }

    private static func elementValueState(
        _ predicate: VerifyStatePredicate,
        selector: VerifyStateElementSelector,
        expected: String,
        accessibilityEvidence: VerifyStateAccessibilityEvidence?) -> VerifyStatePredicateResult
    {
        switch accessibilityEvidence {
        case let .complete(elements):
            return self.elementState(predicate, selector: selector, elements: elements) { element in
                let actual = element.value
                return (actual == expected ? .satisfied : .unsatisfied, actual ?? "<no value>")
            }
        case let .incompleteTraversal(elements, reason):
            guard selector.hasExactIdentifier else {
                return self.axUnknown(
                    predicate,
                    reason: "\(reason); direct positive value proof requires an exact accessibility identifier")
            }
            // Emitted elements have a complete descriptor read; the global incomplete flag can come from a sibling.
            let matches = elements.filter(selector.matches)
            guard matches.count == 1, let element = matches.first else {
                let detail = matches.isEmpty
                    ? "No element matches \(selector.description)"
                    : "Selector is ambiguous: \(matches.count) elements match \(selector.description)"
                return VerifyStatePredicateResult(
                    kind: predicate.kind,
                    status: .unknown,
                    detail: "\(detail); \(reason)",
                    observed: "count=\(matches.count)")
            }
            let actual = element.value
            guard actual == expected else {
                return VerifyStatePredicateResult(
                    kind: predicate.kind,
                    status: .unknown,
                    detail: "\(selector.description): \(reason); an incomplete traversal cannot disprove " +
                        "the expected value",
                    observed: actual ?? "<no value>")
            }
            return VerifyStatePredicateResult(
                kind: predicate.kind,
                status: .satisfied,
                detail: "\(selector.description): direct value match from an incomplete traversal",
                observed: actual)
        case let .unavailable(reason):
            return self.axUnknown(predicate, reason: reason)
        case nil:
            return self.axUnknown(predicate, reason: nil)
        }
    }

    private static func elementState(
        _ predicate: VerifyStatePredicate,
        selector: VerifyStateElementSelector,
        accessibilityEvidence: VerifyStateAccessibilityEvidence?,
        read: (DetectedElement) -> (VerifyStateStatus, String)) -> VerifyStatePredicateResult
    {
        guard case let .complete(elements) = accessibilityEvidence else {
            return self.axUnknown(predicate, reason: accessibilityEvidence?.unknownReason)
        }
        return self.elementState(predicate, selector: selector, elements: elements, read: read)
    }

    private static func elementState(
        _ predicate: VerifyStatePredicate,
        selector: VerifyStateElementSelector,
        elements: [DetectedElement],
        read: (DetectedElement) -> (VerifyStateStatus, String)) -> VerifyStatePredicateResult
    {
        let matches = elements.filter(selector.matches)
        guard matches.count == 1, let element = matches.first else {
            let status: VerifyStateStatus = matches.isEmpty ? .unsatisfied : .unknown
            let detail = matches.isEmpty
                ? "No element matches \(selector.description)"
                : "Selector is ambiguous: \(matches.count) elements match \(selector.description)"
            return VerifyStatePredicateResult(
                kind: predicate.kind,
                status: status,
                detail: detail,
                observed: "count=\(matches.count)")
        }
        let (status, observed) = read(element)
        return VerifyStatePredicateResult(
            kind: predicate.kind,
            status: status,
            detail: status == .unknown ? "\(selector.description): \(observed)" : selector.description,
            observed: observed)
    }

    private static func axUnknown(
        _ predicate: VerifyStatePredicate,
        reason: String?) -> VerifyStatePredicateResult
    {
        VerifyStatePredicateResult(
            kind: predicate.kind,
            status: .unknown,
            detail: reason ?? "Accessibility state is unavailable",
            observed: nil)
    }

    private static func booleanResult(
        kind: String,
        expected: Bool,
        actual: Bool,
        detail: String,
        observed: String? = nil) -> VerifyStatePredicateResult
    {
        VerifyStatePredicateResult(
            kind: kind,
            status: expected == actual ? .satisfied : .unsatisfied,
            detail: detail,
            observed: observed ?? String(actual))
    }

    private static func aggregate(_ results: [VerifyStatePredicateResult]) -> VerifyStateStatus {
        if results.contains(where: { $0.status == .unsatisfied }) {
            return .unsatisfied
        }
        if results.contains(where: { $0.status == .unknown }) {
            return .unknown
        }
        return .satisfied
    }
}

extension VerifyStateAccessibilityEvidence {
    fileprivate var unknownReason: String? {
        switch self {
        case .complete:
            nil
        case let .incompleteTraversal(_, reason), let .unavailable(reason):
            reason
        }
    }
}
