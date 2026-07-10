import Darwin
import Foundation
import os.log

/// Cross-process high-water mark for mutations that make implicit UI snapshots stale.
///
/// Snapshot backends remain free to keep their own watermarks. This store carries the
/// desktop-wide boundary between short-lived CLI processes and long-lived GUI/daemon hosts.
public final class DesktopMutationWatermarkStore: @unchecked Sendable {
    public struct PendingMutation: Sendable, Equatable {
        fileprivate let id: UUID
        fileprivate let startedAt: Date
        fileprivate let completionGenerationAtStart: UInt64
    }

    public struct MutationCompletion: Sendable, Equatable {
        public let cutoff: Date
        public let allowsObservationPreservation: Bool
    }

    private struct Record: Codable {
        let version: Int
        let cutoffReferenceDateSeconds: TimeInterval
        let completionGeneration: UInt64?

        var cutoff: Date {
            Date(timeIntervalSinceReferenceDate: self.cutoffReferenceDateSeconds)
        }
    }

    private struct PendingMutationRecord: Codable {
        let version: Int
        let ownerProcessIdentifier: pid_t
        let ownerProcessStartIdentity: UInt64?
        let startedAtReferenceDateSeconds: TimeInterval
        let resolution: PendingMutationResolution?
    }

    private enum PendingMutationResolution: Codable {
        case completed(cutoffReferenceDateSeconds: TimeInterval, completionGeneration: UInt64)
        case canceled
    }

