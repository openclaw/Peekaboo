import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct CaptureRegionOfInterest: Sendable, Codable, Equatable {
    public let bounds: CGRect

    public init(bounds: CGRect) {
        self.bounds = bounds
    }

    public static func parse(_ rawValue: String) throws -> CaptureRegionOfInterest {
        let parts = rawValue.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count == 4,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              let width = Double(parts[2]),
              let height = Double(parts[3])
        else {
            throw CaptureROIError.invalidFormat
        }
        return CaptureRegionOfInterest(bounds: CGRect(x: x, y: y, width: width, height: height))
    }
}

public enum CaptureROIError: LocalizedError, Equatable {
    case invalidFormat
    case invalidBounds
    case exactWindowRequired
    case missingExactWindowReceipt
    case outOfBounds
    case invalidSourceImage
    case unsupportedScale
    case outputTooLarge
    case hostDidNotApplyROI

    public var code: String {
        switch self {
        case .invalidFormat: "invalid_format"
        case .invalidBounds: "invalid_bounds"
        case .exactWindowRequired: "exact_window_required"
        case .missingExactWindowReceipt: "missing_exact_window_receipt"
        case .outOfBounds: "out_of_bounds"
        case .invalidSourceImage: "invalid_source_image"
        case .unsupportedScale: "unsupported_scale"
        case .outputTooLarge: "output_too_large"
        case .hostDidNotApplyROI: "host_did_not_apply_roi"
        }
    }

    public init?(code: String) {
        switch code {
        case "invalid_format": self = .invalidFormat
        case "invalid_bounds": self = .invalidBounds
        case "exact_window_required": self = .exactWindowRequired
        case "missing_exact_window_receipt": self = .missingExactWindowReceipt
        case "out_of_bounds": self = .outOfBounds
        case "invalid_source_image": self = .invalidSourceImage
        case "unsupported_scale": self = .unsupportedScale
        case "output_too_large": self = .outputTooLarge
        case "host_did_not_apply_roi": self = .hostDidNotApplyROI
        default: return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "ROI must be x,y,width,height in window-local logical points."
        case .invalidBounds:
            "ROI coordinates must be finite, nonnegative, and have positive width and height."
        case .exactWindowRequired:
            "ROI capture requires an exact window ID; automatic, title, index, screen, and area targets are refused."
        case .missingExactWindowReceipt:
            "ROI capture requires a generation-pinned exact-window receipt. Capture the exact window again."
        case .outOfBounds:
            "ROI extends outside the captured exact window."
        case .invalidSourceImage:
            "ROI capture could not decode or crop the source window image."
        case .unsupportedScale:
            "ROI capture requires a finite uniform output scale between 0.25x and 4x."
        case .outputTooLarge:
            "ROI output exceeds the 8192-pixel or 64-megapixel safety limit."
        case .hostDidNotApplyROI:
            "The selected Peekaboo host did not apply the requested ROI. Update or relaunch the host."
        }
    }
}

public struct DesktopObservationROIResult: Sendable {
    public let capture: CaptureResult
    public let elements: ElementDetectionResult?
    public let ocr: OCRTextResult?
}

public enum DesktopObservationROIProcessor {
    public static let maximumOutputDimension = 8192
    public static let maximumPixelCount = 64 * 1024 * 1024
    private static let coordinateTolerance: CGFloat = 0.000_001

    public static func validateRequest(
        _ roi: CaptureRegionOfInterest?,
        target: DesktopObservationTargetRequest) throws
    {
        guard let roi else { return }
        try self.validateBounds(roi.bounds)
        guard target.exactWindowID != nil else {
            throw CaptureROIError.exactWindowRequired
        }
    }

