import CoreGraphics
import Foundation
import ImageIO
import PeekabooFoundation
import Vision

public struct OCRTextObservation: Sendable, Codable, Equatable {
    public let text: String
    public let confidence: Float
    public let boundingBox: CGRect

    public init(text: String, confidence: Float, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public struct OCRTextResult: Sendable, Codable, Equatable {
    public let observations: [OCRTextObservation]
    public let imageSize: CGSize
    public let isComplete: Bool
    public let deadlineReached: Bool
    public let warnings: [String]

    public init(
        observations: [OCRTextObservation],
        imageSize: CGSize,
        isComplete: Bool = true,
        deadlineReached: Bool = false,
        warnings: [String] = [])
    {
        self.observations = observations
        self.imageSize = imageSize
        self.isComplete = isComplete
        self.deadlineReached = deadlineReached
        self.warnings = warnings
    }

    public static func incomplete(imageSize: CGSize, deadlineReached: Bool, reason: String) -> OCRTextResult {
        OCRTextResult(
            observations: [],
            imageSize: imageSize,
            isComplete: false,
            deadlineReached: deadlineReached,
            warnings: [reason])
    }

    private enum CodingKeys: String, CodingKey {
        case observations
        case imageSize
        case isComplete
        case deadlineReached
        case warnings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.observations = try container.decode([OCRTextObservation].self, forKey: .observations)
        self.imageSize = try container.decode(CGSize.self, forKey: .imageSize)
        self.isComplete = try container.decodeIfPresent(Bool.self, forKey: .isComplete) ?? true
        self.deadlineReached = try container.decodeIfPresent(Bool.self, forKey: .deadlineReached) ?? false
        self.warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}

public enum OCRServiceError: Error, Equatable {
    case invalidImageData
    case incomplete(String)
}

extension OCRServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidImageData:
            "OCR could not decode the captured image"
        case let .incomplete(reason):
            reason.isEmpty ? "OCR was incomplete; missing text does not prove absence" : reason
        }
    }
}

public enum OCRRecognitionQuality: String, Sendable, Equatable {
    case accurate
    case fast
}

public protocol OCRRecognizing: Sendable {
    func recognizeText(in imageData: Data, timeoutSeconds: TimeInterval) async throws -> OCRTextResult
    func recognizeText(
        in imageData: Data,
        timeoutSeconds: TimeInterval,
        quality: OCRRecognitionQuality) async throws -> OCRTextResult
    func recognizeText(
        in imageData: Data,
        timeoutSeconds: TimeInterval,
        regions: [OCRRecognitionRegion]) async throws -> OCRTextResult
}

extension OCRRecognizing {
    public func recognizeText(
        in imageData: Data,
        timeoutSeconds: TimeInterval,
        quality _: OCRRecognitionQuality) async throws -> OCRTextResult
    {
        try await self.recognizeText(in: imageData, timeoutSeconds: timeoutSeconds)
    }

    public func recognizeText(
        in imageData: Data,
        timeoutSeconds: TimeInterval,
        regions _: [OCRRecognitionRegion]) async throws -> OCRTextResult
    {
        try await self.recognizeText(in: imageData, timeoutSeconds: timeoutSeconds)
    }
}

public struct OCRRecognitionRegion: Sendable, Equatable {
    /// Top-left-origin bounds normalized to the full captured image.
    public let normalizedBounds: CGRect

    public init(normalizedBounds: CGRect) {
        self.normalizedBounds = normalizedBounds
    }
}

public struct OCRService: OCRRecognizing {
    public static let defaultTimeoutSeconds: TimeInterval = 5

    public init() {}

    public nonisolated func recognizeText(
        in imageData: Data,
        timeoutSeconds: TimeInterval = Self.defaultTimeoutSeconds) async throws -> OCRTextResult
    {
        try await self.recognizeText(
            in: imageData,
            timeoutSeconds: timeoutSeconds,
            quality: .accurate)
    }

