import AXorcist
import CoreGraphics
import Foundation
import os.log
import PeekabooFoundation

public enum ExactWindowHeldPointerButton: String, Codable, Equatable, Sendable {
    case left
    case right

    fileprivate var mouseButton: MouseButton {
        switch self {
        case .left: .left
        case .right: .right
        }
    }
}

/// Opaque bearer capability registered with one lifecycle service instance.
///
/// Random identity is necessary but not sufficient: the lifecycle owner also records this exact
/// value before accepting it, and Bridge callers additionally bind it to an authenticated client
/// process generation.
public struct ExactWindowHeldPointerOwner: Codable, Equatable, Hashable, Sendable {
    fileprivate let identifier: UUID
    fileprivate let secret: UUID

    init(identifier: UUID = UUID(), secret: UUID = UUID()) {
        self.identifier = identifier
        self.secret = secret
    }
}

public struct ExactWindowHeldPointerRequest: Codable, Equatable, Sendable {
    public let point: CGPoint
    public let windowIdentity: WindowMutationIdentity
    public let windowBounds: CGRect
    public let button: ExactWindowHeldPointerButton
    public let expiresAfterSeconds: TimeInterval

    public init(
        point: CGPoint,
        windowIdentity: WindowMutationIdentity,
        windowBounds: CGRect,
        button: ExactWindowHeldPointerButton,
        expiresAfterSeconds: TimeInterval)
    {
        self.point = point
        self.windowIdentity = windowIdentity
        self.windowBounds = windowBounds
        self.button = button
        self.expiresAfterSeconds = expiresAfterSeconds
    }
}

public struct ExactWindowHeldPointerReceipt: Codable, Equatable, Sendable {
    fileprivate let token: UUID
    fileprivate let ownerIdentifier: UUID
    public let point: CGPoint
    public let windowIdentity: WindowMutationIdentity
    public let windowBounds: CGRect
    public let button: ExactWindowHeldPointerButton
    private let expiresAtReferenceDateSeconds: TimeInterval

    public var expiresAt: Date {
        Date(timeIntervalSinceReferenceDate: self.expiresAtReferenceDateSeconds)
    }

    init(
        token: UUID,
        owner: ExactWindowHeldPointerOwner,
        request: ExactWindowHeldPointerRequest,
        expiresAt: Date)
    {
        self.token = token
        self.ownerIdentifier = owner.identifier
        self.point = request.point
        self.windowIdentity = request.windowIdentity
        self.windowBounds = request.windowBounds
        self.button = request.button
        self.expiresAtReferenceDateSeconds = expiresAt.timeIntervalSinceReferenceDate
    }
}

public enum ExactWindowHeldPointerTerminalReason: String, Codable, Equatable, Sendable {
    case released
    case revoked
    case ownerDisconnected
    case callerCancelled
    case expired
    case processGenerationChanged
    case windowChanged
}

public struct ExactWindowHeldPointerTermination: Codable, Equatable, Sendable {
    public let receipt: ExactWindowHeldPointerReceipt
    public let reason: ExactWindowHeldPointerTerminalReason
    public let cleanupOutcome: DesktopActionOutcome
    public let lifecycleDispatchedUnitCount: Int

    public init(
        receipt: ExactWindowHeldPointerReceipt,
        reason: ExactWindowHeldPointerTerminalReason,
        cleanupOutcome: DesktopActionOutcome,
        lifecycleDispatchedUnitCount: Int)
    {
        self.receipt = receipt
        self.reason = reason
        self.cleanupOutcome = cleanupOutcome
        self.lifecycleDispatchedUnitCount = lifecycleDispatchedUnitCount
    }
}