    public static func apply(
        _ roi: CaptureRegionOfInterest?,
        target: ResolvedObservationTarget,
        capture: CaptureResult,
        elements: ElementDetectionResult?,
        ocr: OCRTextResult?) throws -> DesktopObservationROIResult
    {
        guard let roi else {
            return DesktopObservationROIResult(capture: capture, elements: elements, ocr: ocr)
        }
        try self.validateBounds(roi.bounds)
        guard let requestedWindowID = target.window?.windowID,
              self.exactReceiptMatches(
                  target: target,
                  capture: capture,
                  requestedWindowID: requestedWindowID),
              let window = capture.metadata.windowInfo
        else {
            throw CaptureROIError.missingExactWindowReceipt
        }

        let sourceBounds = window.bounds
        guard roi.bounds.maxX <= sourceBounds.width + Self.coordinateTolerance,
              roi.bounds.maxY <= sourceBounds.height + Self.coordinateTolerance
        else {
            throw CaptureROIError.outOfBounds
        }
        guard let source = CGImageSourceCreateWithData(capture.imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw CaptureROIError.invalidSourceImage
        }

        let sourceImageSize = CGSize(width: image.width, height: image.height)
        let scaleX = sourceImageSize.width / sourceBounds.width
        let scaleY = sourceImageSize.height / sourceBounds.height
        guard scaleX.isFinite, scaleY.isFinite,
              (0.25...4).contains(scaleX), (0.25...4).contains(scaleY),
              abs(scaleX - scaleY) <= 0.01
        else {
            throw CaptureROIError.unsupportedScale
        }

        let pixelMinX = floor(roi.bounds.minX * scaleX)
        let pixelMinY = floor(roi.bounds.minY * scaleY)
        let pixelMaxX = min(sourceImageSize.width, ceil(roi.bounds.maxX * scaleX))
        let pixelMaxY = min(sourceImageSize.height, ceil(roi.bounds.maxY * scaleY))
        let pixelBounds = CGRect(
            x: pixelMinX,
            y: pixelMinY,
            width: pixelMaxX - pixelMinX,
            height: pixelMaxY - pixelMinY)
        guard pixelBounds.width > 0, pixelBounds.height > 0,
              pixelBounds.maxX <= sourceImageSize.width + Self.coordinateTolerance,
              pixelBounds.maxY <= sourceImageSize.height + Self.coordinateTolerance,
              pixelBounds.width <= CGFloat(Self.maximumOutputDimension),
              pixelBounds.height <= CGFloat(Self.maximumOutputDimension),
              pixelBounds.width * pixelBounds.height <= CGFloat(Self.maximumPixelCount)
        else {
            throw CaptureROIError.outputTooLarge
        }
        guard let cropped = image.cropping(to: pixelBounds),
              let croppedData = self.pngData(cropped)
        else {
            throw CaptureROIError.invalidSourceImage
        }

        let deliveredMinX = pixelBounds.minX / scaleX
        let deliveredMinY = pixelBounds.minY / scaleY
        let deliveredMaxX = pixelBounds.maxX >= sourceImageSize.width - Self.coordinateTolerance
            ? sourceBounds.width
            : pixelBounds.maxX / scaleX
        let deliveredMaxY = pixelBounds.maxY >= sourceImageSize.height - Self.coordinateTolerance
            ? sourceBounds.height
            : pixelBounds.maxY / scaleY
        let deliveredRelativeBounds = CGRect(
            x: deliveredMinX,
            y: deliveredMinY,
            width: deliveredMaxX - deliveredMinX,
            height: deliveredMaxY - deliveredMinY)
        let deliveredLogicalBounds = CGRect(
            x: sourceBounds.minX + deliveredRelativeBounds.minX,
            y: sourceBounds.minY + deliveredRelativeBounds.minY,
            width: deliveredRelativeBounds.width,
            height: deliveredRelativeBounds.height)
        let viewport = CaptureViewport(
            sourceLogicalBounds: sourceBounds,
            requestedWindowRelativeBounds: roi.bounds,
            deliveredWindowRelativeBounds: deliveredRelativeBounds,
            logicalBounds: deliveredLogicalBounds,
            sourceImageSize: sourceImageSize)
        let croppedSize = CGSize(width: cropped.width, height: cropped.height)
        let croppedCapture = CaptureResult(
            imageData: croppedData,
            savedPath: nil,
            metadata: capture.metadata.withViewport(viewport, deliveredPixelSize: croppedSize),
            warning: capture.warning)

        return DesktopObservationROIResult(
            capture: croppedCapture,
            elements: self.filtered(elements, viewport: viewport, metadata: croppedCapture.metadata),
            ocr: self.filtered(ocr, pixelBounds: pixelBounds, croppedSize: croppedSize))
    }

