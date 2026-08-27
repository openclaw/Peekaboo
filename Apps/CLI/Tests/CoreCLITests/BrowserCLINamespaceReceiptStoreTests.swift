import Darwin
import Foundation
import Testing
@testable import PeekabooCLI

struct BrowserCLINamespaceReceiptStoreTests {
    @Test
    func `store publishes and reloads only canonical mode 0600 receipt bytes`() throws {
        let fixture = try Self.fixture()
        let (store, directory) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.validateCanSave()
        try store.save(fixture)
        #expect(try store.load() == fixture)

        var info = stat()
        #expect(lstat(store.fileURL.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFREG)
        #expect(info.st_uid == geteuid())
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(info.st_nlink == 1)
        #expect(throws: BrowserCLINamespaceReceiptStoreError.alreadyExists) {
            try store.validateCanSave()
        }
        #expect(throws: BrowserCLINamespaceReceiptStoreError.alreadyExists) {
            try store.save(fixture)
        }
        #expect(try store.load() == fixture)
    }

    @Test
    func `store refuses symlink permissive hardlinked and nonregular state`() throws {
        let fixture = try Self.fixture()

        do {
            let (store, directory) = try Self.makeStore()
            defer { try? FileManager.default.removeItem(at: directory) }
            let target = directory.appendingPathComponent("target")
            try fixture.write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: target)
            #expect(throws: BrowserCLINamespaceReceiptStoreError.self) { try store.load() }
            #expect(throws: BrowserCLINamespaceReceiptStoreError.self) { try store.save(fixture) }
        }

        do {
            let (store, directory) = try Self.makeStore()
            defer { try? FileManager.default.removeItem(at: directory) }
            try fixture.write(to: store.fileURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path)
            #expect(throws: BrowserCLINamespaceReceiptStoreError.self) { try store.load() }
            #expect(throws: BrowserCLINamespaceReceiptStoreError.self) { try store.save(fixture) }
        }

        do {
            let (store, directory) = try Self.makeStore()
            defer { try? FileManager.default.removeItem(at: directory) }
            let alias = directory.appendingPathComponent("alias")
            try fixture.write(to: store.fileURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
            #expect(link(store.fileURL.path, alias.path) == 0)
            #expect(throws: BrowserCLINamespaceReceiptStoreError.self) { try store.load() }
            #expect(throws: BrowserCLINamespaceReceiptStoreError.self) { try store.save(fixture) }
        }

        do {
            let (store, directory) = try Self.makeStore()
            defer { try? FileManager.default.removeItem(at: directory) }
            #expect(mkfifo(store.fileURL.path, S_IRUSR | S_IWUSR) == 0)
            #expect(throws: BrowserCLINamespaceReceiptStoreError.self) { try store.load() }
            #expect(throws: BrowserCLINamespaceReceiptStoreError.self) { try store.save(fixture) }
        }
    }

    @Test
    func `store refuses nonprivate state directories`() throws {
        let fixture = try Self.fixture()
        let (store, directory) = try Self.makeStore(directoryMode: 0o755)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: BrowserCLINamespaceReceiptStoreError.self) { try store.save(fixture) }

        let (aclStore, aclDirectory) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: aclDirectory) }
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow delete_child", aclDirectory.path]
        try chmod.run()
        chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
        #expect(throws: BrowserCLINamespaceReceiptStoreError.self) { try aclStore.save(fixture) }
    }

    @Test
    func `store rejects widened ACLs and oversized files before decoding`() throws {
        let fixture = try Self.fixture()
        let (aclStore, aclDirectory) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: aclDirectory) }
        try fixture.write(to: aclStore.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aclStore.fileURL.path)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow read", aclStore.fileURL.path]
        try chmod.run()
        chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
        #expect(throws: BrowserCLINamespaceReceiptStoreError.self) { try aclStore.load() }

        let (oversizedStore, oversizedDirectory) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: oversizedDirectory) }
        let oversized = Data(
            repeating: UInt8(ascii: "x"),
            count: Int(BrowserCLINamespaceReceiptStore.maximumReceiptBytes) + 1
        )
        try oversized.write(to: oversizedStore.fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: oversizedStore.fileURL.path
        )
        #expect(throws: BrowserCLINamespaceReceiptStoreError.self) { try oversizedStore.load() }
    }

    @Test
    func `explicit state paths expand tilde but reject relative and nul paths`() throws {
        let relative = "fixture/namespace.json"
        #expect(throws: BrowserCLINamespaceReceiptStoreError.self) {
            _ = try BrowserCLINamespaceReceiptStore(resolvingPath: relative)
        }
        #expect(throws: BrowserCLINamespaceReceiptStoreError.self) {
            _ = try BrowserCLINamespaceReceiptStore(resolvingPath: "/private/tmp/bad\0path")
        }

        let expanded = try BrowserCLINamespaceReceiptStore(resolvingPath: "~/.peekaboo/fixture.json")
        #expect(expanded.fileURL.path == FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".peekaboo/fixture.json").path)
    }

    @Test
    func `store removes only validated owner private state`() throws {
        let fixture = try Self.fixture()
        let (store, directory) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.save(fixture)
        let newerReceipt = try Self.fixture(namespaceID: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF")
        #expect(throws: BrowserCLINamespaceReceiptStoreError.receiptMismatch) {
            try store.remove(expectedReceipt: newerReceipt)
        }
        #expect(try store.load() == fixture)
        try store.remove(expectedReceipt: fixture)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        try store.remove(expectedReceipt: fixture)
    }

    @Test
    func `canonical parser rejects whitespace key drift field drift and oversized state`() throws {
        let fixture = try Self.fixture()
        var whitespacePrefixed = Data(" \n".utf8)
        whitespacePrefixed.append(fixture)
        #expect(throws: BrowserCLINamespaceReceiptStoreError.self) {
            try BrowserCLINamespaceReceiptStore.validateCanonicalReceipt(whitespacePrefixed)
        }

        let object = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        var extra = object
        extra["unexpected"] = true
        let extraData = try JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys])
        #expect(throws: BrowserCLINamespaceReceiptStoreError.self) {
            try BrowserCLINamespaceReceiptStore.validateCanonicalReceipt(extraData)
        }

        var missing = object
        missing.removeValue(forKey: "signature")
        let missingData = try JSONSerialization.data(withJSONObject: missing, options: [.sortedKeys])
        #expect(throws: BrowserCLINamespaceReceiptStoreError.self) {
            try BrowserCLINamespaceReceiptStore.validateCanonicalReceipt(missingData)
        }

        let oversized = Data(
            repeating: UInt8(ascii: "x"),
            count: Int(BrowserCLINamespaceReceiptStore.maximumReceiptBytes) + 1
        )
        #expect(throws: BrowserCLINamespaceReceiptStoreError.self) {
            try BrowserCLINamespaceReceiptStore.validateCanonicalReceipt(oversized)
        }
    }

    @Test
    func `canonical parser binds the current uid and exact receipt field forms`() throws {
        let fixture = try Self.fixture()
        let object = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])
        let principal = try #require(payload["principal"] as? [String: Any])

        for mutation in ReceiptMutation.allCases {
            var mutatedObject = object
            var mutatedPayload = payload
            var mutatedPrincipal = principal
            mutation.apply(
                object: &mutatedObject,
                payload: &mutatedPayload,
                principal: &mutatedPrincipal
            )
            mutatedPayload["principal"] = mutatedPrincipal
            mutatedObject["payload"] = mutatedPayload
            let data = try JSONSerialization.data(
                withJSONObject: mutatedObject,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            #expect(throws: BrowserCLINamespaceReceiptStoreError.self) {
                try BrowserCLINamespaceReceiptStore.validateCanonicalReceipt(data)
            }
        }
    }

    static func fixture(
        namespaceID: String = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "payload": [
                "schemaVersion": 1,
                "namespaceID": namespaceID,
                "listenerInstanceID": "11111111-2222-3333-4444-555555555555",
                "listenerPublicKeySHA256": String(repeating: "a", count: 64),
                "registryGenerationID": "66666666-7777-4888-9999-AAAAAAAAAAAA",
                "principal": [
                    "effectiveUserIdentifier": Int(geteuid()),
                    "teamIdentifier": "FIXTURETEAM",
                    "bundleIdentifier": "boo.peekaboo.cli.fixture",
                    "codeSignatureHash": String(repeating: "b", count: 40),
                ],
                "issuedAtUnixMilliseconds": 1_800_000_000_000,
                "expiresAtUnixMilliseconds": 1_800_000_060_000,
            ],
            "signature": Data(repeating: 7, count: 64).base64EncodedString(),
        ], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func makeStore(directoryMode: Int = 0o700) throws
    -> (BrowserCLINamespaceReceiptStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-browser-namespace-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: directoryMode]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: directoryMode],
            ofItemAtPath: directory.path
        )
        return (
            BrowserCLINamespaceReceiptStore(fileURL: directory.appendingPathComponent("receipt.json")),
            directory
        )
    }
}

