import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PeekabooFoundation

struct LegacyCapturedRaster {
    let image: CGImage
    let sourcePNG: Data?

    init(image: CGImage) {
        self.image = image
        self.sourcePNG = nil
    }

    init(systemScreencapturePNG data: Data) throws {
        guard
            LegacyPNGValidator.hasValidStructureAndCRC(data),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let providerData = image.dataProvider?.data
        else {
            throw OperationError.captureFailed(reason: "Failed to decode screencapture output")
        }
        let (requiredPixelBytes, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !overflow,
              requiredPixelBytes > 0,
              CFDataGetLength(providerData) >= requiredPixelBytes
        else {
            throw OperationError.captureFailed(reason: "Failed to decode screencapture output")
        }
        self.image = image
        self.sourcePNG = data
    }

    func pngData(for deliveredImage: CGImage) throws -> Data {
        // Object identity is the scaler's no-transform receipt; pixel equality alone is insufficient.
        if deliveredImage === self.image, let sourcePNG {
            return sourcePNG
        }
        return try deliveredImage.pngData()
    }
}

extension LegacyScreenCaptureOperator {
    func captureScreenWithSystemScreencapture(
        screen: NSScreen,
        correlationId: String) async throws -> LegacyCapturedRaster
    {
        guard let displayID = self.displayID(for: screen) else {
            throw OperationError.captureFailed(reason: "Could not resolve the selected NSScreen display ID")
        }
        let activeDisplayIDs = Self.activeDisplays().map(\.id)
        let mirroredDisplayOwners = Dictionary(
            uniqueKeysWithValues: activeDisplayIDs.compactMap { activeDisplayID in
                let owner = CGDisplayMirrorsDisplay(activeDisplayID)
                return owner == kCGNullDirectDisplay ? nil : (activeDisplayID, owner)
            })
        guard let displayNumber = ScreenCapturePlanner.systemScreencaptureDisplayNumber(
            displayID: displayID,
            activeDisplayIDs: activeDisplayIDs,
            mirroredDisplayOwners: mirroredDisplayOwners)
        else {
            throw OperationError.captureFailed(
                reason: "Selected display \(displayID) is not in the active display list")
        }

        return try await self.captureImageWithSystemScreencapture(
            arguments: [
                "-x",
                "-D",
                String(displayNumber),
            ],
            outputPrefix: "peekaboo-screen",
            logMessage: "Captured screen via system screencapture",
            metadata: [
                "displayID": String(displayID),
                "displayNumber": String(displayNumber),
            ],
            correlationId: correlationId)
    }

    func captureAreaWithSystemScreencapture(
        _ rect: CGRect,
        correlationId: String) async throws -> LegacyCapturedRaster
    {
        try await self.captureImageWithSystemScreencapture(
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
        correlationId: String) async throws -> LegacyCapturedRaster
    {
        // Match Apple's native window capture path; Hopper shows `screencapture -l` using
        // private window-id lookup before building its SCScreenshotManager content filter.
        // Exclude attached windows; the caller still validates the returned extent before publication.
        try await self.captureImageWithSystemScreencapture(
            arguments: [
                "-l",
                String(windowID),
                "-o",
                "-a",
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
        correlationId: String) async throws -> LegacyCapturedRaster
    {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(outputPrefix)-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments + [url.path]
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        try await Self.waitForSystemScreencaptureExit(
            process,
            timeoutSeconds: 5,
            operationName: "screencapture \(outputPrefix)")
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorText = (String(bytes: errorData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = errorText.isEmpty ? "" : ": \(errorText)"
            throw OperationError.captureFailed(
                reason: "screencapture exited with \(process.terminationStatus)\(detail)")
        }

        let raster = try LegacyCapturedRaster(systemScreencapturePNG: Data(contentsOf: url))

        var logMetadata = metadata
        logMetadata["imageSize"] = "\(raster.image.width)x\(raster.image.height)"
        self.logger.debug(
            logMessage,
            metadata: logMetadata,
            correlationId: correlationId)
        return raster
    }

    nonisolated static func waitForSystemScreencaptureExit(
        _ process: Process,
        timeoutSeconds: TimeInterval,
        operationName: String) async throws
    {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.waitForSystemScreencaptureExitBlocking(
                        process,
                        timeoutSeconds: timeoutSeconds,
                        operationName: operationName)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func waitForSystemScreencaptureExitBlocking(
        _ process: Process,
        timeoutSeconds: TimeInterval,
        operationName: String) throws
    {
        final class Completion: @unchecked Sendable {
            private let lock = NSLock()
            private let group = DispatchGroup()
            private var completed = false

            init() {
                self.group.enter()
            }

            func finish() {
                self.lock.lock()
                defer { self.lock.unlock() }
                guard !self.completed else { return }
                self.completed = true
                self.group.leave()
            }

            func wait(seconds: TimeInterval) -> DispatchTimeoutResult {
                self.group.wait(timeout: .now() + max(seconds, 0))
            }
        }

        let completion = Completion()
        process.terminationHandler = { _ in completion.finish() }
        if !process.isRunning {
            completion.finish()
        }
        guard completion.wait(seconds: timeoutSeconds) == .timedOut else { return }

        process.terminate()
        if completion.wait(seconds: 0.5) == .timedOut {
            let processIdentifier = process.processIdentifier
            if processIdentifier > 0 {
                kill(processIdentifier, SIGKILL)
            }
            _ = completion.wait(seconds: 0.5)
        }
        throw OperationError.timeout(operation: operationName, duration: timeoutSeconds)
    }

    private nonisolated static func regionArgument(for rect: CGRect) -> String {
        "-R\(Int(rect.minX.rounded(.down))),\(Int(rect.minY.rounded(.down)))," +
            "\(Int(rect.width.rounded(.toNearestOrAwayFromZero)))," +
            "\(Int(rect.height.rounded(.toNearestOrAwayFromZero)))"
    }
}
