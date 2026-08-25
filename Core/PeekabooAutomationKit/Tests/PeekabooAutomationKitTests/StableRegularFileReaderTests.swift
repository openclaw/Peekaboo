import Darwin
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct StableRegularFileReaderTests {
    @Test
    func `owner private regular file is read exactly`() throws {
        let fixture = try Fixture(contents: Data("9222\n/devtools/browser/browser-a".utf8))
        defer { fixture.cleanup() }

        let data = try StableRegularFileReader.live.read(fixture.fileURL, 1024)

        #expect(String(data: data, encoding: .utf8) == "9222\n/devtools/browser/browser-a")
    }

    @Test
    func `symlink group writable and hard linked files are unsafe`() throws {
        let fixture = try Fixture(contents: Data("authority".utf8))
        defer { fixture.cleanup() }

        let symlinkURL = fixture.rootURL.appending(path: "symlink")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: fixture.fileURL)
        #expect(throws: StableRegularFileReadError.self) {
            _ = try StableRegularFileReader.live.read(symlinkURL, 1024)
        }

        #expect(chmod(fixture.fileURL.path, 0o660) == 0)
        #expect(throws: StableRegularFileReadError.self) {
            _ = try StableRegularFileReader.live.read(fixture.fileURL, 1024)
        }
        #expect(chmod(fixture.fileURL.path, 0o600) == 0)

        let linkURL = fixture.rootURL.appending(path: "hard-link")
        #expect(link(fixture.fileURL.path, linkURL.path) == 0)
        #expect(throws: StableRegularFileReadError.self) {
            _ = try StableRegularFileReader.live.read(fixture.fileURL, 1024)
        }
    }

    @Test
    func `same inode mutation during read is refused`() throws {
        let fixture = try Fixture(contents: Data("authority".utf8))
        defer { fixture.cleanup() }

        #expect(throws: StableRegularFileReadError.changedDuringRead(fixture.fileURL.path)) {
            _ = try StableRegularFileReader.readStableRegularFile(
                at: fixture.fileURL,
                maximumByteCount: 1024,
                expectedOwner: geteuid(),
                afterRead: {
                    var times = [timespec(), timespec()]
                    times[0].tv_nsec = Int(UTIME_OMIT)
                    times[1].tv_nsec = Int(UTIME_NOW)
                    _ = utimensat(AT_FDCWD, fixture.fileURL.path, &times, 0)
                })
        }
    }

    private struct Fixture {
        let rootURL: URL
        let fileURL: URL

        init(contents: Data) throws {
            self.rootURL = FileManager.default.temporaryDirectory
                .appending(path: "peekaboo-stable-file-\(UUID().uuidString)", directoryHint: .isDirectory)
            self.fileURL = self.rootURL.appending(path: "authority", directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: false)
            _ = FileManager.default.createFile(atPath: self.fileURL.path, contents: contents)
            guard chmod(self.fileURL.path, 0o600) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: self.rootURL)
        }
    }
}
