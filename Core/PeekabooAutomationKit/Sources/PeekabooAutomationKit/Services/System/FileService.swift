import CoreGraphics
import Foundation
import ImageIO
import PeekabooFoundation
import UniformTypeIdentifiers

/// Default implementation of file system operations for snapshot management
public final class FileService: FileServiceProtocol {
    private let snapshotCacheDirectoryOverride: URL?

    public init() {
        self.snapshotCacheDirectoryOverride = nil
    }

    init(snapshotCacheDirectory: URL) {
        self.snapshotCacheDirectoryOverride = snapshotCacheDirectory
    }

    public func cleanAllSnapshots(dryRun: Bool) async throws -> SnapshotCleanResult {
        let cacheDir = self.getSnapshotCacheDirectory()
        var snapshotDetails: [SnapshotDetail] = []
        var totalBytesFreed: Int64 = 0

        guard FileManager.default.fileExists(atPath: cacheDir.path) else {
            return SnapshotCleanResult(
                snapshotsRemoved: 0,
                bytesFreed: 0,
                snapshotDetails: [],
                dryRun: dryRun)
        }

        let snapshotDirs = try FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: .skipsHiddenFiles)

        for snapshotDir in snapshotDirs {
            guard snapshotDir.hasDirectoryPath else { continue }

            let snapshotSize = try await calculateDirectorySize(snapshotDir)
            let snapshotId = snapshotDir.lastPathComponent
            let resourceValues = try snapshotDir.resourceValues(forKeys: [
                .creationDateKey,
                .contentModificationDateKey,
            ])

            let detail = SnapshotDetail(
                snapshotId: snapshotId,
                path: snapshotDir.path,
                size: snapshotSize,
                creationDate: resourceValues.creationDate,
                modificationDate: resourceValues.contentModificationDate)

            snapshotDetails.append(detail)
            totalBytesFreed += snapshotSize

            if !dryRun {
                try FileManager.default.removeItem(at: snapshotDir)
            }
        }

