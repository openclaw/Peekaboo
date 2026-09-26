import ApplicationServices
import struct AXorcist.Element
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct TargetedTypeInputPolicyTests {
    enum Payload: CaseIterable, Sendable {
        case text, key, clear

        var actions: [TypeAction] {
            switch self {
            case .text: [.text("ab")]
            case .key: [.key(.space)]
            case .clear: [.clear]
            }
        }

        var actionUnits: Int {
            self == .text ? 2 : 1
        }

        var eventUnits: Int {
            self == .key ? 1 : 2
        }
    }

    @Test(arguments: UIInputStrategy.allCases, Payload.allCases)
    func `policies never call forbidden text key or clear primitives`(
        strategy: UIInputStrategy,
        payload: Payload) async throws
    {
        for exactWindow in [false, true] {
            let fixture = Fixture()
            let result = try await fixture.run(payload.actions, strategy: strategy, exactWindow: exactWindow)
            let usesAccessibility = strategy == .actionOnly || strategy == .actionFirst
            let units = usesAccessibility ? payload.actionUnits : payload.eventUnits
            #expect(fixture.actionCalls.count == (usesAccessibility ? payload.actionUnits : 0))
            #expect(fixture.actionProcessIdentifiers == Array(
                repeating: getpid(), count: usesAccessibility ? payload.actionUnits : 0))
            #expect(fixture.actionWindows == Array(
                repeating: fixture.requestedExactWindow, count: usesAccessibility ? payload.actionUnits : 0))
            #expect(fixture.actionReceiverIdentities == Array(
                repeating: fixture.providedReceiver.map { ObjectIdentifier($0.underlyingElement) },
                count: usesAccessibility ? payload.actionUnits : 0))
            #expect(fixture.actionPhases.map { $0 == .initial } == (usesAccessibility
                    ? [true] + Array(repeating: false, count: payload.actionUnits - 1) : []))
            #expect(fixture.eventCalls.count == (usesAccessibility ? 0 : payload.eventUnits))
            #expect(result.result.keyPresses == (usesAccessibility ? 0 : payload.eventUnits))
            #expect(result.result.specialKeyPresses == (usesAccessibility || payload == .text ? 0 : payload.eventUnits))
            #expect(result.executionResult.strategy == strategy)
            #expect(result.executionResult.path == (usesAccessibility ? .action : .synth))
            #expect(result.executionResult.outcome.dispatchState.unitCount?.rawValue == units)
            #expect(result.executionResult.outcome.delivery?.mechanism == (usesAccessibility
                    ? .accessibilityValue : exactWindow ? .windowTargetedEvents : .processTargetedEvents))
            #expect(fixture.bundleLookups == 1)
            #expect(fixture.finalizations == 1)
            if payload == .clear, !usesAccessibility {
                #expect(fixture.eventCalls == ["key:0:1048576", "key:51:0"])
                #expect(fixture.validationEventCounts == [0, 1, 2])
            }
        }
    }

    @Test(arguments: [false, true])
    func `native text key and clear retain the receiver receipt after an accepted prefix`(
        exactWindow: Bool) async throws
    {
        let fixture = Fixture()
        _ = try await fixture.run(
            [.text("ab"), .key(.space), .clear], strategy: .actionOnly, exactWindow: exactWindow)

        #expect(fixture.actionCalls == ["insert:a", "insert:b", "edit:space", "clear"])
        #expect(fixture.actionProcessIdentifiers == Array(repeating: getpid(), count: 4))
        #expect(fixture.actionWindows == Array(repeating: fixture.requestedExactWindow, count: 4))
        #expect(fixture.actionReceiverIdentities == Array(
            repeating: fixture.providedReceiver.map { ObjectIdentifier($0.underlyingElement) }, count: 4))
        #expect(fixture.actionPhases.map { $0 == .initial } == [true, false, false, false])
        #expect(fixture.eventCalls.isEmpty)
    }

    @Test(arguments: Payload.allCases)
    func `action-first falls back only for each unsupported unit`(payload: Payload) async throws {
        let fixture = Fixture()
        fixture.actionResult = .unsupported
        let result = try await fixture.run(payload.actions, strategy: .actionFirst)
        #expect(fixture.actionCalls.count == payload.actionUnits)
        #expect(fixture.eventCalls.count == payload.eventUnits)
        #expect(result.executionResult.fallbackReason == .attributeUnsupported)
        #expect(result.executionResult.outcome.dispatchState.unitCount?.rawValue == payload.eventUnits)
    }

    @Test(arguments: Payload.allCases, [false, true])
    func `cancelled unsupported AX attempt cannot dispatch fallback events`(
        payload: Payload,
        hasPrefix: Bool) async throws
    {
        let fixture = Fixture()
        fixture.actionResult = .unsupported
        fixture.actionResults = hasPrefix ? [.accessibilityValue] : []
        fixture.suspendActionAt = hasPrefix ? 2 : 1
        let actions = (hasPrefix ? [TypeAction.text("p")] : []) + payload.actions
        let operation = Task { @MainActor in try await fixture.run(actions, strategy: .actionFirst) }
        guard await fixture.entered.opensWithin(.seconds(2)) else {
            operation.cancel()
            await fixture.release.open()
            _ = try? await operation.value
            Issue.record("The unsupported AX attempt did not reach its gate")
            return
        }
        operation.cancel()
        await fixture.release.open()

        if hasPrefix {
            let failure = await #expect(throws: InputDeliveryIndeterminateError.self) { try await operation.value }
            #expect(failure?.emittedUnitCount == 1)
            #expect(failure?.retrySafe == false)
            #expect(failure?.delivery?.mechanism == .accessibilityValue)
        } else {
            await #expect(throws: CancellationError.self) { try await operation.value }
        }
        #expect(fixture.actionCalls.count == (hasPrefix ? 2 : 1))
        #expect(fixture.eventCalls.isEmpty)
        #expect(fixture.eventPermissionChecks == 0)
        #expect(fixture.finalizations == 1)
    }

    @Test(arguments: [UIInputStrategy.actionFirst, .actionOnly], Payload.allCases)
    func `uncancelled unsupported AX return retains its strategy`(
        strategy: UIInputStrategy,
        payload: Payload) async throws
    {
        let fixture = Fixture()
        fixture.actionResult = .unsupported
        fixture.suspendActionAt = 1
        let operation = Task { @MainActor in try await fixture.run(payload.actions, strategy: strategy) }
        guard await fixture.entered.opensWithin(.seconds(2)) else {
            operation.cancel()
            await fixture.release.open()
            _ = try? await operation.value
            Issue.record("The unsupported AX strategy control did not reach its gate")
            return
        }
        await fixture.release.open()

        if strategy == .actionOnly {
            let failure = await #expect(throws: DesktopActionFailure.self) { try await operation.value }
            #expect(failure?.outcome.state == .refused)
            #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
            #expect(failure?.outcome.retrySafety == .safe)
            #expect(fixture.actionCalls.count == 1)
            #expect(fixture.eventCalls.isEmpty)
        } else {
            let result = try await operation.value
            #expect(result.executionResult.outcome.dispatchState.unitCount?.rawValue == payload.eventUnits)
            #expect(fixture.actionCalls.count == payload.actionUnits)
            #expect(fixture.eventCalls.count == payload.eventUnits)
        }
        #expect(fixture.finalizations == 1)
    }

    @Test(arguments: [false, true])
    func `cancelled clear before Delete retains accepted selection and earlier prefix`(hasPrefix: Bool) async throws {
        let fixture = Fixture()
        fixture.actionResult = .unsupported
        fixture.actionResults = hasPrefix ? [.accessibilityValue] : []
        fixture.suspendContinuationAtEventCount = 1
        let actions: [TypeAction] = hasPrefix ? [.text("p"), .clear] : [.clear]
        let operation = Task { @MainActor in try await fixture.run(actions, strategy: .actionFirst) }
        guard await fixture.entered.opensWithin(.seconds(2)) else {
            operation.cancel()
            await fixture.release.open()
            _ = try? await operation.value
            Issue.record("Keyboard clear did not reach continuation after Cmd-A")
            return
        }
        #expect(fixture.eventCalls == ["key:0:1048576"])
        operation.cancel()
        await fixture.release.open()

        let failure = await #expect(throws: InputDeliveryIndeterminateError.self) { try await operation.value }
        #expect(failure?.emittedUnitCount == (hasPrefix ? 2 : 1))
        #expect(failure?.retrySafe == false)
        #expect(failure?.delivery?.mechanism == (hasPrefix ? .composite : .windowTargetedEvents))
        #expect(fixture.actionCalls.count == (hasPrefix ? 2 : 1))
        #expect(fixture.eventCalls == ["key:0:1048576"])
        #expect(fixture.eventPermissionChecks == 1)
        #expect(fixture.finalizations == 1)
    }

    @Test
    func `event admission cancellation never interrupts a keyboard pair already entered`() async throws {
        var events: [String] = []
        let driver = TargetedTypeInputDriver(tapKey: { _, _, _ in
            events.append("down")
            withUnsafeCurrentTask { $0?.cancel() }
            events.append("up")
        })
        let operation = Task { @MainActor in
            try driver.tapKeyboardKey(0, flags: [], processIdentifier: getpid())
            #expect(events == ["down", "up"])
            #expect(throws: CancellationError.self) {
                try driver.tapKeyboardKey(0, flags: [], processIdentifier: getpid())
            }
        }
        try await operation.value
        #expect(events == ["down", "up"])
    }

    @Test(arguments: Payload.allCases)
    func `action-only refuses unsupported edits without events`(payload: Payload) async throws {
        let fixture = Fixture()
        fixture.actionResult = .unsupported
        await #expect(throws: DesktopActionFailure.self) {
            do {
                _ = try await fixture.run(payload.actions, strategy: .actionOnly)
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.dispatchState == .none)
                throw failure
            }
        }
        #expect(fixture.actionCalls.count == 1)
        #expect(fixture.eventCalls.isEmpty)
        #expect(fixture.eventPermissionChecks == 0)
        #expect(fixture.finalizations == 1)
    }

    @Test(arguments: [SpecialKey.return, .tab, .escape])
    func `action-only refuses event-only special keys`(key: SpecialKey) async throws {
        let fixture = Fixture()
        fixture.actionResult = .unsupported
        await #expect(throws: DesktopActionFailure.self) {
            _ = try await fixture.run([.key(key)], strategy: .actionOnly)
        }
        #expect(fixture.actionCalls == ["edit:\(key.rawValue)"])
        #expect(fixture.eventCalls.isEmpty)
    }

    @Test(arguments: [UIInputStrategy.actionOnly, .actionFirst])
    func `no-change editing key never falls back`(strategy: UIInputStrategy) async throws {
        let fixture = Fixture()
        fixture.actionResult = .noChange
        let result = try await fixture.run([.key(.delete)], strategy: strategy)
        #expect(fixture.actionCalls.count == 1)
        #expect(fixture.eventCalls.isEmpty)
        #expect(result.executionResult.outcome.state == .confirmedNoChange)
        #expect(result.executionResult.outcome.dispatchState == .none)
        #expect(result.result.keyPresses == 0)
    }

    @Test(arguments: Payload.allCases)
    func `default native edits do not need event permission`(payload: Payload) async throws {
        let fixture = Fixture()
        fixture.eventPermissionGranted = false
        let result = try await fixture.run(payload.actions, policy: .currentBehavior)
        #expect(result.executionResult.strategy == .actionFirst)
        #expect(fixture.actionCalls.count == payload.actionUnits)
        #expect(fixture.eventPermissionChecks == 0)
        #expect(fixture.eventCalls.isEmpty)
    }

    @Test(arguments: [UIInputStrategy.actionFirst, .synthFirst, .synthOnly], Payload.allCases)
    func `event permission denial is checked only before needed events`(
        strategy: UIInputStrategy,
        payload: Payload) async throws
    {
        let fixture = Fixture()
        fixture.actionResult = .unsupported
        fixture.eventPermissionGranted = false
        await #expect(throws: DesktopActionFailure.self) {
            _ = try await fixture.run(payload.actions, strategy: strategy)
        }
        #expect(fixture.actionCalls.count == (strategy == .actionFirst ? 1 : 0))
        #expect(fixture.eventPermissionChecks == 1)
        #expect(fixture.eventCalls.isEmpty)
    }

    @Test(arguments: [UIInputStrategy.synthFirst, .synthOnly])
    func `per-app strategy uses pinned target bundle once not foreground or later lookup`(
        strategy: UIInputStrategy) async throws
    {
        let fixture = Fixture()
        let policy = UIInputPolicy(type: .actionOnly, perApp: ["com.example.target": .init(type: strategy)])
        let result = try await fixture.run([.text("ab"), .key(.space), .clear], policy: policy)
        #expect(result.executionResult.strategy == strategy)
        #expect(result.executionResult.bundleIdentifier == "com.example.target")
        #expect(fixture.bundleLookups == 1)
        #expect(fixture.actionCalls.isEmpty)
        #expect(fixture.eventCalls.count == 5)
    }

    @Test
    func `unknown target bundle keeps global policy without frontmost substitution`() async throws {
        let fixture = Fixture()
        fixture.bundle = nil
        let policy = UIInputPolicy(type: .synthOnly, perApp: ["com.example.target": .init(type: .actionOnly)])
        let result = try await fixture.run([.text("a")], policy: policy)
        #expect(result.executionResult.strategy == .synthOnly)
        #expect(result.executionResult.bundleIdentifier == nil)
        #expect(fixture.actionCalls.isEmpty)
        #expect(fixture.eventCalls.count == 1)
    }

    @Test(arguments: [UIInputStrategy.actionFirst, .synthFirst, .synthOnly], Payload.allCases)
    func `uncertain keyboard delivery never retries through AX or repeats input`(
        strategy: UIInputStrategy,
        payload: Payload) async throws
    {
        let fixture = Fixture()
        fixture.actionResult = .unsupported
        fixture.eventThrowsAfterDispatch = true
        await #expect(throws: InputDeliveryIndeterminateError.self) {
            _ = try await fixture.run(payload.actions, strategy: strategy)
        }
        #expect(fixture.actionCalls.count == (strategy == .actionFirst ? 1 : 0))
        #expect(fixture.eventCalls.count == 1)
    }

    @Test
    func `mixed action-first delivery never replays the accepted prefix`() async throws {
        let fixture = Fixture()
        fixture.actionResults = [.accessibilityValue, .unsupported]
        let result = try await fixture.run([.text("ab")], strategy: .actionFirst)
        #expect(fixture.actionCalls == ["insert:a", "insert:b"])
        #expect(fixture.eventCalls == ["text:b"])
        #expect(result.result.keyPresses == 1)
        #expect(result.executionResult.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(result.executionResult.outcome.delivery?.mechanism == .composite)
    }

    @Test
    func `action-only refusal after a native prefix retains unsafe prefix evidence`() async throws {
        let fixture = Fixture()
        fixture.actionResults = [.accessibilityValue, .unsupported]
        do {
            _ = try await fixture.run([.text("ab")], strategy: .actionOnly)
            Issue.record("Expected a prefix failure")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.emittedUnitCount == 1)
            #expect(error.retrySafe == false)
            #expect(error.delivery?.mechanism == .accessibilityValue)
        }
        #expect(fixture.actionCalls == ["insert:a", "insert:b"])
        #expect(fixture.eventCalls.isEmpty)
    }

    @Test(arguments: Payload.allCases)
    func `uncertain accessibility setter never enables event fallback`(payload: Payload) async throws {
        let fixture = Fixture()
        fixture.actionError = .cannotComplete
        await #expect(throws: InputDeliveryIndeterminateError.self) {
            _ = try await fixture.run(payload.actions, strategy: .actionFirst)
        }
        #expect(fixture.actionCalls.count == 1)
        #expect(fixture.eventPermissionChecks == 0)
        #expect(fixture.eventCalls.isEmpty)
    }

    @Test
    func `uncertain second AX write retains known prefix without replay`() async throws {
        let fixture = Fixture()
        fixture.actionError = .cannotComplete
        fixture.actionErrorAt = 2
        do {
            _ = try await fixture.run([.text("ab")], strategy: .actionFirst)
            Issue.record("Expected uncertain setter failure")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.emittedUnitCount == 1)
            #expect(error.delivery?.mechanism == .accessibilityValue)
        }
        #expect(fixture.eventCalls.isEmpty)
        #expect(fixture.actionCalls == ["insert:a", "insert:b"])
    }

    @Test
    func `keyboard clear stops after selection if target continuation fails`() async throws {
        let fixture = Fixture()
        fixture.failContinuation = true
        do {
            _ = try await fixture.run([.clear], strategy: .synthOnly)
            Issue.record("Expected continuation refusal")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.emittedUnitCount == 1)
            #expect(error.delivery?.mechanism == .windowTargetedEvents)
        }
        #expect(fixture.actionCalls.isEmpty)
        #expect(fixture.eventCalls == ["key:0:1048576"])
    }

    @Test(arguments: [AXError.attributeUnsupported, .parameterizedAttributeUnsupported, .actionUnsupported])
    func `only conclusively unsupported setter errors permit fallback`(error: AXError) throws {
        #expect(try BackgroundInputDriver.textMutationAccepted(error) == false)
    }

    @Test(arguments: [AXError.cannotComplete, .failure, .notImplemented, .illegalArgument, .noValue])
    func `ambiguous and unrecognized setter errors remain indeterminate`(error: AXError) {
        #expect(throws: InputDeliveryIndeterminateError.self) {
            try BackgroundInputDriver.textMutationAccepted(error)
        }
    }

    @Test(arguments: [AXError.apiDisabled, .invalidUIElement, .invalidUIElementObserver])
    func `permission and stale receiver errors refuse without events`(error: AXError) {
        #expect(throws: DesktopActionFailure.self) {
            try BackgroundInputDriver.textMutationAccepted(error)
        }
    }

    @Test
    func `selection mutation failure retains hotkey operation ownership`() {
        do {
            _ = try BackgroundInputDriver.textMutationAccepted(.cannotComplete, operation: .hotkey)
            Issue.record("Expected indeterminate selection mutation")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.operation == .hotkey)
            #expect(error.delivery?.mechanism == .accessibilityValue)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@MainActor
private final class Fixture {
    var actionCalls: [String] = []
    var actionProcessIdentifiers: [pid_t] = []
    var actionWindows: [UIAutomationTarget.ExactWindow?] = []
    var actionPhases: [KeyboardFocusValidationPhase] = []
    var actionReceiverIdentities: [ObjectIdentifier?] = []
    var providedReceiver: Element?
    var requestedExactWindow: UIAutomationTarget.ExactWindow?
    var eventCalls: [String] = []
    var validationEventCounts: [Int] = []
    var actionResult = FocusedTextKeyDispatch.accessibilityValue
    var actionResults: [FocusedTextKeyDispatch] = []
    var actionError: AXError?
    var actionErrorAt = 1
    var eventPermissionGranted = true
    var eventPermissionChecks = 0
    var eventThrowsAfterDispatch = false
    var bundle: String? = "com.example.target"
    var bundleLookups = 0
    var finalizations = 0
    var failContinuation = false
    let entered = ActionLaneLatch()
    let release = ActionLaneLatch()
    var suspendActionAt: Int?
    var suspendContinuationAtEventCount: Int?

    func run(
        _ actions: [TypeAction],
        strategy: UIInputStrategy,
        exactWindow: Bool = true) async throws -> TypeService.TypeActionExecutionSummary
    {
        try await self.run(actions, policy: UIInputPolicy(defaultStrategy: strategy), exactWindow: exactWindow)
    }

    func run(
        _ actions: [TypeAction],
        policy: UIInputPolicy,
        exactWindow: Bool = true) async throws -> TypeService.TypeActionExecutionSummary
    {
        let coordinationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-targeted-typing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: coordinationRoot) }
        let driver = TargetedTypeInputDriver(
            insertText: { text, pid, window, phase, receiver in
                try await self.action(
                    "insert:\(text)", processIdentifier: pid, exactWindow: window, phase: phase, receiver: receiver)
            },
            performTextKey: { key, pid, window, phase, receiver in
                try await self.action(
                    "edit:\(key.rawValue)",
                    processIdentifier: pid,
                    exactWindow: window,
                    phase: phase,
                    receiver: receiver)
            },
            replaceText: { _, pid, window, phase, receiver in
                try await self.action(
                    "clear", processIdentifier: pid, exactWindow: window, phase: phase, receiver: receiver)
            },
            typeCharacter: { character, _ in try self.event("text:\(character)") },
            tapKey: { code, flags, _ in try self.event("key:\(code):\(flags.rawValue)") })
        let service = TypeService(
            inputPolicy: policy,
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedInputDriver: driver,
            targetBundleIdentifier: { _ in
                self.bundleLookups += 1
                return self.bundleLookups == 1 ? self.bundle : "com.example.different"
            },
            desktopOperationExecutor: DesktopOperationExecutor(
                laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: coordinationRoot)),
            operationFinalizer: { self.finalizations += 1 })
        let process = ApplicationProcessIdentity(processIdentifier: getpid(), processStartIdentity: 91)
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let target: UIAutomationTarget = try exactWindow ? .exactWindow(.init(
            identity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: process.processIdentifier,
                ownerProcessStartIdentity: process.processStartIdentity,
                capturedBounds: bounds),
            bounds: bounds)) : .process(.init(processIdentifier: process.processIdentifier, identity: process))
        self.requestedExactWindow = target.exactWindow
        self.providedReceiver = exactWindow ? Element(AXUIElementCreateApplication(process.processIdentifier)) : nil
        return try await service.typeActionsTrackingSecureInput(
            actions,
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: target,
            deliveryValidator: { self.validationEventCounts.append(self.eventCalls.count) },
            continuationValidator: {
                self.validationEventCounts.append(self.eventCalls.count)
                if self.suspendContinuationAtEventCount == self.eventCalls.count {
                    await self.entered.open()
                    await self.release.wait()
                }
                if self.failContinuation {
                    throw DesktopActionFailure.preDispatchRefusal(
                        reason: .targetUnavailable,
                        message: "Synthetic fixture target changed")
                }
            },
            validatedReceiverProvider: { self.providedReceiver })
    }

    private func action(
        _ name: String,
        processIdentifier: pid_t,
        exactWindow: UIAutomationTarget.ExactWindow?,
        phase: KeyboardFocusValidationPhase,
        receiver: Element?) async throws -> FocusedTextKeyDispatch
    {
        self.actionCalls.append(name)
        self.actionProcessIdentifiers.append(processIdentifier)
        self.actionWindows.append(exactWindow)
        self.actionPhases.append(phase)
        self.actionReceiverIdentities.append(receiver.map { ObjectIdentifier($0.underlyingElement) })
        if self.actionCalls.count == self.suspendActionAt {
            await self.entered.open()
            await self.release.wait()
        }
        if let actionError, self.actionCalls.count == self.actionErrorAt {
            _ = try BackgroundInputDriver.textMutationAccepted(actionError)
        }
        return self.actionResults.isEmpty ? self.actionResult : self.actionResults.removeFirst()
    }

    private func event(_ name: String) throws {
        self.eventPermissionChecks += 1
        guard self.eventPermissionGranted else { throw PeekabooError.permissionDeniedEventSynthesizing }
        self.eventCalls.append(name)
        if self.eventThrowsAfterDispatch {
            throw InputDeliveryIndeterminateError(
                operation: .type,
                emittedUnitCount: 1,
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background))
        }
    }
}
