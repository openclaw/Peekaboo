import ApplicationServices
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct TypingFinalReceiverBindingTests {
    enum Payload: CaseIterable, Sendable {
        case text, clear, editingKey

        var actions: [TypeAction] {
            switch self {
            case .text: [.text("x")]
            case .clear: [.clear]
            case .editingKey: [.key(.leftArrow)]
            }
        }
    }

    @Test(arguments: [UIInputStrategy.actionFirst, .actionOnly], Payload.allCases)
    func `native typing refuses a sibling selected after receipt validation`(
        strategy: UIInputStrategy,
        payload: Payload) async
    {
        let fixture = TypingReceiverFixture()
        fixture.switchAfterValidation = 1
        await self.expectRefusal {
            _ = try await fixture.run(payload.actions, strategy: strategy)
        }

        #expect(fixture.validatedReceivers == [.a])
        #expect(fixture.nativeLookups == [.b])
        #expect(fixture.textWrites.isEmpty)
        #expect(fixture.selectionWrites.isEmpty)
        #expect(fixture.events.isEmpty)
        #expect(fixture.values[.a] == "alpha")
        #expect(fixture.values[.b] == "bravo")
    }

    @Test(arguments: [UIInputStrategy.actionFirst, .actionOnly], Payload.allCases)
    func `a noneditable sibling cannot turn receiver drift into event fallback`(
        strategy: UIInputStrategy,
        payload: Payload) async
    {
        let fixture = TypingReceiverFixture()
        fixture.switchAfterValidation = 1
        fixture.editable[.b] = false
        await self.expectRefusal {
            _ = try await fixture.run(payload.actions, strategy: strategy)
        }
        #expect(fixture.nativeLookups == [.b])
        #expect(fixture.editabilityReads.isEmpty)
        #expect(fixture.textWrites.isEmpty)
        #expect(fixture.selectionWrites.isEmpty)
        #expect(fixture.events.isEmpty)
    }

    @Test(arguments: [true, false], Payload.allCases)
    func `a focused receipt requires both validated and observed native proof`(
        missingValidatedProof: Bool,
        payload: Payload) async
    {
        let fixture = TypingReceiverFixture()
        fixture.providesNativeProof = !missingValidatedProof
        fixture.snapshotIncludesNativeProof = missingValidatedProof
        fixture.routes[.a] = .web
        await self.expectRefusal { _ = try await fixture.run(payload.actions) }
        #expect(fixture.nativeLookups == [.a])
        #expect(fixture.editabilityReads.isEmpty)
        #expect(fixture.routeChecks.isEmpty)
        #expect(fixture.textValueReads.isEmpty)
        #expect(fixture.selectedRangeReads.isEmpty)
        #expect(fixture.textWrites.isEmpty)
        #expect(fixture.selectionWrites.isEmpty)
        #expect(fixture.events.isEmpty)
    }

    @Test(arguments: [UIInputStrategy.actionFirst, .actionOnly], Payload.allCases)
    func `an accepted prefix cannot rebind after continuation validation`(
        strategy: UIInputStrategy,
        payload: Payload) async
    {
        let fixture = TypingReceiverFixture()
        fixture.identifiers[.b] = "a"
        fixture.frames[.b] = TypingReceiverFixture.reflowedFrame
        fixture.switchAfterValidation = 2
        do {
            _ = try await fixture.run([.text("p")] + payload.actions, strategy: strategy)
            Issue.record("Expected the sibling receiver to stop continuation")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.operation == .type)
            #expect(error.emittedUnitCount == 1)
            #expect(error.retrySafe == false)
            let failure = error.desktopActionFailure(delivery: nil)
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 1)
        } catch {
            Issue.record("Expected accepted-prefix evidence, got \(error)")
        }
        #expect(fixture.validatedReceivers == [.a, .a])
        #expect(fixture.nativeLookups == [.a, .b])
        #expect(fixture.nativePhases.map { $0 == .initial } == [true, false])
        #expect(fixture.textWrites == [.a])
        #expect(fixture.selectionWrites == [.a])
        #expect(fixture.events.isEmpty)
        #expect(fixture.values[.a] == "alphap")
        #expect(fixture.values[.b] == "bravo")
    }

    @Test(arguments: [UIInputStrategy.actionFirst, .actionOnly], Payload.allCases)
    func `the retained receiver can reflow after an accepted prefix`(
        strategy: UIInputStrategy,
        payload: Payload) async throws
    {
        let fixture = TypingReceiverFixture()
        fixture.reflowAfterTextWrite = 1
        let result = try await fixture.run([.text("p")] + payload.actions, strategy: strategy)
        #expect(fixture.nativeLookups == [.a, .a])
        #expect(fixture.nativePhases.map { $0 == .initial } == [true, false])
        #expect(!fixture.textWrites.contains(.b))
        #expect(!fixture.selectionWrites.contains(.b))
        #expect(fixture.events.isEmpty)
        #expect(result.executionResult.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(result.executionResult.outcome.delivery?.mechanism == .accessibilityValue)
    }

    @Test(arguments: Payload.allCases)
    func `a stable retained receiver accepts native edits`(payload: Payload) async throws {
        let fixture = TypingReceiverFixture()
        let result = try await fixture.run(payload.actions)
        #expect(fixture.nativeLookups == [.a])
        #expect(fixture.nativePhases.map { $0 == .initial } == [true])
        #expect(result.executionResult.outcome.dispatchState.unitCount?.rawValue == 1)
        #expect(result.executionResult.outcome.delivery?.mechanism == .accessibilityValue)
        #expect(fixture.events.isEmpty)
    }

    @Test(arguments: [false, true], Payload.allCases)
    func `built in targeted typing uses AX without checking event permission`(
        exactWindow: Bool,
        payload: Payload) async throws
    {
        let fixture = TypingReceiverFixture()
        fixture.eventPermissionGranted = false
        let result = try await fixture.run(
            payload.actions, policy: .currentBehavior, exactWindow: exactWindow)
        #expect(result.executionResult.strategy == .actionFirst)
        #expect(result.executionResult.path == .action)
        #expect(result.executionResult.outcome.delivery?.mechanism == .accessibilityValue)
        #expect(result.executionResult.outcome.dispatchState.unitCount?.rawValue == 1)
        #expect(result.result.keyPresses == 0)
        #expect(fixture.nativeLookups == [.a])
        #expect(fixture.events.isEmpty)
        #expect(fixture.eventPermissionChecks == 0)
    }

    @Test(arguments: [false, true])
    func `explicit synthetic overrides still control targeted delivery`(perApp: Bool) async throws {
        var policy = UIInputPolicy.currentBehavior
        if perApp {
            policy.perApp["example.typing-receiver-fixture"] = AppUIInputPolicy(type: .synthFirst)
        } else {
            // Assigning the same value still represents an explicit caller override.
            #expect(policy.defaultStrategy == .synthFirst)
            policy.defaultStrategy = .synthFirst
        }
        let fixture = TypingReceiverFixture()
        let result = try await fixture.run([.text("x")], policy: policy)
        #expect(result.executionResult.strategy == .synthFirst)
        #expect(result.executionResult.path == .synth)
        #expect(result.executionResult.outcome.delivery?.mechanism == .windowTargetedEvents)
        #expect(fixture.nativeLookups.isEmpty)
        #expect(fixture.events == ["text:x"])
        #expect(fixture.eventPermissionChecks == 1)
    }

    @Test
    func `a no change key does not advance the receiver validation phase`() async throws {
        let fixture = TypingReceiverFixture()
        fixture.selections[.a] = CFRange(location: 0, length: 0)
        let result = try await fixture.run([.key(.delete), .text("x")])
        #expect(fixture.nativePhases.map { $0 == .initial } == [true, true])
        #expect(fixture.textWrites == [.a])
        #expect(result.executionResult.outcome.dispatchState.unitCount?.rawValue == 1)
    }

    @Test(arguments: [true, false])
    func `window only and process only routes retain current focus behavior`(exactWindow: Bool) async throws {
        let fixture = TypingReceiverFixture()
        fixture.focusedReceiver = .b
        fixture.providesNativeProof = false
        fixture.snapshotIncludesNativeProof = false
        let result = try await fixture.run([.text("x")], exactWindow: exactWindow, focusedReceipt: false)
        #expect(fixture.nativeLookups == [.b])
        #expect(fixture.textWrites == [.b])
        #expect(fixture.values[.b] == "bravox")
        #expect(fixture.events.isEmpty)
        #expect(result.executionResult.outcome.dispatchState.unitCount?.rawValue == 1)
    }

    @Test(arguments: [UIInputStrategy.synthFirst, .synthOnly], Payload.allCases)
    func `explicit synthetic strategies never resolve a native edit receiver`(
        strategy: UIInputStrategy,
        payload: Payload) async throws
    {
        let fixture = TypingReceiverFixture()
        fixture.providesNativeProof = false
        fixture.snapshotIncludesNativeProof = false
        let result = try await fixture.run(payload.actions, strategy: strategy)
        #expect(fixture.nativeLookups.isEmpty)
        #expect(fixture.nativePhases.isEmpty)
        #expect(fixture.textWrites.isEmpty)
        #expect(fixture.selectionWrites.isEmpty)
        #expect(fixture.events.count == (payload == .clear ? 2 : 1))
        #expect(result.executionResult.outcome.delivery?.mechanism == .windowTargetedEvents)
    }

    @Test(arguments: [false, true], Payload.allCases)
    func `a changed or missing receiver refuses before considering a web route`(
        missingReceiver: Bool,
        payload: Payload) async
    {
        let fixture = TypingReceiverFixture()
        fixture.routes = [.a: .web, .b: .web]
        fixture.nativeReceiverAvailable = !missingReceiver
        fixture.switchAfterValidation = missingReceiver ? nil : 1
        await self.expectRefusal { _ = try await fixture.run(payload.actions) }
        #expect(fixture.validatedReceivers == [.a])
        #expect(fixture.nativeLookups.count == 1)
        #expect(fixture.editabilityReads.isEmpty)
        #expect(fixture.routeChecks.isEmpty)
        #expect(fixture.textValueReads.isEmpty)
        #expect(fixture.selectedRangeReads.isEmpty)
        #expect(fixture.textWrites.isEmpty)
        #expect(fixture.selectionWrites.isEmpty)
        #expect(fixture.events.isEmpty)
    }

    @Test(arguments: [UIInputStrategy.actionFirst, .actionOnly], Payload.allCases)
    func `a retained web receiver permits only policy allowed event delivery`(
        strategy: UIInputStrategy,
        payload: Payload) async throws
    {
        let fixture = TypingReceiverFixture()
        fixture.routes[.a] = .web
        if strategy == .actionOnly {
            await self.expectRefusal(reason: .operationUnsupported) {
                _ = try await fixture.run(payload.actions, strategy: strategy)
            }
            #expect(fixture.events.isEmpty)
        } else {
            let result = try await fixture.run(payload.actions, strategy: strategy)
            let units = payload == .clear ? 2 : 1
            #expect(fixture.events.count == units)
            #expect(result.result.keyPresses == units)
            #expect(result.executionResult.outcome.dispatchState.unitCount?.rawValue == units)
            #expect(result.executionResult.outcome.delivery?.mechanism == .windowTargetedEvents)
            #expect(result.executionResult.fallbackReason == .attributeUnsupported)
        }
        #expect(fixture.nativeLookups == [.a])
        #expect(fixture.editabilityReads == [.a])
        #expect(fixture.routeChecks == [.a])
        #expect(fixture.textValueReads.isEmpty)
        #expect(fixture.selectedRangeReads.isEmpty)
        #expect(fixture.textWrites.isEmpty)
        #expect(fixture.selectionWrites.isEmpty)
    }

    @Test(arguments: [UIInputStrategy.actionFirst, .actionOnly], Payload.allCases)
    func `an unproven retained route refuses without value reads or fallback`(
        strategy: UIInputStrategy,
        payload: Payload) async
    {
        let fixture = TypingReceiverFixture()
        fixture.routes[.a] = .unproven
        await self.expectRefusal { _ = try await fixture.run(payload.actions, strategy: strategy) }
        #expect(fixture.routeChecks == [.a])
        #expect(fixture.textValueReads.isEmpty)
        #expect(fixture.selectedRangeReads.isEmpty)
        #expect(fixture.textWrites.isEmpty)
        #expect(fixture.selectionWrites.isEmpty)
        #expect(fixture.events.isEmpty)
    }

    @Test(arguments: [false, true], Payload.allCases)
    func `route refusal after native or web delivery keeps the accepted prefix retry unsafe`(
        webPrefix: Bool,
        payload: Payload) async
    {
        let fixture = TypingReceiverFixture()
        fixture.routes[.a] = webPrefix ? .web : .native
        fixture.routeAfterFirstDispatch = .unproven
        do {
            _ = try await fixture.run([.text("p")] + payload.actions)
            Issue.record("Expected the unproven continuation route to stop dispatch")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.emittedUnitCount == 1)
            #expect(error.retrySafe == false)
            #expect(error.delivery?.mechanism == (webPrefix ? .windowTargetedEvents : .accessibilityValue))
            let failure = error.desktopActionFailure(delivery: nil)
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 1)
        } catch {
            Issue.record("Expected accepted-prefix evidence, got \(error)")
        }
        #expect(fixture.routeChecks == [.a, .a])
        #expect(fixture.nativePhases.map { $0 == .initial } == [true, false])
        #expect(fixture.textValueReads == (webPrefix ? [] : [.a]))
        #expect(fixture.selectedRangeReads == (webPrefix ? [] : [.a]))
        #expect(fixture.textWrites == (webPrefix ? [] : [.a]))
        #expect(fixture.selectionWrites == (webPrefix ? [] : [.a]))
        #expect(fixture.events == (webPrefix ? ["text:p"] : []))
    }

    private func expectRefusal(
        reason: DesktopActionOutcome.RefusalReason = .targetUnavailable,
        _ operation: () async throws -> Void) async
    {
        do {
            try await operation()
            Issue.record("Expected a final receiver refusal before dispatch")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == reason)
            #expect(failure.outcome.dispatchState == .none)
        } catch {
            Issue.record("Expected a pre-dispatch receiver refusal, got \(error)")
        }
    }
}

