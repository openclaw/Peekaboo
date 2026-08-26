import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

// Keep the exact-lane lifecycle, focus, dispatch, and readback matrix beside its shared fixtures.
// swiftlint:disable type_body_length
@MainActor
struct TypeServicePixelFocusTests {
    @Test
    func `pixel focus write and typing share one exact lane and compose units`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(
            processIdentity: ApplicationProcessIdentity(
                processIdentifier: getpid(),
                processStartIdentity: 42))
        let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let synthetic = ClickRecordingSyntheticInputDriver()
        var focusRequests: [(point: CGPoint, window: UIAutomationTarget.ExactWindow)] = []
        let executor = DesktopOperationExecutor(laneCoordinator: DesktopOperationLaneCoordinator(
            coordinationRootURL: self.temporaryRoot()))
        let click = ClickService(
            snapshotManager: manager,
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic,
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 42 },
            desktopOperationExecutor: executor,
            exactWindowPixelFocusExecutor: { point, window in
                focusRequests.append((point, window))
                return Self.focusAction(for: window)
            })
        var typed: [Character] = []
        var finalizerCount = 0
        let service = TypeService(
            snapshotManager: manager,
            clickService: click,
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic,
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { character, _, delivery in
                typed.append(character)
                return .dispatched(delivery: delivery, keyPressCount: 1)
            },
            desktopOperationExecutor: executor,
            operationFinalizer: { finalizerCount += 1 })
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)

        let result = try await service.typeActionsByFocusingPixel(
            ExactWindowPixelFocusTypeRequest(
                point: CGPoint(x: 40, y: 50),
                actions: [.text("ab")],
                cadence: .fixed(milliseconds: 0),
                snapshotID: fixture.snapshotID,
                windowIdentity: exactWindow.identity,
                windowBounds: exactWindow.bounds),
            deliveryValidator: { focusedElement in
                #expect(focusedElement == Self.focusedElement(for: exactWindow))
            })

        #expect(result.payload.totalCharacters == 2)
        #expect(result.payload.keyPresses == 2)
        #expect(result.outcome?.delivery == .init(mechanism: .composite, mode: .background))
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 3)
        let expectedIdentity = try fixture.targetIdentity
        #expect(result.targetIdentity == expectedIdentity)
        #expect(typed == ["a", "b"])
        #expect(finalizerCount == 1)
        #expect(focusRequests.count == 1)
        #expect(focusRequests.first?.point == CGPoint(x: 40, y: 50))
        #expect(focusRequests.first?.window == exactWindow)
        #expect(synthetic.events.isEmpty)
    }

    @Test
    func `confirmed pixel focus cannot confirm unverified text typing`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(
            processIdentity: .init(processIdentifier: getpid(), processStartIdentity: 42))
        let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let executor = DesktopOperationExecutor(laneCoordinator: DesktopOperationLaneCoordinator(
            coordinationRootURL: self.temporaryRoot()))
        let click = ClickService(
            snapshotManager: manager,
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 42 },
            desktopOperationExecutor: executor,
            exactWindowPixelFocusExecutor: { _, window in Self.confirmedFocusAction(for: window) })
        let service = TypeService(
            snapshotManager: manager,
            clickService: click,
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { _, _, delivery in
                .dispatched(delivery: delivery, keyPressCount: 1)
            },
            desktopOperationExecutor: executor)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)

        let result = try await service.typeActionsByFocusingPixel(
            .init(
                point: CGPoint(x: 40, y: 50),
                actions: [.text("x")],
                cadence: .fixed(milliseconds: 0),
                snapshotID: fixture.snapshotID,
                windowIdentity: exactWindow.identity,
                windowBounds: exactWindow.bounds),
            deliveryValidator: { _ in })

        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(result.outcome?.delivery == .init(mechanism: .composite, mode: .background))
        #expect(result.outcome?.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(2))
    }

    @Test
    func `pixel clear literal readback confirms the typing leaf`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(
            processIdentity: .init(processIdentifier: getpid(), processStartIdentity: 42))
        let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let executor = DesktopOperationExecutor(laneCoordinator: DesktopOperationLaneCoordinator(
            coordinationRootURL: self.temporaryRoot()))
        let value = PixelFocusLockedValue("before")
        let clock = PixelFocusPollClock { value.set("ok") }
        let click = ClickService(
            snapshotManager: manager,
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 42 },
            desktopOperationExecutor: executor,
            exactWindowPixelFocusExecutor: { _, window in Self.confirmedFocusAction(for: window) })
        let service = TypeService(
            snapshotManager: manager,
            clickService: click,
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { _, _, delivery in
                .dispatched(delivery: delivery, keyPressCount: 1)
            },
            targetedTextReplacer: { text, _ in
                value.set(text)
                return true
            },
            exactFocusedElementValueReader: { focusedElement in
                .success(Self.focusSnapshot(focusedElement, value: value.get()))
            },
            processStartIdentityProvider: { _ in 42 },
            desktopOperationExecutor: executor,
            effectConfirmationTiming: clock.timing())
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)

        let result = try await service.typeActionsByFocusingPixel(
            .init(
                point: CGPoint(x: 40, y: 50),
                actions: [.clear, .text("ok")],
                cadence: .fixed(milliseconds: 0),
                snapshotID: fixture.snapshotID,
                windowIdentity: exactWindow.identity,
                windowBounds: exactWindow.bounds),
            deliveryValidator: { _ in })

        #expect(value.get() == "ok")
        #expect(result.outcome?.state == .confirmedChange)
        #expect(result.outcome?.delivery == .init(mechanism: .composite, mode: .background))
        #expect(result.outcome?.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(4))
        #expect(clock.sleepCount == 1)
    }

    @Test
    func `missing or mismatched pixel readback leaves typing unverified`() async throws {
        for readbackAvailable in [false, true] {
            let fixture = AutomationTestFixtures.linkedSnapshotTarget(
                processIdentity: .init(processIdentifier: getpid(), processStartIdentity: 42))
            let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
            let executor = DesktopOperationExecutor(laneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: self.temporaryRoot()))
            let value = PixelFocusLockedValue("before")
            let click = ClickService(
                snapshotManager: manager,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                exactWindowIdentityValidator: { _, _ in true },
                processStartIdentityProvider: { _ in 42 },
                desktopOperationExecutor: executor,
                exactWindowPixelFocusExecutor: { _, window in Self.confirmedFocusAction(for: window) })
            let service = TypeService(
                snapshotManager: manager,
                clickService: click,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                randomSource: SystemTypingCadenceRandomSource(),
                focusedElementSecurityProbe: { _ in false },
                targetedCharacterTyper: { _, _, _ in
                    value.set("mismatch")
                    return .dispatched(
                        delivery: .init(mechanism: .accessibilityValue, mode: .background),
                        keyPressCount: 0)
                },
                targetedTextReplacer: { text, _ in
                    value.set(text)
                    return true
                },
                exactFocusedElementValueReader: { focusedElement in
                    readbackAvailable
                        ? .success(Self.focusSnapshot(focusedElement, value: value.get()))
                        : .failure(.focusedAttributeUnreadable)
                },
                processStartIdentityProvider: { _ in 42 },
                desktopOperationExecutor: executor)
            let exactWindow = try #require(fixture.targetIdentity.exactWindow)

            let result = try await service.typeActionsByFocusingPixel(
                .init(
                    point: CGPoint(x: 40, y: 50),
                    actions: [.clear, .text("ok")],
                    cadence: .fixed(milliseconds: 0),
                    snapshotID: fixture.snapshotID,
                    windowIdentity: exactWindow.identity,
                    windowBounds: exactWindow.bounds),
                deliveryValidator: { _ in })

            #expect(result.outcome?.state == .dispatchedUnverified)
            #expect(result.outcome?.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(4))
        }
    }

    @Test
    func `snapshot lease blocks concurrent pixel focus replay`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(
            processIdentity: ApplicationProcessIdentity(
                processIdentifier: getpid(),
                processStartIdentity: 45))
        let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let suspension = PixelFocusDeliverySuspension()
        var focusCount = 0
        var typed: [Character] = []
        let executor = DesktopOperationExecutor(laneCoordinator: DesktopOperationLaneCoordinator(
            coordinationRootURL: self.temporaryRoot()))
        let click = ClickService(
            snapshotManager: manager,
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 45 },
            desktopOperationExecutor: executor,
            exactWindowPixelFocusExecutor: { _, window in
                focusCount += 1
                return Self.focusAction(for: window)
            })
        let service = TypeService(
            snapshotManager: manager,
            clickService: click,
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { character, _, delivery in
                typed.append(character)
                return .dispatched(delivery: delivery, keyPressCount: 1)
            },
            desktopOperationExecutor: executor)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        let request = ExactWindowPixelFocusTypeRequest(
            point: CGPoint(x: 40, y: 50),
            actions: [.text("x")],
            cadence: .fixed(milliseconds: 0),
            snapshotID: fixture.snapshotID,
            windowIdentity: exactWindow.identity,
            windowBounds: exactWindow.bounds)

        let first = Task { @MainActor in
            try await service.typeActionsByFocusingPixel(
                request,
                deliveryValidator: { _ in await suspension.wait() })
        }
        await suspension.waitUntilEntered()
        await #expect(throws: (any Error).self) {
            _ = try await service.typeActionsByFocusingPixel(
                request,
                deliveryValidator: { _ in })
        }
        await suspension.release()
        let result = try await first.value

        #expect(result.payload.totalCharacters == 1)
        #expect(focusCount == 1)
        #expect(typed == ["x"])
    }

    @Test
    func `typing failure after pixel focus preserves the exact retry unsafe prefix`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(
            processIdentity: ApplicationProcessIdentity(
                processIdentifier: getpid(),
                processStartIdentity: 43))
        let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let synthetic = ClickRecordingSyntheticInputDriver()
        let executor = DesktopOperationExecutor(laneCoordinator: DesktopOperationLaneCoordinator(
            coordinationRootURL: self.temporaryRoot()))
        let click = ClickService(
            snapshotManager: manager,
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic,
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 43 },
            desktopOperationExecutor: executor,
            exactWindowPixelFocusExecutor: { _, window in Self.focusAction(for: window) })
        var typedCount = 0
        let service = TypeService(
            snapshotManager: manager,
            clickService: click,
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic,
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { _, _, delivery in
                typedCount += 1
                if typedCount == 2 {
                    throw PixelFocusFixtureError.deliveryFailed
                }
                return .dispatched(delivery: delivery, keyPressCount: 1)
            },
            desktopOperationExecutor: executor)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)

        do {
            _ = try await service.typeActionsByFocusingPixel(
                ExactWindowPixelFocusTypeRequest(
                    point: CGPoint(x: 40, y: 50),
                    actions: [.text("ab")],
                    cadence: .fixed(milliseconds: 0),
                    snapshotID: fixture.snapshotID,
                    windowIdentity: exactWindow.identity,
                    windowBounds: exactWindow.bounds),
                deliveryValidator: { _ in })
            Issue.record("Expected the second keyboard unit to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
            #expect(failure.targetReceipt == DesktopTargetIdentity(exactWindow: exactWindow).actionTargetReceipt)
        }
    }

    @Test
    func `stale coordinate authority refuses before click or typing`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let synthetic = ClickRecordingSyntheticInputDriver()
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        var focusAttempted = false
        let service = TypeService(
            snapshotManager: manager,
            clickService: ClickService(
                snapshotManager: manager,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                syntheticInputDriver: synthetic,
                exactWindowIdentityValidator: { _, _ in true },
                exactWindowPixelFocusExecutor: { _, window in
                    focusAttempted = true
                    return Self.focusAction(for: window)
                }),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic)

        await #expect(throws: (any Error).self) {
            _ = try await service.typeActionsByFocusingPixel(
                ExactWindowPixelFocusTypeRequest(
                    point: CGPoint(x: exactWindow.bounds.maxX + 10, y: exactWindow.bounds.midY),
                    actions: [.text("x")],
                    cadence: .fixed(milliseconds: 0),
                    snapshotID: fixture.snapshotID,
                    windowIdentity: exactWindow.identity,
                    windowBounds: exactWindow.bounds),
                deliveryValidator: { _ in })
        }
        #expect(!focusAttempted)
        #expect(synthetic.events.isEmpty)
        let subsequentLease = try await manager.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await manager.finishSnapshotMutation(
            subsequentLease,
            requiresFreshObservation: false)
    }

    @Test
    func `ordinary snapshot planning failure releases lease before focus`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        var focusAttempted = false
        let service = TypeService(
            snapshotManager: manager,
            clickService: ClickService(
                snapshotManager: manager,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                exactWindowIdentityValidator: { _, _ in true },
                exactWindowPixelFocusExecutor: { _, window in
                    focusAttempted = true
                    return Self.focusAction(for: window)
                }),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            randomSource: SystemTypingCadenceRandomSource(),
            pixelFocusReceiptPlanner: { _ in throw PixelFocusFixtureError.deliveryFailed })

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await service.typeActionsByFocusingPixel(
                ExactWindowPixelFocusTypeRequest(
                    point: CGPoint(x: 40, y: 50),
                    actions: [.text("x")],
                    cadence: .fixed(milliseconds: 0),
                    snapshotID: fixture.snapshotID,
                    windowIdentity: exactWindow.identity,
                    windowBounds: exactWindow.bounds),
                deliveryValidator: { _ in })
        }
        #expect(!focusAttempted)
        let lease = try await manager.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await manager.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    func `snapshot planning cancellation preserves cancellation and releases lease`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        var focusAttempted = false
        let service = TypeService(
            snapshotManager: manager,
            clickService: ClickService(
                snapshotManager: manager,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                exactWindowIdentityValidator: { _, _ in true },
                exactWindowPixelFocusExecutor: { _, window in
                    focusAttempted = true
                    return Self.focusAction(for: window)
                }),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            randomSource: SystemTypingCadenceRandomSource(),
            pixelFocusReceiptPlanner: { _ in throw CancellationError() })

        await #expect(throws: CancellationError.self) {
            _ = try await service.typeActionsByFocusingPixel(
                ExactWindowPixelFocusTypeRequest(
                    point: CGPoint(x: 40, y: 50),
                    actions: [.text("x")],
                    cadence: .fixed(milliseconds: 0),
                    snapshotID: fixture.snapshotID,
                    windowIdentity: exactWindow.identity,
                    windowBounds: exactWindow.bounds),
                deliveryValidator: { _ in })
        }
        #expect(!focusAttempted)
        let lease = try await manager.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await manager.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    func `unknown pixel focus failure finalizes snapshot as retry unsafe`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let storage = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let manager = SnapshotMutationRecordingManager(wrapping: storage)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        let service = TypeService(
            snapshotManager: manager,
            clickService: ClickService(
                snapshotManager: manager,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                exactWindowIdentityValidator: { _, _ in true },
                exactWindowPixelFocusExecutor: { _, _ in
                    throw PixelFocusFixtureError.deliveryFailed
                }),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly))

        do {
            _ = try await service.typeActionsByFocusingPixel(
                ExactWindowPixelFocusTypeRequest(
                    point: CGPoint(x: 40, y: 50),
                    actions: [.text("x")],
                    cadence: .fixed(milliseconds: 0),
                    snapshotID: fixture.snapshotID,
                    windowIdentity: exactWindow.identity,
                    windowBounds: exactWindow.bounds),
                deliveryValidator: { _ in })
            Issue.record("Expected an indeterminate pixel-focus failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.targetReceipt == DesktopTargetIdentity(exactWindow: exactWindow).actionTargetReceipt)
        }

        #expect(manager.finishCalls.count == 1)
        let finishCall = try #require(manager.finishCalls.first)
        #expect(finishCall.lease.snapshotId == fixture.snapshotID)
        #expect(finishCall.requiresFreshObservation)
        guard case .requiresFreshObservation? = storage.mutationLeases[fixture.snapshotID] else {
            Issue.record("Expected the unknown service failure to consume the snapshot")
            return
        }
        await #expect(throws: (any Error).self) {
            _ = try await manager.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        }
    }

    @Test
    func `accessibility refusal before focus releases snapshot lease`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        let service = TypeService(
            snapshotManager: manager,
            clickService: ClickService(
                snapshotManager: manager,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                exactWindowIdentityValidator: { _, _ in true },
                exactWindowPixelFocusExecutor: { _, _ in
                    throw PeekabooError.permissionDeniedAccessibility
                }),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly))

        do {
            _ = try await service.typeActionsByFocusingPixel(
                ExactWindowPixelFocusTypeRequest(
                    point: CGPoint(x: 40, y: 50),
                    actions: [.text("x")],
                    cadence: .fixed(milliseconds: 0),
                    snapshotID: fixture.snapshotID,
                    windowIdentity: exactWindow.identity,
                    windowBounds: exactWindow.bounds),
                deliveryValidator: { _ in })
            Issue.record("Expected Accessibility refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .permissionDenied)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.targetReceipt == DesktopTargetIdentity(exactWindow: exactWindow).actionTargetReceipt)
        }
        let lease = try await manager.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await manager.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    func `cancellation before focus releases snapshot lease`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        let service = TypeService(
            snapshotManager: manager,
            clickService: ClickService(
                snapshotManager: manager,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                exactWindowIdentityValidator: { _, _ in true },
                exactWindowPixelFocusExecutor: { _, _ in throw CancellationError() }),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly))

        await #expect(throws: CancellationError.self) {
            _ = try await service.typeActionsByFocusingPixel(
                ExactWindowPixelFocusTypeRequest(
                    point: CGPoint(x: 40, y: 50),
                    actions: [.text("x")],
                    cadence: .fixed(milliseconds: 0),
                    snapshotID: fixture.snapshotID,
                    windowIdentity: exactWindow.identity,
                    windowBounds: exactWindow.bounds),
                deliveryValidator: { _ in })
        }
        let lease = try await manager.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await manager.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    func `cancellation while waiting for operation lane releases snapshot lease`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(
            processIdentity: ApplicationProcessIdentity(
                processIdentifier: getpid(),
                processStartIdentity: 46))
        let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let executor = DesktopOperationExecutor(laneCoordinator: coordinator)
        let suspension = PixelFocusDeliverySuspension()
        let holder = Task {
            try await coordinator.run(scope: .process(exactWindow.identity.processIdentity), access: .write) {
                await suspension.wait()
            }
        }
        await suspension.waitUntilEntered()
        var focusAttempted = false
        let service = TypeService(
            snapshotManager: manager,
            clickService: ClickService(
                snapshotManager: manager,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                exactWindowIdentityValidator: { _, _ in true },
                desktopOperationExecutor: executor,
                exactWindowPixelFocusExecutor: { _, window in
                    focusAttempted = true
                    return Self.focusAction(for: window)
                }),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            desktopOperationExecutor: executor)
        let operation = Task { @MainActor in
            try await service.typeActionsByFocusingPixel(
                ExactWindowPixelFocusTypeRequest(
                    point: CGPoint(x: 40, y: 50),
                    actions: [.text("x")],
                    cadence: .fixed(milliseconds: 0),
                    snapshotID: fixture.snapshotID,
                    windowIdentity: exactWindow.identity,
                    windowBounds: exactWindow.bounds),
                deliveryValidator: { _ in })
        }
        while manager.mutationLeases[fixture.snapshotID] == nil {
            await Task.yield()
        }

        operation.cancel()
        await suspension.release()
        _ = try await holder.value
        await #expect(throws: CancellationError.self) {
            _ = try await operation.value
        }

        #expect(!focusAttempted)
        let lease = try await manager.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await manager.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    func `raw cancellation after plan entry preserves pending snapshot lease`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        var focusAttempted = false
        let service = TypeService(
            snapshotManager: manager,
            clickService: ClickService(
                snapshotManager: manager,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                exactWindowIdentityValidator: { _, _ in true },
                exactWindowPixelFocusExecutor: { _, window in
                    focusAttempted = true
                    return Self.focusAction(for: window)
                }),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            randomSource: SystemTypingCadenceRandomSource(),
            pixelFocusPlanEntryHook: { throw CancellationError() })

        await #expect(throws: CancellationError.self) {
            _ = try await service.typeActionsByFocusingPixel(
                ExactWindowPixelFocusTypeRequest(
                    point: CGPoint(x: 40, y: 50),
                    actions: [.text("x")],
                    cadence: .fixed(milliseconds: 0),
                    snapshotID: fixture.snapshotID,
                    windowIdentity: exactWindow.identity,
                    windowBounds: exactWindow.bounds),
                deliveryValidator: { _ in })
        }

        #expect(!focusAttempted)
        await #expect(throws: (any Error).self) {
            _ = try await manager.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        }
    }

    @Test
    func `lease finalization failure retains exact target attribution`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(
            processIdentity: ApplicationProcessIdentity(
                processIdentifier: getpid(),
                processStartIdentity: 47))
        let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = DesktopOperationExecutor(laneCoordinator: DesktopOperationLaneCoordinator(
            coordinationRootURL: root))
        var typed: [Character] = []
        let service = TypeService(
            snapshotManager: manager,
            clickService: ClickService(
                snapshotManager: manager,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                exactWindowIdentityValidator: { _, _ in true },
                processStartIdentityProvider: { _ in 47 },
                desktopOperationExecutor: executor,
                exactWindowPixelFocusExecutor: { _, window in Self.focusAction(for: window) }),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { character, _, delivery in
                typed.append(character)
                return .dispatched(delivery: delivery, keyPressCount: 1)
            },
            desktopOperationExecutor: executor,
            operationFinalizer: {
                manager.mutationLeases[fixture.snapshotID] = .requiresFreshObservation(
                    SnapshotMutationLease(snapshotId: fixture.snapshotID))
            })

        do {
            _ = try await service.typeActionsByFocusingPixel(
                ExactWindowPixelFocusTypeRequest(
                    point: CGPoint(x: 40, y: 50),
                    actions: [.text("x")],
                    cadence: .fixed(milliseconds: 0),
                    snapshotID: fixture.snapshotID,
                    windowIdentity: exactWindow.identity,
                    windowBounds: exactWindow.bounds),
                deliveryValidator: { _ in })
            Issue.record("Expected snapshot lease finalization failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
            #expect(failure.targetReceipt == DesktopTargetIdentity(exactWindow: exactWindow).actionTargetReceipt)
        }
        #expect(typed == ["x"])
        await #expect(throws: (any Error).self) {
            _ = try await manager.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        }
    }

    @Test
    func `cancellation after focus keeps snapshot replay blocked`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        let service = TypeService(
            snapshotManager: manager,
            clickService: ClickService(
                snapshotManager: manager,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                exactWindowIdentityValidator: { _, _ in true },
                exactWindowPixelFocusExecutor: { _, window in Self.focusAction(for: window) }),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly))

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await service.typeActionsByFocusingPixel(
                ExactWindowPixelFocusTypeRequest(
                    point: CGPoint(x: 40, y: 50),
                    actions: [.text("x")],
                    cadence: .fixed(milliseconds: 0),
                    snapshotID: fixture.snapshotID,
                    windowIdentity: exactWindow.identity,
                    windowBounds: exactWindow.bounds),
                deliveryValidator: { _ in throw CancellationError() })
        }
        await #expect(throws: (any Error).self) {
            _ = try await manager.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        }
    }

    @Test
    func `zero keyboard units refuse before the focus write`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let synthetic = ClickRecordingSyntheticInputDriver()
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        var focusAttempted = false
        let service = TypeService(
            snapshotManager: manager,
            clickService: ClickService(
                snapshotManager: manager,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                syntheticInputDriver: synthetic,
                exactWindowIdentityValidator: { _, _ in true },
                exactWindowPixelFocusExecutor: { _, window in
                    focusAttempted = true
                    return Self.focusAction(for: window)
                }),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic)

        await #expect(throws: (any Error).self) {
            _ = try await service.typeActionsByFocusingPixel(
                ExactWindowPixelFocusTypeRequest(
                    point: CGPoint(x: 40, y: 50),
                    actions: [.text("")],
                    cadence: .fixed(milliseconds: 0),
                    snapshotID: fixture.snapshotID,
                    windowIdentity: exactWindow.identity,
                    windowBounds: exactWindow.bounds),
                deliveryValidator: { _ in })
        }
        #expect(!focusAttempted)
        #expect(synthetic.events.isEmpty)
    }

    @Test
    func `malformed exact window refuses before acquiring snapshot lease`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        let service = TypeService(snapshotManager: manager)
        let mismatchedBounds = exactWindow.bounds.offsetBy(dx: 1, dy: 0)

        await #expect(throws: (any Error).self) {
            _ = try await service.typeActionsByFocusingPixel(
                ExactWindowPixelFocusTypeRequest(
                    point: CGPoint(x: 40, y: 50),
                    actions: [.text("x")],
                    cadence: .fixed(milliseconds: 0),
                    snapshotID: fixture.snapshotID,
                    windowIdentity: exactWindow.identity,
                    windowBounds: mismatchedBounds),
                deliveryValidator: { _ in })
        }
        let lease = try await manager.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await manager.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    func `focused element drift refuses every keyboard unit after the focus write`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(
            processIdentity: ApplicationProcessIdentity(
                processIdentifier: getpid(),
                processStartIdentity: 44))
        let manager = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        var typed: [Character] = []
        var validatedReceipts: [FocusedElementIdentity] = []
        let executor = DesktopOperationExecutor(laneCoordinator: DesktopOperationLaneCoordinator(
            coordinationRootURL: self.temporaryRoot()))
        let click = ClickService(
            snapshotManager: manager,
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 44 },
            desktopOperationExecutor: executor,
            exactWindowPixelFocusExecutor: { _, window in Self.focusAction(for: window) })
        let service = TypeService(
            snapshotManager: manager,
            clickService: click,
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { character, _, delivery in
                typed.append(character)
                return .dispatched(delivery: delivery, keyPressCount: 1)
            },
            desktopOperationExecutor: executor)

        do {
            _ = try await service.typeActionsByFocusingPixel(
                ExactWindowPixelFocusTypeRequest(
                    point: CGPoint(x: 40, y: 50),
                    actions: [.text("x")],
                    cadence: .fixed(milliseconds: 0),
                    snapshotID: fixture.snapshotID,
                    windowIdentity: exactWindow.identity,
                    windowBounds: exactWindow.bounds),
                deliveryValidator: { focusedElement in
                    validatedReceipts.append(focusedElement)
                    throw PixelFocusFixtureError.deliveryFailed
                })
            Issue.record("Expected focused-element drift refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState.unitCount == .one)
        }
        #expect(validatedReceipts == [Self.focusedElement(for: exactWindow)])
        #expect(typed.isEmpty)
    }

    private static func focusAction(
        for exactWindow: UIAutomationTarget.ExactWindow) -> UIInputExecutionResult.Action
    {
        UIInputExecutionResult.Action(
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one),
            focusedElement: self.focusedElement(for: exactWindow))
    }

    private static func confirmedFocusAction(
        for exactWindow: UIAutomationTarget.ExactWindow) -> UIInputExecutionResult.Action
    {
        UIInputExecutionResult.Action(
            outcome: .confirmedChange(
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                unitCount: .one),
            focusedElement: self.focusedElement(for: exactWindow))
    }

    private nonisolated static func focusSnapshot(
        _ focusedElement: FocusedElementIdentity,
        value: String) -> ExactWindowFocusSnapshot
    {
        ExactWindowFocusSnapshot(
            processIdentifier: focusedElement.processIdentifier,
            windowID: focusedElement.windowID,
            frame: focusedElement.frame,
            role: focusedElement.role,
            identifier: focusedElement.identifier,
            value: value)
    }

    private static func focusedElement(
        for exactWindow: UIAutomationTarget.ExactWindow) -> FocusedElementIdentity
    {
        FocusedElementIdentity(
            processIdentifier: exactWindow.identity.ownerProcessIdentifier,
            windowID: exactWindow.identity.windowID,
            role: "AXTextField",
            identifier: "pixel-focus-field",
            frame: CGRect(x: 30, y: 40, width: 120, height: 24))
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-pixel-focus-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

// swiftlint:enable type_body_length

private enum PixelFocusFixtureError: Error {
    case deliveryFailed
}

private final class PixelFocusLockedValue: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ value: String) {
        self.value = value
    }

    func get() -> String {
        self.lock.withLock { self.value }
    }

    func set(_ value: String) {
        self.lock.withLock { self.value = value }
    }
}

@MainActor
private final class PixelFocusPollClock {
    private var instant = ContinuousClock.now
    private let onSleep: @MainActor () -> Void
    private(set) var sleepCount = 0

    init(onSleep: @escaping @MainActor () -> Void) {
        self.onSleep = onSleep
    }

    func timing() -> ExactLiteralTypingEffectConfirmationTiming {
        .init(
            timeout: .milliseconds(60),
            interval: .milliseconds(20),
            maximumSampleCount: 8,
            now: { self.instant },
            sleep: { duration in
                self.sleepCount += 1
                self.instant = self.instant.advanced(by: duration)
                self.onSleep()
            })
    }
}

private actor PixelFocusDeliverySuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryContinuations: [CheckedContinuation<Void, Never>] = []
    private var entered = false

    func wait() async {
        guard !self.entered else { return }
        self.entered = true
        let entries = self.entryContinuations
        self.entryContinuations.removeAll()
        entries.forEach { $0.resume() }
        await withCheckedContinuation { self.continuation = $0 }
    }

    func waitUntilEntered() async {
        guard !self.entered else { return }
        await withCheckedContinuation { self.entryContinuations.append($0) }
    }

    func release() {
        self.continuation?.resume()
        self.continuation = nil
    }
}
