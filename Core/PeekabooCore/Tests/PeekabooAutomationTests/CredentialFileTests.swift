import Darwin
import Foundation
import Testing
@testable import PeekabooAutomation

@Suite(.serialized)
struct CredentialFileTests {
    @Test
    func `fresh snapshots preserve equals and forget deleted entries`() throws {
        try self.withFile { file in
            #expect(try file.readCredentialSnapshot().isEmpty)
            _ = try file.updateCredentials { $0["OPENAI_API_KEY"] = "synthetic==value" }
            _ = try file.updateCredentials { $0["OTHER"] = "synthetic-other" }
            let roundTrip = try file.readCredentialSnapshot()["OPENAI_API_KEY"] == "synthetic==value"
            #expect(roundTrip)
            try FileManager.default.removeItem(at: file.url)
            _ = try file.updateCredentials { $0["NEW"] = "synthetic-new" }
            #expect(try file.readCredentialSnapshot().count == 1)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
            let directory = try FileManager.default.attributesOfItem(atPath: file.url.deletingLastPathComponent().path)
            #expect(directory[.posixPermissions] as? Int == 0o700)
        }
    }

    @Test(arguments: 0..<4)
    func `malformed file cannot be overwritten`(_ example: Int) throws {
        let content = ["not an entry", "=missing name", "KEY=synthetic\u{0}", "KEY=synthetic\ninvalid"][example]
        try self.withFile { file in
            _ = try file.updateCredentials { $0["OLD"] = "synthetic-original" }
            try content.write(to: file.url, atomically: false, encoding: .utf8)
            #expect(throws: CredentialFile.Failure.invalidData) {
                try file.updateCredentials { $0["NEW"] = "synthetic-new" }
            }
            let preserved = try String(contentsOf: file.url, encoding: .utf8) == content
            #expect(preserved)
        }
    }

    @Test
    func `failed read does not run mutation`() throws {
        try self.withFile { file in
            _ = try file.updateCredentials { $0["OLD"] = "synthetic-original" }
            #expect(chmod(file.url.path, 0) == 0)
            defer { chmod(file.url.path, 0o600) }
            var edited = false
            #expect(throws: CredentialFile.Failure.unreadable) {
                try file.updateCredentials { _ in edited = true }
            }
            #expect(!edited)
        }
    }

    @Test
    func `failure requires an unwritable directory`() throws {
        try self.withFile { file in
            _ = try file.updateCredentials { $0["OLD"] = "synthetic-original" }
            #expect(chmod(file.url.path, 0o400) == 0)
            _ = try file.updateCredentials { $0["NEW"] = "synthetic-new" }
            let directory = file.url.deletingLastPathComponent()
            #expect(chmod(directory.path, 0o500) == 0)
            defer { chmod(directory.path, 0o700) }
            #expect(throws: CredentialFile.Failure.publicationFailed) {
                try file.updateCredentials { $0.removeAll() }
            }
            #expect(throws: CredentialFile.Failure.publicationFailed) {
                try file.updateCredentials { $0["NEW"] = "synthetic-failed" }
            }
            let preserved = try file.readCredentialSnapshot()["NEW"] == "synthetic-new"
            #expect(preserved)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["credentials"])
        }
    }

    @Test
    func `durability failure after publication is not A rejected write`() throws {
        try self.withFile { file in
            let warningFile = CredentialFile(url: file.url, synchronizeDirectory: { _ in false })
            let publication = try warningFile.updateCredentials { $0["KEY"] = "synthetic-published" }
            #expect(publication.durabilityWarning)
            let published = try file.readCredentialSnapshot() == publication.snapshot
            #expect(published)
            let deleted = try warningFile.updateCredentials { $0.removeAll() }
            #expect(deleted.durabilityWarning)
            #expect(try file.readCredentialSnapshot().isEmpty)
        }
    }

    @Test
    func `directory synchronization accepts aliases without weakening credential reads`() throws {
        try self.withFile { file in
            let directory = file.url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let alias = directory.appendingPathComponent("directory-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
            #expect(CredentialFile.syncDirectory(alias))
        }
    }

    @Test
    func `rejects non regular and symlink files`() throws {
        try self.withFile { file in
            try FileManager.default.createDirectory(at: file.url, withIntermediateDirectories: true)
            #expect(throws: CredentialFile.Failure.unsafePath) { try file.readCredentialSnapshot() }
            try FileManager.default.removeItem(at: file.url)
            try FileManager.default.createSymbolicLink(atPath: file.url.path, withDestinationPath: "missing-owned-file")
            #expect(throws: CredentialFile.Failure.unreadable) { try file.readCredentialSnapshot() }
        }
    }

    private func withFile(_ body: (CredentialFile) throws -> Void) throws {
        let root = ProcessInfo.processInfo.environment["PEEKABOO_CREDENTIAL_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(CredentialFile(url: directory.appendingPathComponent("credentials")))
    }
}
