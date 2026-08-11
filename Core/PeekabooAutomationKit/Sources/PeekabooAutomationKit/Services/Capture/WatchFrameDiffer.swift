import CoreGraphics
import Foundation

enum WatchFrameDiffer {
    struct LumaBuffer {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    struct DiffResult {
        let changePercent: Double
        let boundingBoxes: [CGRect]
        let downgraded: Bool
    }

    struct DiffInput {
        let strategy: WatchCaptureOptions.DiffStrategy
        let diffBudgetMs: Int?
        let previous: LumaBuffer?
        let current: LumaBuffer
        let deltaThreshold: UInt8
        let originalSize: CGSize
    }

    static func makeLumaBuffer(from image: CGImage, maxWidth: CGFloat) -> LumaBuffer {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxWidth / max(width, height))
        let targetSize = CGSize(width: width * scale, height: height * scale)
        let w = Int(targetSize.width)
        let h = Int(targetSize.height)
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let context = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else {
            return LumaBuffer(width: 1, height: 1, pixels: [0])
        }
        context.draw(image, in: CGRect(origin: .zero, size: targetSize))
        return LumaBuffer(width: w, height: h, pixels: pixels)
    }

    static func computeChange(using input: DiffInput) -> DiffResult {
        guard let previous = input.previous else {
            // First frame: force 100% change and a full-frame box so downstream logic always keeps it.
            return self.fullFrameChange(originalSize: input.originalSize)
        }

        guard previous.width == input.current.width,
              previous.height == input.current.height
        else {
            // Luma coordinates are incomparable after a geometry change. Treat the current frame as wholly changed
            // instead of truncating unequal buffers and publishing a partial percentage or misplaced motion box.
            return self.fullFrameChange(originalSize: input.originalSize)
        }

        // Fast path always runs to get bounding boxes; quality may replace change% but keeps the boxes.
        let pixelDiff = self.computePixelDelta(
            previous: previous,
            current: input.current,
            deltaThreshold: input.deltaThreshold,
            originalSize: input.originalSize)

        var changePercent: Double
        switch input.strategy {
        case .fast:
            changePercent = pixelDiff.changePercent
        case .quality:
            if let budget = input.diffBudgetMs {
                let start = DispatchTime.now().uptimeNanoseconds
                let ssim = self.computeSSIM(previous: previous, current: input.current)
                let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                if elapsedMs > budget {
                    // Guardrail: fall back to fast diff if SSIM is too slow to keep the session responsive.
                    changePercent = pixelDiff.changePercent
                    return DiffResult(
                        changePercent: changePercent,
                        boundingBoxes: pixelDiff.boundingBoxes,
                        downgraded: true)
                } else {
                    changePercent = max(0, min(100, (1 - ssim) * 100))
                }
            } else {
                let ssim = self.computeSSIM(previous: previous, current: input.current)
                changePercent = max(0, min(100, (1 - ssim) * 100))
            }
        }

        return DiffResult(
            changePercent: changePercent,
            boundingBoxes: pixelDiff.boundingBoxes,
            downgraded: false)
    }

    private static func fullFrameChange(originalSize: CGSize) -> DiffResult {
        DiffResult(
            changePercent: 100.0,
            boundingBoxes: [CGRect(origin: .zero, size: originalSize)],
            downgraded: false)
    }

    static func computeSSIM(previous: LumaBuffer, current: LumaBuffer) -> Double {
        let count = min(previous.pixels.count, current.pixels.count)
        if count == 0 {
            return 0
        }

        var meanX: Double = 0
        var meanY: Double = 0
        for idx in 0..<count {
            meanX += Double(previous.pixels[idx])
            meanY += Double(current.pixels[idx])
        }
        meanX /= Double(count)
        meanY /= Double(count)

        var varianceX: Double = 0
        var varianceY: Double = 0
        var covariance: Double = 0
        for idx in 0..<count {
            let x = Double(previous.pixels[idx]) - meanX
            let y = Double(current.pixels[idx]) - meanY
            varianceX += x * x
            varianceY += y * y
            covariance += x * y
        }
        varianceX /= Double(count - 1)
        varianceY /= Double(count - 1)
        covariance /= Double(count - 1)

        let c1 = pow(0.01 * 255.0, 2.0)
        let c2 = pow(0.03 * 255.0, 2.0)

        let numerator = (2 * meanX * meanY + c1) * (2 * covariance + c2)
        let denominator = (meanX * meanX + meanY * meanY + c1) * (varianceX + varianceY + c2)

        guard denominator != 0 else { return 0 }
        return numerator / denominator
    }

