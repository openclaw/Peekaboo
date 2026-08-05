import CoreGraphics
import Foundation

public enum CaptureCoordinateSpace: String, Sendable, Codable, CaseIterable {
    case globalDisplayPoints = "global_display_points"
    case imagePixels = "image_pixels"
    case normalized

    public var requiresReference: Bool {
        self != .globalDisplayPoints
    }
}

public enum CaptureCoordinateMappingError: LocalizedError, Equatable {
    case invalidCoordinate
    case missingLogicalBounds
    case invalidDeliveredImageSize
    case imagePointOutOfBounds
    case normalizedPointOutOfBounds

    public var errorDescription: String? {
        switch self {
        case .invalidCoordinate:
            "Coordinates must contain finite numbers."
        case .missingLogicalBounds:
            "The coordinate reference has no logical capture bounds. Capture a fresh snapshot."
        case .invalidDeliveredImageSize:
            "The coordinate reference has an invalid delivered image size. Capture a fresh snapshot."
        case .imagePointOutOfBounds:
            "Image-pixel coordinates are outside the delivered image bounds."
        case .normalizedPointOutOfBounds:
            "Normalized coordinates must be between 0 and 1 inclusive."
        }
    }
}

public enum CaptureCoordinateMapper {
    public static func globalPoint(
        for point: CGPoint,
        in space: CaptureCoordinateSpace,
        context: CaptureCoordinateContext) throws -> CGPoint
    {
        guard point.x.isFinite, point.y.isFinite else {
            throw CaptureCoordinateMappingError.invalidCoordinate
        }
        guard space != .globalDisplayPoints else { return point }
        guard let bounds = context.logicalBounds, bounds.width > 0, bounds.height > 0 else {
            throw CaptureCoordinateMappingError.missingLogicalBounds
        }

        switch space {
        case .globalDisplayPoints:
            return point
        case .imagePixels:
            let imageSize = context.deliveredImageSize
            guard imageSize.width > 0, imageSize.height > 0 else {
                throw CaptureCoordinateMappingError.invalidDeliveredImageSize
            }
            guard point.x >= 0, point.y >= 0, point.x < imageSize.width, point.y < imageSize.height else {
                throw CaptureCoordinateMappingError.imagePointOutOfBounds
            }
            return CGPoint(
                x: bounds.minX + point.x / imageSize.width * bounds.width,
                y: bounds.minY + point.y / imageSize.height * bounds.height)
        case .normalized:
            guard (0...1).contains(point.x), (0...1).contains(point.y) else {
                throw CaptureCoordinateMappingError.normalizedPointOutOfBounds
            }
            return CGPoint(
                x: bounds.minX + point.x * bounds.width,
                y: bounds.minY + point.y * bounds.height)
        }
    }
}
