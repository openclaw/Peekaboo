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
        fileprivate let target: DesktopOperationScope
        fileprivate let relevantGenerationAtStart: UInt64
    }

    public struct PreservationFence: Sendable, Codable, Equatable {
        public let target: DesktopOperationScope
        public let relevantGeneration: UInt64

        public init(target: DesktopOperationScope, relevantGeneration: UInt64) {
            self.target = target
            self.relevantGeneration = relevantGeneration
        }
    }

    public struct MutationCompletion: Sendable, Equatable {
        public let cutoff: Date
        public let allowsObservationPreservation: Bool
        public let preservationFence: PreservationFence
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
        let target: DesktopOperationScope?
        let resolution: PendingMutationResolution?
    }

    private struct ScopedMark: Codable, Equatable {
        let cutoffReferenceDateSeconds: TimeInterval
        let generation: UInt64

        var cutoff: Date {
            Date(timeIntervalSinceReferenceDate: self.cutoffReferenceDateSeconds)
        }
    }

    private struct ScopedProcessMarks: Codable {
        var direct: ScopedMark?
        var aggregate: ScopedMark?
    }

    private struct LegacyShadow: Codable, Equatable {
        let cutoffReferenceDateSeconds: TimeInterval?
        let completionGeneration: UInt64
    }

    private struct ScopedLedger: Codable {
        let version: Int
        var aggregate: ScopedMark?
        var globalExclusive: ScopedMark?
        var processes: [String: ScopedProcessMarks]
        var windows: [String: ScopedMark]
        var legacyShadow: LegacyShadow

        static let empty = ScopedLedger(
            version: 1,
            aggregate: nil,
            globalExclusive: nil,
            processes: [:],
            windows: [:],
            legacyShadow: LegacyShadow(cutoffReferenceDateSeconds: nil, completionGeneration: 0))
    }

    private enum PendingMutationResolution: Codable {
        case completed(cutoffReferenceDateSeconds: TimeInterval, completionGeneration: UInt64)
        case canceled
    }

    private static let currentVersion = 1
    private static let watermarkFileName = "desktop-mutation-watermark.json"
    private static let lockFileName = "desktop-mutation-watermark.lock"
    private static let pendingDirectoryName = "desktop-mutation-pending"
    private static let scopedLedgerFileName = "desktop-mutation-targets.json"
    private static let scopedEntryRetentionSeconds: TimeInterval = 3600
    @TaskLocal private static var visiblePendingMutationIDs: Set<UUID> = []

    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "DesktopMutationWatermark")
    let directoryURL: URL
    let watermarkURL: URL
    private let lockURL: URL
    private let pendingDirectoryURL: URL
    let scopedLedgerURL: URL
    private let processStartIdentityProvider: @Sendable (pid_t) -> UInt64?
    private let pendingRecordRemover: @Sendable (URL) throws -> Void

    public convenience init() {
        self.init(directoryURL: DesktopCoordinationRuntimeRoot.defaultURL)
    }

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.watermarkURL = directoryURL.appendingPathComponent(Self.watermarkFileName, isDirectory: false)
        self.lockURL = directoryURL.appendingPathComponent(Self.lockFileName, isDirectory: false)
        self.pendingDirectoryURL = directoryURL.appendingPathComponent(Self.pendingDirectoryName, isDirectory: true)
        self.scopedLedgerURL = directoryURL.appendingPathComponent(Self.scopedLedgerFileName, isDirectory: false)
        self.processStartIdentityProvider = SystemIdentityResolver.processStartIdentity
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
        self.scopedLedgerURL = directoryURL.appendingPathComponent(Self.scopedLedgerFileName, isDirectory: false)
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
            return try self.withLock(operation: LOCK_EX | LOCK_NB) {
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

    /// Returns the cutoff relevant to a generation-pinned target. Legacy and unresolved callers
    /// deliberately continue to use `effectiveWatermark()`, the aggregate compatibility shadow.
    public func effectiveWatermark(for target: DesktopOperationScope) -> Date? {
        do {
            return try self.withLock(operation: LOCK_EX | LOCK_NB) {
                let now = Date()
                let hasPendingMutation = try self.hasPendingMutationUnlocked(
                    recoveredAt: now,
                    excluding: Self.visiblePendingMutationIDs,
                    relevantTo: target)
                var ledger = self.readScopedLedgerUnlocked()
                try self.reconcileForeignLegacyWriterUnlocked(ledger: &ledger)
                let persisted = self.relevantMark(in: ledger, for: target)?.cutoff
                return hasPendingMutation
                    ? max(persisted ?? now, now)
                    : persisted
            }
        } catch {
            // Lock contention or unreadable target metadata is conservatively aggregate. This can
            // over-invalidate briefly, but can never expose a snapshot across an uncertain mutation.
            return self.effectiveWatermarkLockless()
        }
    }

    /// Whether no relevant mutation completed or remains pending after this completion certificate.
    /// Sibling windows and unrelated process generations do not invalidate one another's fences.
    public func isPreservationFenceCurrent(_ fence: PreservationFence) -> Bool {
        do {
            return try self.withLock(operation: LOCK_EX | LOCK_NB) {
                if try self.hasPendingMutationUnlocked(recoveredAt: Date(), relevantTo: fence.target) {
                    return false
                }
                var ledger = self.readScopedLedgerUnlocked()
                try self.reconcileForeignLegacyWriterUnlocked(ledger: &ledger)
                return self.relevantGeneration(in: ledger, for: fence.target) == fence.relevantGeneration
            }
        } catch {
            return false
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
    public func beginMutation(
        at startedAt: Date = Date(),
        target: DesktopOperationScope = .global) throws -> PendingMutation
    {
        try self.beginMutation(
            at: startedAt,
            ownerProcessIdentifier: getpid(),
            target: target)
    }

    /// Waits for the cross-process barrier without blocking an actor executor and stops promptly when its task is
    /// cancelled. Bridge requests use this before dispatch so a disconnected client cannot remain queued in `flock`.
    public func beginMutationCancellable(
        at startedAt: Date = Date(),
        target: DesktopOperationScope = .global) async throws -> PendingMutation
    {
        let descriptor = try self.openLockDescriptor()
        defer { close(descriptor) }

        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
                throw self.lockError(code: code)
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        try Task.checkCancellation()
        return try self.beginMutationUnlocked(
            at: startedAt,
            ownerProcessIdentifier: getpid(),
            target: target)
    }

    func beginMutation(
        at startedAt: Date,
        ownerProcessIdentifier: pid_t,
        target: DesktopOperationScope = .global) throws -> PendingMutation
    {
        try self.withLock(operation: LOCK_EX) {
            try self.beginMutationUnlocked(
                at: startedAt,
                ownerProcessIdentifier: ownerProcessIdentifier,
                target: target)
        }
    }

    private func beginMutationUnlocked(
        at startedAt: Date,
        ownerProcessIdentifier: pid_t,
        target: DesktopOperationScope) throws -> PendingMutation
    {
        try FileManager.default.createDirectory(
            at: self.pendingDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: S_IRWXU)])
        _ = try self.hasPendingMutationUnlocked(recoveredAt: Date())
        var ledger = self.readScopedLedgerUnlocked()
        try self.reconcileForeignLegacyWriterUnlocked(ledger: &ledger)
        let mutation = PendingMutation(
            id: UUID(),
            startedAt: startedAt,
            target: target,
            relevantGenerationAtStart: self.relevantGeneration(in: ledger, for: target))
        let record = PendingMutationRecord(
            version: Self.currentVersion,
            ownerProcessIdentifier: ownerProcessIdentifier,
            ownerProcessStartIdentity: self.processStartIdentityProvider(ownerProcessIdentifier),
            startedAtReferenceDateSeconds: startedAt.timeIntervalSinceReferenceDate,
            target: target,
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

    /// Publishes the host-observed completion boundary before removing its pending barrier.
    @discardableResult
    public func completeMutation(
        _ mutation: PendingMutation,
        through cutoff: Date = Date()) throws -> MutationCompletion
    {
        try self.withLock(operation: LOCK_EX) {
            let hasOtherPendingMutation = try self.hasOtherPendingMutationUnlocked(
                excluding: mutation,
                relevantTo: mutation.target)
            var ledger = self.readScopedLedgerUnlocked()
            try self.reconcileForeignLegacyWriterUnlocked(ledger: &ledger)
            let relevantGenerationBeforeCompletion = self.relevantGeneration(
                in: ledger,
                for: mutation.target)
            let allowsObservationPreservation = !hasOtherPendingMutation &&
                relevantGenerationBeforeCompletion == mutation.relevantGenerationAtStart &&
                relevantGenerationBeforeCompletion < UInt64.max
            let url = self.pendingMutationURL(for: mutation)
            let targetGeneration = self.nextCompletionGenerationUnlocked(ledger: ledger)
            try self.writeResolvedPendingRecordUnlocked(
                mutation,
                resolution: .completed(
                    cutoffReferenceDateSeconds: cutoff.timeIntervalSinceReferenceDate,
                    completionGeneration: targetGeneration))
            let next = try self.writeUnlocked(
                through: cutoff,
                minimumCompletionGeneration: targetGeneration)
            self.apply(
                target: mutation.target,
                cutoff: cutoff,
                generation: targetGeneration,
                to: &ledger)
            ledger.legacyShadow = self.currentLegacyShadowUnlocked()
            try self.writeScopedLedgerUnlocked(ledger)
            self.removeResolvedPendingRecordBestEffort(at: url)
            return MutationCompletion(
                cutoff: next,
                allowsObservationPreservation: allowsObservationPreservation,
                preservationFence: PreservationFence(
                    target: mutation.target,
                    relevantGeneration: self.relevantGeneration(in: ledger, for: mutation.target)))
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
    public func advance(
        through cutoff: Date,
        target: DesktopOperationScope = .global) throws -> Date
    {
        try self.withLock(operation: LOCK_EX) {
            _ = try self.hasPendingMutationUnlocked(recoveredAt: Date())
            var ledger = self.readScopedLedgerUnlocked()
            try self.reconcileForeignLegacyWriterUnlocked(ledger: &ledger)
            if let current = self.relevantMark(in: ledger, for: target)?.cutoff, cutoff <= current {
                return current
            }
            let generation = self.nextCompletionGenerationUnlocked(ledger: ledger)
            let aggregate = try self.writeUnlocked(
                through: cutoff,
                minimumCompletionGeneration: generation)
            self.apply(target: target, cutoff: cutoff, generation: generation, to: &ledger)
            ledger.legacyShadow = self.currentLegacyShadowUnlocked()
            try self.writeScopedLedgerUnlocked(ledger)
            return target == .global
                ? aggregate
                : self.relevantMark(in: ledger, for: target)?.cutoff ?? cutoff
        }
    }

    private func writeUnlocked(
        through cutoff: Date,
        minimumCompletionGeneration: UInt64? = nil) throws -> Date
    {
        let next = max(self.readUnlocked() ?? cutoff, cutoff)
        let currentGeneration = self.readCompletionGenerationUnlocked()
        let nextGeneration = max(currentGeneration, minimumCompletionGeneration ?? 0)
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

    private func nextCompletionGenerationUnlocked(ledger: ScopedLedger) -> UInt64 {
        let current = max(
            self.readCompletionGenerationUnlocked(),
            ledger.aggregate?.generation ?? 0)
        return current < UInt64.max ? current + 1 : current
    }

    private func readScopedLedgerUnlocked() -> ScopedLedger {
        guard let data = try? Data(contentsOf: self.scopedLedgerURL),
              let ledger = try? JSONDecoder().decode(ScopedLedger.self, from: data),
              ledger.version == 1
        else {
            return .empty
        }
        return ledger
    }

    private func writeScopedLedgerUnlocked(_ ledger: ScopedLedger) throws {
        var ledger = ledger
        self.pruneScopedEntries(in: &ledger)
        let data = try JSONEncoder().encode(ledger)
        try data.write(to: self.scopedLedgerURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: S_IRUSR | S_IWUSR)],
            ofItemAtPath: self.scopedLedgerURL.path)
    }

    private func currentLegacyShadowUnlocked() -> LegacyShadow {
        guard let data = try? Data(contentsOf: self.watermarkURL),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == Self.currentVersion
        else {
            return LegacyShadow(
                cutoffReferenceDateSeconds: self.readUnlocked()?.timeIntervalSinceReferenceDate,
                completionGeneration: 0)
        }
        return LegacyShadow(
            cutoffReferenceDateSeconds: record.cutoffReferenceDateSeconds,
            completionGeneration: record.completionGeneration ?? 0)
    }

    private func reconcileForeignLegacyWriterUnlocked(ledger: inout ScopedLedger) throws {
        let legacy = self.currentLegacyShadowUnlocked()
        guard legacy != ledger.legacyShadow else { return }

        if let seconds = legacy.cutoffReferenceDateSeconds {
            let nextGeneration: UInt64
            let aggregateGeneration = ledger.aggregate?.generation ?? 0
            if legacy.completionGeneration > aggregateGeneration {
                nextGeneration = legacy.completionGeneration
            } else if aggregateGeneration < UInt64.max {
                nextGeneration = aggregateGeneration + 1
            } else {
                nextGeneration = aggregateGeneration
            }
            self.apply(
                target: .global,
                cutoff: Date(timeIntervalSinceReferenceDate: seconds),
                generation: nextGeneration,
                to: &ledger)
        }
        ledger.legacyShadow = legacy
        try self.writeScopedLedgerUnlocked(ledger)
    }

    private func apply(
        target: DesktopOperationScope,
        cutoff: Date,
        generation: UInt64,
        to ledger: inout ScopedLedger)
    {
        let mark = ScopedMark(
            cutoffReferenceDateSeconds: cutoff.timeIntervalSinceReferenceDate,
            generation: generation)
        ledger.aggregate = Self.merging(ledger.aggregate, mark)
        switch target {
        case .global:
            ledger.globalExclusive = Self.merging(ledger.globalExclusive, mark)
        case let .process(identity):
            let key = Self.processKey(identity)
            var process = ledger.processes[key] ?? ScopedProcessMarks(direct: nil, aggregate: nil)
            process.direct = Self.merging(process.direct, mark)
            process.aggregate = Self.merging(process.aggregate, mark)
            ledger.processes[key] = process
        case let .window(identity):
            let processIdentity = ApplicationProcessIdentity(
                processIdentifier: identity.ownerProcessIdentifier,
                processStartIdentity: identity.ownerProcessStartIdentity)
            let processKey = Self.processKey(processIdentity)
            var process = ledger.processes[processKey] ?? ScopedProcessMarks(direct: nil, aggregate: nil)
            process.aggregate = Self.merging(process.aggregate, mark)
            ledger.processes[processKey] = process
            let windowKey = Self.windowKey(identity)
            ledger.windows[windowKey] = Self.merging(ledger.windows[windowKey], mark)
        }
    }

    private static func merging(_ current: ScopedMark?, _ candidate: ScopedMark) -> ScopedMark {
        guard let current else { return candidate }
        return ScopedMark(
            cutoffReferenceDateSeconds: max(
                current.cutoffReferenceDateSeconds,
                candidate.cutoffReferenceDateSeconds),
            generation: max(current.generation, candidate.generation))
    }

    private func relevantGeneration(in ledger: ScopedLedger, for target: DesktopOperationScope) -> UInt64 {
        self.relevantMark(in: ledger, for: target)?.generation ?? 0
    }

    private func relevantMark(in ledger: ScopedLedger, for target: DesktopOperationScope) -> ScopedMark? {
        switch target {
        case .global:
            return ledger.aggregate
        case let .process(identity):
            return Self.mergingOptional(
                ledger.globalExclusive,
                ledger.processes[Self.processKey(identity)]?.aggregate)
        case let .window(identity):
            let processIdentity = ApplicationProcessIdentity(
                processIdentifier: identity.ownerProcessIdentifier,
                processStartIdentity: identity.ownerProcessStartIdentity)
            let process = ledger.processes[Self.processKey(processIdentity)]
            return Self.mergingOptional(
                Self.mergingOptional(ledger.globalExclusive, process?.direct),
                ledger.windows[Self.windowKey(identity)])
        }
    }

    private static func mergingOptional(_ lhs: ScopedMark?, _ rhs: ScopedMark?) -> ScopedMark? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): self.merging(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private static func processKey(_ identity: ApplicationProcessIdentity) -> String {
        "\(identity.processIdentifier):\(identity.processStartIdentity)"
    }

    private static func processKey(fromWindowKey key: String) -> String? {
        guard let separator = key.lastIndex(of: ":"), separator != key.startIndex else { return nil }
        return String(key[..<separator])
    }

    private static func windowKey(_ identity: WindowMutationIdentity) -> String {
        "\(identity.ownerProcessIdentifier):\(identity.ownerProcessStartIdentity):\(identity.windowID)"
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
            target: existing?.target ?? mutation.target,
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
            var ledger = self.readScopedLedgerUnlocked()
            let legacyBeforeRecovery = self.currentLegacyShadowUnlocked()
            let legacyBelongsToThisJournal = legacyBeforeRecovery.completionGeneration == completionGeneration &&
                legacyBeforeRecovery.cutoffReferenceDateSeconds == cutoffReferenceDateSeconds
            if legacyBeforeRecovery != ledger.legacyShadow, !legacyBelongsToThisJournal {
                try self.reconcileForeignLegacyWriterUnlocked(ledger: &ledger)
            }
            let persistedCutoff = self.readUnlocked()
            let persistedGeneration = self.readCompletionGenerationUnlocked()
            if persistedCutoff == nil || persistedCutoff! < cutoff || persistedGeneration < completionGeneration {
                _ = try self.writeUnlocked(
                    through: cutoff,
                    minimumCompletionGeneration: completionGeneration)
            }
            self.apply(
                target: record.target ?? .global,
                cutoff: cutoff,
                generation: completionGeneration,
                to: &ledger)
            ledger.legacyShadow = self.currentLegacyShadowUnlocked()
            try self.writeScopedLedgerUnlocked(ledger)
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
        excluding excludedMutationIDs: Set<UUID> = [],
        relevantTo target: DesktopOperationScope? = nil) throws -> Bool
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
                if self.targetsOverlap(record.target, target) {
                    hasPendingMutation = true
                }
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
        excluding mutation: PendingMutation,
        relevantTo target: DesktopOperationScope? = nil) throws -> Bool
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
                if self.targetsOverlap(record.target, target) {
                    foundOtherMutation = true
                }
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
            try self.hasOtherPendingMutationUnlocked(excluding: mutation, relevantTo: mutation.target)
        }
    }

    private func resolveOrphanedPendingRecordUnlocked(
        _ record: PendingMutationRecord,
        at url: URL,
        recoveredAt: Date) throws
    {
        let ledger = self.readScopedLedgerUnlocked()
        let completionGeneration = self.nextCompletionGenerationUnlocked(ledger: ledger)
        let resolved = PendingMutationRecord(
            version: record.version,
            ownerProcessIdentifier: record.ownerProcessIdentifier,
            ownerProcessStartIdentity: record.ownerProcessStartIdentity,
            startedAtReferenceDateSeconds: record.startedAtReferenceDateSeconds,
            target: record.target,
            resolution: .completed(
                cutoffReferenceDateSeconds: recoveredAt.timeIntervalSinceReferenceDate,
                completionGeneration: completionGeneration))
        try self.writePendingRecordUnlocked(resolved, to: url)
        _ = try self.reconcileResolvedPendingRecordUnlocked(resolved)
        self.removeResolvedPendingRecordBestEffort(at: url)
    }

    private func targetsOverlap(
        _ pendingTarget: DesktopOperationScope?,
        _ requestedTarget: DesktopOperationScope?) -> Bool
    {
        guard let pendingTarget, let requestedTarget else { return true }
        switch (pendingTarget, requestedTarget) {
        case (.global, _), (_, .global):
            return true
        case let (.process(lhs), .process(rhs)):
            return lhs == rhs
        case let (.process(process), .window(window)),
             let (.window(window), .process(process)):
            return process.processIdentifier == window.ownerProcessIdentifier &&
                process.processStartIdentity == window.ownerProcessStartIdentity
        case let (.window(lhs), .window(rhs)):
            return lhs.ownerProcessIdentifier == rhs.ownerProcessIdentifier &&
                lhs.ownerProcessStartIdentity == rhs.ownerProcessStartIdentity &&
                lhs.windowID == rhs.windowID
        }
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

    private func withLock<T>(operation: Int32, _ body: () throws -> T) throws -> T {
        let descriptor = try self.openLockDescriptor()
        defer { close(descriptor) }

        guard flock(descriptor, operation) == 0 else {
            throw self.lockError(code: errno)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func openLockDescriptor() throws -> Int32 {
        try FileManager.default.createDirectory(
            at: self.directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: S_IRWXU)])

        var directoryInfo = stat()
        guard lstat(self.directoryURL.path, &directoryInfo) == 0,
              directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryInfo.st_uid == geteuid(),
              directoryInfo.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
              chmod(self.directoryURL.path, S_IRWXU) == 0
        else {
            throw self.lockError(code: EACCES)
        }
        let descriptor = open(
            self.lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw self.lockError(code: errno)
        }
        var lockInfo = stat()
        guard fstat(descriptor, &lockInfo) == 0,
              lockInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              lockInfo.st_uid == geteuid(),
              lockInfo.st_nlink == 1,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
        else {
            let code = errno == 0 ? EACCES : errno
            close(descriptor)
            throw self.lockError(code: code)
        }
        return descriptor
    }

    private func lockError(code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: self.lockURL.path])
    }
}