@MainActor
private final class TypingReceiverFixture {
    enum Receiver: String, Hashable {
        case a, b
    }

    enum Route {
        case native, web, unproven
    }

    static let processIdentifier: pid_t = 4242
    static let processStartIdentity: UInt64 = 91
    static let windowID = 42
    static let windowBounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    static let initialFrame = CGRect(x: 20, y: 30, width: 180, height: 24)
    static let reflowedFrame = CGRect(x: 40, y: 60, width: 200, height: 24)

    var focusedReceiver = Receiver.a
    var nativeReceiverAvailable = true
    var switchAfterValidation: Int?
    var reflowAfterTextWrite: Int?
    var providesNativeProof = true
    var snapshotIncludesNativeProof = true
    var validatedReceiver: Element?
    var validatedReceivers: [Receiver] = []
    var nativeLookups: [Receiver] = []
    var nativePhases: [KeyboardFocusValidationPhase] = []
    var editabilityReads: [Receiver] = []
    var routeChecks: [Receiver] = []
    var textValueReads: [Receiver] = []
    var selectedRangeReads: [Receiver] = []
    var textWrites: [Receiver] = []
    var selectionWrites: [Receiver] = []
    var events: [String] = []
    var eventPermissionGranted = true
    var eventPermissionChecks = 0
    var values: [Receiver: String] = [.a: "alpha", .b: "bravo"]
    var selections: [Receiver: CFRange] = [
        .a: CFRange(location: 5, length: 0),
        .b: CFRange(location: 5, length: 0),
    ]
    var frames: [Receiver: CGRect] = [
        .a: TypingReceiverFixture.initialFrame,
        .b: TypingReceiverFixture.initialFrame,
    ]
    var editable: [Receiver: Bool] = [.a: true, .b: true]
    var routes: [Receiver: Route] = [.a: .native, .b: .native]
    var routeAfterFirstDispatch: Route?
    var identifiers: [Receiver: String] = [.a: "a", .b: "b"]
    /// These are equality tokens only; no Accessibility attributes or actions are queried.
    private let nativeElements: [Receiver: Element] = [
        .a: Element(AXUIElementCreateApplication(424_201)),
        .b: Element(AXUIElementCreateApplication(424_202)),
    ]