public enum ExactWindowHeldPointerLifecycleError: LocalizedError, Equatable, Sendable {
    case ownerUnknown
    case ownerAlreadyHolding
    case ownerMismatch
    case receiptUnknown
    case receiptMismatch
    case ownerCapacityExceeded
    case invalidExpiry
    case cancelledBeforeDispatch
    case ownerDisconnectedBeforeDispatch
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .ownerUnknown:
            "Held pointer owner is not registered with this automation service"
        case .ownerAlreadyHolding:
            "Held pointer owner already has an active exact-window hold"
        case .ownerMismatch:
            "Held pointer receipt belongs to a different owner"
        case .receiptUnknown:
            "Held pointer receipt is unknown or no longer retained"
        case .receiptMismatch:
            "Held pointer receipt does not match the retained exact-window hold"
        case .ownerCapacityExceeded:
            "Held pointer owner capacity is exhausted; disconnect an idle owner before retrying"
        case .invalidExpiry:
            "Held pointer expiry must be finite and between 0.05 and 30 seconds"
        case .cancelledBeforeDispatch:
            "Held pointer request was cancelled before mouse-down dispatch"
        case .ownerDisconnectedBeforeDispatch:
            "Held pointer owner process generation exited before mouse-down dispatch"
        case let .operationFailed(message):
            message
        }
    }
}

@MainActor
private final class HeldPointerOneShot<Value: Sendable> {
    private var value: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    @discardableResult
    func resolve(_ value: Value) -> Bool {
        guard self.value == nil else { return false }
        self.value = value
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume(returning: value) }
        return true
    }

    func wait() async -> Value {
        if let value = self.value {
            return value
        }
        return await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    var resolvedValue: Value? {
        self.value
    }
}

