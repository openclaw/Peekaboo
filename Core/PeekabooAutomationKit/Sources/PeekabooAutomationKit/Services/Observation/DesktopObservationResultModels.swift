import CoreGraphics
import CryptoKit
import Foundation

public struct ObservationSpan: Sendable, Codable, Equatable {
    public let name: String
    public let durationMS: Double
    public let metadata: [String: String]

    public init(name: String, durationMS: Double, metadata: [String: String] = [:]) {
        self.name = name
        self.durationMS = durationMS
        self.metadata = metadata
    }
}

public struct ObservationTimings: Sendable, Codable, Equatable {
    public let spans: [ObservationSpan]

    public init(spans: [ObservationSpan] = []) {
        self.spans = spans
    }
}

public struct DesktopObservationFiles: Sendable, Codable, Equatable {
    public let rawScreenshotPath: String?
    public let annotatedScreenshotPath: String?
    /// Snapshot identifier published by the observation output writer after every requested
    /// snapshot artifact has been stored successfully.
    public let publishedSnapshotID: String?

    public init(
        rawScreenshotPath: String? = nil,
        annotatedScreenshotPath: String? = nil,
        publishedSnapshotID: String? = nil)
    {
        self.rawScreenshotPath = rawScreenshotPath
        self.annotatedScreenshotPath = annotatedScreenshotPath
        self.publishedSnapshotID = publishedSnapshotID
    }
}

public struct DesktopObservationOutputWriteResult: Sendable, Codable, Equatable {
    public let files: DesktopObservationFiles
    public let spans: [ObservationSpan]

    public init(files: DesktopObservationFiles, spans: [ObservationSpan] = []) {
        self.files = files
        self.spans = spans
    }
}

/// Digests of the exact raster bytes produced by a desktop observation.
///
/// Bridge responses omit the in-memory capture bytes, but retain this manifest inside the
/// listener-signed response. Callers can therefore authenticate a file immediately before they
/// read or publish its pixels instead of trusting its path, size, or earlier validation.
public struct DesktopObservationContentDigest: Sendable, Codable, Equatable {
    public static let algorithm = "sha256"

    public let captureImageSHA256: String
    public let rawScreenshotSHA256: String?
    public let annotatedScreenshotSHA256: String?

    public init(
        captureImageData: Data,
        rawScreenshotData: Data?,
        annotatedScreenshotData: Data?)
    {
        self.captureImageSHA256 = Self.sha256(captureImageData)
        self.rawScreenshotSHA256 = rawScreenshotData.map(Self.sha256)
        self.annotatedScreenshotSHA256 = annotatedScreenshotData.map(Self.sha256)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ data: Data, expectedSHA256: String) throws {
        guard expectedSHA256.count == 64,
              expectedSHA256.allSatisfy(\.isHexDigit),
              self.sha256(data) == expectedSHA256.lowercased()
        else {
            throw DesktopObservationContentVerificationError.digestMismatch
        }
    }
}

public enum DesktopObservationContentVerificationRequirement: Sendable, Equatable {
    /// Verify a digest whenever the producer supplied one. This is the explicit compatibility
    /// mode for local test doubles and receiptless Bridge protocols 1.23 through 1.28.
    case allowUnsignedLegacy
    /// Refuse content without a digest. Protocol 1.29 signed Bridge responses use this mode.
    case requireDigest
}

public enum DesktopObservationContentVerificationError: Error, LocalizedError, Sendable, Equatable {
    case missingDigest
    case missingArtifactDigest(String)
    case missingArtifactPath(String)
    case unreadableArtifact(String)
    case digestMismatch

    public var errorDescription: String? {
        switch self {
        case .missingDigest:
            "Desktop observation omitted its capture-content digest."
        case let .missingArtifactDigest(label):
            "Desktop observation omitted its \(label) content digest."
        case let .missingArtifactPath(label):
            "Desktop observation omitted its \(label) path."
        case let .unreadableArtifact(label):
            "Desktop observation \(label) could not be read."
        case .digestMismatch:
            "Desktop observation content no longer matches its signed digest."
        }
    }
}

public struct DesktopObservationTargetDiagnostics: Sendable, Codable, Equatable {
    public let requestedKind: String
    public let resolvedKind: String
    public let source: String
    public let hints: [String]
    public let openIfNeeded: Bool
    public let clickHint: String?
    public let windowID: Int?
    public let bounds: CGRect?
    public let captureScaleHint: CGFloat?

