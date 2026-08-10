import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

enum VerifyStateStatus: String, Sendable {
    case satisfied
    case unsatisfied
    case unknown
}

enum VerifyStatePredicateContract {
    static let schemaDescription =
        """
        Each item must be a JSON object, never a prose string or AX expression. Supported shapes:
        {"kind":"window_exists","expected":true}
        {"kind":"window_bounds","bounds":{"x":0,"y":0,"width":800,"height":600},"tolerance":1}
        {"kind":"element_exists","selector":{"identifier":"save-button"},"expected":true}
        {"kind":"element_value","selector":{"identifier":"basic-text-field"},"expected_value":"Ready"}
        {"kind":"element_enabled","selector":{"label":"Save"},"expected":true}
        {"kind":"element_selected","selector":{"role":"AXCheckBox"},"expected":true}
        Selectors accept one or more exact identifier, label, or role fields.
        """

    static let malformedInputMessage =
        """
        predicates must be an array of structured JSON objects, not prose strings or AX expressions. For example: \
        {"kind":"element_value","selector":{"identifier":"basic-text-field"},"expected_value":"Ready"}
        """
}

struct VerifyStateRequest: Sendable {
    static let defaultTimeoutMilliseconds = 5000
    static let maximumTimeoutMilliseconds = 10000
    static let pollIntervalMilliseconds = 100

    enum Target: Sendable {
        case application(String)
        case pid(Int32)
    }

    let target: Target
    let windowID: CGWindowID?
    let windowTitle: String?
    let windowIndex: Int?
    let predicates: [VerifyStatePredicate]
    let timeoutMilliseconds: Int
    let stableSamples: Int
    let finalScreenshot: Bool

    init(
        target: Target,
        windowID: CGWindowID?,
        windowTitle: String? = nil,
        windowIndex: Int? = nil,
        predicates: [VerifyStatePredicate],
        timeoutMilliseconds: Int,
        stableSamples: Int,
        finalScreenshot: Bool)
    {
        self.target = target
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.windowIndex = windowIndex
        self.predicates = predicates
        self.timeoutMilliseconds = timeoutMilliseconds
        self.stableSamples = stableSamples
        self.finalScreenshot = finalScreenshot
    }

    init(arguments: ToolArguments) throws {
        if let predicatesValue = arguments.getValue(for: "predicates") {
            guard case let .array(predicateValues) = predicatesValue,
                  predicateValues.allSatisfy({ value in
                      if case .object = value {
                          true
                      } else {
                          false
                      }
                  })
            else {
                throw VerifyStateInputError(VerifyStatePredicateContract.malformedInputMessage)
            }
        }

        let input = try arguments.decode(VerifyStateInput.self)
        let normalizedApp = input.app?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (normalizedApp?.isEmpty == false ? normalizedApp : nil, input.pid) {
        case let (.some(app), nil):
            self.target = .application(app)
        case let (nil, .some(pid)) where pid > 0 && Int32(exactly: pid) != nil:
            self.target = .pid(Int32(pid))
        case (nil, .some):
            throw VerifyStateInputError("pid must be a positive Int32 value")
        case (nil, nil):
            throw VerifyStateInputError("exactly one of app or pid is required")
        case (.some, .some):
            throw VerifyStateInputError("app and pid are mutually exclusive")
        }

        if let windowID = input.windowID {
            guard windowID > 0, let exactWindowID = CGWindowID(exactly: windowID) else {
                throw VerifyStateInputError("window_id must be between 1 and \(UInt32.max)")
            }
            self.windowID = exactWindowID
        } else {
            self.windowID = nil
        }
        self.windowTitle = input.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.windowIndex = input.windowIndex
        let selectors = [self.windowID != nil, self.windowTitle?.isEmpty == false, self.windowIndex != nil]
        guard selectors.count(where: { $0 }) <= 1 else {
            throw VerifyStateInputError("window_id, window_title, and window_index are mutually exclusive")
        }
        guard self.windowTitle?.isEmpty != true else { throw VerifyStateInputError("window_title must not be empty") }
        guard self.windowIndex.map({ $0 >= 0 }) ?? true else {
            throw VerifyStateInputError("window_index must be 0 or greater")
        }

        guard (1...8).contains(input.predicates.count) else {
            throw VerifyStateInputError("predicates must contain between 1 and 8 AND predicates")
        }
        self.predicates = try input.predicates.map(VerifyStatePredicate.init)

        let timeout = input.timeoutMilliseconds ?? Self.defaultTimeoutMilliseconds
        guard (100...Self.maximumTimeoutMilliseconds).contains(timeout) else {
            throw VerifyStateInputError("timeout_ms must be between 100 and 10000")
        }
        self.timeoutMilliseconds = timeout

        let stableSamples = input.stableSamples ?? 2
        guard (1...10).contains(stableSamples) else {
            throw VerifyStateInputError("stable_samples must be between 1 and 10")
        }
        self.stableSamples = stableSamples
        self.finalScreenshot = input.finalScreenshot ?? false
    }

