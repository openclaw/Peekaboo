import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct TypeServicePixelFocusTests {
    @Test
    func `pixel focus click and typing share one exact lane and compose units`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(
            processIdentity: ApplicationProcessIdentity(
                processIdentifier: getpid(),
                processStartIdentity: 42))
        let manager = InMemorySnapshotManager(detectionResult: fixture.detectionResult)
        let synthetic = ClickRecordingSyntheticInputDriver()
        let executor = DesktopOperationExecutor(laneCoordinator: DesktopOperationLaneCoordinator(
            coordinationRootURL: self.temporaryRoot()))
        let click = ClickService(
            snapshotManager: manager,
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic,
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 42 },
            desktopOperationExecutor: executor)
        var typed: [Character] = []
        var finalizerCount = 0
        let service = TypeService(
            snapshotManager: manager,
            clickService: click,
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic,
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { character, _ in typed.append(character) },
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
            deliveryValidator: {})

        #expect(result.payload.totalCharacters == 2)
        #expect(result.payload.keyPresses == 2)
        #expect(result.outcome?.delivery == .init(mechanism: .composite, mode: .background))
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 3)
        let expectedIdentity = try fixture.targetIdentity
        #expect(result.targetIdentity == expectedIdentity)
        #expect(typed == ["a", "b"])
        #expect(finalizerCount == 1)
        #expect(synthetic.events.contains {
            if case let .targetedClick(point, _, _, pid, windowID) = $0 {
                point == CGPoint(x: 40, y: 50) &&
                    pid == exactWindow.identity.ownerProcessIdentifier &&
                    windowID == CGWindowID(exactWindow.identity.windowID)
            } else {
                false
            }
        })
    }

    @Test
    func `typing failure after pixel focus preserves the exact retry unsafe prefix`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(
            processIdentity: ApplicationProcessIdentity(
                processIdentifier: getpid(),
                processStartIdentity: 43))
        let manager = InMemorySnapshotManager(detectionResult: fixture.detectionResult)
        let synthetic = ClickRecordingSyntheticInputDriver()
        let executor = DesktopOperationExecutor(laneCoordinator: DesktopOperationLaneCoordinator(
            coordinationRootURL: self.temporaryRoot()))
        let click = ClickService(
            snapshotManager: manager,
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic,
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 43 },
            desktopOperationExecutor: executor)
        var typedCount = 0
        let service = TypeService(
            snapshotManager: manager,
            clickService: click,
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic,
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { _, _ in
                typedCount += 1
                if typedCount == 2 {
                    throw PixelFocusFixtureError.deliveryFailed
                }
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
                deliveryValidator: {})
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
        let manager = InMemorySnapshotManager(detectionResult: fixture.detectionResult)
        let synthetic = ClickRecordingSyntheticInputDriver()
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        let service = TypeService(
            snapshotManager: manager,
            clickService: ClickService(
                snapshotManager: manager,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                syntheticInputDriver: synthetic,
                exactWindowIdentityValidator: { _, _ in true }),
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
                deliveryValidator: {})
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    func `zero keyboard units refuse before the focus click`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = InMemorySnapshotManager(detectionResult: fixture.detectionResult)
        let synthetic = ClickRecordingSyntheticInputDriver()
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        let service = TypeService(
            snapshotManager: manager,
            clickService: ClickService(
                snapshotManager: manager,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                syntheticInputDriver: synthetic,
                exactWindowIdentityValidator: { _, _ in true }),
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
                deliveryValidator: {})
        }
        #expect(synthetic.events.isEmpty)
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-pixel-focus-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private enum PixelFocusFixtureError: Error {
    case deliveryFailed
}