    public static func validateApplied(
        _ roi: CaptureRegionOfInterest?,
        requestTarget: DesktopObservationTargetRequest,
        resolvedTarget: ResolvedObservationTarget,
        capture: CaptureResult) throws
    {
        guard let roi else { return }
        guard let viewport = capture.metadata.viewport,
              viewport.requestedWindowRelativeBounds == roi.bounds,
              let requestedWindowID = requestTarget.exactWindowID,
              self.exactReceiptMatches(
                  target: resolvedTarget,
                  capture: capture,
                  requestedWindowID: Int(requestedWindowID)),
              let window = capture.metadata.windowInfo,
              let expectedDeliveredBounds = self.pixelAlignedDeliveredBounds(
                  requestedBounds: roi.bounds,
                  sourceBounds: window.bounds,
                  sourceImageSize: viewport.sourceImageSize),
              let identity = window.mutationIdentity,
              identity.windowID == window.windowID,
              identity.capturedBounds == window.bounds,
              viewport.sourceLogicalBounds == window.bounds,
              (try? self.validateBounds(viewport.deliveredWindowRelativeBounds)) != nil,
              self.rectsMatch(viewport.deliveredWindowRelativeBounds, expectedDeliveredBounds),
              viewport.deliveredWindowRelativeBounds.maxX <= window.bounds.width + Self.coordinateTolerance,
              viewport.deliveredWindowRelativeBounds.maxY <= window.bounds.height + Self.coordinateTolerance,
              self.rectsMatch(
                  viewport.logicalBounds,
                  CGRect(
                      x: window.bounds.minX + viewport.deliveredWindowRelativeBounds.minX,
                      y: window.bounds.minY + viewport.deliveredWindowRelativeBounds.minY,
                      width: viewport.deliveredWindowRelativeBounds.width,
                      height: viewport.deliveredWindowRelativeBounds.height)),
              viewport.sourceImageSize.width > 0,
              viewport.sourceImageSize.height > 0,
              capture.metadata.size.width > 0,
              capture.metadata.size.height > 0,
              capture.metadata.size.width <= CGFloat(Self.maximumOutputDimension),
              capture.metadata.size.height <= CGFloat(Self.maximumOutputDimension),
              capture.metadata.size.width * capture.metadata.size.height <= CGFloat(Self.maximumPixelCount),
              self.uniformScaleMatches(
                  sourceSize: viewport.sourceImageSize,
                  sourceBounds: window.bounds,
                  deliveredSize: capture.metadata.size,
                  deliveredBounds: viewport.deliveredWindowRelativeBounds)
        else {
            throw CaptureROIError.hostDidNotApplyROI
        }
    }

    private static func exactReceiptMatches(
        target: ResolvedObservationTarget,
        capture: CaptureResult,
        requestedWindowID: Int) -> Bool
    {
        guard let expectedIdentity = target.detectionContext?.windowMutationIdentity,
              let expectedBounds = expectedIdentity.capturedBounds,
              expectedIdentity.windowID == requestedWindowID,
              let targetApplication = target.app,
              targetApplication.processIdentifier == expectedIdentity.ownerProcessIdentifier,
              targetApplication.processStartIdentity == expectedIdentity.ownerProcessStartIdentity,
              let targetWindow = target.window,
              targetWindow.windowID == requestedWindowID,
              targetWindow.bounds == expectedBounds,
              let window = capture.metadata.windowInfo,
              window.windowID == requestedWindowID,
              window.bounds == expectedBounds,
              let identity = window.mutationIdentity,
              identity.windowID == requestedWindowID,
              identity.ownerProcessIdentifier == expectedIdentity.ownerProcessIdentifier,
              identity.ownerProcessStartIdentity == expectedIdentity.ownerProcessStartIdentity,
              identity.capturedBounds == expectedBounds,
              let capturedApplication = capture.metadata.applicationInfo,
              capturedApplication.processIdentifier == expectedIdentity.ownerProcessIdentifier,
              capturedApplication.processStartIdentity == expectedIdentity.ownerProcessStartIdentity
        else { return false }
        return true
    }