@MainActor
final class ExactWindowHeldPointerLifecycle {
    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "HeldPointerLifecycle")
    private enum StartResolution: Sendable {
        case started(ExactWindowHeldPointerReceipt, dispatchedUnitCount: Int)
        case failed(HeldPointerFailure)
    }

    private enum TerminalResolution: Sendable {
        case terminated(ExactWindowHeldPointerTermination)
        case failed(DesktopActionFailure)
    }

    private enum HeldPointerFailure: Error, Sendable {
        case lifecycle(ExactWindowHeldPointerLifecycleError)
        case action(DesktopActionFailure)

        func throwValue() throws -> Never {
            switch self {
            case let .lifecycle(error): throw error
            case let .action(error): throw error
            }
        }
    }

    private struct OwnerState {
        let boundProcessIdentity: ApplicationProcessIdentity?
        var activeToken: UUID?
    }

    private struct HoldState {
        let owner: ExactWindowHeldPointerOwner
        let receipt: ExactWindowHeldPointerReceipt
        let expirationDeadline: ContinuousClock.Instant
        let start: HeldPointerOneShot<StartResolution>
        let terminalSignal: HeldPointerOneShot<ExactWindowHeldPointerTerminalReason>
        let terminal: HeldPointerOneShot<TerminalResolution>
        var lifecycleTask: Task<Void, Never>?
        var watchdogTask: Task<Void, Never>?
        var dispatch: WindowRoutedPointerDriver.HeldPointerDispatch?
        var downUnitCount = 0
        var completedAt: Date?
    }

    private let laneCoordinator: DesktopOperationLaneCoordinator
    private let pointerDriver: WindowRoutedPointerDriver
    private let processStartIdentityProvider: @Sendable (pid_t) -> UInt64?
    private let now: @MainActor @Sendable () -> Date
    private let monotonicNow: @MainActor @Sendable () -> ContinuousClock.Instant
    private let watchdogSleeper: @MainActor @Sendable () async throws -> Void
    private let beginResolutionHook: @MainActor @Sendable () async -> Void
    private let ownerCapacity: Int
    private let terminalRetentionCapacity: Int
    private let terminalRetentionDuration: TimeInterval
    private var owners: [ExactWindowHeldPointerOwner: OwnerState] = [:]
    private var holds: [UUID: HoldState] = [:]

    init(
        laneCoordinator: DesktopOperationLaneCoordinator,
        pointerDriver: WindowRoutedPointerDriver = WindowRoutedPointerDriver(),
        processStartIdentityProvider: @escaping @Sendable (pid_t) -> UInt64?,
        now: @escaping @MainActor @Sendable () -> Date = Date.init,
        monotonicNow: @escaping @MainActor @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        watchdogSleeper: @escaping @MainActor @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(20))
        },
        beginResolutionHook: @escaping @MainActor @Sendable () async -> Void = {},
        ownerCapacity: Int = 1024,
        terminalRetentionCapacity: Int = 256,
        terminalRetentionDuration: TimeInterval = 60)
    {
        self.laneCoordinator = laneCoordinator
        self.pointerDriver = pointerDriver
        self.processStartIdentityProvider = processStartIdentityProvider
        self.now = now
        self.monotonicNow = monotonicNow
        self.watchdogSleeper = watchdogSleeper
        self.beginResolutionHook = beginResolutionHook
        self.ownerCapacity = max(1, ownerCapacity)
        self.terminalRetentionCapacity = max(1, terminalRetentionCapacity)
        self.terminalRetentionDuration = max(0, terminalRetentionDuration)
    }

    func createOwner(boundTo processIdentity: ApplicationProcessIdentity?) throws -> ExactWindowHeldPointerOwner {
        self.pruneTerminalHolds()
        guard self.owners.count < self.ownerCapacity else {
            throw ExactWindowHeldPointerLifecycleError.ownerCapacityExceeded
        }
        var owner = ExactWindowHeldPointerOwner()
        while self.owners[owner] != nil {
            owner = ExactWindowHeldPointerOwner()
        }
        self.owners[owner] = OwnerState(boundProcessIdentity: processIdentity, activeToken: nil)
        return owner
    }

    func begin(
        owner: ExactWindowHeldPointerOwner,
        request: ExactWindowHeldPointerRequest) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerReceipt>
    {
        self.pruneTerminalHolds()
        guard request.expiresAfterSeconds.isFinite,
              (0.05...30).contains(request.expiresAfterSeconds)
        else { throw ExactWindowHeldPointerLifecycleError.invalidExpiry }
        guard var ownerState = self.owners[owner] else {
            throw ExactWindowHeldPointerLifecycleError.ownerUnknown
        }
        guard ownerState.activeToken == nil else {
            throw ExactWindowHeldPointerLifecycleError.ownerAlreadyHolding
        }
        _ = try UIAutomationTarget.ExactWindow(
            identity: request.windowIdentity,
            bounds: request.windowBounds)
        guard request.windowBounds.contains(request.point) else {
            throw ExactWindowHeldPointerLifecycleError.operationFailed(
                "Held pointer point is outside the exact target window bounds")
        }

        let token = UUID()
        let expirationDeadline = self.monotonicNow().advanced(by: .seconds(request.expiresAfterSeconds))
        let receipt = ExactWindowHeldPointerReceipt(
            token: token,
            owner: owner,
            request: request,
            expiresAt: self.now().addingTimeInterval(request.expiresAfterSeconds))
        let start = HeldPointerOneShot<StartResolution>()
        let terminalSignal = HeldPointerOneShot<ExactWindowHeldPointerTerminalReason>()
        let terminal = HeldPointerOneShot<TerminalResolution>()
        self.holds[token] = HoldState(
            owner: owner,
            receipt: receipt,
            expirationDeadline: expirationDeadline,
            start: start,
            terminalSignal: terminalSignal,
            terminal: terminal)
        ownerState.activeToken = token
        self.owners[owner] = ownerState

        let lifecycleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runHold(token: token, request: request)
        }
        self.holds[token]?.lifecycleTask = lifecycleTask

        let resolution = await withTaskCancellationHandler {
            await start.wait()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.signalTerminal(token: token, reason: .callerCancelled)
            }
        }
        await self.beginResolutionHook()
        switch resolution {
        case let .started(receipt, dispatchedUnitCount):
            if Task.isCancelled {
                self.signalTerminal(token: token, reason: .callerCancelled)
            }
            if let terminalReason = terminalSignal.resolvedValue {
                switch await terminal.wait() {
                case let .terminated(termination):
                    throw DesktopActionFailure.dispatchedUnverified(
                        delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                        evidence: .deliveryAccepted,
                        unitCount: DesktopActionOutcome.DispatchUnitCount(
                            termination.lifecycleDispatchedUnitCount),
                        message: "Held pointer ended before its begin receipt could be delivered.",
                        hint: "Do not treat the returned hold receipt as live or retry the pointer action blindly.",
                        causeDescription: "Terminal reason: \(terminalReason.rawValue)")
                case let .failed(failure):
                    throw failure
                }
            }
            return try UIAutomationActionResult(
                payload: receipt,
                outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                    evidence: .deliveryAccepted,
                    unitCount: DesktopActionOutcome.DispatchUnitCount(dispatchedUnitCount)),
                targetIdentity: DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                    identity: request.windowIdentity,
                    bounds: request.windowBounds)))
        case let .failed(failure):
            try failure.throwValue()
        }
    }

    func release(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt) async throws -> ExactWindowHeldPointerTermination
    {
        try await self.terminate(owner: owner, receipt: receipt, reason: .released)
    }

    func revoke(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt) async throws -> ExactWindowHeldPointerTermination
    {
        try await self.terminate(owner: owner, receipt: receipt, reason: .revoked)
    }

    func disconnect(owner: ExactWindowHeldPointerOwner) async throws -> ExactWindowHeldPointerTermination? {
        self.pruneTerminalHolds()
        guard let ownerState = self.owners[owner] else {
            throw ExactWindowHeldPointerLifecycleError.ownerUnknown
        }
        guard let token = ownerState.activeToken, let hold = self.holds[token] else {
            self.removeOwner(owner)
            return nil
        }
        self.signalTerminal(token: token, reason: .ownerDisconnected)
        let resolution = await hold.terminal.wait()
        self.closeOwner(owner, preserving: token)
        switch resolution {
        case let .terminated(termination): return termination
        case let .failed(failure): throw failure
        }
    }

    private func terminate(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt,
        reason: ExactWindowHeldPointerTerminalReason) async throws -> ExactWindowHeldPointerTermination
    {
        self.pruneTerminalHolds()
        guard receipt.ownerIdentifier == owner.identifier else {
            throw ExactWindowHeldPointerLifecycleError.ownerMismatch
        }
        guard let hold = self.holds[receipt.token] else {
            throw ExactWindowHeldPointerLifecycleError.receiptUnknown
        }
        guard hold.owner == owner else {
            throw ExactWindowHeldPointerLifecycleError.ownerMismatch
        }
        guard hold.receipt == receipt else {
            throw ExactWindowHeldPointerLifecycleError.receiptMismatch
        }
        guard self.owners[owner] != nil || hold.completedAt != nil else {
            throw ExactWindowHeldPointerLifecycleError.ownerUnknown
        }
        self.signalTerminal(token: receipt.token, reason: reason)
        switch await hold.terminal.wait() {
        case let .terminated(termination): return termination
        case let .failed(failure): throw failure
        }
    }

    private func runHold(token: UUID, request: ExactWindowHeldPointerRequest) async {
        guard let hold = self.holds[token] else { return }
        var completedTerminal: TerminalResolution?
        var completedReason: ExactWindowHeldPointerTerminalReason?
        do {
            try await self.laneCoordinator.run(scope: .window(request.windowIdentity), access: .write) {
                guard hold.terminalSignal.resolvedValue == nil else {
                    throw ExactWindowHeldPointerLifecycleError.cancelledBeforeDispatch
                }
                guard self.ownerBindingIsCurrent(hold.owner) else {
                    throw ExactWindowHeldPointerLifecycleError.ownerDisconnectedBeforeDispatch
                }
                guard self.monotonicNow() < hold.expirationDeadline else {
                    throw ExactWindowHeldPointerLifecycleError.cancelledBeforeDispatch
                }
                let dispatch = try self.pointerDriver.prepareHold(
                    at: request.point,
                    button: request.button.mouseButton,
                    target: ExactWindowPointerTarget(
                        identity: request.windowIdentity,
                        bounds: request.windowBounds))
                guard hold.terminalSignal.resolvedValue == nil else {
                    throw ExactWindowHeldPointerLifecycleError.cancelledBeforeDispatch
                }
                guard self.ownerBindingIsCurrent(hold.owner) else {
                    throw ExactWindowHeldPointerLifecycleError.ownerDisconnectedBeforeDispatch
                }
                guard self.monotonicNow() < hold.expirationDeadline else {
                    throw ExactWindowHeldPointerLifecycleError.cancelledBeforeDispatch
                }
                let downUnits = try await self.pointerDriver.postHeldDown(dispatch)
                self.holds[token]?.dispatch = dispatch
                self.holds[token]?.downUnitCount = downUnits
                hold.start.resolve(.started(hold.receipt, dispatchedUnitCount: downUnits))
                self.startWatchdog(token: token)

                let reason = await hold.terminalSignal.wait()
                completedReason = reason
                self.holds[token]?.watchdogTask?.cancel()
                completedTerminal = self.finishHold(
                    hold: hold,
                    dispatch: dispatch,
                    downUnitCount: downUnits,
                    reason: reason)
            }
        } catch {
            let failure = self.startFailure(error)
            if hold.start.resolve(.failed(failure)) {
                completedReason = hold.terminalSignal.resolvedValue ?? self.preDispatchTerminalReason(hold: hold)
                if let completedReason {
                    completedTerminal = .terminated(ExactWindowHeldPointerTermination(
                        receipt: hold.receipt,
                        reason: completedReason,
                        cleanupOutcome: .confirmedNoChange(),
                        lifecycleDispatchedUnitCount: 0))
                } else {
                    completedTerminal = .failed(self.preDispatchTerminalFailure(failure))
                }
            } else {
                completedTerminal = .failed(self.terminalFailure(
                    error,
                    downUnitCount: self.holds[token]?.downUnitCount ?? 0))
            }
        }
        self.holds[token]?.watchdogTask?.cancel()
        let closesOwner = completedReason == .ownerDisconnected
        if !closesOwner, var ownerState = self.owners[hold.owner], ownerState.activeToken == token {
            ownerState.activeToken = nil
            self.owners[hold.owner] = ownerState
        }
        if let completedTerminal {
            if case let .failed(failure) = completedTerminal {
                self.logger
                    .error("Held pointer terminal cleanup failed: \(failure.localizedDescription, privacy: .private)")
            }
            if closesOwner {
                self.closeOwner(hold.owner, preserving: token)
            }
            if var retained = self.holds[token] {
                retained.lifecycleTask = nil
                retained.watchdogTask = nil
                retained.dispatch = nil
                retained.completedAt = self.now()
                self.holds[token] = retained
            }
            self.pruneTerminalHolds()
            hold.terminal.resolve(completedTerminal)
        }
    }

    private func startWatchdog(token: UUID) {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.watch(token: token)
        }
        self.holds[token]?.watchdogTask = task
    }

    private func watch(token: UUID) async {
        while !Task.isCancelled {
            do {
                try await self.watchdogSleeper()
            } catch {
                return
            }
            guard let hold = self.holds[token],
                  hold.terminalSignal.resolvedValue == nil,
                  let dispatch = hold.dispatch
            else { return }

            if let binding = self.owners[hold.owner]?.boundProcessIdentity,
               self.processStartIdentityProvider(binding.processIdentifier) != binding.processStartIdentity
            {
                self.signalTerminal(token: token, reason: .ownerDisconnected)
                return
            }
            if self.monotonicNow() >= hold.expirationDeadline {
                self.signalTerminal(token: token, reason: .expired)
                return
            }
            switch self.pointerDriver.heldPointerRouteState(dispatch) {
            case .current:
                continue
            case .windowChanged:
                self.signalTerminal(token: token, reason: .windowChanged)
            case .processGenerationChanged:
                self.signalTerminal(token: token, reason: .processGenerationChanged)
            }
            return
        }
    }

    private func signalTerminal(token: UUID, reason: ExactWindowHeldPointerTerminalReason) {
        self.holds[token]?.terminalSignal.resolve(reason)
    }

    private func ownerBindingIsCurrent(_ owner: ExactWindowHeldPointerOwner) -> Bool {
        guard let binding = self.owners[owner]?.boundProcessIdentity else { return true }
        return self.processStartIdentityProvider(binding.processIdentifier) == binding.processStartIdentity
    }

    private func removeOwner(_ owner: ExactWindowHeldPointerOwner) {
        self.owners.removeValue(forKey: owner)
        self.holds = self.holds.filter { $0.value.owner != owner }
    }

    private func closeOwner(_ owner: ExactWindowHeldPointerOwner, preserving token: UUID) {
        self.owners.removeValue(forKey: owner)
        self.holds = self.holds.filter { candidate, hold in
            hold.owner != owner || candidate == token
        }
    }

    private func pruneTerminalHolds() {
        let current = self.now()
        let expiredTokens = self.holds.compactMap { token, hold -> UUID? in
            guard let completedAt = hold.completedAt else { return nil }
            return current.timeIntervalSince(completedAt) >= self.terminalRetentionDuration ? token : nil
        }
        for token in expiredTokens {
            self.holds.removeValue(forKey: token)
        }

        let completed = self.holds.compactMap { token, hold -> (UUID, Date)? in
            hold.completedAt.map { (token, $0) }
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 {
                return lhs.1 < rhs.1
            }
            return lhs.0.uuidString < rhs.0.uuidString
        }
        for (token, _) in completed.dropLast(self.terminalRetentionCapacity) {
            self.holds.removeValue(forKey: token)
        }
    }

    #if DEBUG
    var retainedHoldCountForTesting: Int {
        self.holds.count
    }

    var registeredOwnerCountForTesting: Int {
        self.owners.count
    }
    #endif

    private func finishHold(
        hold: HoldState,
        dispatch: WindowRoutedPointerDriver.HeldPointerDispatch,
        downUnitCount: Int,
        reason: ExactWindowHeldPointerTerminalReason) -> TerminalResolution
    {
        guard self.pointerDriver.heldPointerRouteState(dispatch) != .processGenerationChanged else {
            return .failed(self.missingCleanupFailure(
                downUnitCount: downUnitCount,
                reason: "The original process generation disappeared; mouse-up was not sent to a recycled PID"))
        }
        do {
            let cleanupUnits = try self.pointerDriver.postHeldRelease(dispatch)
            let cleanupCount = DesktopActionOutcome.DispatchUnitCount(cleanupUnits)
            let outcome = DesktopActionOutcome.dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: cleanupCount)
            return .terminated(ExactWindowHeldPointerTermination(
                receipt: hold.receipt,
                reason: reason,
                cleanupOutcome: outcome,
                lifecycleDispatchedUnitCount: downUnitCount + cleanupUnits))
        } catch {
            return .failed(self.missingCleanupFailure(
                downUnitCount: downUnitCount,
                reason: error.localizedDescription))
        }
    }

    private func startFailure(_ error: any Error) -> HeldPointerFailure {
        if let failure = error as? DesktopActionFailure {
            return .action(failure)
        }
        if let error = error as? InputDeliveryIndeterminateError {
            return .action(error.desktopActionFailure(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background)))
        }
        if let error = error as? ExactWindowHeldPointerLifecycleError {
            return .lifecycle(error)
        }
        return .lifecycle(.operationFailed(error.localizedDescription))
    }

    private func terminalFailure(_ error: any Error, downUnitCount: Int) -> DesktopActionFailure {
        if let failure = error as? DesktopActionFailure {
            return failure
        }
        return self.missingCleanupFailure(
            downUnitCount: downUnitCount,
            reason: error.localizedDescription)
    }

    private func preDispatchTerminalReason(hold: HoldState) -> ExactWindowHeldPointerTerminalReason? {
        if !self.ownerBindingIsCurrent(hold.owner) {
            return .ownerDisconnected
        }
        if self.monotonicNow() >= hold.expirationDeadline {
            return .expired
        }
        return nil
    }

    private func preDispatchTerminalFailure(_ failure: HeldPointerFailure) -> DesktopActionFailure {
        switch failure {
        case let .action(failure):
            return failure
        case let .lifecycle(error):
            let reason: DesktopActionOutcome.RefusalReason = switch error {
            case .cancelledBeforeDispatch:
                .requestCancelled
            case .invalidExpiry, .ownerMismatch, .receiptMismatch:
                .invalidRequest
            case .ownerUnknown, .ownerAlreadyHolding, .receiptUnknown, .ownerCapacityExceeded,
                 .ownerDisconnectedBeforeDispatch, .operationFailed:
                .targetUnavailable
            }
            return .preDispatchRefusal(
                reason: reason,
                message: "Held pointer did not start.",
                hint: "Refresh the exact target and owner state before retrying.",
                causeDescription: error.localizedDescription)
        }
    }

    private func missingCleanupFailure(downUnitCount: Int, reason: String) -> DesktopActionFailure {
        DesktopActionFailure.partial(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            unitCount: DesktopActionOutcome.DispatchUnitCount(downUnitCount),
            message: "Held pointer cleanup did not complete",
            hint: "The original target generation must be inspected before any further pointer input.",
            causeDescription: reason)
    }
}