private enum ReceiptMutation: CaseIterable {
    case schemaVersion
    case namespaceID
    case listenerInstanceID
    case listenerDigest
    case generationID
    case issuedAt
    case expiration
    case userIdentifier
    case teamIdentifier
    case bundleIdentifier
    case codeSignatureHash
    case signature
    case noncanonicalSignature

    func apply(
        object: inout [String: Any],
        payload: inout [String: Any],
        principal: inout [String: Any]
    ) {
        switch self {
        case .schemaVersion: payload["schemaVersion"] = 2
        case .namespaceID: payload["namespaceID"] = "not-a-uuid"
        case .listenerInstanceID: payload["listenerInstanceID"] = "not-a-uuid"
        case .listenerDigest: payload["listenerPublicKeySHA256"] = String(repeating: "A", count: 64)
        case .generationID: payload["registryGenerationID"] = "not-a-uuid"
        case .issuedAt: payload["issuedAtUnixMilliseconds"] = true
        case .expiration: payload["expiresAtUnixMilliseconds"] = payload["issuedAtUnixMilliseconds"]
        case .userIdentifier: principal["effectiveUserIdentifier"] = Int(geteuid()) + 1
        case .teamIdentifier: principal["teamIdentifier"] = ""
        case .bundleIdentifier: principal["bundleIdentifier"] = "invalid_bundle"
        case .codeSignatureHash: principal["codeSignatureHash"] = String(repeating: "g", count: 40)
        case .signature: object["signature"] = Data(repeating: 7, count: 63).base64EncodedString()
        case .noncanonicalSignature:
            let canonical = Data(repeating: 7, count: 64).base64EncodedString()
            object["signature"] = String(canonical.dropLast(3)) + "x=="
        }
    }
}
