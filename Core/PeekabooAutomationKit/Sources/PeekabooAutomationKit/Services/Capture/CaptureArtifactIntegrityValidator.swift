import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct CaptureArtifactIntegrityError: LocalizedError, Sendable, Equatable {
    public let artifact: String
    public let reason: String

    public init(artifact: String, reason: String) {
        self.artifact = artifact
        self.reason = reason
    }

    public var errorDescription: String? {
        "Capture artifact integrity failed for \(self.artifact): \(self.reason)"
    }
}

public struct CaptureArtifactIntegrityReceipt: Sendable, Equatable {
    public let metadataSHA256: String
}

public enum CaptureArtifactIntegrityValidator {
    struct RetainedFile: Sendable {
        let data: Data
        let sha256: String
    }

    static let maximumPNGBytes = 256 * 1024 * 1024
    public static let maximumVideoBytes = 4 * 1024 * 1024 * 1024
    private static let maximumMetadataBytes = 16 * 1024 * 1024

    @discardableResult
    public static func validate(_ result: CaptureSessionResult) throws -> CaptureArtifactIntegrityReceipt {
        guard !result.frames.isEmpty else {
            throw CaptureArtifactIntegrityError(artifact: "frames", reason: "no retained frames")
        }
        for frame in result.frames {
            try Task.checkCancellation()
            try self.validatePNG(
                path: frame.path,
                expectedSHA256: frame.sha256,
                expectedSize: nil)
        }

        let contactSize = CGSize(
            width: CGFloat(result.contactSheet.columns) * result.contactSheet.thumbSize.width,
            height: CGFloat(result.contactSheet.rows) * result.contactSheet.thumbSize.height)
        try self.validatePNG(
            path: result.contactSheet.path,
            expectedSHA256: result.contactSheet.sha256,
            expectedSize: contactSize)

        try Task.checkCancellation()
        let metadataFile = try self.retainedRegularFile(
            path: result.metadataFile,
            maximumBytes: self.maximumMetadataBytes)
        let decoded: CaptureSessionResult
        do {
            decoded = try JSONDecoder().decode(CaptureSessionResult.self, from: metadataFile.data)
        } catch {
            throw CaptureArtifactIntegrityError(
                artifact: result.metadataFile,
                reason: "metadata is not a CaptureSessionResult")
        }
        guard decoded == result else {
            throw CaptureArtifactIntegrityError(
                artifact: result.metadataFile,
                reason: "metadata does not match the in-memory capture result")
        }
        switch (result.videoOut, result.videoArtifactCustody) {
        case (nil, nil):
            break
        case let (path?, expected?):
            let observed = try self.videoCustody(path: path)
            guard observed == expected else {
                throw CaptureArtifactIntegrityError(
                    artifact: path,
                    reason: "video does not match writer-authored custody")
            }
        case let (path?, nil):
            throw CaptureArtifactIntegrityError(
                artifact: path,
                reason: "video lacks writer-authored custody")
        case let (nil, custody?):
            throw CaptureArtifactIntegrityError(
                artifact: custody.path,
                reason: "video custody exists without a video output")
        }
        return CaptureArtifactIntegrityReceipt(
            metadataSHA256: metadataFile.sha256)
    }

    public static func videoCustody(path: String) throws -> CaptureVideoArtifactCustody {
        let descriptor = path.withCString { filePath in
            open(filePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw CaptureArtifactIntegrityError(artifact: path, reason: "video could not be opened safely")
        }
        defer { close(descriptor) }
        return try self.videoCustody(descriptor: descriptor, path: path)
    }

    static func videoCustody(
        descriptor: Int32,
        path: String,
        expectedDevice: UInt64? = nil,
        expectedInode: UInt64? = nil) throws -> CaptureVideoArtifactCustody
    {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw CaptureArtifactIntegrityError(artifact: path, reason: "video could not be rewound safely")
        }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(),
              before.st_nlink == 1,
              before.st_mode & (S_IWGRP | S_IWOTH) == 0,
              before.st_size > 0,
              before.st_size <= off_t(self.maximumVideoBytes)
        else {
            throw CaptureArtifactIntegrityError(artifact: path, reason: "video is not a bounded owner-controlled file")
        }
        let device = UInt64(before.st_dev)
        let inode = UInt64(before.st_ino)
        guard expectedDevice == nil || expectedDevice == device,
              expectedInode == nil || expectedInode == inode
        else {
            throw CaptureArtifactIntegrityError(artifact: path, reason: "video inode changed after writer admission")
        }

        var hasher = SHA256()
        var byteCount = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let (updatedCount, overflow) = byteCount.addingReportingOverflow(count)
                guard !overflow, updatedCount <= self.maximumVideoBytes else {
                    throw CaptureArtifactIntegrityError(artifact: path, reason: "video exceeds the size limit")
                }
                hasher.update(data: Data(buffer.prefix(count)))
                byteCount = updatedCount
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw CaptureArtifactIntegrityError(artifact: path, reason: "video could not be read safely")
        }