    public nonisolated func recognizeText(
        in imageData: Data,
        timeoutSeconds: TimeInterval,
        quality: OCRRecognitionQuality) async throws -> OCRTextResult
    {
        try await OCRExecutionRunner.run(seconds: timeoutSeconds) {
            try Self.performRecognition(in: imageData, quality: quality)
        }
    }

    public nonisolated func recognizeText(
        in imageData: Data,
        timeoutSeconds: TimeInterval,
        regions: [OCRRecognitionRegion]) async throws -> OCRTextResult
    {
        guard !regions.isEmpty else {
            return try await self.recognizeText(in: imageData, timeoutSeconds: timeoutSeconds)
        }
        return try await OCRExecutionRunner.run(seconds: timeoutSeconds) {
            try Self.performTargetedRecognition(in: imageData, regions: regions)
        }
    }

    private nonisolated static func performRecognition(
        in imageData: Data,
        quality: OCRRecognitionQuality) throws -> OCRTextResult
    {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw OCRServiceError.invalidImageData
        }

        let results = switch quality {
        case .accurate:
            try self.withRecognitionFallback(
                primary: { try self.visionResults(in: image, recognitionLevel: .accurate) },
                fallback: { try self.visionResults(in: image, recognitionLevel: .fast) })
        case .fast:
            try self.withSingleRecognitionAttempt {
                try self.visionResults(in: image, recognitionLevel: .fast)
            }
        }
        let observations = results.compactMap { observation -> OCRTextObservation? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return OCRTextObservation(
                text: text,
                confidence: candidate.confidence,
                boundingBox: observation.boundingBox)
        }

        return OCRTextResult(
            observations: observations,
            imageSize: CGSize(width: image.width, height: image.height))
    }

    private nonisolated static func performTargetedRecognition(
        in imageData: Data,
        regions: [OCRRecognitionRegion]) throws -> OCRTextResult
    {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw OCRServiceError.invalidImageData
        }

        var observations: [OCRTextObservation] = []
        for region in regions {
            guard let crop = self.targetedCrop(region.normalizedBounds, from: image) else { continue }
            let results = try self.withSingleRecognitionAttempt {
                try self.visionResults(in: crop.image, recognitionLevel: .fast)
            }
            observations.append(contentsOf: results.compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return OCRTextObservation(
                    text: text,
                    confidence: candidate.confidence,
                    boundingBox: self.fullImageBoundingBox(
                        observation.boundingBox,
                        region: crop.normalizedBounds))
            })
        }

        return OCRTextResult(
            observations: observations,
            imageSize: CGSize(width: image.width, height: image.height))
    }

    private nonisolated static func visionResults(
        in image: CGImage,
        recognitionLevel: VNRequestTextRecognitionLevel) throws -> [VNRecognizedTextObservation]
    {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = recognitionLevel == .fast
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results ?? []
    }

    static func withRecognitionFallback<T>(
        primary: () throws -> T,
        fallback: () throws -> T) throws -> T
    {
        try Task.checkCancellation()
        do {
            let result = try primary()
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            do {
                let result = try fallback()
                try Task.checkCancellation()
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw OCRServiceError.incomplete(
                    "Apple Vision text recognition failed in both primary and fast fallback modes")
            }
        }
    }

    static func withSingleRecognitionAttempt<T>(_ operation: () throws -> T) throws -> T {
        try Task.checkCancellation()
        do {
            let result = try operation()
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw OCRServiceError.incomplete("Apple Vision fast text recognition failed")
        }
    }

    private nonisolated static func targetedCrop(
        _ normalizedBounds: CGRect,
        from image: CGImage) -> (image: CGImage, normalizedBounds: CGRect)?
    {
        let unitBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let normalized = normalizedBounds.standardized.intersection(unitBounds)
        guard !normalized.isNull, normalized.width > 0, normalized.height > 0 else { return nil }
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixelBounds = CGRect(
            x: normalized.minX * imageBounds.width,
            y: normalized.minY * imageBounds.height,
            width: normalized.width * imageBounds.width,
            height: normalized.height * imageBounds.height)
            .integral
            .intersection(imageBounds)
        guard !pixelBounds.isNull,
              let cropped = image.cropping(to: pixelBounds),
              let context = CGContext(
                  data: nil,
                  width: cropped.width * 4,
                  height: cropped.height * 4,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard let scaled = context.makeImage() else { return nil }
        return (scaled, CGRect(
            x: pixelBounds.minX / imageBounds.width,
            y: pixelBounds.minY / imageBounds.height,
            width: pixelBounds.width / imageBounds.width,
            height: pixelBounds.height / imageBounds.height))
    }

    @_spi(Testing) public nonisolated static func fullImageBoundingBox(
        _ localVisionBounds: CGRect,
        region: CGRect) -> CGRect
    {
        CGRect(
            x: region.minX + localVisionBounds.minX * region.width,
            y: 1 - region.maxY + localVisionBounds.minY * region.height,
            width: localVisionBounds.width * region.width,
            height: localVisionBounds.height * region.height)
    }
}

