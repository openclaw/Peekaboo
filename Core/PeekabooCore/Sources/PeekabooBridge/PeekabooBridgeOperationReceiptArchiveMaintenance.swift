import Foundation

struct PeekabooBridgeOperationReceiptArchiveFileSystem: Sendable {
    let fileExists: @Sendable (URL) -> Bool
    let moveItem: @Sendable (URL, URL) throws -> Void
    let removeItem: @Sendable (URL) throws -> Void

    static let live = Self(
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
        removeItem: { try FileManager.default.removeItem(at: $0) })
}

struct PeekabooBridgeOperationReceiptArchiveCleanupJob: Sendable {
    enum Owner: Sendable {
        case retiredSession(UUID)
        case orphan
    }

    enum Stage: Sendable {
        case quarantine
        case removeQuarantine
    }

    let id = UUID()
    let owner: Owner
    let source: URL
    let quarantine: URL
    var stage = Stage.quarantine
}

/// Serializes retired-session quarantine and deletion without holding receipt-authority locks.
final class PeekabooBridgeOperationReceiptArchiveMaintenance: @unchecked Sendable {
    typealias Job = PeekabooBridgeOperationReceiptArchiveCleanupJob
    typealias CommitQuarantine = @Sendable (Job) -> Bool

    private let fileSystem: PeekabooBridgeOperationReceiptArchiveFileSystem
    private let capacityBacklogLimit: Int
    private let lock = NSLock()
    private var pending: [Job] = []
    private var reservedSources: Set<URL> = []
    private var activeRun: Run?
    private var activeJob: Job?

    init(
        fileSystem: PeekabooBridgeOperationReceiptArchiveFileSystem,
        capacityBacklogLimit: Int)
    {
        self.fileSystem = fileSystem
        self.capacityBacklogLimit = capacityBacklogLimit
    }

    var requiresCapacityMaintenance: Bool {
        self.lock.withLock {
            self.backlogIsSaturatedLocked || self.jobsContainUncommittedRetiredSessionLocked
        }
    }

    var backlogIsSaturated: Bool {
        self.lock.withLock { self.backlogIsSaturatedLocked }
    }

    var hasUncommittedRetiredSession: Bool {
        self.lock.withLock { self.jobsContainUncommittedRetiredSessionLocked }
    }

    func enqueue(owner: Job.Owner, source: URL, quarantine: URL) -> UUID? {
        self.lock.withLock {
            guard self.reservedSources.insert(source).inserted else { return nil }
            let job = Job(owner: owner, source: source, quarantine: quarantine)
            if Self.requiresRegistryCommit(job) {
                self.pending.insert(job, at: 0)
            } else {
                self.pending.append(job)
            }
            return job.id
        }
    }

    func schedule(commitQuarantine: @escaping CommitQuarantine) {
        _ = self.scheduleRun(commitQuarantine: commitQuarantine)
    }

    func performRequired(commitQuarantine: @escaping CommitQuarantine) async -> Bool {
        while self.requiresCapacityMaintenance {
            guard let run = self.scheduleRun(commitQuarantine: commitQuarantine) else {
                return !self.requiresCapacityMaintenance
            }
            switch await run.waitForResult() {
            case .completed:
                continue
            case let .failed(preventsCapacity, madeRegistryProgress):
                if preventsCapacity {
                    return false
                }
                if madeRegistryProgress {
                    return true
                }
            }
        }
        return true
    }

    private func scheduleRun(commitQuarantine: @escaping CommitQuarantine) -> Run? {
        let scheduled = self.lock.withLock { () -> (run: Run, shouldStart: Bool)? in
            if let activeRun {
                return (activeRun, false)
            }
            guard !self.pending.isEmpty else { return nil }
            let run = Run()
            self.activeRun = run
            return (run, true)
        }
        guard let scheduled else { return nil }
        if scheduled.shouldStart {
            Task.detached(priority: .utility) { [self] in
                self.runCleanup(scheduled.run, commitQuarantine: commitQuarantine)
            }
        }
        return scheduled.run
    }