        var after = stat()
        var pathAfter = stat()
        let pathResult = path.withCString { lstat($0, &pathAfter) }
        guard fstat(descriptor, &after) == 0,
              pathResult == 0,
              after.st_mode & S_IFMT == S_IFREG,
              pathAfter.st_mode & S_IFMT == S_IFREG,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              after.st_dev == pathAfter.st_dev,
              after.st_ino == pathAfter.st_ino,
              byteCount == Int(after.st_size)
        else {
            throw CaptureArtifactIntegrityError(artifact: path, reason: "video changed while custody was retained")
        }
        return CaptureVideoArtifactCustody(
            path: URL(fileURLWithPath: path).standardizedFileURL.path,
            byteCount: byteCount,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            device: device,
            inode: inode)
    }

    private static func validatePNG(
        path: String,
        expectedSHA256: String?,
        expectedSize: CGSize?) throws
    {
        guard let expectedSHA256,
              expectedSHA256.count == 64,
              expectedSHA256.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ||
                      (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
              })
        else {
            throw CaptureArtifactIntegrityError(artifact: path, reason: "missing canonical SHA-256 custody")
        }
        let retained = try self.retainedRegularFile(path: path, maximumBytes: self.maximumPNGBytes)
        guard retained.sha256 == expectedSHA256 else {
            throw CaptureArtifactIntegrityError(artifact: path, reason: "SHA-256 does not match capture custody")
        }
        guard let source = CGImageSourceCreateWithData(
            retained.data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) == 1,
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
            let sourceType = CGImageSourceGetType(source),
            UTType(sourceType as String)?.conforms(to: .png) == true,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
            width > 0,
            height > 0,
            CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary) != nil
        else {
            throw CaptureArtifactIntegrityError(artifact: path, reason: "file is not one complete PNG image")
        }
        if let expectedSize,
           width != Double(expectedSize.width) || height != Double(expectedSize.height)
        {
            throw CaptureArtifactIntegrityError(
                artifact: path,
                reason: "PNG dimensions do not match the capture result")
        }
    }

    static func retainedRegularFile(path: String, maximumBytes: Int) throws -> RetainedFile {
        let descriptor = path.withCString { filePath in
            open(filePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw CaptureArtifactIntegrityError(artifact: path, reason: "file could not be opened safely")
        }
        defer { close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0,
              before.st_size <= off_t(maximumBytes)
        else {
            throw CaptureArtifactIntegrityError(artifact: path, reason: "file is not a bounded regular file")
        }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard data.count <= maximumBytes - count else {
                    throw CaptureArtifactIntegrityError(artifact: path, reason: "file exceeds the size limit")
                }
                let chunk = Data(buffer.prefix(count))
                data.append(chunk)
                hasher.update(data: chunk)
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw CaptureArtifactIntegrityError(artifact: path, reason: "file could not be read safely")
        }

        var after = stat()
        var pathAfter = stat()
        let pathResult = path.withCString { lstat($0, &pathAfter) }
        guard fstat(descriptor, &after) == 0,
              pathResult == 0,
              after.st_mode & S_IFMT == S_IFREG,
              pathAfter.st_mode & S_IFMT == S_IFREG,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              after.st_dev == pathAfter.st_dev,
              after.st_ino == pathAfter.st_ino,
              data.count == Int(after.st_size)
        else {
            throw CaptureArtifactIntegrityError(artifact: path, reason: "file changed while being retained")
        }
        return RetainedFile(
            data: data,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
