import AppKit
import Foundation
import PeekabooFoundation

struct ObservationAnnotationLog {
    static let disabled = ObservationAnnotationLog(enabled: false)

    let enabled: Bool

    func verbose(_ message: String, category: String? = nil, metadata: [String: Any] = [:]) {
        guard self.enabled else { return }
        _ = (message, category, metadata)
    }

    func info(_ message: String, category: String? = nil, metadata: [String: Any] = [:]) {
        guard self.enabled else { return }
        _ = (message, category, metadata)
    }
}

@MainActor
public enum ObservationAnnotationCoordinateMapper {
    public static func logicalBounds(for detectionResult: ElementDetectionResult, imageSize: CGSize) -> CGRect {
        if let bounds = detectionResult.metadata.captureCoordinateContext?.logicalBounds {
            return bounds
        }
        if let windowBounds = detectionResult.metadata.windowContext?.windowBounds {
            return windowBounds
        }
        return CGRect(origin: self.windowOrigin(for: detectionResult), size: imageSize)
    }

    public static func windowOrigin(for detectionResult: ElementDetectionResult) -> CGPoint {
        if let windowBounds = detectionResult.metadata.windowContext?.windowBounds {
            return windowBounds.origin
        }

        guard !detectionResult.elements.all.isEmpty else {
            return .zero
        }

        let minX = detectionResult.elements.all.map(\.bounds.minX).min() ?? 0
        let minY = detectionResult.elements.all.map(\.bounds.minY).min() ?? 0
        return CGPoint(x: minX, y: minY)
    }

    public static func drawingRect(
        for element: DetectedElement,
        imageSize: CGSize,
        logicalBounds: CGRect) -> NSRect
    {
        let clipped = element.bounds.intersection(logicalBounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0,
              logicalBounds.width > 0, logicalBounds.height > 0
        else { return .zero }
        let scaleX = imageSize.width / logicalBounds.width
        let scaleY = imageSize.height / logicalBounds.height
        let elementFrame = CGRect(
            x: (clipped.origin.x - logicalBounds.origin.x) * scaleX,
            y: (clipped.origin.y - logicalBounds.origin.y) * scaleY,
            width: clipped.width * scaleX,
            height: clipped.height * scaleY)

        return NSRect(
            x: elementFrame.origin.x,
            y: imageSize.height - elementFrame.origin.y - elementFrame.height,
            width: elementFrame.width,
            height: elementFrame.height)
    }

    public static func drawingRect(
        for element: DetectedElement,
        imageSize: CGSize,
        windowOrigin: CGPoint) -> NSRect
    {
        self.drawingRect(
            for: element,
            imageSize: imageSize,
            logicalBounds: CGRect(origin: windowOrigin, size: imageSize))
    }
}

@MainActor
public final class ObservationAnnotationRenderer {
    private let logger: ObservationAnnotationLog
    private let debugMode: Bool

    public init(debugMode: Bool = false) {
        self.logger = ObservationAnnotationLog(enabled: debugMode)
        self.debugMode = debugMode
    }

    public func renderAnnotatedScreenshot(
        originalPath: String,
        detectionResult: ElementDetectionResult,
        annotatedPath: String? = nil) throws -> String?
    {
        guard let sourceImage = NSImage(contentsOfFile: originalPath) else {
            throw OperationError.captureFailed(reason: "Failed to load screenshot for annotation: \(originalPath)")
        }

        guard let bitmapRep = try self.renderAnnotatedBitmap(
            from: sourceImage,
            detectionResult: detectionResult)
        else {
            return nil
        }

        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw OperationError.captureFailed(reason: "Failed to encode annotated screenshot")
        }

        let outputPath = annotatedPath ?? ObservationOutputWriter
            .annotatedScreenshotPath(forRawScreenshotPath: originalPath)
        try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        return outputPath
    }

    public func renderAnnotatedImage(
        from sourceImage: NSImage,
        detectionResult: ElementDetectionResult) throws -> NSImage?
    {
        guard let bitmapRep = try self.renderAnnotatedBitmap(
            from: sourceImage,
            detectionResult: detectionResult)
        else {
            return nil
        }

        let image = NSImage(size: sourceImage.size)
        image.addRepresentation(bitmapRep)
        return image
    }