    private static func pixelAlignedDeliveredBounds(
        requestedBounds: CGRect,
        sourceBounds: CGRect,
        sourceImageSize: CGSize) -> CGRect?
    {
        guard (try? self.validateBounds(requestedBounds)) != nil,
              sourceBounds.width > 0,
              sourceBounds.height > 0,
              requestedBounds.maxX <= sourceBounds.width + self.coordinateTolerance,
              requestedBounds.maxY <= sourceBounds.height + self.coordinateTolerance
        else { return nil }
        let scaleX = sourceImageSize.width / sourceBounds.width
        let scaleY = sourceImageSize.height / sourceBounds.height
        guard scaleX.isFinite, scaleY.isFinite,
              (0.25...4).contains(scaleX),
              (0.25...4).contains(scaleY),
              abs(scaleX - scaleY) <= 0.01
        else { return nil }
        let pixelMinX = floor(requestedBounds.minX * scaleX)
        let pixelMinY = floor(requestedBounds.minY * scaleY)
        let pixelMaxX = min(sourceImageSize.width, ceil(requestedBounds.maxX * scaleX))
        let pixelMaxY = min(sourceImageSize.height, ceil(requestedBounds.maxY * scaleY))
        let deliveredMinX = pixelMinX / scaleX
        let deliveredMinY = pixelMinY / scaleY
        let deliveredMaxX = pixelMaxX >= sourceImageSize.width - Self.coordinateTolerance
            ? sourceBounds.width
            : pixelMaxX / scaleX
        let deliveredMaxY = pixelMaxY >= sourceImageSize.height - Self.coordinateTolerance
            ? sourceBounds.height
            : pixelMaxY / scaleY
        return CGRect(
            x: deliveredMinX,
            y: deliveredMinY,
            width: deliveredMaxX - deliveredMinX,
            height: deliveredMaxY - deliveredMinY)
    }

    public static func presentationBounds(_ globalBounds: CGRect, viewport: CaptureViewport?) -> CGRect? {
        guard let viewport else { return globalBounds }
        let clipped = globalBounds.intersection(viewport.logicalBounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        return CGRect(
            x: clipped.minX - viewport.logicalBounds.minX,
            y: clipped.minY - viewport.logicalBounds.minY,
            width: clipped.width,
            height: clipped.height)
    }

    public static func presentationElements(
        _ elements: DetectedElements,
        viewport: CaptureViewport?) -> DetectedElements
    {
        guard let viewport else { return elements }
        return elements.compactMapping { element in
            guard let bounds = self.presentationBounds(element.bounds, viewport: viewport) else { return nil }
            return DetectedElement(
                id: element.id,
                type: element.type,
                label: element.label,
                value: element.value,
                bounds: bounds,
                isEnabled: element.isEnabled,
                isSelected: element.isSelected,
                attributes: element.attributes)
        }
    }

    public static func presentationElements(
        _ elements: [UIElement],
        viewport: CaptureViewport?) -> [UIElement]
    {
        guard let viewport else { return elements }
        return elements.compactMap { element in
            guard let frame = self.presentationBounds(element.frame, viewport: viewport) else { return nil }
            return UIElement(
                id: element.id,
                elementId: element.elementId,
                role: element.role,
                title: element.title,
                label: element.label,
                value: element.value,
                description: element.description,
                help: element.help,
                roleDescription: element.roleDescription,
                identifier: element.identifier,
                confidence: element.confidence,
                frame: frame,
                isActionable: element.isActionable,
                isEnabled: element.isEnabled,
                isSelected: element.isSelected,
                isValueSettable: element.isValueSettable,
                parentId: element.parentId,
                children: element.children,
                keyboardShortcut: element.keyboardShortcut)
        }
    }

    private static func validateBounds(_ bounds: CGRect) throws {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.minX >= 0, bounds.minY >= 0,
              bounds.width > 0, bounds.height > 0
        else {
            throw CaptureROIError.invalidBounds
        }
    }

    private static func uniformScaleMatches(
        sourceSize: CGSize,
        sourceBounds: CGRect,
        deliveredSize: CGSize,
        deliveredBounds: CGRect) -> Bool
    {
        guard sourceBounds.width > 0, sourceBounds.height > 0,
              deliveredBounds.width > 0, deliveredBounds.height > 0
        else { return false }
        let scales = [
            sourceSize.width / sourceBounds.width,
            sourceSize.height / sourceBounds.height,
            deliveredSize.width / deliveredBounds.width,
            deliveredSize.height / deliveredBounds.height,
        ]
        guard scales.allSatisfy({ $0.isFinite && (0.25...4).contains($0) }),
              let first = scales.first
        else { return false }
        return scales.dropFirst().allSatisfy { abs($0 - first) <= 0.01 }
    }

    private static func rectsMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 0.000_001 &&
            abs(lhs.minY - rhs.minY) <= 0.000_001 &&
            abs(lhs.width - rhs.width) <= 0.000_001 &&
            abs(lhs.height - rhs.height) <= 0.000_001
    }