    private func runCleanup(_ run: Run, commitQuarantine: CommitQuarantine) {
        var madeRegistryProgress = false
        while let job = self.nextJob(run: run) {
            switch self.perform(job, commitQuarantine: commitQuarantine) {
            case let .success(committedRetiredSession):
                madeRegistryProgress = madeRegistryProgress || committedRetiredSession
                self.lock.withLock {
                    self.activeJob = nil
                    _ = self.reservedSources.remove(job.source)
                }
            case let .retry(retryJob, committedRetiredSession):
                madeRegistryProgress = madeRegistryProgress || committedRetiredSession
                self.finish(
                    run,
                    failedJob: retryJob,
                    madeRegistryProgress: madeRegistryProgress)
                return
            }
        }
        run.resolve(.completed)
    }

    private func nextJob(run: Run) -> Job? {
        self.lock.withLock {
            guard self.activeRun === run else { return nil }
            guard !self.pending.isEmpty else {
                self.activeRun = nil
                self.activeJob = nil
                return nil
            }
            let job = self.pending.removeFirst()
            self.activeJob = job
            return job
        }
    }

    private func perform(_ initialJob: Job, commitQuarantine: CommitQuarantine) -> JobResult {
        var job = initialJob
        var committedRetiredSession = false
        if job.stage == .quarantine {
            do {
                let sourceExists = self.fileSystem.fileExists(job.source)
                let quarantineExists = self.fileSystem.fileExists(job.quarantine)
                guard !sourceExists || !quarantineExists else {
                    return .retry(job, committedRetiredSession: false)
                }
                if sourceExists {
                    try self.fileSystem.moveItem(job.source, job.quarantine)
                }
            } catch {
                return .retry(job, committedRetiredSession: false)
            }
            guard commitQuarantine(job) else {
                return .retry(job, committedRetiredSession: false)
            }
            committedRetiredSession = Self.requiresRegistryCommit(job)
            job.stage = .removeQuarantine
            let updatedActiveJob: Bool = self.lock.withLock {
                guard self.activeJob?.id == job.id else { return false }
                self.activeJob = job
                return true
            }
            guard updatedActiveJob else {
                return .retry(job, committedRetiredSession: committedRetiredSession)
            }
        }

        do {
            if self.fileSystem.fileExists(job.quarantine) {
                try self.fileSystem.removeItem(job.quarantine)
            }
            return .success(committedRetiredSession: committedRetiredSession)
        } catch {
            return .retry(job, committedRetiredSession: committedRetiredSession)
        }
    }

    private func finish(
        _ run: Run,
        failedJob: Job,
        madeRegistryProgress: Bool)
    {
        let preventsCapacity: Bool = self.lock.withLock {
            guard self.activeRun === run else { return true }
            if !self.pending.contains(where: { $0.id == failedJob.id }) {
                if Self.requiresRegistryCommit(failedJob) {
                    self.pending.insert(failedJob, at: 0)
                } else {
                    self.pending.append(failedJob)
                }
            }
            self.activeRun = nil
            self.activeJob = nil
            return Self.requiresRegistryCommit(failedJob) ||
                self.reservedSources.count >= self.capacityBacklogLimit
        }
        run.resolve(.failed(
            preventsCapacity: preventsCapacity,
            madeRegistryProgress: madeRegistryProgress))
    }

    private var jobsContainUncommittedRetiredSessionLocked: Bool {
        let activeRequiresCommit = self.activeJob.map(Self.requiresRegistryCommit) ?? false
        return activeRequiresCommit || self.pending.contains(where: Self.requiresRegistryCommit)
    }

    private var backlogIsSaturatedLocked: Bool {
        self.reservedSources.count >= self.capacityBacklogLimit
    }

    private static func requiresRegistryCommit(_ job: Job) -> Bool {
        guard job.stage == .quarantine else { return false }
        if case .retiredSession = job.owner {
            return true
        }
        return false
    }

    private enum JobResult {
        case success(committedRetiredSession: Bool)
        case retry(Job, committedRetiredSession: Bool)
    }

    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result?
        private var waiters: [CheckedContinuation<Result, Never>] = []

        func waitForResult() async -> Result {
            await withCheckedContinuation { continuation in
                self.lock.lock()
                if let result = self.result {
                    self.lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    self.waiters.append(continuation)
                    self.lock.unlock()
                }
            }
        }

        func resolve(_ result: Result) {
            self.lock.lock()
            guard self.result == nil else {
                self.lock.unlock()
                return
            }
            self.result = result
            let waiters = self.waiters
            self.waiters.removeAll()
            self.lock.unlock()
            waiters.forEach { $0.resume(returning: result) }
        }

        enum Result: Sendable {
            case completed
            case failed(preventsCapacity: Bool, madeRegistryProgress: Bool)
        }
    }
}
