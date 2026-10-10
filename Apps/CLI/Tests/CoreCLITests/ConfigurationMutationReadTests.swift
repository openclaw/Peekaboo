import CryptoKit
import Darwin
import Foundation
import PeekabooAutomation
import Tachikoma
import Testing

@Suite(.serialized)
@MainActor
struct ConfigurationMutationReadTests {
    enum Operation: String, CaseIterable {
        case add, remove, update
    }

    enum InvalidFile: String, CaseIterable {
        case truncated, wrongType, unreadable
    }

    enum ValidFile: String, CaseIterable {
        case json, jsonc, environment
    }

    @Test(arguments: Operation.allCases, [InvalidFile.truncated, .wrongType])
    func `Existing failed reads refuse mutation and preserve bytes`(
        operation: Operation,
        invalid: InvalidFile
    ) throws {
        try self.assertFailedRead(operation: operation, invalid: invalid)
    }

    @Test(.enabled(if: geteuid() != 0, "POSIX permissions do not deny root access"), arguments: Operation.allCases)
    func `An unreadable existing file refuses mutation and preserves bytes`(operation: Operation) throws {
        try self.assertFailedRead(operation: operation, invalid: .unreadable)
    }

    private func assertFailedRead(operation: Operation, invalid: InvalidFile) throws {
        try self.withOwnedConfiguration { manager, file in
            let original: Data = switch invalid {
            case .truncated: Data(#"{"defaults":{"savePath":"owned-retained"}"#.utf8)
            case .wrongType: Data(#"{"defaults":{"savePath":[]}}"#.utf8)
            case .unreadable: self.validConfiguration()
            }
            try original.write(to: file)
            if invalid == .unreadable {
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
            }
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            var closureEntered = false
            var refused = false
            do {
                try self.mutate(operation, manager: manager, closureEntered: &closureEntered)
            } catch {
                refused = true
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let after = try Data(contentsOf: file)
            self.receipt(
                operation.rawValue + "/" + invalid.rawValue,
                before: original,
                after: after,
                refused: refused,
                closureEntered: closureEntered
            )
            #expect(refused)
            #expect(after == original)
            #expect(!closureEntered)
        }
    }

    @Test
    func `Cached valid configuration does not replace a currently invalid file`() throws {
        try self.withOwnedConfiguration { manager, file in
            try self.validConfiguration().write(to: file)
            #expect(manager.loadConfiguration()?.defaults?.savePath == "owned-original")
            let original = Data(#"{"defaults":{"savePath":[]}}"#.utf8)
            try original.write(to: file)
            var closureEntered = false
            var refused = false
            do {
                try self.mutate(.update, manager: manager, closureEntered: &closureEntered)
            } catch {
                refused = true
            }
            let after = try Data(contentsOf: file)
            self.receipt(
                "update/cached-then-invalid",
                before: original,
                after: after,
                refused: refused,
                closureEntered: closureEntered
            )
            #expect(refused)
            #expect(after == original)
            #expect(!closureEntered)
        }
    }

    @Test(arguments: Operation.allCases, ValidFile.allCases)
    func `Valid JSON JSONC and environment references retain their values`(
        operation: Operation,
        valid: ValidFile
    ) throws {
        try self.withOwnedConfiguration { manager, file in
            var original = self.validConfiguration(environment: valid == .environment)
            if valid == .jsonc {
                original = Data("// Owned JSONC fixture\n".utf8) + original
            }
            try original.write(to: file)
            var closureEntered = false
            try self.mutate(operation, manager: manager, closureEntered: &closureEntered)
            let after = try Data(contentsOf: file)
            let configuration = try JSONDecoder().decode(Configuration.self, from: after)
            let expectedPath = operation == .update ? "owned-updated"
                : valid == .environment ? "owned-environment-path" : "owned-original"
            #expect(configuration.defaults?.savePath == expectedPath)
            #expect(configuration.logging?.level == "error")
            #expect(configuration.customProviders?["owned-retained"]?.options.apiKey == "${OWNED_FAKE_REFERENCE}")
            #expect((configuration.customProviders?["owned-existing"] != nil) == (operation != .remove))
            #expect((configuration.customProviders?["owned-new"] != nil) == (operation == .add))
            #expect(closureEntered == (operation == .update))
            self.receipt(
                operation.rawValue + "/" + valid.rawValue,
                before: original,
                after: after,
                refused: false,
                closureEntered: closureEntered
            )
        }
    }

    @Test(arguments: Operation.allCases)
    func `An absent file retains configuration creation behavior`(operation: Operation) throws {
        try self.withOwnedConfiguration { manager, file in
            #expect(!FileManager.default.fileExists(atPath: file.path))
            var closureEntered = false
            try self.mutate(operation, manager: manager, closureEntered: &closureEntered)
            let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: file))
            #expect((configuration.customProviders?["owned-new"] != nil) == (operation == .add))
            #expect(configuration.defaults?.savePath == (operation == .update ? "owned-updated" : nil))
            #expect(closureEntered == (operation == .update))
        }
    }

    @Test
    func `An absent file retains cached values for the update API`() throws {
        try self.withOwnedConfiguration { manager, file in
            try self.validConfiguration().write(to: file)
            #expect(manager.loadConfiguration()?.defaults?.savePath == "owned-original")
            try FileManager.default.removeItem(at: file)
            var closureEntered = false
            try self.mutate(.update, manager: manager, closureEntered: &closureEntered)
            let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: file))
            #expect(configuration.defaults?.savePath == "owned-updated")
            #expect(configuration.logging?.level == "error")
            #expect(configuration.customProviders?["owned-retained"]?.options.apiKey == "${OWNED_FAKE_REFERENCE}")
            #expect(closureEntered)
        }
    }