extension UIAutomationService: ExactWindowHeldPointerLifecycleServiceProtocol {
    public var supportsExactWindowHeldPointerLifecycle: Bool {
        true
    }

    public func createExactWindowHeldPointerOwner(
        boundTo processIdentity: ApplicationProcessIdentity? = nil) async throws -> ExactWindowHeldPointerOwner
    {
        try self.heldPointerLifecycle.createOwner(boundTo: processIdentity)
    }

    public func beginExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        request: ExactWindowHeldPointerRequest) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerReceipt>
    {
        try await self.heldPointerLifecycle.begin(owner: owner, request: request)
    }

    public func releaseExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination>
    {
        let termination = try await self.heldPointerLifecycle.release(owner: owner, receipt: receipt)
        return try UIAutomationActionResult(
            payload: termination,
            outcome: termination.cleanupOutcome,
            targetIdentity: DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                identity: receipt.windowIdentity,
                bounds: receipt.windowBounds)))
    }

    public func revokeExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination>
    {
        let termination = try await self.heldPointerLifecycle.revoke(owner: owner, receipt: receipt)
        return try UIAutomationActionResult(
            payload: termination,
            outcome: termination.cleanupOutcome,
            targetIdentity: DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                identity: receipt.windowIdentity,
                bounds: receipt.windowBounds)))
    }

    public func disconnectExactWindowHeldPointerOwner(
        _ owner: ExactWindowHeldPointerOwner) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination?>
    {
        let termination = try await self.heldPointerLifecycle.disconnect(owner: owner)
        let identity = try termination.map {
            try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                identity: $0.receipt.windowIdentity,
                bounds: $0.receipt.windowBounds))
        }
        return UIAutomationActionResult(
            payload: termination,
            outcome: termination?.cleanupOutcome ?? .confirmedNoChange(),
            targetIdentity: identity)
    }
}