    var needsAccessibilityTree: Bool {
        self.predicates.contains(where: \.needsAccessibilityTree)
    }

    var windowBoundsRequirements: [VerifyStateWindowBoundsRequirement] {
        self.predicates.compactMap { predicate in
            guard case let .windowBounds(bounds, tolerance) = predicate else { return nil }
            return VerifyStateWindowBoundsRequirement(bounds: bounds, tolerance: tolerance)
        }
    }

    var receiptTargetMetadata: Value {
        var target: [String: Value] = switch self.target {
        case let .application(application):
            ["application": .string(application)]
        case let .pid(pid):
            ["pid": .int(Int(pid))]
        }
        if let windowID {
            target["window_id"] = .int(Int(windowID))
        }
        if let windowTitle {
            target["window_title"] = .string(windowTitle)
        }
        if let windowIndex {
            target["window_index"] = .int(windowIndex)
        }
        return .object(target)
    }
}

private struct VerifyStateInput: Decodable {
    let app: String?
    let pid: Int?
    let windowID: Int?
    let windowTitle: String?
    let windowIndex: Int?
    let predicates: [VerifyStatePredicateInput]
    let timeoutMilliseconds: Int?
    let stableSamples: Int?
    let finalScreenshot: Bool?

    enum CodingKeys: String, CodingKey {
        case app, pid, predicates
        case windowID = "window_id"
        case windowTitle = "window_title"
        case windowIndex = "window_index"
        case timeoutMilliseconds = "timeout_ms"
        case stableSamples = "stable_samples"
        case finalScreenshot = "final_screenshot"
    }
}

private struct VerifyStatePredicateInput: Decodable {
    let kind: String
    let expected: Bool?
    let expectedValue: String?
    let selector: VerifyStateElementSelector?
    let bounds: VerifyStateBounds?
    let tolerance: Double?

    enum CodingKeys: String, CodingKey {
        case kind, expected, selector, bounds, tolerance
        case expectedValue = "expected_value"
    }
}

enum VerifyStatePredicate: Sendable {
    case windowExists(Bool)
    case windowBounds(VerifyStateBounds, tolerance: Double)
    case elementExists(VerifyStateElementSelector, Bool)
    case elementValue(VerifyStateElementSelector, String)
    case elementEnabled(VerifyStateElementSelector, Bool)
    case elementSelected(VerifyStateElementSelector, Bool)

    fileprivate init(_ input: VerifyStatePredicateInput) throws {
        switch input.kind {
        case "window_exists":
            self = try .windowExists(Self.required(input.expected, field: "expected", kind: input.kind))
        case "window_bounds":
            let bounds = try Self.required(input.bounds, field: "bounds", kind: input.kind)
            try bounds.validate()
            let tolerance = input.tolerance ?? 1
            guard tolerance.isFinite, (0...100).contains(tolerance) else {
                throw VerifyStateInputError("window_bounds tolerance must be between 0 and 100")
            }
            self = .windowBounds(bounds, tolerance: tolerance)
        case "element_exists":
            self = try .elementExists(
                Self.selector(input, kind: input.kind),
                Self.required(input.expected, field: "expected", kind: input.kind))
        case "element_value":
            self = try .elementValue(
                Self.selector(input, kind: input.kind),
                Self.required(input.expectedValue, field: "expected_value", kind: input.kind))
        case "element_enabled":
            self = try .elementEnabled(
                Self.selector(input, kind: input.kind),
                Self.required(input.expected, field: "expected", kind: input.kind))
        case "element_selected":
            self = try .elementSelected(
                Self.selector(input, kind: input.kind),
                Self.required(input.expected, field: "expected", kind: input.kind))
        default:
            throw VerifyStateInputError("unknown predicate kind '\(input.kind)'")
        }
    }

    var needsAccessibilityTree: Bool {
        switch self {
        case .windowExists, .windowBounds:
            false
        case .elementExists, .elementValue, .elementEnabled, .elementSelected:
            true
        }
    }

    var kind: String {
        switch self {
        case .windowExists: "window_exists"
        case .windowBounds: "window_bounds"
        case .elementExists: "element_exists"
        case .elementValue: "element_value"
        case .elementEnabled: "element_enabled"
        case .elementSelected: "element_selected"
        }
    }