@_spi(Testing) public enum OCRExecutionRunner {
    @TaskLocal private static var ownsLease = false
    private static let coordinator = OCRExecutionCoordinator()

    public static func run<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () throws -> T) async throws -> T
    {
        if self.ownsLease {
            return try autoreleasepool(invoking: operation)
        }
        return try await self.runAsync(seconds: seconds) {
            try autoreleasepool(invoking: operation)
        }
    }

    static func runAsync<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        if self.ownsLease {
            return try await operation()
        }
        return try await self.coordinator.run(seconds: seconds) {
            try await self.$ownsLease.withValue(true) {
                try await operation()
            }
        }
    }

    static func isQuarantinedForTesting() async -> Bool {
        await self.coordinator.isQuarantined
    }
}

/// Owns the real lifetime of one OCR call, including async recognizers that ignore cancellation. A caller-visible
/// timeout or cancellation quarantines the lease until that operation actually returns, preventing job buildup.
actor OCRExecutionCoordinator {
    private enum LeasePhase: Equatable {
        case acquiring
        case running
        case quarantined
    }

    private struct Lease {
        let id: UUID
        var phase: LeasePhase
    }

    private var activeLease: Lease?

    func run<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        guard seconds.isFinite, seconds > 0 else {
            throw CaptureError.detectionTimedOut(seconds)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        let leaseID = try await self.reserveLease(deadline: deadline, timeoutSeconds: seconds)
        let race = OCRExecutionRace<T>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard race.install(continuation) else {
                    self.release(id: leaseID)
                    return
                }
                guard ContinuousClock.now < deadline else {
                    self.release(id: leaseID)
                    race.resume(.failure(CaptureError.detectionTimedOut(seconds)))
                    return
                }

                self.markRunning(id: leaseID)
                let operationTask = Task.detached(priority: .userInitiated) {
                    guard race.claimOperation() else {
                        await self.release(id: leaseID)
                        return
                    }
                    let result: Result<T, any Error>
                    do {
                        let value = try await operation()
                        result = .success(value)
                    } catch {
                        result = .failure(error)
                    }
                    await self.release(id: leaseID)
                    race.resume(result)
                }
                race.setOperationTask(operationTask)

                let timeoutTask = Task.detached {
                    do {
                        let now = ContinuousClock.now
                        if now < deadline {
                            try await Task.sleep(for: now.duration(to: deadline))
                        }
                    } catch {
                        return
                    }
                    if race.resume(.failure(CaptureError.detectionTimedOut(seconds))) {
                        race.cancelOperation()
                        await self.quarantine(id: leaseID)
                    }
                }
                race.setTimeoutTask(timeoutTask)
            }
        } onCancel: {
            if race.cancel() {
                race.cancelOperation()
                Task { await self.quarantine(id: leaseID) }
            }
        }
    }

    var isQuarantined: Bool {
        self.activeLease?.phase == .quarantined
    }

    private func reserveLease(
        deadline: ContinuousClock.Instant,
        timeoutSeconds: TimeInterval) async throws -> UUID
    {
        while let lease = self.activeLease {
            if lease.phase == .quarantined {
                throw OCRServiceError.incomplete(
                    "OCR unavailable while a timed-out or cancelled Vision operation is still finishing")
            }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw CaptureError.detectionTimedOut(timeoutSeconds)
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw CaptureError.detectionTimedOut(timeoutSeconds)
        }
        let id = UUID()
        self.activeLease = Lease(id: id, phase: .acquiring)
        return id
    }

    private func markRunning(id: UUID) {
        guard self.activeLease?.id == id else { return }
        self.activeLease?.phase = .running
    }

    private func quarantine(id: UUID) {
        guard self.activeLease?.id == id, self.activeLease?.phase == .running else { return }
        self.activeLease?.phase = .quarantined
    }

    private func release(id: UUID) {
        guard self.activeLease?.id == id else { return }
        self.activeLease = nil
    }
}

