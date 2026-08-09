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

public protocol OCRRecognizing: Sendable {
    func recognizeText(in imageData: Data, timeoutSeconds: TimeInterval) async throws -> OCRTextResult
}

public struct OCRService: OCRRecognizing {
    public static let defaultTimeoutSeconds: TimeInterval = 5

    public init() {}

    public nonisolated func recognizeText(
        in imageData: Data,
        timeoutSeconds: TimeInterval = Self.defaultTimeoutSeconds) async throws -> OCRTextResult
    {
        try await OCRExecutionRunner.run(seconds: timeoutSeconds) {
            try Self.performRecognition(in: imageData)
        }
    }

    private nonisolated static func performRecognition(in imageData: Data) throws -> OCRTextResult {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw OCRServiceError.invalidImageData
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let observations = (request.results ?? []).compactMap { observation -> OCRTextObservation? in
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
}

@_spi(Testing) public enum OCRExecutionRunner {
    public static func run<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () throws -> T) async throws -> T
    {
        guard seconds.isFinite, seconds > 0 else {
            throw CaptureError.detectionTimedOut(seconds)
        }
        let state = OCRExecutionState<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                let timeoutTask = Task.detached {
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                        state.resume(with: .failure(CaptureError.detectionTimedOut(seconds)))
                    } catch {
                        // Completion or caller cancellation cancels the deadline task.
                    }
                }
                state.setTimeoutTask(timeoutTask)
                DispatchQueue.global(qos: .userInitiated).async {
                    let result: Result<T, any Error> = autoreleasepool {
                        do {
                            return try .success(operation())
                        } catch {
                            return .failure(error)
                        }
                    }
                    state.resume(with: result)
                }
            }
        } onCancel: {
            state.resume(with: .failure(CancellationError()))
        }
    }

    public static func runAsync<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        guard seconds.isFinite, seconds > 0 else {
            throw CaptureError.detectionTimedOut(seconds)
        }
        let state = OCRExecutionState<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                let timeoutTask = Task.detached {
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                        state.resume(with: .failure(CaptureError.detectionTimedOut(seconds)))
                    } catch {
                        // Completion or caller cancellation cancels the deadline task.
                    }
                }
                state.setTimeoutTask(timeoutTask)
                Task.detached {
                    do {
                        let value = try await operation()
                        state.resume(with: .success(value))
                    } catch {
                        state.resume(with: .failure(error))
                    }
                }
            }
        } onCancel: {
            state.resume(with: .failure(CancellationError()))
        }
    }
}

private final class OCRExecutionState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        let alreadyFinished = self.lock.withLock {
            guard !self.finished else { return true }
            self.continuation = continuation
            return false
        }
        if alreadyFinished {
            continuation.resume(throwing: CancellationError())
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        let cancel = self.lock.withLock {
            if self.finished {
                return true
            }
            self.timeoutTask = task
            return false
        }
        if cancel {
            task.cancel()
        }
    }

    func resume(with result: Result<T, any Error>) {
        let completion: (CheckedContinuation<T, any Error>?, Task<Void, Never>?) = self.lock.withLock {
            guard !self.finished else { return (nil, nil) }
            self.finished = true
            let completion = (self.continuation, self.timeoutTask)
            self.continuation = nil
            self.timeoutTask = nil
            return completion
        }
        completion.1?.cancel()
        completion.0?.resume(with: result)
    }
}

public enum ObservationOCRMapper {
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
                imageSize: result.imageSize,
                windowBounds: windowBounds)

            guard rect.width > 2, rect.height > 2 else { continue }

            let attributes = [
                "description": "ocr",
                "confidence": String(format: "%.2f", observation.confidence),
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
        let elements = detectionResult.elements
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
                        incompleteAccessibilityRead: false))))
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
            snapshotId: snapshotID ?? "ocr-\(UUID().uuidString)",
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
        imageSize: CGSize,
        windowBounds: CGRect) -> CGRect
    {
        let width = normalizedBox.width * imageSize.width
        let height = normalizedBox.height * imageSize.height
        let x = normalizedBox.origin.x * imageSize.width
        let y = (1.0 - normalizedBox.origin.y - normalizedBox.height) * imageSize.height
        return CGRect(
            x: windowBounds.origin.x + x,
            y: windowBounds.origin.y + y,
            width: width,
            height: height)
    }
}
