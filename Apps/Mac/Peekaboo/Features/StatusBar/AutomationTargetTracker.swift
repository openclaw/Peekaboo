import AppKit
import Observation
import os

struct AutomationTarget: Equatable, Identifiable {
    var id: pid_t {
        self.processIdentifier
    }

    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let name: String
    let lastActivity: Date
}

struct AutomationTargetActivityStore {
    private(set) var activeTargets: [AutomationTarget] = []
    private var targetsByProcessIdentifier: [pid_t: AutomationTarget] = [:]
    private let maximumDisplayedTargets: Int
    private let idleTimeout: TimeInterval
    private(set) var isEnabled: Bool

    init(
        isEnabled: Bool = true,
        maximumDisplayedTargets: Int = 3,
        idleTimeout: TimeInterval)
    {
        self.isEnabled = isEnabled
        self.maximumDisplayedTargets = maximumDisplayedTargets
        self.idleTimeout = idleTimeout
    }

    mutating func recordActivity(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        name: String,
        at date: Date)
    {
        guard self.isEnabled else { return }

        self.targetsByProcessIdentifier[processIdentifier] = AutomationTarget(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            name: name,
            lastActivity: date)
        self.expireTargets(at: date)
    }

    mutating func expireTargets(at date: Date) {
        self.targetsByProcessIdentifier = self.targetsByProcessIdentifier.filter {
            date.timeIntervalSince($0.value.lastActivity) < self.idleTimeout
        }
        self.refreshActiveTargets()
    }

    mutating func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        if !isEnabled {
            self.targetsByProcessIdentifier.removeAll()
        }
        self.refreshActiveTargets()
    }

    private mutating func refreshActiveTargets() {
        self.activeTargets = self.targetsByProcessIdentifier.values
            .sorted {
                if $0.lastActivity == $1.lastActivity {
                    return $0.processIdentifier < $1.processIdentifier
                }
                return $0.lastActivity > $1.lastActivity
            }
            .prefix(self.maximumDisplayedTargets)
            .map(\.self)
    }
}

@Observable
@MainActor
final class AutomationTargetTracker {
    static let idleTimeout: TimeInterval = 10

    @ObservationIgnored private let logger = Logger(subsystem: "boo.peekaboo.app", category: "AutomationTargets")

    private(set) var activeTargets: [AutomationTarget] = []
    private var store: AutomationTargetActivityStore
    private var expiryTask: Task<Void, Never>?

    init(isEnabled: Bool = true) {
        self.store = AutomationTargetActivityStore(
            isEnabled: isEnabled,
            idleTimeout: Self.idleTimeout)
        self.startExpiryTask()
    }

    isolated deinit {
        self.expiryTask?.cancel()
    }

    func recordActivity(pid: pid_t) {
        guard pid > 0 else { return }

        let application = NSRunningApplication(processIdentifier: pid)
        let bundleIdentifier = application?.bundleIdentifier
        let name = application?.localizedName ?? bundleIdentifier ?? "Application"
        self.store.recordActivity(
            processIdentifier: pid,
            bundleIdentifier: bundleIdentifier,
            name: name,
            at: Date())
        self.publishActiveTargets()
        self.logger.debug(
            "Recorded activity for \(name, privacy: .public) (pid \(pid)); \(self.activeTargets.count) active")
    }

    func setEnabled(_ isEnabled: Bool) {
        self.store.setEnabled(isEnabled)
        self.publishActiveTargets()
    }

    private func startExpiryTask() {
        self.expiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                self?.expireTargets()
            }
        }
    }

    private func expireTargets() {
        self.store.expireTargets(at: Date())
        self.publishActiveTargets()
    }

    private func publishActiveTargets() {
        guard self.activeTargets != self.store.activeTargets else { return }
        self.activeTargets = self.store.activeTargets
    }
}