    private func mutate(
        _ operation: Operation,
        manager: ConfigurationManager,
        closureEntered: inout Bool
    ) throws {
        switch operation {
        case .add:
            try manager.addCustomProvider(
                .init(
                    name: "Owned new",
                    type: .openai,
                    options: .init(baseURL: "http://127.0.0.1:9/v1", apiKey: "${OWNED_FAKE_REFERENCE}")
                ),
                id: "owned-new"
            )
        case .remove:
            try manager.removeCustomProvider(id: "owned-existing")
        case .update:
            try manager.updateConfiguration { configuration in
                closureEntered = true
                configuration.defaults = .init(savePath: "owned-updated")
            }
        }
    }

    private func validConfiguration(environment: Bool = false) -> Data {
        let path = environment ? "${OWNED_CONFIG_SAVE_PATH}" : "owned-original"
        return Data("""
        {"defaults":{"savePath":"\(path)"},"logging":{"level":"error"},"customProviders":{
          "owned-existing":{"name":"Owned existing","type":"openai","enabled":true,
            "options":{"baseURL":"http://127.0.0.1:9/v1","apiKey":"${OWNED_FAKE_REFERENCE}"}},
          "owned-retained":{"name":"Owned retained","type":"openai","enabled":true,
            "options":{"baseURL":"http://127.0.0.1:9/v1","apiKey":"${OWNED_FAKE_REFERENCE}"}}
        }}
        """.utf8)
    }

    private func receipt(_ label: String, before: Data, after: Data, refused: Bool, closureEntered: Bool) {
        let original = SHA256.hash(data: before).map { String(format: "%02x", $0) }.joined()
        let result = SHA256.hash(data: after).map { String(format: "%02x", $0) }.joined()
        print("SDK mutation \(label): uid=\(getuid()) refused=\(refused) closure=\(closureEntered) " +
            "before=\(original) after=\(result)")
    }

    private func withOwnedConfiguration(_ body: (ConfigurationManager, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-config-sdk-owned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keys = ["PEEKABOO_CONFIG_DIR", "PEEKABOO_CONFIG_DISABLE_MIGRATION", "OWNED_CONFIG_SAVE_PATH"]
        let previous = keys.map { key in getenv(key).map { String(cString: $0) } }
        let previousProfile = TachikomaConfiguration.profileDirectoryName
        setenv(keys[0], root.path, 1)
        setenv(keys[1], "true", 1)
        setenv(keys[2], "owned-environment-path", 1)
        let manager = ConfigurationManager.shared
        manager.resetForTesting()
        defer {
            for (key, value) in zip(keys, previous) {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            TachikomaConfiguration.profileDirectoryName = previousProfile
            manager.resetForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        try body(manager, root.appendingPathComponent("config.json"))
    }
}