    private func renderAnnotatedBitmap(
        from sourceImage: NSImage,
        detectionResult: ElementDetectionResult) throws -> NSBitmapImageRep?
    {
        let enabledElements = detectionResult.elements.all.filter(\.isEnabled)
        guard !enabledElements.isEmpty else {
            self.logger.info(
                "No enabled elements to annotate. Total elements: \(detectionResult.elements.all.count)")
            return nil
        }

        let imageSize = sourceImage.size
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(imageSize.width),
            pixelsHigh: Int(imageSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else {
            throw OperationError.captureFailed(reason: "Failed to create annotation bitmap")
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
            throw OperationError.captureFailed(reason: "Failed to create annotation graphics context")
        }
        NSGraphicsContext.current = context

        sourceImage.draw(in: NSRect(origin: .zero, size: imageSize))

        let fontSize: CGFloat = 8
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]

        let logicalBounds = ObservationAnnotationCoordinateMapper.logicalBounds(
            for: detectionResult,
            imageSize: imageSize)
        self.logger.verbose("Using annotation logical bounds: \(logicalBounds)")

        let elementRects = enabledElements.map { element in
            (
                element: element,
                rect: ObservationAnnotationCoordinateMapper.drawingRect(
                    for: element,
                    imageSize: imageSize,
                    logicalBounds: logicalBounds))
        }
        let allElements = elementRects.map { ($0.element, $0.rect) }
        let labelPlacer = SmartLabelPlacer(
            image: sourceImage,
            fontSize: fontSize,
            debugMode: self.debugMode,
            logger: self.logger)

        var labelPositions: [(rect: NSRect, connection: NSPoint?, element: DetectedElement)] = []
        var placedLabels: [(rect: NSRect, element: DetectedElement)] = []

        for (element, rect) in elementRects {
            self.logger.verbose("Drawing annotation", metadata: [
                "elementId": element.id,
                "type": "\(element.type)",
                "rect": "\(rect)",
                "elementBounds": "\(element.bounds)",
            ])

            let color = Self.color(for: element.type)
            color.withAlphaComponent(0.8).setStroke()

            let outlinePath = NSBezierPath(rect: rect)
            outlinePath.lineWidth = 1.5
            outlinePath.stroke()

            let labelSize = (element.id as NSString).size(withAttributes: textAttributes)
            guard let placement = labelPlacer.findBestLabelPosition(
                for: element,
                elementRect: rect,
                labelSize: labelSize,
                existingLabels: placedLabels,
                allElements: allElements)
            else {
                continue
            }

            labelPositions.append((rect: placement.labelRect, connection: placement.connectionPoint, element: element))
            placedLabels.append((rect: placement.labelRect, element: element))

            if let connectionPoint = placement.connectionPoint {
                let linePath = NSBezierPath()
                linePath.move(to: connectionPoint)
                linePath.line(to: NSPoint(x: rect.midX, y: rect.midY))
                linePath.lineWidth = 0.8
                linePath.stroke()
            }
        }

        for (labelRect, _, element) in labelPositions where labelRect.width > 0 {
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: labelRect, xRadius: 1, yRadius: 1).fill()

            let color = Self.color(for: element.type)
            color.withAlphaComponent(0.8).setStroke()
            let borderPath = NSBezierPath(roundedRect: labelRect, xRadius: 1, yRadius: 1)
            borderPath.lineWidth = 0.5
            borderPath.stroke()

            let idString = NSAttributedString(string: element.id, attributes: textAttributes)
            idString.draw(at: NSPoint(x: labelRect.origin.x + 4, y: labelRect.origin.y + 2))
        }

        return bitmapRep
    }

    private static func color(for type: ElementType) -> NSColor {
        switch type {
        case .button, .link, .menu:
            NSColor(red: 0, green: 0.48, blue: 1, alpha: 1)
        case .textField:
            NSColor(red: 0.204, green: 0.78, blue: 0.349, alpha: 1)
        default:
            NSColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1)
        }
    }
}
