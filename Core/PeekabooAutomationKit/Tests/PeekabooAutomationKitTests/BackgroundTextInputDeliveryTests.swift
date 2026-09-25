import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct BackgroundTextInputDeliveryTests {
    enum Payload: CaseIterable {
        case text, editingKey, clear

        var action: TypeAction {
            switch self {
            case .text: .text("x")
            case .editingKey: .key(.space)
            case .clear: .clear
            }
        }

        var eventCount: Int {
            self == .clear ? 2 : 1
        }
    }

    @Test(arguments: UIInputStrategy.allCases, Payload.allCases)
    func `web route composes with policy without AX writes`(
        strategy: UIInputStrategy,
        payload: Payload) async throws
    {
        let fixture = Fixture(route: .webKeyboard, strategy: strategy)
        if strategy == .actionOnly {
            await #expect(throws: DesktopActionFailure.self) {
                _ = try await fixture.run(payload)
            }
            #expect(fixture.events.isEmpty)
        } else {
            let result = try await fixture.run(payload)
            #expect(result.result.keyPresses == payload.eventCount)
            #expect(result.executionResult.outcome.delivery?.mechanism == .processTargetedEvents)
            #expect(fixture.events.count == payload.eventCount)
            if payload == .clear {
                #expect(fixture.events == ["key:0:1048576", "key:51:0"])
            }
        }
        #expect(fixture.axWrites == 0)
        #expect(fixture.routeChecks == (strategy == .actionFirst || strategy == .actionOnly ? 1 : 0))
    }

    @Test(arguments: [UIInputStrategy.actionFirst, .actionOnly], Payload.allCases)
    func `unproven AX route cannot become a keyboard fallback`(
        strategy: UIInputStrategy,
        payload: Payload) async throws
    {
        let fixture = Fixture(route: .unproven, strategy: strategy)
        do {
            _ = try await fixture.run(payload)
            Issue.record("Expected route refusal before any mutation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.projection.retrySafe)
        }
        #expect(fixture.routeChecks == 1)
        #expect(fixture.axWrites == 0)
        #expect(fixture.events.isEmpty)
    }

    @Test(arguments: [UIInputStrategy.actionFirst, .actionOnly], Payload.allCases)
    func `proven native route retains AX editing without keyboard events`(
        strategy: UIInputStrategy,
        payload: Payload) async throws
    {
        let fixture = Fixture(route: .nativeAX, strategy: strategy)
        let result = try await fixture.run(payload)
        #expect(result.result.keyPresses == 0)
        #expect(result.executionResult.outcome.delivery?.mechanism == .accessibilityValue)
        #expect(fixture.axWrites == 1)
        #expect(fixture.events.isEmpty)
    }

    @Test(arguments: Payload.allCases)
    func `web route requires event permission without trying an AX write`(payload: Payload) async throws {
        let fixture = Fixture(route: .webKeyboard, strategy: .actionFirst)
        fixture.eventPermissionGranted = false
        do {
            _ = try await fixture.run(payload)
            Issue.record("Expected event permission refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .permissionDenied)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(fixture.routeChecks == 1)
        #expect(fixture.axWrites == 0)
        #expect(fixture.events.isEmpty)
    }

    @MainActor
    private final class Fixture {
        let route: TextInputRoute
        let strategy: UIInputStrategy
        var routeChecks = 0
        var axWrites = 0
        var events: [String] = []
        var eventPermissionGranted = true

        init(route: TextInputRoute, strategy: UIInputStrategy) {
            self.route = route
            self.strategy = strategy
        }

        func run(_ payload: Payload) async throws -> TypeService.TypeActionExecutionSummary {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("background-text-delivery-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let driver = TargetedTypeInputDriver(
                insertText: { _, _, _, _, _ in try self.tryAXWrite() },
                performTextKey: { _, _, _, _, _ in try self.tryAXWrite() ? .accessibilityValue : .unsupported },
                replaceText: { _, _, _, _, _ in try self.tryAXWrite() },
                typeCharacter: { _, _ in try self.postEvent("character") },
                tapKey: { code, flags, _ in
                    try self.postEvent("key:\(code):\(flags.rawValue)")
                })
            let service = TypeService(
                snapshotManager: InMemorySnapshotManager(),
                inputPolicy: UIInputPolicy(type: self.strategy),
                actionInputDriver: RecordingActionInputDriver(),
                syntheticInputDriver: ClickRecordingSyntheticInputDriver(),
                randomSource: SystemTypingCadenceRandomSource(),
                focusedElementSecurityProbe: { _ in false },
                targetedInputDriver: driver,
                targetBundleIdentifier: { _ in nil },
                desktopOperationExecutor: DesktopOperationExecutor(laneCoordinator: DesktopOperationLaneCoordinator(
                    coordinationRootURL: root)))
            return try await service.typeActionsTrackingSecureInput(
                [payload.action], cadence: .fixed(milliseconds: 0), snapshotId: nil, targetProcessIdentifier: 42)
        }

        private func tryAXWrite() throws -> Bool {
            self.routeChecks += 1
            guard try self.route.permitsAccessibilityEditing() else { return false }
            self.axWrites += 1
            return true
        }

        private func postEvent(_ event: String) throws {
            guard self.eventPermissionGranted else { throw PeekabooError.permissionDeniedEventSynthesizing }
            self.events.append(event)
        }
    }
}