private final class OCRExecutionRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var terminalResult: Result<T, any Error>?
    private var operationStarted = false

    func install(_ continuation: CheckedContinuation<T, any Error>) -> Bool {
        let terminalResult = self.lock.withLock { () -> Result<T, any Error>? in
            if let terminalResult = self.terminalResult {
                return terminalResult
            }
            self.continuation = continuation
            return nil
        }
        if let terminalResult {
            continuation.resume(with: terminalResult)
            return false
        }
        return true
    }

    func claimOperation() -> Bool {
        self.lock.withLock {
            guard self.terminalResult == nil, !self.operationStarted else { return false }
            self.operationStarted = true
            return true
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        let cancel = self.lock.withLock {
            if self.terminalResult != nil {
                return true
            }
            self.timeoutTask = task
            return false
        }
        if cancel {
            task.cancel()
        }
    }

    func setOperationTask(_ task: Task<Void, Never>) {
        let cancel = self.lock.withLock {
            if self.terminalResult != nil {
                return true
            }
            self.operationTask = task
            return false
        }
        if cancel {
            task.cancel()
        }
    }

    func cancelOperation() {
        self.lock.withLock { self.operationTask }?.cancel()
    }

    @discardableResult
    func resume(_ result: Result<T, any Error>) -> Bool {
        let completion: (CheckedContinuation<T, any Error>?, Task<Void, Never>?) = self.lock.withLock {
            guard self.terminalResult == nil else { return (nil, nil) }
            self.terminalResult = result
            let completion = (self.continuation, self.timeoutTask)
            self.continuation = nil
            self.timeoutTask = nil
            return completion
        }
        guard completion.0 != nil else { return false }
        completion.1?.cancel()
        completion.0?.resume(with: result)
        return true
    }

    func cancel() -> Bool {
        self.resume(.failure(CancellationError()))
    }
}

public enum ObservationOCRMapper {
    /// Returns true only when AX exposes an actionable button but no semantic text beyond its generic role.
    /// Those controls need pixel text to avoid presenting an identifier-derived guess as their visible label.
    public static func needsSemanticLabelRecovery(in detectionResult: ElementDetectionResult?) -> Bool {
        detectionResult?.elements.buttons.contains(where: self.needsSemanticLabelRecovery) == true
    }

    public static func semanticLabelRecognitionRegions(
        in detectionResult: ElementDetectionResult?,
        windowBounds: CGRect,
        padding: CGFloat = 8) -> [OCRRecognitionRegion]
    {
        guard let detectionResult, windowBounds.width > 0, windowBounds.height > 0 else { return [] }
        return detectionResult.elements.buttons.compactMap { element in
            guard self.needsSemanticLabelRecovery(element) else { return nil }
            let padded = element.bounds.insetBy(dx: -padding, dy: -padding).intersection(windowBounds)
            guard !padded.isNull, padded.width > 0, padded.height > 0 else { return nil }
            return OCRRecognitionRegion(normalizedBounds: CGRect(
                x: (padded.minX - windowBounds.minX) / windowBounds.width,
                y: (padded.minY - windowBounds.minY) / windowBounds.height,
                width: padded.width / windowBounds.width,
                height: padded.height / windowBounds.height))
        }
    }