    private static let currentVersion = 1
    private static let watermarkFileName = "desktop-mutation-watermark.json"
    private static let lockFileName = "desktop-mutation-watermark.lock"
    private static let pendingDirectoryName = "desktop-mutation-pending"
    @TaskLocal private static var visiblePendingMutationIDs: Set<UUID> = []

    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "DesktopMutationWatermark")
    let directoryURL: URL
    let watermarkURL: URL
    private let lockURL: URL
    private let pendingDirectoryURL: URL
    private let processStartIdentityProvider: @Sendable (pid_t) -> UInt64?
    private let pendingRecordRemover: @Sendable (URL) throws -> Void

    public convenience init() {
        let processInfo = ProcessInfo.processInfo
        let configuredRoot = processInfo.environment["PEEKABOO_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root = if let configuredRoot, !configuredRoot.isEmpty {
            URL(fileURLWithPath: NSString(string: configuredRoot).expandingTildeInPath, isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".peekaboo", isDirectory: true)
        }
        self.init(directoryURL: root)
    }

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.watermarkURL = directoryURL.appendingPathComponent(Self.watermarkFileName, isDirectory: false)
        self.lockURL = directoryURL.appendingPathComponent(Self.lockFileName, isDirectory: false)
        self.pendingDirectoryURL = directoryURL.appendingPathComponent(Self.pendingDirectoryName, isDirectory: true)
        self.processStartIdentityProvider = Self.processStartIdentity
        self.pendingRecordRemover = { try FileManager.default.removeItem(at: $0) }
    }

    init(
        directoryURL: URL,
        processStartIdentityProvider: @escaping @Sendable (pid_t) -> UInt64?,
        pendingRecordRemover: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        })
    {
        self.directoryURL = directoryURL
        self.watermarkURL = directoryURL.appendingPathComponent(Self.watermarkFileName, isDirectory: false)
        self.lockURL = directoryURL.appendingPathComponent(Self.lockFileName, isDirectory: false)
        self.pendingDirectoryURL = directoryURL.appendingPathComponent(Self.pendingDirectoryName, isDirectory: true)
        self.processStartIdentityProvider = processStartIdentityProvider
        self.pendingRecordRemover = pendingRecordRemover
    }

    /// Keeps one caller-owned pre-dispatch barrier visible to every other task and process while
    /// allowing that caller to resolve the snapshot it is about to act on.
    public static func withPendingMutationVisible<T>(
        _ mutation: PendingMutation,
        operation: () async throws -> T) async rethrows -> T
    {
        let visibleIDs = Self.visiblePendingMutationIDs.union([mutation.id])
        return try await Self.$visiblePendingMutationIDs.withValue(visibleIDs) {
            try await operation()
        }
    }

    /// Returns the persisted boundary. Active mutations use the read time so snapshots stay hidden
    /// without permanently poisoning the monotonic watermark with `Date.distantFuture`.
    public func effectiveWatermark() -> Date? {
        do {
            return try self.withLock(operation: LOCK_EX) {
                let now = Date()
                let hasPendingMutation = try self.hasPendingMutationUnlocked(
                    recoveredAt: now,
                    excluding: Self.visiblePendingMutationIDs)
                let persisted = self.readUnlocked()
                return hasPendingMutation
                    ? max(persisted ?? now, now)
                    : persisted
            }
        } catch {
            // A transient lock failure must not be treated as "hide every cached snapshot".
            // All records are written atomically, so a lockless read is a safe best effort;
            // orphan recovery simply waits for the next locked reader.
            self.logger
                .error("Failed to lock desktop mutation watermark; using lockless read: \(error.localizedDescription)")
            return self.effectiveWatermarkLockless()
        }
    }

    /// Read-only variant of the locked read: no orphan recovery, no reconciliation writes.
    /// Unresolved records (live or orphaned) count as pending, and resolved-but-unreconciled
    /// completions contribute their published cutoff, matching the locked reader's outcome.
    private func effectiveWatermarkLockless() -> Date? {
        let now = Date()
        let excludedMutationIDs = Self.visiblePendingMutationIDs
        var effective = self.readUnlocked()
        // An absent pending directory means no in-flight mutations (matches the locked reader).
        guard FileManager.default.fileExists(atPath: self.pendingDirectoryURL.path) else {
            return effective
        }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: self.pendingDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else {
            // The directory exists but cannot be enumerated: a pending marker may be present, so
            // fail closed rather than exposing snapshots during a possible in-flight mutation.
            return max(effective ?? now, now)
        }
        for url in urls {
            let mutationID = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            if mutationID.map(excludedMutationIDs.contains) ?? false {
                continue
            }
            guard let record = self.readPendingRecordUnlocked(at: url) else {
                // Unreadable records stay fail-closed, matching `hasPendingMutationUnlocked`.
                return max(effective ?? now, now)
            }
            switch record.resolution {
            case .canceled:
                continue
            case let .completed(cutoffReferenceDateSeconds, _):
                let cutoff = Date(timeIntervalSinceReferenceDate: cutoffReferenceDateSeconds)
                effective = Self.maxWatermark(effective, cutoff)
            case nil:
                return max(effective ?? now, now)
            }
        }
        return effective
    }

    private static func maxWatermark(_ lhs: Date?, _ rhs: Date) -> Date {
        lhs.map { max($0, rhs) } ?? rhs
    }

    /// Installs a durable, cross-process barrier before a mutation is dispatched.
    public func beginMutation(at startedAt: Date = Date()) throws -> PendingMutation {
        try self.beginMutation(at: startedAt, ownerProcessIdentifier: getpid())
    }

    func beginMutation(
        at startedAt: Date,
        ownerProcessIdentifier: pid_t) throws -> PendingMutation
    {
        try self.withLock(operation: LOCK_EX) {
            try FileManager.default.createDirectory(
                at: self.pendingDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: S_IRWXU)])
            let mutation = PendingMutation(
                id: UUID(),
                startedAt: startedAt,
                completionGenerationAtStart: self.readCompletionGenerationUnlocked())
            let record = PendingMutationRecord(
                version: Self.currentVersion,
                ownerProcessIdentifier: ownerProcessIdentifier,
                ownerProcessStartIdentity: self.processStartIdentityProvider(ownerProcessIdentifier),
                startedAtReferenceDateSeconds: startedAt.timeIntervalSinceReferenceDate,
                resolution: nil)
            let url = self.pendingMutationURL(for: mutation)
            do {
                try self.writePendingRecordUnlocked(record, to: url)
            } catch {
                try? self.pendingRecordRemover(url)
                throw error
            }
            return mutation
        }
    }

    /// Publishes the host-observed completion boundary before removing its pending barrier.
    @discardableResult
    public func completeMutation(
        _ mutation: PendingMutation,
        through cutoff: Date = Date()) throws -> MutationCompletion
    {
        try self.withLock(operation: LOCK_EX) {
            let hasOtherPendingMutation = try self.hasOtherPendingMutationUnlocked(
                excluding: mutation)
            let allowsObservationPreservation = !hasOtherPendingMutation &&
                self.readCompletionGenerationUnlocked() == mutation.completionGenerationAtStart
            let url = self.pendingMutationURL(for: mutation)
            let targetGeneration = self.nextCompletionGenerationUnlocked()
            try self.writeResolvedPendingRecordUnlocked(
                mutation,
                resolution: .completed(
                    cutoffReferenceDateSeconds: cutoff.timeIntervalSinceReferenceDate,
                    completionGeneration: targetGeneration))
            let next = try self.writeUnlocked(
                through: cutoff,
                minimumCompletionGeneration: targetGeneration)
            self.removeResolvedPendingRecordBestEffort(at: url)
            return MutationCompletion(
                cutoff: next,
                allowsObservationPreservation: allowsObservationPreservation)
        }
    }

    /// Removes a barrier after the caller proves no desktop mutation was dispatched.
    public func cancelMutation(_ mutation: PendingMutation) throws {
        try self.withLock(operation: LOCK_EX) {
            let url = self.pendingMutationURL(for: mutation)
            try self.writeResolvedPendingRecordUnlocked(mutation, resolution: .canceled)
            self.removeResolvedPendingRecordBestEffort(at: url)
        }
    }

    /// Atomically advances the boundary without allowing older writers to move it backwards.
    @discardableResult
    public func advance(through cutoff: Date) throws -> Date {
        try self.withLock(operation: LOCK_EX) {
            if let current = self.readUnlocked(), cutoff <= current {
                return current
            }
            return try self.writeUnlocked(through: cutoff, incrementCompletionGeneration: true)
        }
    }

    private func writeUnlocked(
        through cutoff: Date,
        incrementCompletionGeneration: Bool = false,
        minimumCompletionGeneration: UInt64? = nil) throws -> Date
    {
        let next = max(self.readUnlocked() ?? cutoff, cutoff)
        let currentGeneration = self.readCompletionGenerationUnlocked()
        let incrementedGeneration = if incrementCompletionGeneration, currentGeneration < UInt64.max {
            currentGeneration + 1
        } else {
            currentGeneration
        }
        let nextGeneration = max(incrementedGeneration, minimumCompletionGeneration ?? 0)
        let record = Record(
            version: Self.currentVersion,
            cutoffReferenceDateSeconds: next.timeIntervalSinceReferenceDate,
            completionGeneration: nextGeneration)
        let data = try JSONEncoder().encode(record)
        try data.write(to: self.watermarkURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: S_IRUSR | S_IWUSR)],
            ofItemAtPath: self.watermarkURL.path)
        return next
    }

    private func nextCompletionGenerationUnlocked() -> UInt64 {
        let current = self.readCompletionGenerationUnlocked()
        return current < UInt64.max ? current + 1 : current
    }

    private func writeResolvedPendingRecordUnlocked(
        _ mutation: PendingMutation,
        resolution: PendingMutationResolution) throws
    {
        let url = self.pendingMutationURL(for: mutation)
        let existing = self.readPendingRecordUnlocked(at: url)
        let record = PendingMutationRecord(
            version: Self.currentVersion,
            ownerProcessIdentifier: existing?.ownerProcessIdentifier ?? getpid(),
            ownerProcessStartIdentity: existing?.ownerProcessStartIdentity ??
                self.processStartIdentityProvider(getpid()),
            startedAtReferenceDateSeconds: existing?.startedAtReferenceDateSeconds ??
                mutation.startedAt.timeIntervalSinceReferenceDate,
            resolution: resolution)
        try self.writePendingRecordUnlocked(record, to: url)
    }

    private func writePendingRecordUnlocked(_ record: PendingMutationRecord, to url: URL) throws {
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: S_IRUSR | S_IWUSR)],
            ofItemAtPath: url.path)
    }

    private func readPendingRecordUnlocked(at url: URL) -> PendingMutationRecord? {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(PendingMutationRecord.self, from: data),
              record.version == Self.currentVersion
        else { return nil }
        return record
    }

    /// A resolved record is the durable source of truth if the process exits between publishing
    /// completion and deleting its pending file. Reconciliation is idempotent by generation.
    private func reconcileResolvedPendingRecordUnlocked(_ record: PendingMutationRecord) throws -> Bool {
        guard let resolution = record.resolution else { return false }
        switch resolution {
        case let .completed(cutoffReferenceDateSeconds, completionGeneration):
            let cutoff = Date(timeIntervalSinceReferenceDate: cutoffReferenceDateSeconds)
            let persistedCutoff = self.readUnlocked()
            let persistedGeneration = self.readCompletionGenerationUnlocked()
            if persistedCutoff == nil || persistedCutoff! < cutoff || persistedGeneration < completionGeneration {
                _ = try self.writeUnlocked(
                    through: cutoff,
                    minimumCompletionGeneration: completionGeneration)
            }
        case .canceled:
            break
        }
        return true
    }

    private func removeResolvedPendingRecordBestEffort(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try self.pendingRecordRemover(url)
        } catch {
            self.logger.warning(
                "Resolved desktop mutation record cleanup will be retried: \(error.localizedDescription)")
        }
    }

    private func readUnlocked() -> Date? {
        guard FileManager.default.fileExists(atPath: self.watermarkURL.path) else { return nil }
        if let data = try? Data(contentsOf: self.watermarkURL),
           let record = try? JSONDecoder().decode(Record.self, from: data),
           record.version == Self.currentVersion
        {
            return record.cutoff
        }

        // A corrupt watermark still marks a real past boundary, so approximate it with the file's
        // own timestamps. If even those are unreadable, fail open instead of hiding every snapshot.
        self.logger.error("Desktop mutation watermark is unreadable; using its file timestamp instead")
        let values = try? self.watermarkURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .creationDateKey,
        ])
        return values?.contentModificationDate ?? values?.creationDate
    }

    private func readCompletionGenerationUnlocked() -> UInt64 {
        guard let data = try? Data(contentsOf: self.watermarkURL),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == Self.currentVersion
        else { return 0 }
        return record.completionGeneration ?? 0
    }

    private func hasPendingMutationUnlocked(
        recoveredAt: Date,
        excluding excludedMutationIDs: Set<UUID> = []) throws -> Bool
    {
        guard FileManager.default.fileExists(atPath: self.pendingDirectoryURL.path) else { return false }
        let urls = try FileManager.default.contentsOfDirectory(
            at: self.pendingDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        var hasPendingMutation = false
        for url in urls {
            let mutationID = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            let isExcluded = mutationID.map(excludedMutationIDs.contains) ?? false
            guard let record = self.readPendingRecordUnlocked(at: url) else {
                if !isExcluded {
                    hasPendingMutation = true
                }
                continue
            }
            if try self.reconcileResolvedPendingRecordUnlocked(record) {
                self.removeResolvedPendingRecordBestEffort(at: url)
                continue
            }
            if isExcluded {
                continue
            }
            if self.processMatches(record) {
                hasPendingMutation = true
                continue
            }
            try self.resolveOrphanedPendingRecordUnlocked(
                record,
                at: url,
                recoveredAt: recoveredAt)
        }
        return hasPendingMutation
    }

    private func hasOtherPendingMutationUnlocked(
        excluding mutation: PendingMutation) throws -> Bool
    {
        guard FileManager.default.fileExists(atPath: self.pendingDirectoryURL.path) else { return false }
        let ownURL = self.pendingMutationURL(for: mutation)
        let urls = try FileManager.default.contentsOfDirectory(
            at: self.pendingDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        // Match `hasPendingMutationUnlocked`: only live owner processes count as pending.
        // Orphans are recovered and must not keep blocking observation preservation.
        var foundOtherMutation = false
        for url in urls where url.standardizedFileURL != ownURL.standardizedFileURL {
            guard let record = self.readPendingRecordUnlocked(at: url) else {
                foundOtherMutation = true
                continue
            }
            if try self.reconcileResolvedPendingRecordUnlocked(record) {
                self.removeResolvedPendingRecordBestEffort(at: url)
                continue
            }
            if self.processMatches(record) {
                foundOtherMutation = true
                continue
            }
            try self.resolveOrphanedPendingRecordUnlocked(
                record,
                at: url,
                recoveredAt: Date())
        }
        return foundOtherMutation
    }

    /// Whether other *live* pending mutations exist after orphan recovery (test seam).
    /// Uses the same lock and rules as `completeMutation`.
    func hasOtherLivePendingMutation(excluding mutation: PendingMutation) throws -> Bool {
        try self.withLock(operation: LOCK_EX) {
            try self.hasOtherPendingMutationUnlocked(excluding: mutation)
        }
    }

    private func resolveOrphanedPendingRecordUnlocked(
        _ record: PendingMutationRecord,
        at url: URL,
        recoveredAt: Date) throws
    {
        let resolved = PendingMutationRecord(
            version: record.version,
            ownerProcessIdentifier: record.ownerProcessIdentifier,
            ownerProcessStartIdentity: record.ownerProcessStartIdentity,
            startedAtReferenceDateSeconds: record.startedAtReferenceDateSeconds,
            resolution: .completed(
                cutoffReferenceDateSeconds: recoveredAt.timeIntervalSinceReferenceDate,
                completionGeneration: self.nextCompletionGenerationUnlocked()))
        try self.writePendingRecordUnlocked(resolved, to: url)
        _ = try self.reconcileResolvedPendingRecordUnlocked(resolved)
        self.removeResolvedPendingRecordBestEffort(at: url)
    }

    private func pendingMutationURL(for mutation: PendingMutation) -> URL {
        self.pendingDirectoryURL.appendingPathComponent("\(mutation.id.uuidString).json", isDirectory: false)
    }

    private static func processExists(_ processIdentifier: pid_t) -> Bool {
        guard processIdentifier > 0 else { return false }
        if kill(processIdentifier, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func processMatches(_ record: PendingMutationRecord) -> Bool {
        guard Self.processExists(record.ownerProcessIdentifier) else { return false }
        guard let recordedIdentity = record.ownerProcessStartIdentity,
              let currentIdentity = self.processStartIdentityProvider(record.ownerProcessIdentifier)
        else {
            // Old records and temporarily uninspectable live processes stay fail-closed.
            return true
        }
        return currentIdentity == recordedIdentity
    }

    private static func processStartIdentity(_ processIdentifier: pid_t) -> UInt64? {
        guard processIdentifier > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize) == expectedSize
        else { return nil }
        let seconds = UInt64(info.pbi_start_tvsec)
        let microseconds = UInt64(info.pbi_start_tvusec)
        return seconds.multipliedReportingOverflow(by: 1_000_000).partialValue &+ microseconds
    }

    private func withLock<T>(operation: Int32, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: self.directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: S_IRWXU)])
        let descriptor = open(
            self.lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: self.lockURL.path])
        }
        defer { close(descriptor) }

        guard flock(descriptor, operation) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: self.lockURL.path])
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}