    private static func filtered(
        _ result: ElementDetectionResult?,
        viewport: CaptureViewport,
        metadata: CaptureMetadata) -> ElementDetectionResult?
    {
        guard let result else { return nil }
        let elements = result.elements.filtering { element in
            self.presentationBounds(element.bounds, viewport: viewport) != nil
        }
        let coordinateContext = CaptureCoordinateContext(metadata: metadata, referenceID: result.snapshotId)
        let resultMetadata = result.metadata.withROI(
            elementCount: elements.all.count,
            coordinateContext: coordinateContext)
        return ElementDetectionResult(
            snapshotId: result.snapshotId,
            screenshotPath: "",
            elements: elements,
            metadata: resultMetadata)
    }

    private static func filtered(
        _ result: OCRTextResult?,
        pixelBounds: CGRect,
        croppedSize: CGSize) -> OCRTextResult?
    {
        guard let result else { return nil }
        let sourceSize = result.imageSize
        let observations = result.observations.compactMap { observation -> OCRTextObservation? in
            let sourceRect = CGRect(
                x: observation.boundingBox.minX * sourceSize.width,
                y: (1 - observation.boundingBox.maxY) * sourceSize.height,
                width: observation.boundingBox.width * sourceSize.width,
                height: observation.boundingBox.height * sourceSize.height)
            let clipped = sourceRect.intersection(pixelBounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
            let localTop = (clipped.minY - pixelBounds.minY) / croppedSize.height
            let localHeight = clipped.height / croppedSize.height
            return OCRTextObservation(
                text: observation.text,
                confidence: observation.confidence,
                boundingBox: CGRect(
                    x: (clipped.minX - pixelBounds.minX) / croppedSize.width,
                    y: 1 - localTop - localHeight,
                    width: clipped.width / croppedSize.width,
                    height: localHeight))
        }
        return OCRTextResult(
            observations: observations,
            imageSize: croppedSize,
            isComplete: result.isComplete,
            deadlineReached: result.deadlineReached,
            warnings: result.warnings)
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

extension DesktopObservationTargetRequest {
    public var exactWindowID: CGWindowID? {
        switch self {
        case let .windowID(windowID): windowID
        case let .app(_, window: .id(windowID)): windowID
        case let .pid(_, window: .id(windowID)): windowID
        default: nil
        }
    }
}

extension DetectedElements {
    func filtering(_ predicate: (DetectedElement) -> Bool) -> DetectedElements {
        DetectedElements(
            buttons: self.buttons.filter(predicate),
            textFields: self.textFields.filter(predicate),
            links: self.links.filter(predicate),
            images: self.images.filter(predicate),
            groups: self.groups.filter(predicate),
            sliders: self.sliders.filter(predicate),
            checkboxes: self.checkboxes.filter(predicate),
            menus: self.menus.filter(predicate),
            other: self.other.filter(predicate))
    }

    func compactMapping(_ transform: (DetectedElement) -> DetectedElement?) -> DetectedElements {
        DetectedElements(
            buttons: self.buttons.compactMap(transform),
            textFields: self.textFields.compactMap(transform),
            links: self.links.compactMap(transform),
            images: self.images.compactMap(transform),
            groups: self.groups.compactMap(transform),
            sliders: self.sliders.compactMap(transform),
            checkboxes: self.checkboxes.compactMap(transform),
            menus: self.menus.compactMap(transform),
            other: self.other.compactMap(transform))
    }
}

extension DetectionMetadata {
    func withROI(elementCount: Int, coordinateContext: CaptureCoordinateContext) -> DetectionMetadata {
        self.withCaptureCoordinateContext(coordinateContext, elementCount: elementCount)
    }

    func withCaptureCoordinateContext(
        _ coordinateContext: CaptureCoordinateContext?,
        elementCount: Int? = nil) -> DetectionMetadata
    {
        DetectionMetadata(
            detectionTime: self.detectionTime,
            elementCount: elementCount ?? self.elementCount,
            method: self.method,
            warnings: self.warnings,
            windowContext: self.windowContext,
            isDialog: self.isDialog,
            truncationInfo: self.truncationInfo,
            desktopMutationCompletedAt: self.desktopMutationCompletedAt,
            desktopMutationPreservationAllowed: self.desktopMutationPreservationAllowed,
            captureCoordinateContext: coordinateContext)
    }
}
