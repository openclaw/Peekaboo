import CoreGraphics
import Foundation

enum ScreenCaptureImageScaler {
    static func maybeDownscale(
        _ image: CGImage,
        scale: CaptureScalePreference,
        fallbackScale: CGFloat) -> CGImage
    {
        guard scale == .logical1x, fallbackScale > 1 else {
            return image
        }

        let targetSize = CGSize(
            width: CGFloat(image.width) / fallbackScale,
            height: CGFloat(image.height) / fallbackScale)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = Self.contextBitmapInfo(for: image)
        guard let context = CGContext(
            data: nil,
            width: Int(targetSize.width.rounded()),
            height: Int(targetSize.height.rounded()),
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue)
        else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: targetSize))
        return context.makeImage() ?? image
    }

    private static func contextBitmapInfo(for image: CGImage) -> CGBitmapInfo {
        let alphaInfo: CGImageAlphaInfo = switch image.alphaInfo {
        case .first: .premultipliedFirst
        case .last: .premultipliedLast
        default: image.alphaInfo
        }
        guard alphaInfo != image.alphaInfo else { return image.bitmapInfo }

        // ImageIO can decode PNGs with straight alpha, which is invalid as a bitmap-context destination format.
        let alphaInfoMask: UInt32 = 0x1F
        let rawValue = (image.bitmapInfo.rawValue & ~alphaInfoMask) | alphaInfo.rawValue
        return CGBitmapInfo(rawValue: rawValue)
    }
}
