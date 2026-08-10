import Foundation

public struct DesktopCaptureOptions: Sendable, Codable, Equatable {
    public var engine: CaptureEnginePreference
    public var scale: CaptureScalePreference
    public var focus: CaptureFocus
    public var visualizerMode: CaptureVisualizerMode
    public var includeMenuBar: Bool
    public var roi: CaptureRegionOfInterest?

    public init(
        engine: CaptureEnginePreference = .auto,
        scale: CaptureScalePreference = .logical1x,
        focus: CaptureFocus = .background,
        visualizerMode: CaptureVisualizerMode = .none,
        includeMenuBar: Bool = false,
        roi: CaptureRegionOfInterest? = nil)
    {
        self.engine = engine
        self.scale = scale
        self.focus = focus
        self.visualizerMode = visualizerMode
        self.includeMenuBar = includeMenuBar
        self.roi = roi
    }
}

public enum DetectionMode: Sendable, Codable, Equatable {
    case none
    case accessibility
    case accessibilityAndOCR
}

public struct AXTraversalBudget: Sendable, Codable, Equatable {
    public static let defaultMaxDepth = 12
    public static let defaultMaxElementCount = 1000
    public static let defaultMaxChildrenPerNode = 250

    public static let maxDepthEnvironmentKey = "PEEKABOO_AX_MAX_DEPTH"
    public static let maxElementCountEnvironmentKey = "PEEKABOO_AX_MAX_ELEMENTS"
    public static let maxChildrenPerNodeEnvironmentKey = "PEEKABOO_AX_MAX_CHILDREN"

    public var maxDepth: Int
    public var maxElementCount: Int
    public var maxChildrenPerNode: Int

    public init(
        maxDepth: Int = Self.defaultMaxDepth,
        maxElementCount: Int = Self.defaultMaxElementCount,
        maxChildrenPerNode: Int = Self.defaultMaxChildrenPerNode)
    {
        self.maxDepth = maxDepth
        self.maxElementCount = maxElementCount
        self.maxChildrenPerNode = maxChildrenPerNode
    }

    public static func resolved(
        maxDepth: Int? = nil,
        maxElementCount: Int? = nil,
        maxChildrenPerNode: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> AXTraversalBudget
    {
        AXTraversalBudget(
            maxDepth: self.resolvedLimit(
                explicit: maxDepth,
                environmentKey: self.maxDepthEnvironmentKey,
                defaultValue: self.defaultMaxDepth,
                environment: environment),
            maxElementCount: self.resolvedLimit(
                explicit: maxElementCount,
                environmentKey: self.maxElementCountEnvironmentKey,
                defaultValue: self.defaultMaxElementCount,
                environment: environment),
            maxChildrenPerNode: self.resolvedLimit(
                explicit: maxChildrenPerNode,
                environmentKey: self.maxChildrenPerNodeEnvironmentKey,
                defaultValue: self.defaultMaxChildrenPerNode,
                environment: environment))
    }

    @_spi(Testing) public static func intFromEnv(
        _ key: String,
        default defaultValue: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Int
    {
        guard
            let raw = environment[key],
            let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            parsed > 0
        else { return defaultValue }
        return parsed
    }

    private static func resolvedLimit(
        explicit: Int?,
        environmentKey: String,
        defaultValue: Int,
        environment: [String: String]) -> Int
    {
        if let explicit {
            return max(0, explicit)
        }
        return self.intFromEnv(environmentKey, default: defaultValue, environment: environment)
    }
}

public struct DetectionTruncationInfo: Sendable, Codable, Equatable {
    public let maxDepthReached: Bool
    public let maxElementCountReached: Bool
    public let maxChildrenPerNodeReached: Bool
    public let deadlineReached: Bool
    public let incompleteAccessibilityRead: Bool

    private enum CodingKeys: String, CodingKey {
        case maxDepthReached
        case maxElementCountReached
        case maxChildrenPerNodeReached
        case deadlineReached
        case incompleteAccessibilityRead
    }

    public init(
        maxDepthReached: Bool = false,
        maxElementCountReached: Bool = false,
        maxChildrenPerNodeReached: Bool = false,
        deadlineReached: Bool = false,
        incompleteAccessibilityRead: Bool = false)
    {
        self.maxDepthReached = maxDepthReached
        self.maxElementCountReached = maxElementCountReached
        self.maxChildrenPerNodeReached = maxChildrenPerNodeReached
        self.deadlineReached = deadlineReached
        self.incompleteAccessibilityRead = incompleteAccessibilityRead
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.maxDepthReached = try container.decode(Bool.self, forKey: .maxDepthReached)
        self.maxElementCountReached = try container.decode(Bool.self, forKey: .maxElementCountReached)
        self.maxChildrenPerNodeReached = try container.decode(Bool.self, forKey: .maxChildrenPerNodeReached)
        self.deadlineReached = try container.decodeIfPresent(Bool.self, forKey: .deadlineReached) ?? false
        self.incompleteAccessibilityRead = try container.decodeIfPresent(
            Bool.self,
            forKey: .incompleteAccessibilityRead) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.maxDepthReached, forKey: .maxDepthReached)
        try container.encode(self.maxElementCountReached, forKey: .maxElementCountReached)
        try container.encode(self.maxChildrenPerNodeReached, forKey: .maxChildrenPerNodeReached)
        try container.encode(self.deadlineReached, forKey: .deadlineReached)
        if self.incompleteAccessibilityRead {
            try container.encode(true, forKey: .incompleteAccessibilityRead)
        }
    }
}

extension DetectionTruncationInfo {
    public var isTruncated: Bool {
        self.maxDepthReached || self.maxElementCountReached || self.maxChildrenPerNodeReached ||
            self.deadlineReached || self.incompleteAccessibilityRead
    }