    private static func computePixelDelta(
        previous: LumaBuffer,
        current: LumaBuffer,
        deltaThreshold: UInt8,
        originalSize: CGSize) -> DiffResult
    {
        let count = min(previous.pixels.count, current.pixels.count)
        if count == 0 {
            return DiffResult(changePercent: 0, boundingBoxes: [], downgraded: false)
        }

        var changed = 0
        var mask = Array(repeating: false, count: count)
        for idx in 0..<count {
            let diff = abs(Int(previous.pixels[idx]) - Int(current.pixels[idx]))
            if diff >= deltaThreshold {
                changed += 1
                mask[idx] = true
            }
        }

        let percent = (Double(changed) / Double(count)) * 100.0
        if changed == 0 {
            return DiffResult(changePercent: percent, boundingBoxes: [], downgraded: false)
        }

        let boxes = self.extractBoundingBoxes(
            mask: mask,
            width: current.width,
            height: current.height,
            originalSize: originalSize)
        return DiffResult(changePercent: percent, boundingBoxes: boxes, downgraded: false)
    }

    /// Extract axis-aligned bounding boxes for connected components in the diff mask.
    private static func extractBoundingBoxes(
        mask: [Bool],
        width: Int,
        height: Int,
        originalSize: CGSize) -> [CGRect]
    {
        var visited = Array(repeating: false, count: mask.count)
        let directions = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        let maxBoxes = 5 // Avoid overwhelming overlays
        let minPixels = 1 // Tiny blobs still count; caller can filter when drawing
        var collected: [CGRect] = []

        func index(_ x: Int, _ y: Int) -> Int {
            y * width + x
        }

        for y in 0..<height {
            for x in 0..<width {
                let idx = index(x, y)
                if !mask[idx] || visited[idx] {
                    continue
                }

                var stack = [(x, y)]
                visited[idx] = true
                var minX = x
                var maxX = x
                var minY = y
                var maxY = y
                var count = 0

                while let (cx, cy) = stack.popLast() {
                    count += 1
                    minX = min(minX, cx)
                    maxX = max(maxX, cx)
                    minY = min(minY, cy)
                    maxY = max(maxY, cy)
                    for (dx, dy) in directions {
                        let nx = cx + dx
                        let ny = cy + dy
                        if nx < 0 || ny < 0 || nx >= width || ny >= height {
                            continue
                        }
                        let nIdx = index(nx, ny)
                        if mask[nIdx], !visited[nIdx] {
                            visited[nIdx] = true
                            stack.append((nx, ny))
                        }
                    }
                }

                guard count >= minPixels else { continue }

                let scaleX = originalSize.width / CGFloat(width)
                let scaleY = originalSize.height / CGFloat(height)
                let rect = CGRect(
                    x: CGFloat(minX) * scaleX,
                    y: CGFloat(minY) * scaleY,
                    width: CGFloat(maxX - minX + 1) * scaleX,
                    height: CGFloat(maxY - minY + 1) * scaleY)
                collected.append(rect)
            }
        }

        guard !collected.isEmpty else {
            return []
        }

        let sorted = collected.sorted { lhs, rhs in
            let lhsArea = lhs.width * lhs.height
            let rhsArea = rhs.width * rhs.height
            if lhsArea == rhsArea {
                return lhs.origin.y < rhs.origin.y
            }
            return lhsArea > rhsArea
        }

        let unionRect = sorted.dropFirst().reduce(sorted[0]) { partialResult, rect in
            partialResult.union(rect)
        }

        var result: [CGRect] = [unionRect]
        for rect in sorted {
            guard result.count < maxBoxes else { break }
            if rect.equalTo(unionRect) {
                continue
            }
            result.append(rect)
        }

        return result
    }
}