    public init(
        requestedKind: String,
        resolvedKind: String,
        source: String,
        hints: [String] = [],
        openIfNeeded: Bool = false,
        clickHint: String? = nil,
        windowID: Int? = nil,
        bounds: CGRect? = nil,
        captureScaleHint: CGFloat? = nil)
    {
        self.requestedKind = requestedKind
        self.resolvedKind = resolvedKind
        self.source = source
        self.hints = hints
        self.openIfNeeded = openIfNeeded
        self.clickHint = clickHint
        self.windowID = windowID
        self.bounds = bounds
        self.captureScaleHint = captureScaleHint
    }
}

public struct DesktopObservationDiagnostics: Sendable, Codable, Equatable {
    public let warnings: [String]
    public let stateSnapshot: DesktopStateSnapshotSummary?
    public let target: DesktopObservationTargetDiagnostics?
    public let desktopMutationCompletedAt: Date?
    public let desktopMutationPreservationAllowed: Bool?

    private enum CodingKeys: String, CodingKey {
        case warnings
        case stateSnapshot
        case target
        case desktopMutationCompletedAt
        case desktopMutationCompletedAtReferenceDateSeconds
        case desktopMutationPreservationAllowed
    }

    public init(
        warnings: [String] = [],
        stateSnapshot: DesktopStateSnapshotSummary? = nil,
        target: DesktopObservationTargetDiagnostics? = nil,
        desktopMutationCompletedAt: Date? = nil,
        desktopMutationPreservationAllowed: Bool? = nil)
    {
        self.warnings = warnings
        self.stateSnapshot = stateSnapshot
        self.target = target
        self.desktopMutationCompletedAt = desktopMutationCompletedAt
        self.desktopMutationPreservationAllowed = desktopMutationPreservationAllowed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        self.stateSnapshot = try container.decodeIfPresent(
            DesktopStateSnapshotSummary.self,
            forKey: .stateSnapshot)
        self.target = try container.decodeIfPresent(
            DesktopObservationTargetDiagnostics.self,
            forKey: .target)
        if let seconds = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .desktopMutationCompletedAtReferenceDateSeconds)
        {
            self.desktopMutationCompletedAt = Date(timeIntervalSinceReferenceDate: seconds)
        } else {
            self.desktopMutationCompletedAt = try container.decodeIfPresent(
                Date.self,
                forKey: .desktopMutationCompletedAt)
        }
        self.desktopMutationPreservationAllowed = try container.decodeIfPresent(
            Bool.self,
            forKey: .desktopMutationPreservationAllowed)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.warnings, forKey: .warnings)
        try container.encodeIfPresent(self.stateSnapshot, forKey: .stateSnapshot)
        try container.encodeIfPresent(self.target, forKey: .target)
        try container.encodeIfPresent(
            self.desktopMutationCompletedAt?.timeIntervalSinceReferenceDate,
            forKey: .desktopMutationCompletedAtReferenceDateSeconds)
        try container.encodeIfPresent(
            self.desktopMutationPreservationAllowed,
            forKey: .desktopMutationPreservationAllowed)
    }
}

public struct DesktopObservationResult: Sendable, Codable {
    public let target: ResolvedObservationTarget
    public let capture: CaptureResult
    public let elements: ElementDetectionResult?
    public let ocr: OCRTextResult?
    public let files: DesktopObservationFiles
    public let timings: ObservationTimings
    public let diagnostics: DesktopObservationDiagnostics
    public let captureContentDigest: DesktopObservationContentDigest?

    public init(
        target: ResolvedObservationTarget,
        capture: CaptureResult,
        elements: ElementDetectionResult?,
        ocr: OCRTextResult? = nil,
        files: DesktopObservationFiles = DesktopObservationFiles(),
        timings: ObservationTimings = ObservationTimings(),
        diagnostics: DesktopObservationDiagnostics = DesktopObservationDiagnostics(),
        captureContentDigest: DesktopObservationContentDigest? = nil)
    {
        self.target = target
        self.capture = capture
        self.elements = elements
        self.ocr = ocr
        self.files = files
        self.timings = timings
        self.diagnostics = diagnostics
        self.captureContentDigest = captureContentDigest
    }
}