    public func remediationMessage(budget: AXTraversalBudget?) -> String {
        self.remediationMessage(budget: budget, style: .commandLine)
    }

    public func automationToolRemediationMessage(budget: AXTraversalBudget?) -> String {
        self.remediationMessage(budget: budget, style: .automationTool)
    }

    private func remediationMessage(
        budget: AXTraversalBudget?,
        style: DetectionRemediationStyle) -> String
    {
        let budget = budget ?? AXTraversalBudget()
        var limits: [String] = []
        if self.maxDepthReached {
            limits.append("depth \(budget.maxDepth)")
        }
        if self.maxElementCountReached {
            limits.append("element count \(budget.maxElementCount)")
        }
        if self.maxChildrenPerNodeReached {
            limits.append("children per node \(budget.maxChildrenPerNode)")
        }
        if self.deadlineReached {
            limits.append("time deadline")
        }
        if self.incompleteAccessibilityRead {
            limits.append("incomplete accessibility read")
        }

        let limitSummary = limits.isEmpty ? "the AX traversal budget" : limits.joined(separator: ", ")
        if self.incompleteAccessibilityRead {
            return switch style {
            case .commandLine:
                "Warning: AX tree incomplete at \(limitSummary). Retry once to obtain a fresh observation; " +
                    "if this persists, the target may " +
                    "not expose a readable Accessibility tree. Use a narrower window target or screenshot/OCR; " +
                    "increase the timeout only when the app is slow to respond."
            case .automationTool:
                "Warning: AX tree incomplete at \(limitSummary). Retry once with an exact app_target and " +
                    "window_id to obtain a fresh observation. If this persists, the target may not expose a " +
                    "readable Accessibility tree; " +
                    "use screenshot/OCR evidence instead."
            }
        }
        if self.deadlineReached {
            let structuralLimits = self.structuralLimitControls(style: style)
            let structuralGuidance = structuralLimits.isEmpty
                ? ""
                : " The result also reached \(structuralLimits.joined(separator: ", ")); " +
                "use larger AX traversal limits only for those reported caps."
            let retryGuidance = switch style {
            case .commandLine:
                "Retry with a longer caller timeout or a narrower target."
            case .automationTool:
                "Retry with an exact app_target and window_id; this tool does not expose a timeout argument."
            }
            return "Warning: AX tree truncated at \(limitSummary). \(retryGuidance)\(structuralGuidance)"
        }

        switch style {
        case .commandLine:
            return "Warning: AX tree truncated at \(limitSummary). Retry with larger --depth, --max-elements, " +
                "or --max-children values, or set \(AXTraversalBudget.maxDepthEnvironmentKey), " +
                "\(AXTraversalBudget.maxElementCountEnvironmentKey), or " +
                "\(AXTraversalBudget.maxChildrenPerNodeEnvironmentKey)."
        case .automationTool:
            let controls = self.structuralLimitControls(style: style)
            let guidance = controls.isEmpty
                ? "max_depth, max_elements, or max_children"
                : controls.joined(separator: ", ")
            return "Warning: AX tree truncated at \(limitSummary). Retry with larger \(guidance) tool arguments."
        }
    }

    private func structuralLimitControls(style: DetectionRemediationStyle) -> [String] {
        switch style {
        case .commandLine:
            ([
                self.maxDepthReached ? "--depth" : nil,
                self.maxElementCountReached ? "--max-elements" : nil,
                self.maxChildrenPerNodeReached ? "--max-children" : nil,
            ] as [String?]).compactMap(\.self)
        case .automationTool:
            ([
                self.maxDepthReached ? "max_depth" : nil,
                self.maxElementCountReached ? "max_elements" : nil,
                self.maxChildrenPerNodeReached ? "max_children" : nil,
            ] as [String?]).compactMap(\.self)
        }
    }