    var receiptMetadata: [String: Value] {
        var metadata: [String: Value] = ["kind": .string(self.kind)]
        switch self {
        case let .windowExists(expected):
            metadata["expected"] = .bool(expected)
        case let .windowBounds(bounds, tolerance):
            metadata["bounds"] = bounds.receiptMetadata
            metadata["tolerance"] = .double(tolerance)
        case let .elementExists(selector, expected),
             let .elementEnabled(selector, expected),
             let .elementSelected(selector, expected):
            metadata["selector"] = selector.receiptMetadata
            metadata["expected"] = .bool(expected)
        case let .elementValue(selector, expectedValue):
            metadata["selector"] = selector.receiptMetadata
            metadata["expected_value"] = .string(expectedValue)
        }
        return metadata
    }

    private static func selector(
        _ input: VerifyStatePredicateInput,
        kind: String) throws -> VerifyStateElementSelector
    {
        let selector = try Self.required(input.selector, field: "selector", kind: kind)
        try selector.validate()
        return selector
    }

    private static func required<T>(_ value: T?, field: String, kind: String) throws -> T {
        guard let value else {
            throw VerifyStateInputError("\(kind) requires \(field)")
        }
        return value
    }
}

struct VerifyStateElementSelector: Decodable, Sendable, Equatable {
    let identifier: String?
    let label: String?
    let role: String?

    func validate() throws {
        let values = [self.identifier, self.label, self.role]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else {
            throw VerifyStateInputError("element selector requires identifier, label, or role")
        }
    }

    func matches(_ element: DetectedElement) -> Bool {
        if let identifier, element.attributes["identifier"] != identifier {
            return false
        }
        if let label, element.label != label {
            return false
        }
        if let role {
            let detectedRoles = [element.attributes["role"], element.type.rawValue].compactMap(\.self)
            if !detectedRoles.contains(where: {
                $0.compare(role, options: .caseInsensitive) == .orderedSame
            }) {
                return false
            }
        }
        return true
    }

    var hasExactIdentifier: Bool {
        self.identifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var description: String {
        [
            self.identifier.map { "identifier=\($0)" },
            self.label.map { "label=\($0)" },
            self.role.map { "role=\($0)" },
        ]
            .compactMap(\.self)
            .joined(separator: ", ")
    }

    var receiptMetadata: Value {
        var metadata: [String: Value] = [:]
        if let identifier {
            metadata["identifier"] = .string(identifier)
        }
        if let label {
            metadata["label"] = .string(label)
        }
        if let role {
            metadata["role"] = .string(role)
        }
        return .object(metadata)
    }
}

struct VerifyStateBounds: Decodable, Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    func validate() throws {
        guard [self.x, self.y, self.width, self.height].allSatisfy(\.isFinite),
              self.width >= 0,
              self.height >= 0
        else {
            throw VerifyStateInputError("window_bounds requires finite coordinates and non-negative dimensions")
        }
    }

    func matches(_ rect: CGRect, tolerance: Double) -> Bool {
        abs(Double(rect.origin.x) - self.x) <= tolerance &&
            abs(Double(rect.origin.y) - self.y) <= tolerance &&
            abs(Double(rect.width) - self.width) <= tolerance &&
            abs(Double(rect.height) - self.height) <= tolerance
    }

    var description: String {
        "x=\(Self.number(self.x)), y=\(Self.number(self.y)), " +
            "width=\(Self.number(self.width)), height=\(Self.number(self.height))"
    }

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.width)
        self.height = Double(rect.height)
    }

    var receiptMetadata: Value {
        .object([
            "x": .double(self.x),
            "y": .double(self.y),
            "width": .double(self.width),
            "height": .double(self.height),
        ])
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct VerifyStateWindowBoundsRequirement: Sendable, Equatable {
    let bounds: VerifyStateBounds
    let tolerance: Double

    func matches(_ rect: CGRect) -> Bool {
        self.bounds.matches(rect, tolerance: self.tolerance)
    }
}

struct VerifyStatePredicateResult: Sendable, Equatable {
    let kind: String
    let status: VerifyStateStatus
    let detail: String
    let observed: String?
}

struct VerifyStateSample: Sendable, Equatable {
    let status: VerifyStateStatus
    let application: ServiceApplicationInfo?
    let window: ServiceWindowInfo?
    let predicates: [VerifyStatePredicateResult]
    let reason: String?

    var stabilityFingerprint: String {
        let target = "\(self.application?.processIdentifier ?? -1):\(self.window?.windowID ?? -1)"
        return ([target] + self.predicates.map { "\($0.kind):\($0.status.rawValue):\($0.observed ?? "nil")" })
            .joined(separator: "|")
    }
}

struct VerifyStateInputError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        self.message
    }
}
