import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PeekabooFoundation

extension LegacyScreenCaptureOperator {
    func captureScreenWithSystemScreencapture(
        screen: NSScreen,
        correlationId: String) throws -> CGImage
    {
        let desktopBounds = Self.desktopBounds(for: NSScreen.screens.map(\.frame))
        let region = ScreenCapturePlanner.systemScreencaptureRegionRect(
            appKitRect: screen.frame,
            desktopBounds: desktopBounds)
        return try self.captureImageWithSystemScreencapture(
            arguments: [
                "-x",
                Self.regionArgument(for: region),
            ],
            outputPrefix: "peekaboo-screen",
            logMessage: "Captured screen via system screencapture",
            metadata: [:],
            correlationId: correlationId)
    }

    func captureAreaWithSystemScreencapture(
        _ rect: CGRect,
        correlationId: String) throws -> CGImage
    {
        try self.captureImageWithSystemScreencapture(
            arguments: [
                "-x",
                Self.regionArgument(for: rect),
            ],
            outputPrefix: "peekaboo-area",
            logMessage: "Captured area via system screencapture",
            metadata: [:],
            correlationId: correlationId)
    }

    func captureWindowWithSystemScreencapture(
        windowID: CGWindowID,
        correlationId: String) throws -> CGImage
    {
        // Match Apple's native window capture path; Hopper shows `screencapture -l` using
        // private window-id lookup before building its SCScreenshotManager content filter.
        try self.captureImageWithSystemScreencapture(
            arguments: [
                "-l",
                String(windowID),
                "-o",
                "-x",
            ],
            outputPrefix: "peekaboo-window-\(windowID)",
            logMessage: "Captured window via system screencapture",
            metadata: ["windowID": String(windowID)],
            correlationId: correlationId)
    }

    private func captureImageWithSystemScreencapture(
        arguments: [String],
        outputPrefix: String,
        logMessage: String,
        metadata: [String: String],
        correlationId: String) throws -> CGImage
    {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(outputPrefix)-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments + [url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OperationError.captureFailed(reason: "screencapture exited with \(process.terminationStatus)")
        }

        let data = try Data(contentsOf: url)
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw OperationError.captureFailed(reason: "Failed to decode screencapture output")
        }

        var logMetadata = metadata
        logMetadata["imageSize"] = "\(image.width)x\(image.height)"
        self.logger.debug(
            logMessage,
            metadata: logMetadata,
            correlationId: correlationId)
        return image
    }

    private nonisolated static func regionArgument(for rect: CGRect) -> String {
        "-R\(Int(rect.minX.rounded(.down))),\(Int(rect.minY.rounded(.down)))," +
            "\(Int(rect.width.rounded(.toNearestOrAwayFromZero)))," +
            "\(Int(rect.height.rounded(.toNearestOrAwayFromZero)))"
    }

    private nonisolated static func desktopBounds(for frames: [CGRect]) -> CGRect {
        frames.reduce(CGRect.null) { partial, frame in
            partial.union(frame)
        }
    }
}