    private var access: BackgroundInputDriver.FocusedTextEditAccess<Receiver> {
        BackgroundInputDriver.FocusedTextEditAccess(
            focusedElement: {
                self.nativeLookups.append(self.focusedReceiver)
                return self.nativeReceiverAvailable ? self.focusedReceiver : nil
            },
            isEditable: {
                self.editabilityReads.append($0)
                guard self.editable[$0] == true else { return false }
                self.routeChecks.append($0)
                switch self.routes[$0] ?? .unproven {
                case .native: return true
                case .web: return false
                case .unproven:
                    throw DesktopActionFailure.preDispatchRefusal(
                        reason: .targetUnavailable,
                        message: "The fixture could not prove the retained text route")
                }
            },
            textValue: {
                self.textValueReads.append($0)
                return self.values[$0]
            },
            selectedRange: {
                self.selectedRangeReads.append($0)
                return self.selections[$0]
            },
            focusSnapshot: { self.snapshot(for: $0) },
            setText: { text, receiver in
                self.textWrites.append(receiver)
                self.values[receiver] = text
                self.applyRouteTransition(afterDispatchTo: receiver)
                if self.textWrites.count == self.reflowAfterTextWrite {
                    self.frames[.a] = Self.reflowedFrame
                }
                return true
            },
            selectRange: { range, receiver in
                self.selectionWrites.append(receiver)
                self.selections[receiver] = range
                return true
            })
    }

