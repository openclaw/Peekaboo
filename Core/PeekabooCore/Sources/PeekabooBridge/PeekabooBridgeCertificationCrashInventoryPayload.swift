import Foundation

public struct PeekabooBridgeCertificationCrashInventoryPairPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let captureID: String
    public let source: Source
    public let before: Inventory
    public let after: Inventory
    public let result: Result

    public init(
        schemaVersion: Int = 4,
        captureID: String,
        source: Source,
        before: Inventory,
        after: Inventory,
        result: Result)
    {
        self.schemaVersion = schemaVersion
        self.captureID = captureID
        self.source = source
        self.before = before
        self.after = after
        self.result = result
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case captureID
        case source
        case before
        case after
        case result
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Crash inventory pair")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.captureID = try container.decode(String.self, forKey: .captureID)
        self.source = try container.decode(Source.self, forKey: .source)
        self.before = try container.decode(Inventory.self, forKey: .before)
        self.after = try container.decode(Inventory.self, forKey: .after)
        self.result = try container.decode(Result.self, forKey: .result)
    }

    public struct Source: Codable, Equatable, Sendable {
        public let sourceCommit: String
        public let executableSHA256: String
        public let catalogVersion: Int
        public let monitorContractVersion: Int
        public let catalogSHA256: String
        public let scanDomain: ScanDomain
        public let crashReportPrefixes: [String]

        public init(
            sourceCommit: String,
            executableSHA256: String,
            catalogVersion: Int,
            monitorContractVersion: Int,
            catalogSHA256: String,
            scanDomain: ScanDomain,
            crashReportPrefixes: [String])
        {
            self.sourceCommit = sourceCommit
            self.executableSHA256 = executableSHA256
            self.catalogVersion = catalogVersion
            self.monitorContractVersion = monitorContractVersion
            self.catalogSHA256 = catalogSHA256
            self.scanDomain = scanDomain
            self.crashReportPrefixes = crashReportPrefixes
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case sourceCommit
            case executableSHA256
            case catalogVersion
            case monitorContractVersion
            case catalogSHA256
            case scanDomain
            case crashReportPrefixes
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Crash inventory source")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.sourceCommit = try container.decode(String.self, forKey: .sourceCommit)
            self.executableSHA256 = try container.decode(String.self, forKey: .executableSHA256)
            self.catalogVersion = try container.decode(Int.self, forKey: .catalogVersion)
            self.monitorContractVersion = try container.decode(Int.self, forKey: .monitorContractVersion)
            self.catalogSHA256 = try container.decode(String.self, forKey: .catalogSHA256)
            self.scanDomain = try container.decode(ScanDomain.self, forKey: .scanDomain)
            self.crashReportPrefixes = try container.decode([String].self, forKey: .crashReportPrefixes)
        }
    }

    public enum ScanDomain: String, Codable, Sendable {
        case currentUserDiagnosticReports
    }

    public enum Role: String, Codable, CaseIterable, Sendable {
        case matrixBefore = "matrix-before"
        case matrixAfter = "matrix-after"
        case alertBefore = "alert-before"
        case alertAfter = "alert-after"
        case heldPointerBefore = "held-pointer-before"
        case heldPointerAfter = "held-pointer-after"

        var counterpart: Self? {
            switch self {
            case .matrixBefore: .matrixAfter
            case .alertBefore: .alertAfter
            case .heldPointerBefore: .heldPointerAfter
            case .matrixAfter, .alertAfter, .heldPointerAfter: nil
            }
        }
    }

    public struct Inventory: Codable, Equatable, Sendable {
        public let role: Role
        public let hostUUID: String
        public let hostname: String
        public let entries: [Entry]
        public let scanCount: Int
        public let quietPeriodMilliseconds: Int64
        public let captureStartedAtUnixMilliseconds: Int64
        public let captureCompletedAtUnixMilliseconds: Int64

        public init(
            role: Role,
            hostUUID: String,
            hostname: String,
            entries: [Entry],
            scanCount: Int,
            quietPeriodMilliseconds: Int64,
            captureStartedAtUnixMilliseconds: Int64,
            captureCompletedAtUnixMilliseconds: Int64)
        {
            self.role = role
            self.hostUUID = hostUUID
            self.hostname = hostname
            self.entries = entries
            self.scanCount = scanCount
            self.quietPeriodMilliseconds = quietPeriodMilliseconds
            self.captureStartedAtUnixMilliseconds = captureStartedAtUnixMilliseconds
            self.captureCompletedAtUnixMilliseconds = captureCompletedAtUnixMilliseconds
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case role
            case hostUUID
            case hostname
            case entries
            case scanCount
            case quietPeriodMilliseconds
            case captureStartedAtUnixMilliseconds
            case captureCompletedAtUnixMilliseconds
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Crash inventory")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.role = try container.decode(Role.self, forKey: .role)
            self.hostUUID = try container.decode(String.self, forKey: .hostUUID)
            self.hostname = try container.decode(String.self, forKey: .hostname)
            self.entries = try container.decode([Entry].self, forKey: .entries)
            self.scanCount = try container.decode(Int.self, forKey: .scanCount)
            self.quietPeriodMilliseconds = try container.decode(Int64.self, forKey: .quietPeriodMilliseconds)
            self.captureStartedAtUnixMilliseconds = try container.decode(
                Int64.self,
                forKey: .captureStartedAtUnixMilliseconds)
            self.captureCompletedAtUnixMilliseconds = try container.decode(
                Int64.self,
                forKey: .captureCompletedAtUnixMilliseconds)
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let name: String
        public let size: Int64
        public let modifiedAtUnixMilliseconds: Int64
        public let sha256: String

        public init(name: String, size: Int64, modifiedAtUnixMilliseconds: Int64, sha256: String) {
            self.name = name
            self.size = size
            self.modifiedAtUnixMilliseconds = modifiedAtUnixMilliseconds
            self.sha256 = sha256
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case name
            case size
            case modifiedAtUnixMilliseconds
            case sha256
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Crash inventory entry")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try container.decode(String.self, forKey: .name)
            self.size = try container.decode(Int64.self, forKey: .size)
            self.modifiedAtUnixMilliseconds = try container.decode(
                Int64.self,
                forKey: .modifiedAtUnixMilliseconds)
            self.sha256 = try container.decode(String.self, forKey: .sha256)
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public let passed: Bool
        public let added: [Entry]
        public let changed: [Entry]
        public let removed: [Entry]

        public init(passed: Bool, added: [Entry], changed: [Entry], removed: [Entry]) {
            self.passed = passed
            self.added = added
            self.changed = changed
            self.removed = removed
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case passed
            case added
            case changed
            case removed
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Crash inventory result")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.passed = try container.decode(Bool.self, forKey: .passed)
            self.added = try container.decode([Entry].self, forKey: .added)
            self.changed = try container.decode([Entry].self, forKey: .changed)
            self.removed = try container.decode([Entry].self, forKey: .removed)
        }
    }

    func validate(context: PeekabooBridgeCertificationPayloadValidationContext) throws {
        let source = self.source
        guard self.schemaVersion == 4,
              self.captureID == context.request.executionNonce,
              PeekabooBridgeCertificationValidation.isSafeIdentifier(self.captureID, maximumBytes: 64),
              source.sourceCommit == context.producer.sourceCommit,
              source.executableSHA256 == context.producer.executableSHA256,
              PeekabooBridgeCertificationValidation.isLowerHex(source.sourceCommit, count: 40),
              PeekabooBridgeCertificationValidation.isLowerHex(source.executableSHA256, count: 64),
              source.catalogVersion == 2,
              source.monitorContractVersion == 1,
              PeekabooBridgeCertificationValidation.isLowerHex(source.catalogSHA256, count: 64),
              source.scanDomain == .currentUserDiagnosticReports,
              !source.crashReportPrefixes.isEmpty,
              source.crashReportPrefixes.count <= 32,
              Set(source.crashReportPrefixes).count == source.crashReportPrefixes.count,
              source.crashReportPrefixes.allSatisfy(Self.isSafeName)
        else { throw Self.invalid("source metadata") }

        try Self.validate(self.before, prefixes: source.crashReportPrefixes)
        try Self.validate(self.after, prefixes: source.crashReportPrefixes)
        guard self.before.role.counterpart == self.after.role,
              self.before.hostUUID == self.after.hostUUID,
              self.before.hostname == self.after.hostname,
              self.after.captureStartedAtUnixMilliseconds >= self.before.captureCompletedAtUnixMilliseconds
        else { throw Self.invalid("ordered inventory pair") }

        let expected = Self.result(before: self.before.entries, after: self.after.entries)
        guard self.result.added == expected.added,
              self.result.changed == expected.changed,
              self.result.removed == expected.removed,
              self.result.passed == (
                  expected.added.isEmpty && expected.changed.isEmpty && expected.removed.isEmpty)
        else { throw Self.invalid("derived delta") }
    }

    private static func validate(_ inventory: Inventory, prefixes: [String]) throws {
        let entries = inventory.entries
        let names = entries.map(\.name)
        guard Self.isCanonicalHostUUID(inventory.hostUUID),
              Self.isHostname(inventory.hostname),
              entries.count <= 256,
              inventory.scanCount >= 2,
              Int64(inventory.scanCount) <= PeekabooBridgeCertificationValidation.maximumSafeInteger,
              (1000...5000).contains(inventory.quietPeriodMilliseconds),
              PeekabooBridgeCertificationValidation.isPositiveSafeInteger(
                  inventory.captureStartedAtUnixMilliseconds),
              inventory.captureCompletedAtUnixMilliseconds >= inventory.captureStartedAtUnixMilliseconds,
              inventory.captureCompletedAtUnixMilliseconds <=
              PeekabooBridgeCertificationValidation.maximumSafeInteger,
              inventory.captureCompletedAtUnixMilliseconds - inventory.captureStartedAtUnixMilliseconds >=
              inventory.quietPeriodMilliseconds,
              inventory.captureCompletedAtUnixMilliseconds - inventory.captureStartedAtUnixMilliseconds <= 5000,
              names == names.sorted(),
              Set(names).count == names.count,
              entries.allSatisfy({ entry in
                  Self.isSafeName(entry.name) &&
                      (0...64 * 1024 * 1024).contains(entry.size) &&
                      PeekabooBridgeCertificationValidation.isPositiveSafeInteger(
                          entry.modifiedAtUnixMilliseconds) &&
                      PeekabooBridgeCertificationValidation.isLowerHex(entry.sha256, count: 64) &&
                      prefixes.contains(where: entry.name.hasPrefix)
              }),
              entries.reduce(Int64(0), { partial, entry in
                  let sum = partial.addingReportingOverflow(entry.size)
                  return sum.overflow ? Int64.max : sum.partialValue
              }) <= 256 * 1024 * 1024
        else { throw Self.invalid("inventory fields") }
    }

    private static func result(before: [Entry], after: [Entry]) -> Result {
        let beforeByName = Dictionary(uniqueKeysWithValues: before.map { ($0.name, $0) })
        let afterByName = Dictionary(uniqueKeysWithValues: after.map { ($0.name, $0) })
        let added = after.filter { beforeByName[$0.name] == nil }
        let changed = after.filter { entry in
            guard let prior = beforeByName[entry.name] else { return false }
            return prior != entry
        }
        let removed = before.filter { afterByName[$0.name] == nil }
        return Result(
            passed: added.isEmpty && changed.isEmpty && removed.isEmpty,
            added: added,
            changed: changed,
            removed: removed)
    }

    private static func isSafeName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= 255 && bytes.allSatisfy {
            (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) ||
                (0x30...0x39).contains($0) || [0x2E, 0x5F, 0x2D].contains($0)
        }
    }

    private static func isCanonicalHostUUID(_ value: String) -> Bool {
        guard value == value.uppercased(), let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString == value
    }

    private static func isHostname(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...253).contains(bytes.count),
              let first = bytes.first,
              Self.isHostnameAlphanumeric(first)
        else { return false }
        return bytes.allSatisfy { Self.isHostnameAlphanumeric($0) || $0 == 0x2E || $0 == 0x2D }
    }

    private static func isHostnameAlphanumeric(_ value: UInt8) -> Bool {
        (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) || (0x30...0x39).contains(value)
    }

    private static func invalid(_ field: String) -> PeekabooBridgeOperationReceiptError {
        .receiptMismatch("certification crash inventory \(field)")
    }
}