    public static func matches(_ result: OCRTextResult, hints: [String]) -> Bool {
        guard result.isComplete else { return false }
        guard !hints.isEmpty else { return !result.observations.isEmpty }
        let text = result.observations.map(\.text).joined(separator: " ").lowercased()
        return hints.contains { hint in
            text.contains(hint.lowercased())
        }
    }

    public static func elements(
        from result: OCRTextResult,
        windowBounds: CGRect,
        minConfidence: Float = 0.3,
        idPrefix: String = "ocr") -> [DetectedElement]
    {
        var elements: [DetectedElement] = []
        var index = 1

        for observation in result.observations where observation.confidence >= minConfidence {
            let rect = self.screenRect(
                from: observation.boundingBox,
                windowBounds: windowBounds)

            guard rect.width > 2, rect.height > 2 else { continue }

            let attributes = [
                "description": "ocr",
                "confidence": String(format: "%.2f", observation.confidence),
                "source": "ocr",
            ]

            elements.append(
                DetectedElement(
                    id: "\(idPrefix)_\(index)",
                    type: .staticText,
                    label: observation.text,
                    value: nil,
                    bounds: rect,
                    isEnabled: true,
                    isSelected: nil,
                    attributes: attributes))
            index += 1
        }

        return elements
    }

    public static func merge(
        ocrResult: OCRTextResult,
        ocrElements: [DetectedElement],
        into detectionResult: ElementDetectionResult,
        methodSuffix: String = "+OCR") -> ElementDetectionResult
    {
        let elements = self.recoverSemanticLabels(
            in: detectionResult.elements,
            from: ocrElements)
        let mergedElements = DetectedElements(
            buttons: elements.buttons,
            textFields: elements.textFields,
            links: elements.links,
            images: elements.images,
            groups: elements.groups,
            sliders: elements.sliders,
            checkboxes: elements.checkboxes,
            menus: elements.menus,
            other: elements.other + ocrElements)
        let metadata = detectionResult.metadata
        let method = metadata.method.localizedCaseInsensitiveContains("ocr")
            ? metadata.method
            : "\(metadata.method)\(methodSuffix)"

        return ElementDetectionResult(
            snapshotId: detectionResult.snapshotId,
            screenshotPath: detectionResult.screenshotPath,
            elements: mergedElements,
            metadata: DetectionMetadata(
                detectionTime: metadata.detectionTime,
                elementCount: mergedElements.all.count,
                method: method,
                warnings: metadata.warnings + ocrResult.warnings,
                windowContext: metadata.windowContext,
                isDialog: metadata.isDialog,
                truncationInfo: DetectionTruncationInfo.merge(
                    metadata.truncationInfo,
                    ocrResult.isComplete ? nil : DetectionTruncationInfo(
                        deadlineReached: ocrResult.deadlineReached,
                        incompleteAccessibilityRead: false)),
                desktopMutationCompletedAt: metadata.desktopMutationCompletedAt,
                desktopMutationPreservationAllowed: metadata.desktopMutationPreservationAllowed,
                captureCoordinateContext: metadata.captureCoordinateContext))
    }

    @_spi(Testing) public static func recoverSemanticLabels(
        in elements: DetectedElements,
        from ocrElements: [DetectedElement]) -> DetectedElements
    {
        DetectedElements(
            buttons: elements.buttons.map { self.recoverSemanticLabel(for: $0, from: ocrElements) },
            textFields: elements.textFields,
            links: elements.links,
            images: elements.images,
            groups: elements.groups,
            sliders: elements.sliders,
            checkboxes: elements.checkboxes,
            menus: elements.menus,
            other: elements.other)
    }

    private static func recoverSemanticLabel(
        for element: DetectedElement,
        from ocrElements: [DetectedElement]) -> DetectedElement
    {
        guard self.needsSemanticLabelRecovery(element) else { return element }
        let matches = ocrElements
            .filter { self.isOCRText($0) && self.isSpatiallyContained($0.bounds, in: element.bounds) }
            .sorted { lhs, rhs in
                if abs(lhs.bounds.midY - rhs.bounds.midY) > 2 {
                    return lhs.bounds.minY < rhs.bounds.minY
                }
                return lhs.bounds.minX < rhs.bounds.minX
            }
        let label = matches.compactMap(\.label)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !label.isEmpty else { return element }

        var attributes = element.attributes
        attributes["labelSource"] = "ocr"
        return DetectedElement(
            id: element.id,
            type: element.type,
            label: label,
            value: element.value,
            bounds: element.bounds,
            isEnabled: element.isEnabled,
            isSelected: element.isSelected,
            attributes: attributes)
    }

