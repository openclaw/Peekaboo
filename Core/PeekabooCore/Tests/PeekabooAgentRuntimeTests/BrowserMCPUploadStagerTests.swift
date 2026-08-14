import Darwin
import Foundation
import Testing
@testable import PeekabooAgentRuntime

struct BrowserMCPUploadStagerTests {
    @Test
    func `staging uses owner-only session and transfer directories and preserves the safe basename`() async throws {
        let fixture = try UploadStagingFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write(name: "invoice upload.txt", contents: Data("fixture-value".utf8))
        let stager = fixture.stager()
        let workspace = try await stager.createWorkspace()
        defer { workspace.cleanup() }

        let staged = try await stager.stage(path: source.path, in: workspace)

        #expect(URL(fileURLWithPath: staged.filePath).lastPathComponent == "invoice upload.txt")
        #expect(URL(fileURLWithPath: staged.rootPath).deletingLastPathComponent().path == workspace.rootPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: staged.filePath)) == Data("fixture-value".utf8))
        #expect(Self.permissionBits(workspace.rootPath) == 0o700)
        #expect(Self.permissionBits(staged.rootPath) == 0o700)
        #expect(Self.permissionBits(staged.filePath) == 0o400)

        staged.cleanup()
        #expect(!FileManager.default.fileExists(atPath: staged.rootPath))
        #expect(FileManager.default.fileExists(atPath: workspace.rootPath))
        workspace.cleanup()
        #expect(!FileManager.default.fileExists(atPath: workspace.rootPath))
    }

    @Test
    func `path policy refuses relative traversal symlink directory and oversized sources`() async throws {
        let fixture = try UploadStagingFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write(name: "source.txt", contents: Data("1234".utf8))
        let symlink = fixture.root.appendingPathComponent("source-link.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        let directory = fixture.root.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let workspace = try await fixture.stager().createWorkspace()
        defer { workspace.cleanup() }

        await #expect(throws: BrowserMCPUploadStagingError.self) {
            _ = try await fixture.stager().stage(path: "source.txt", in: workspace)
        }
        await #expect(throws: BrowserMCPUploadStagingError.self) {
            _ = try await fixture.stager().stage(
                path: source.deletingLastPathComponent()
                    .appendingPathComponent("directory/../source.txt").path,
                in: workspace)
        }
        await #expect(throws: BrowserMCPUploadStagingError.self) {
            _ = try await fixture.stager().stage(path: symlink.path, in: workspace)
        }
        await #expect(throws: BrowserMCPUploadStagingError.self) {
            _ = try await fixture.stager().stage(path: directory.path, in: workspace)
        }
        let exactLimit = try await fixture.stager(maximumBytes: 4).stage(path: source.path, in: workspace)
        exactLimit.cleanup()
        await #expect(throws: BrowserMCPUploadStagingError.sourceTooLarge(maximumBytes: 3)) {
            _ = try await fixture.stager(maximumBytes: 3).stage(path: source.path, in: workspace)
        }
        #expect(try Self.transferDirectories(in: workspace.rootPath).isEmpty)
    }

    @Test
    func `final symlink swap and regular-file replacement are refused without staging bytes`() async throws {
        let fixture = try UploadStagingFixture()
        defer { fixture.cleanup() }
        let target = try fixture.write(name: "target.txt", contents: Data("do-not-read".utf8))

        let symlinkSource = try fixture.write(name: "symlink-source.txt", contents: Data("original".utf8))
        let symlinkStager = fixture.stager(sourceInspectionHook: { path in
            try FileManager.default.removeItem(atPath: path)
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target.path)
        })
        let symlinkWorkspace = try await symlinkStager.createWorkspace()
        defer { symlinkWorkspace.cleanup() }
        await #expect(throws: BrowserMCPUploadStagingError.sourceChanged) {
            _ = try await symlinkStager.stage(path: symlinkSource.path, in: symlinkWorkspace)
        }
        #expect(try Self.transferDirectories(in: symlinkWorkspace.rootPath).isEmpty)

        let replacedSource = try fixture.write(name: "replaced-source.txt", contents: Data("original".utf8))
        let regularStager = fixture.stager(sourceInspectionHook: { path in
            try FileManager.default.removeItem(atPath: path)
            try Data("replacement".utf8).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        })
        let regularWorkspace = try await regularStager.createWorkspace()
        defer { regularWorkspace.cleanup() }
        await #expect(throws: BrowserMCPUploadStagingError.sourceChanged) {
            _ = try await regularStager.stage(path: replacedSource.path, in: regularWorkspace)
        }
        #expect(try Self.transferDirectories(in: regularWorkspace.rootPath).isEmpty)
    }

    @Test
    func `source size drift during copy fails closed and removes transfer directory`() async throws {
        let fixture = try UploadStagingFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write(
            name: "changing.bin",
            contents: Data(repeating: 0x41, count: 512 * 1024))
        let truncated = LockedFlag()
        let stager = fixture.stager(copyProgressHook: { _ in
            if truncated.take() {
                guard truncate(source.path, 0) == 0 else {
                    throw BrowserMCPUploadStagingError.stagingFailed("test truncate failed")
                }
            }
        })
        let workspace = try await stager.createWorkspace()
        defer { workspace.cleanup() }

        await #expect(throws: BrowserMCPUploadStagingError.sourceChanged) {
            _ = try await stager.stage(path: source.path, in: workspace)
        }
        #expect(try Self.transferDirectories(in: workspace.rootPath).isEmpty)
    }

    @Test
    func `cancellation during copy removes transfer directory and leaves workspace reusable`() async throws {
        let fixture = try UploadStagingFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write(
            name: "cancel.bin",
            contents: Data(repeating: 0x42, count: 512 * 1024))
        let barrier = UploadCopyBarrier()
        let stager = fixture.stager(copyProgressHook: { _ in barrier.blockOnce() })
        let workspace = try await stager.createWorkspace()
        defer { workspace.cleanup() }

        let task = Task {
            try await stager.stage(path: source.path, in: workspace)
        }
        #expect(await barrier.waitUntilBlocked())
        task.cancel()
        barrier.release()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(try Self.transferDirectories(in: workspace.rootPath).isEmpty)

        let staged = try await fixture.stager().stage(path: source.path, in: workspace)
        staged.cleanup()
    }

    private static func permissionBits(_ path: String) -> mode_t? {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & mode_t(0o777)
    }

    private static func transferDirectories(in workspacePath: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: workspacePath)
            .filter { $0.hasPrefix("upload.") }
    }
}