        return SnapshotCleanResult(
            snapshotsRemoved: snapshotDetails.count,
            bytesFreed: totalBytesFreed,
            snapshotDetails: snapshotDetails,
            dryRun: dryRun)
    }

    public func cleanOldSnapshots(hours: Int, dryRun: Bool) async throws -> SnapshotCleanResult {
        let cacheDir = self.getSnapshotCacheDirectory()
        var snapshotDetails: [SnapshotDetail] = []
        var totalBytesFreed: Int64 = 0

        guard FileManager.default.fileExists(atPath: cacheDir.path) else {
            return SnapshotCleanResult(
                snapshotsRemoved: 0,
                bytesFreed: 0,
                snapshotDetails: [],
                dryRun: dryRun)
        }

        let cutoffDate = Date().addingTimeInterval(-Double(hours) * 3600)

        let snapshotDirs = try FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: .skipsHiddenFiles)

        for snapshotDir in snapshotDirs {
            guard snapshotDir.hasDirectoryPath else { continue }

            let resourceValues = try snapshotDir.resourceValues(forKeys: [.contentModificationDateKey])
            let modificationDate = resourceValues.contentModificationDate

            if let modDate = modificationDate, modDate < cutoffDate {
                let snapshotSize = try await calculateDirectorySize(snapshotDir)
                let snapshotId = snapshotDir.lastPathComponent

                let detail = SnapshotDetail(
                    snapshotId: snapshotId,
                    path: snapshotDir.path,
                    size: snapshotSize,
                    creationDate: nil,
                    modificationDate: modDate)

                snapshotDetails.append(detail)
                totalBytesFreed += snapshotSize

                if !dryRun {
                    try FileManager.default.removeItem(at: snapshotDir)
                }
            }
        }

        return SnapshotCleanResult(
            snapshotsRemoved: snapshotDetails.count,
            bytesFreed: totalBytesFreed,
            snapshotDetails: snapshotDetails,
            dryRun: dryRun)
    }

    public func cleanSpecificSnapshot(snapshotId: String, dryRun: Bool) async throws -> SnapshotCleanResult {
        let cacheDir = self.getSnapshotCacheDirectory()
        guard let snapshotDir = SnapshotPathValidator.directChildURL(for: snapshotId, in: cacheDir) else {
            throw FileServiceError.invalidSnapshotID
        }

        guard FileManager.default.fileExists(atPath: snapshotDir.path) else {
            // Return empty result instead of throwing error for consistency with original behavior
            return SnapshotCleanResult(
                snapshotsRemoved: 0,
                bytesFreed: 0,
                snapshotDetails: [],
                dryRun: dryRun)
        }

        let snapshotSize = try await calculateDirectorySize(snapshotDir)
        let resourceValues = try snapshotDir.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])

        let detail = SnapshotDetail(
            snapshotId: snapshotId,
            path: snapshotDir.path,
            size: snapshotSize,
            creationDate: resourceValues.creationDate,
            modificationDate: resourceValues.contentModificationDate)

        if !dryRun {
            try FileManager.default.removeItem(at: snapshotDir)
        }

        return SnapshotCleanResult(
            snapshotsRemoved: 1,
            bytesFreed: snapshotSize,
            snapshotDetails: [detail],
            dryRun: dryRun)
    }

    public func getSnapshotCacheDirectory() -> URL {
        if let snapshotCacheDirectoryOverride {
            return snapshotCacheDirectoryOverride
        }
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".peekaboo/snapshots")
    }

    public func calculateDirectorySize(_ directory: URL) async throws -> Int64 {
        var totalSize: Int64 = 0

        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles])

        while let fileURL = enumerator?.nextObject() as? URL {
            let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            totalSize += Int64(fileSize)
        }

        return totalSize
    }

    public func listSnapshots() async throws -> [FileSnapshotInfo] {
        let cacheDir = self.getSnapshotCacheDirectory()
        var snapshots: [FileSnapshotInfo] = []

        guard FileManager.default.fileExists(atPath: cacheDir.path) else {
            return snapshots
        }

        let snapshotDirs = try FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: .skipsHiddenFiles)

        for snapshotDir in snapshotDirs {
            guard snapshotDir.hasDirectoryPath else { continue }

            let snapshotId = snapshotDir.lastPathComponent
            let snapshotSize = try await calculateDirectorySize(snapshotDir)
            let resourceValues = try snapshotDir.resourceValues(forKeys: [
                .creationDateKey,
                .contentModificationDateKey,
            ])

            // Get files in the snapshot directory
            let files = try FileManager.default.contentsOfDirectory(atPath: snapshotDir.path)
                .filter { !$0.hasPrefix(".") } // Skip hidden files

            let snapshotInfo = FileSnapshotInfo(
                snapshotId: snapshotId,
                path: snapshotDir,
                size: snapshotSize,
                creationDate: resourceValues.creationDate ?? Date(),
                modificationDate: resourceValues.contentModificationDate ?? Date(),
                files: files)

            snapshots.append(snapshotInfo)
        }

        // Sort by modification date, newest first
        snapshots.sort { $0.modificationDate > $1.modificationDate }

        return snapshots
    }

    // MARK: - Image Saving

    /// Save a CGImage to disk in the specified format
    public func saveImage(_ image: CGImage, to path: String, format: ImageFormat) throws {
        // Validate path doesn't contain null characters
        if path.contains("\0") {
            throw PeekabooError.fileIOError("Invalid characters in file path: \(path)")
        }

        let resolvedPath = PathResolver.expandPath(path)
        let url = URL(fileURLWithPath: resolvedPath)

        // Create parent directory if it doesn't exist
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil)
        } catch {
            throw error.asPeekabooError(context: "Failed to create directory for file: \(resolvedPath)")
        }

        let utType: UTType = format == .png ? .png : .jpeg
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            utType.identifier as CFString,
            1,
            nil)
        else {
            // Try to create a more specific error for common cases
            if !FileManager.default.isWritableFile(atPath: directory.path) {
                throw PeekabooError.fileIOError("Permission denied writing to: \(resolvedPath)")
            }
            throw PeekabooError.fileIOError("Failed to create image destination for: \(resolvedPath)")
        }

        // Set compression quality for JPEG images (1.0 = highest quality)
        let properties: CFDictionary? = if format == .jpg {
            [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
        } else {
            nil
        }

        CGImageDestinationAddImage(destination, image, properties)

        guard CGImageDestinationFinalize(destination) else {
            throw PeekabooError.fileIOError("Failed to finalize image write to: \(resolvedPath)")
        }
    }
}