    func run(
        _ actions: [TypeAction],
        strategy: UIInputStrategy = .actionFirst,
        policy: UIInputPolicy? = nil,
        exactWindow: Bool = true,
        focusedReceipt: Bool = true) async throws -> TypeService.TypeActionExecutionSummary
    {
        let coordinationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-typing-receiver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: coordinationRoot) }
        let driver = TargetedTypeInputDriver(
            insertText: { text, pid, window, phase, validatedReceiver in
                #expect(pid == Self.processIdentifier)
                self.nativePhases.append(phase)
                return try BackgroundInputDriver.insertTextIntoFocusedText(
                    text,
                    exactWindow: window,
                    phase: phase,
                    validatedReceiver: validatedReceiver,
                    access: self.access)
            },
            performTextKey: { key, pid, window, phase, validatedReceiver in
                #expect(pid == Self.processIdentifier)
                self.nativePhases.append(phase)
                return try BackgroundInputDriver.performFocusedTextKey(
                    key,
                    exactWindow: window,
                    phase: phase,
                    validatedReceiver: validatedReceiver,
                    access: self.access)
            },
            replaceText: { text, pid, window, phase, validatedReceiver in
                #expect(pid == Self.processIdentifier)
                self.nativePhases.append(phase)
                return try BackgroundInputDriver.replaceFocusedText(
                    with: text,
                    exactWindow: window,
                    phase: phase,
                    validatedReceiver: validatedReceiver,
                    access: self.access)
            },
            typeCharacter: { character, _ in try self.recordEvent("text:\(character)") },
            tapKey: { code, flags, _ in try self.recordEvent("key:\(code):\(flags.rawValue)") })
        let service = TypeService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: policy ?? UIInputPolicy(defaultStrategy: strategy),
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            focusedUIElementReader: {
                Issue.record("Background typing must not read foreground focus")
                throw PeekabooError.invalidInput("Unexpected foreground focus read")
            },
            targetedInputDriver: driver,
            targetBundleIdentifier: { _ in "example.typing-receiver-fixture" },
            exactFocusedElementValueReader: { _ in .failure(.focusNotConfirmed) },
            exactFocusedValueRunner: { _, _, _, _ in nil },
            processStartIdentityProvider: { _ in 91 },
            desktopOperationExecutor: DesktopOperationExecutor(
                laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: coordinationRoot)),
            operationFinalizer: {})
        let process = ApplicationProcessIdentity(
            processIdentifier: Self.processIdentifier,
            processStartIdentity: Self.processStartIdentity)
        let target: UIAutomationTarget = try exactWindow ? .exactWindow(.init(
            identity: WindowMutationIdentity(
                windowID: Self.windowID,
                ownerProcessIdentifier: process.processIdentifier,
                ownerProcessStartIdentity: process.processStartIdentity,
                capturedBounds: Self.windowBounds),
            bounds: Self.windowBounds,
            focusedElement: focusedReceipt ? self.expectedReceipt : nil)) : .process(.init(
            processIdentifier: process.processIdentifier,
            identity: process))
        return try await service.typeActionsTrackingSecureInput(
            actions,
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: target,
            deliveryValidator: {
                try self.validate(phase: .initial, requiresReceipt: exactWindow && focusedReceipt)
            },
            continuationValidator: {
                try self.validate(phase: .continuation, requiresReceipt: exactWindow && focusedReceipt)
            },
            validatedReceiverProvider: { self.validatedReceiver })
    }

    private func recordEvent(_ event: String) throws {
        self.eventPermissionChecks += 1
        guard self.eventPermissionGranted else { throw PeekabooError.permissionDeniedEventSynthesizing }
        self.events.append(event)
        self.applyRouteTransition(afterDispatchTo: self.focusedReceiver)
    }

    private func applyRouteTransition(afterDispatchTo receiver: Receiver) {
        if self.textWrites.count + self.events.count == 1, let routeAfterFirstDispatch {
            self.routes[receiver] = routeAfterFirstDispatch
        }
    }

    private var expectedReceipt: FocusedElementIdentity {
        FocusedElementIdentity(
            processIdentifier: Self.processIdentifier,
            windowID: Self.windowID,
            role: "AXTextField",
            title: nil,
            identifier: Receiver.a.rawValue,
            frame: Self.initialFrame)
    }

    private func validate(phase: KeyboardFocusValidationPhase, requiresReceipt: Bool) throws {
        if requiresReceipt {
            let current = self.receipt(for: self.focusedReceiver)
            if phase == .initial {
                try FocusedElementReceiptResolver.validate(current, matches: self.expectedReceipt)
            } else {
                try FocusedElementReceiptResolver.validateContinuation(current, matches: self.expectedReceipt)
            }
        }
        self.validatedReceiver = self.providesNativeProof ? self.nativeElements[self.focusedReceiver] : nil
        self.validatedReceivers.append(self.focusedReceiver)
        if self.validatedReceivers.count == self.switchAfterValidation {
            self.focusedReceiver = .b
        }
    }

    private func receipt(for receiver: Receiver) -> FocusedElementIdentity {
        FocusedElementIdentity(
            processIdentifier: Self.processIdentifier,
            windowID: Self.windowID,
            role: "AXTextField",
            title: nil,
            identifier: self.identifiers[receiver],
            frame: self.frames[receiver] ?? .zero)
    }

    private func snapshot(for receiver: Receiver) -> ExactWindowFocusSnapshot {
        ExactWindowFocusSnapshot(
            processIdentifier: Self.processIdentifier,
            windowID: Self.windowID,
            frame: self.frames[receiver] ?? .zero,
            role: "AXTextField",
            identifier: self.identifiers[receiver],
            nativeElement: self.snapshotIncludesNativeProof
                ? self.nativeElements[receiver].map { RetainedFocusElement(element: $0.underlyingElement) }
                : nil)
    }
}
