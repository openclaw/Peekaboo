import Foundation

public struct DesktopCaptureOptions: Sendable, Codable, Equatable {
    public var engine: CaptureEnginePreference
    public var scale: CaptureScalePreference
    public var focus: CaptureFocus
    public var visualizerMode: CaptureVisualizerMode
    public var includeMenuBar: Bool

    public init(
        engine: CaptureEnginePreference = .auto,
        scale: CaptureScalePreference = .logical1x,
        focus: CaptureFocus = .auto,
        visualizerMode: CaptureVisualizerMode = .screenshotFlash,
        includeMenuBar: Bool = false)
    {
        self.engine = engine
        self.scale = scale
        self.focus = focus
        self.visualizerMode = visualizerMode
        self.includeMenuBar = includeMenuBar
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

    public init(
        maxDepthReached: Bool = false,
        maxElementCountReached: Bool = false,
        maxChildrenPerNodeReached: Bool = false)
    {
        self.maxDepthReached = maxDepthReached
        self.maxElementCountReached = maxElementCountReached
        self.maxChildrenPerNodeReached = maxChildrenPerNodeReached
    }
}

extension DetectionTruncationInfo {
    public var isTruncated: Bool {
        self.maxDepthReached || self.maxElementCountReached || self.maxChildrenPerNodeReached
    }

    public func remediationMessage(budget: AXTraversalBudget?) -> String {
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

        let limitSummary = limits.isEmpty ? "the AX traversal budget" : limits.joined(separator: ", ")
        return "Warning: AX tree truncated at \(limitSummary). Retry with larger --max-depth, --max-elements, " +
            "or --max-children values, or set \(AXTraversalBudget.maxDepthEnvironmentKey), " +
            "\(AXTraversalBudget.maxElementCountEnvironmentKey), or " +
            "\(AXTraversalBudget.maxChildrenPerNodeEnvironmentKey)."
    }

    static func merge(
        _ lhs: DetectionTruncationInfo?,
        _ rhs: DetectionTruncationInfo?) -> DetectionTruncationInfo?
    {
        guard lhs != nil || rhs != nil else { return nil }
        return DetectionTruncationInfo(
            maxDepthReached: lhs?.maxDepthReached == true || rhs?.maxDepthReached == true,
            maxElementCountReached: lhs?.maxElementCountReached == true || rhs?.maxElementCountReached == true,
            maxChildrenPerNodeReached: lhs?.maxChildrenPerNodeReached == true || rhs?.maxChildrenPerNodeReached == true)
    }
}

public struct DesktopDetectionOptions: Sendable, Codable, Equatable {
    public var mode: DetectionMode
    public var allowWebFocusFallback: Bool
    public var includeMenuBarElements: Bool
    public var preferOCR: Bool
    public var traversalBudget: AXTraversalBudget

    public init(
        mode: DetectionMode = .accessibility,
        allowWebFocusFallback: Bool = true,
        includeMenuBarElements: Bool = true,
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
        self.allowWebFocusFallback = try container.decode(Bool.self, forKey: .allowWebFocusFallback)
        self.includeMenuBarElements = try container.decode(Bool.self, forKey: .includeMenuBarElements)
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

    public init(overall: TimeInterval? = nil, detection: TimeInterval? = nil) {
        self.overall = overall
        self.detection = detection
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
