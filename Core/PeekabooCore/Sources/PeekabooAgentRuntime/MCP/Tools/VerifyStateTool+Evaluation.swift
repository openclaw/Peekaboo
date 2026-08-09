import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKit

extension VerifyStateTool {
    static func evaluate(
        request: VerifyStateRequest,
        application: ServiceApplicationInfo,
        window: ServiceWindowInfo,
        elements: [DetectedElement]?,
        accessibilityUnknownReason: String?) -> VerifyStateSample
    {
        let results = request.predicates.map { predicate in
            self.evaluate(
                predicate,
                window: window,
                elements: elements,
                accessibilityUnknownReason: accessibilityUnknownReason)
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
        elements: [DetectedElement]?,
        accessibilityUnknownReason: String?) -> VerifyStatePredicateResult
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
            guard let elements else {
                return self.axUnknown(predicate, reason: accessibilityUnknownReason)
            }
            let count = elements.count(where: selector.matches)
            return self.booleanResult(
                kind: predicate.kind,
                expected: expected,
                actual: count > 0,
                detail: selector.description,
                observed: "count=\(count)")
        case let .elementValue(selector, expected):
            return self.elementState(
                predicate,
                selector: selector,
                elements: elements,
                accessibilityUnknownReason: accessibilityUnknownReason)
            { element in
                let actual = element.value
                return (actual == expected ? .satisfied : .unsatisfied, actual ?? "<no value>")
            }
        case let .elementEnabled(selector, expected):
            return self.elementState(
                predicate,
                selector: selector,
                elements: elements,
                accessibilityUnknownReason: accessibilityUnknownReason)
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
                elements: elements,
                accessibilityUnknownReason: accessibilityUnknownReason)
            { element in
                guard let selected = element.isSelected else {
                    return (.unknown, "<AXSelected unavailable>")
                }
                return (selected == expected ? .satisfied : .unsatisfied, String(selected))
            }
        }
    }

    private static func elementState(
        _ predicate: VerifyStatePredicate,
        selector: VerifyStateElementSelector,
        elements: [DetectedElement]?,
        accessibilityUnknownReason: String?,
        read: (DetectedElement) -> (VerifyStateStatus, String)) -> VerifyStatePredicateResult
    {
        guard let elements else {
            return self.axUnknown(predicate, reason: accessibilityUnknownReason)
        }
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