struct UploadStagingFixture {
    let root: URL
    let stagingParent: URL

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-upload-stager-tests-\(UUID().uuidString)", isDirectory: true)
        self.stagingParent = self.root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: self.stagingParent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    func write(name: String, contents: Data) throws -> URL {
        let url = self.root.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: url, options: .withoutOverwriting)
        return url
    }

    func stager(
        maximumBytes: Int64 = BrowserMCPUploadStager.maximumFileSize,
        sourceInspectionHook: @escaping BrowserMCPUploadStager.SourceInspectionHook = { _ in },
        copyProgressHook: @escaping BrowserMCPUploadStager.CopyProgressHook = { _ in })
        -> BrowserMCPUploadStager
    {
        BrowserMCPUploadStager(
            temporaryDirectory: self.stagingParent.path,
            maximumBytes: maximumBytes,
            sourceInspectionHook: sourceInspectionHook,
            copyProgressHook: copyProgressHook)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.root)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true

    func take() -> Bool {
        self.lock.withLock {
            defer { self.available = false }
            return self.available
        }
    }
}

private final class UploadCopyBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let blockedSignal = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var shouldBlock = true

    func blockOnce() {
        let block = self.lock.withLock {
            defer { self.shouldBlock = false }
            return self.shouldBlock
        }
        guard block else { return }
        self.blockedSignal.signal()
        self.releaseSignal.wait()
    }

    func waitUntilBlocked() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.blockedSignal.wait(timeout: .now() + 2) == .success)
            }
        }
    }

    func release() {
        self.releaseSignal.signal()
    }
}