extension DesktopObservationResult {
    /// Computes a fresh digest manifest from the in-memory capture and the exact files currently
    /// reported by the result. A Bridge host calls this immediately before stripping image data
    /// and signing the response.
    public func attestingCaptureContent() throws -> DesktopObservationResult {
        try self.withCaptureContentDigest(
            rawScreenshotData: Self.readArtifactIfPresent(
                at: self.files.rawScreenshotPath,
                label: "raw screenshot"),
            annotatedScreenshotData: Self.readArtifactIfPresent(
                at: self.files.annotatedScreenshotPath,
                label: "annotated screenshot"))
    }

    /// Builds a digest manifest from already-owned bytes. This is used when a verified remote
    /// artifact is republished under a new caller-owned path.
    public func withCaptureContentDigest(
        rawScreenshotData: Data?,
        annotatedScreenshotData: Data?) -> DesktopObservationResult
    {
        DesktopObservationResult(
            target: self.target,
            capture: self.capture,
            elements: self.elements,
            ocr: self.ocr,
            files: self.files,
            timings: self.timings,
            diagnostics: self.diagnostics,
            captureContentDigest: DesktopObservationContentDigest(
                captureImageData: self.capture.imageData,
                rawScreenshotData: rawScreenshotData,
                annotatedScreenshotData: annotatedScreenshotData))
    }

    public func verifiedCaptureImageData(
        requirement: DesktopObservationContentVerificationRequirement = .allowUnsignedLegacy) throws -> Data
    {
        guard let digest = self.captureContentDigest else {
            try Self.requireDigestIfNeeded(requirement)
            return self.capture.imageData
        }
        try DesktopObservationContentDigest.verify(
            self.capture.imageData,
            expectedSHA256: digest.captureImageSHA256)
        return self.capture.imageData
    }

    public func verifiedRawScreenshotData(
        requirement: DesktopObservationContentVerificationRequirement = .allowUnsignedLegacy) throws -> Data
    {
        try self.verifiedArtifactData(
            path: self.files.rawScreenshotPath,
            expectedSHA256: self.captureContentDigest?.rawScreenshotSHA256,
            label: "raw screenshot",
            requirement: requirement)
    }

    public func verifiedAnnotatedScreenshotData(
        requirement: DesktopObservationContentVerificationRequirement = .allowUnsignedLegacy) throws -> Data
    {
        try self.verifiedArtifactData(
            path: self.files.annotatedScreenshotPath,
            expectedSHA256: self.captureContentDigest?.annotatedScreenshotSHA256,
            label: "annotated screenshot",
            requirement: requirement)
    }

    public func withoutImageData() -> DesktopObservationResult {
        DesktopObservationResult(
            target: self.target,
            capture: CaptureResult(
                imageData: Data(),
                savedPath: self.capture.savedPath,
                metadata: self.capture.metadata,
                warning: self.capture.warning),
            elements: self.elements,
            ocr: self.ocr,
            files: self.files,
            timings: self.timings,
            diagnostics: self.diagnostics,
            captureContentDigest: self.captureContentDigest)
    }

    private func verifiedArtifactData(
        path: String?,
        expectedSHA256: String?,
        label: String,
        requirement: DesktopObservationContentVerificationRequirement) throws -> Data
    {
        let hasDigest = self.captureContentDigest != nil
        if !hasDigest {
            try Self.requireDigestIfNeeded(requirement)
        } else if expectedSHA256 == nil {
            throw DesktopObservationContentVerificationError.missingArtifactDigest(label)
        }
        guard let path else {
            throw DesktopObservationContentVerificationError.missingArtifactPath(label)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw DesktopObservationContentVerificationError.unreadableArtifact(label)
        }
        guard let expectedSHA256 else { return data }
        try DesktopObservationContentDigest.verify(data, expectedSHA256: expectedSHA256)
        return data
    }

    private static func readArtifactIfPresent(at path: String?, label: String) throws -> Data? {
        guard let path else { return nil }
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw DesktopObservationContentVerificationError.unreadableArtifact(label)
        }
    }

    private static func requireDigestIfNeeded(
        _ requirement: DesktopObservationContentVerificationRequirement) throws
    {
        guard requirement == .allowUnsignedLegacy else {
            throw DesktopObservationContentVerificationError.missingDigest
        }
    }
}