    static func merge(
        _ lhs: DetectionTruncationInfo?,
        _ rhs: DetectionTruncationInfo?) -> DetectionTruncationInfo?
    {
        guard lhs != nil || rhs != nil else { return nil }
        return DetectionTruncationInfo(
            maxDepthReached: lhs?.maxDepthReached == true || rhs?.maxDepthReached == true,
            maxElementCountReached: lhs?.maxElementCountReached == true || rhs?.maxElementCountReached == true,
            maxChildrenPerNodeReached: lhs?.maxChildrenPerNodeReached == true || rhs?.maxChildrenPerNodeReached == true,
            deadlineReached: lhs?.deadlineReached == true || rhs?.deadlineReached == true,
            incompleteAccessibilityRead: lhs?.incompleteAccessibilityRead == true ||
                rhs?.incompleteAccessibilityRead == true)
    }
}

private enum DetectionRemediationStyle {
    case commandLine
    case automationTool
}

public struct DesktopDetectionOptions: Sendable, Codable, Equatable {
    public var mode: DetectionMode
    public var allowWebFocusFallback: Bool
    public var includeMenuBarElements: Bool
    public var preferOCR: Bool
    public var traversalBudget: AXTraversalBudget

    public init(
        mode: DetectionMode = .accessibility,
        allowWebFocusFallback: Bool = false,
        includeMenuBarElements: Bool = false,
        preferOCR: Bool = false,
        traversalBudget: AXTraversalBudget = AXTraversalBudget.resolved())
    {
        self.mode = mode
        self.allowWebFocusFallback = allowWebFocusFallback
        self.includeMenuBarElements = includeMenuBarElements
        self.preferOCR = preferOCR
        self.traversalBudget = traversalBudget
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case allowWebFocusFallback
        case includeMenuBarElements
        case preferOCR
        case traversalBudget
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try container.decode(DetectionMode.self, forKey: .mode)
        self.allowWebFocusFallback = try container.decodeIfPresent(Bool.self, forKey: .allowWebFocusFallback) ?? false
        self.includeMenuBarElements = try container.decodeIfPresent(Bool.self, forKey: .includeMenuBarElements) ?? false
        self.preferOCR = try container.decode(Bool.self, forKey: .preferOCR)
        self.traversalBudget = try container.decodeIfPresent(AXTraversalBudget.self, forKey: .traversalBudget)
            ?? AXTraversalBudget.resolved()
    }
}

public struct DesktopObservationOutputOptions: Sendable, Codable, Equatable {
    public var path: String?
    public var format: ImageFormat
    public var saveRawScreenshot: Bool
    public var saveAnnotatedScreenshot: Bool
    public var saveSnapshot: Bool
    public var snapshotID: String?

    public init(
        path: String? = nil,
        format: ImageFormat = .png,
        saveRawScreenshot: Bool = false,
        saveAnnotatedScreenshot: Bool = false,
        saveSnapshot: Bool = false,
        snapshotID: String? = nil)
    {
        self.path = path
        self.format = format
        self.saveRawScreenshot = saveRawScreenshot
        self.saveAnnotatedScreenshot = saveAnnotatedScreenshot
        self.saveSnapshot = saveSnapshot
        self.snapshotID = snapshotID
    }
}

public struct DesktopObservationTimeouts: Sendable, Codable, Equatable {
    public var overall: TimeInterval?
    public var detection: TimeInterval?
    public var ocr: TimeInterval?

    public init(overall: TimeInterval? = nil, detection: TimeInterval? = nil, ocr: TimeInterval? = nil) {
        self.overall = overall
        self.detection = detection
        self.ocr = ocr
    }
}

public struct DesktopObservationRequest: Sendable, Codable, Equatable {
    public var target: DesktopObservationTargetRequest
    public var capture: DesktopCaptureOptions
    public var detection: DesktopDetectionOptions
    public var output: DesktopObservationOutputOptions
    public var timeout: DesktopObservationTimeouts

    public init(
        target: DesktopObservationTargetRequest,
        capture: DesktopCaptureOptions = DesktopCaptureOptions(),
        detection: DesktopDetectionOptions = DesktopDetectionOptions(),
        output: DesktopObservationOutputOptions = DesktopObservationOutputOptions(),
        timeout: DesktopObservationTimeouts = DesktopObservationTimeouts())
    {
        self.target = target
        self.capture = capture
        self.detection = detection
        self.output = output
        self.timeout = timeout
    }
}