extension DesktopMutationWatermarkStore {
    private func pruneScopedEntries(in ledger: inout ScopedLedger, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.scopedEntryRetentionSeconds)
        var processTombstones: [String: ScopedMark] = [:]
        var globalTombstone = ledger.globalExclusive
        ledger.windows = ledger.windows.filter { key, mark in
            guard mark.cutoff < cutoff else { return true }
            guard let processKey = Self.processKey(fromWindowKey: key) else {
                globalTombstone = Self.mergingOptional(globalTombstone, mark)
                return false
            }
            processTombstones[processKey] = Self.mergingOptional(processTombstones[processKey], mark)
            return false
        }
        for (key, tombstone) in processTombstones {
            var marks = ledger.processes[key] ?? ScopedProcessMarks(direct: nil, aggregate: nil)
            // Once the per-window key is discarded, retain its boundary at the narrowest safe
            // ancestor. `direct` keeps every window in the process behind the old mutation, while
            // `aggregate` preserves process-level snapshot invalidation.
            marks.direct = Self.mergingOptional(marks.direct, tombstone)
            marks.aggregate = Self.mergingOptional(marks.aggregate, tombstone)
            ledger.processes[key] = marks
        }

        ledger.processes = ledger.processes.compactMapValues { marks in
            let direct = marks.direct.flatMap { $0.cutoff >= cutoff ? $0 : nil }
            let aggregate = marks.aggregate.flatMap { $0.cutoff >= cutoff ? $0 : nil }
            if direct == nil, let expired = marks.direct {
                globalTombstone = Self.mergingOptional(globalTombstone, expired)
            }
            if aggregate == nil, let expired = marks.aggregate {
                globalTombstone = Self.mergingOptional(globalTombstone, expired)
            }
            guard direct != nil || aggregate != nil else { return nil }
            return ScopedProcessMarks(direct: direct, aggregate: aggregate)
        }
        ledger.globalExclusive = globalTombstone
    }
}