    private static func needsSemanticLabelRecovery(_ element: DetectedElement) -> Bool {
        guard element.type == .button, element.isActionable else { return false }
        let candidates = [
            element.attributes["title"],
            element.attributes["description"],
            element.attributes["help"],
            element.value,
        ]
        guard candidates.compactMap(self.nonGenericButtonText).isEmpty else { return false }
        guard let label = self.nonGenericButtonText(element.label) else { return true }
        guard let identifier = element.attributes["identifier"] else { return false }
        return self.normalizedIdentifierLabel(identifier) == self.normalizedIdentifierLabel(label)
    }

    private static func nonGenericButtonText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        switch normalized.lowercased() {
        case "button", "push button", "axbutton":
            return nil
        default:
            return normalized
        }
    }

    private static func isOCRText(_ element: DetectedElement) -> Bool {
        element.attributes["description"] == "ocr" && self.nonGenericButtonText(element.label) != nil
    }

    private static func normalizedIdentifierLabel(_ value: String) -> String {
        let withoutButtonSuffix = value.lowercased().hasSuffix("-button")
            ? String(value.dropLast("-button".count))
            : value
        return withoutButtonSuffix.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func isSpatiallyContained(_ textBounds: CGRect, in controlBounds: CGRect) -> Bool {
        guard !textBounds.isEmpty, !controlBounds.isEmpty else { return false }
        if controlBounds.insetBy(dx: -2, dy: -2).contains(
            CGPoint(x: textBounds.midX, y: textBounds.midY))
        {
            return true
        }
        let intersection = textBounds.intersection(controlBounds)
        guard !intersection.isNull else { return false }
        return intersection.width * intersection.height >= textBounds.width * textBounds.height * 0.5
    }

    public static func detectionResult(
        from ocrResult: OCRTextResult,
        snapshotID: String?,
        screenshotPath: String,
        windowContext: WindowContext?,
        detectionTime: TimeInterval,
        minConfidence: Float = 0.3) -> ElementDetectionResult
    {
        let windowBounds = windowContext?.windowBounds ?? CGRect(
            origin: .zero,
            size: ocrResult.imageSize)
        let elements = self.elements(
            from: ocrResult,
            windowBounds: windowBounds,
            minConfidence: minConfidence)
        let grouped = DetectedElements(other: elements)
        return ElementDetectionResult(
            snapshotId: SnapshotPublicationBinding.resultIdentifier(
                explicit: snapshotID,
                transientPrefix: "ocr"),
            screenshotPath: screenshotPath,
            elements: grouped,
            metadata: DetectionMetadata(
                detectionTime: detectionTime,
                elementCount: elements.count,
                method: "OCR",
                warnings: ocrResult.warnings + (elements.isEmpty && ocrResult.isComplete
                    ? ["OCR produced no elements"]
                    : []),
                windowContext: windowContext,
                isDialog: false,
                truncationInfo: ocrResult.isComplete ? nil : DetectionTruncationInfo(
                    deadlineReached: ocrResult.deadlineReached,
                    incompleteAccessibilityRead: false)))
    }

    private static func screenRect(
        from normalizedBox: CGRect,
        windowBounds: CGRect) -> CGRect
    {
        let width = normalizedBox.width * windowBounds.width
        let height = normalizedBox.height * windowBounds.height
        let x = normalizedBox.origin.x * windowBounds.width
        let y = (1.0 - normalizedBox.origin.y - normalizedBox.height) * windowBounds.height
        return CGRect(
            x: windowBounds.origin.x + x,
            y: windowBounds.origin.y + y,
            width: width,
            height: height)
    }
}
