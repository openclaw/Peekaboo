import CoreGraphics
import PeekabooFoundation

/// A window raster has no origin receipt. Never infer its extent or density from its dimensions.
struct LegacyWindowCaptureGeometry {
    let bounds: CGRect
    let scalePlan: ScreenCaptureScaleResolver.Plan

    init(bounds: CGRect, scalePlan: ScreenCaptureScaleResolver.Plan) throws {
        try Self.validateBounds(bounds)
        self.bounds = bounds
        self.scalePlan = scalePlan
        _ = try self.pixelSize(scale: scalePlan.nativeScale)
        _ = try self.pixelSize(scale: scalePlan.outputScale)
    }

    static func screenIndex(for bounds: CGRect, screenFrames: [CGRect]) -> Int? {
        let appKitBounds = GlobalScreenCoordinateGeometry.appKitRect(
            fromGlobalDisplay: bounds,
            primaryScreenFrame: screenFrames.first)
        switch ScreenCapturePlanner.matchDisplay(windowFrame: appKitBounds, displayFrames: screenFrames) {
        case let .mapped(index), let .unmapped(index):
            return index
        case .noDisplays:
            return nil
        }
    }

    static func validateBounds(_ bounds: CGRect) throws {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.size.width.isFinite, bounds.size.height.isFinite,
              bounds.size.width > 0, bounds.size.height > 0,
              bounds.maxX.isFinite, bounds.maxY.isFinite
        else {
            throw OperationError.captureFailed(reason: "Exact window capture requires finite, positive window bounds")
        }
    }

    func deliver(_ raster: LegacyCapturedRaster, sourceScale: CGFloat) throws -> LegacyCapturedRaster {
        try self.validate(raster.image, scale: sourceScale)
        let image = ScreenCaptureImageScaler.maybeDownscale(
            raster.image,
            scale: self.scalePlan.preference,
            fallbackScale: sourceScale)
        try self.validate(image, scale: self.scalePlan.outputScale)
        return image === raster.image ? raster : LegacyCapturedRaster(image: image)
    }

    private func validate(_ image: CGImage, scale: CGFloat) throws {
        let expected = try self.pixelSize(scale: scale)
        guard image.width == expected.width, image.height == expected.height else {
            throw OperationError.captureFailed(
                reason: "Exact window capture returned \(image.width)x\(image.height) pixels; " +
                    "expected \(expected.width)x\(expected.height) for the selected window. " +
                    "Refusing a raster whose extent cannot be mapped to that window.")
        }
    }

    private func pixelSize(scale: CGFloat) throws -> (width: Int, height: Int) {
        guard scale.isFinite, scale > 0,
              let width = Int(exactly: self.bounds.width * scale), width > 0,
              let height = Int(exactly: self.bounds.height * scale), height > 0
        else {
            throw OperationError.captureFailed(
                reason: "Exact window bounds must map to whole pixels at the capture scale")
        }
        return (width, height)
    }
}
