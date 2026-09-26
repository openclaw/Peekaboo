import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct BackgroundTextRouteRefusalTests {
    @Test(arguments: [TypeAction.text("x"), .key(.delete), .clear])
    func `known first unit routing refusal remains retry safe`(action: TypeAction) async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var keyTapCount = 0
        let service = Self.service(coordinationRoot: root, keyTap: { keyTapCount += 1 })

        do {
            _ = try await service.typeActionsTrackingSecureInput(
                [action], cadence: .fixed(milliseconds: 0), snapshotId: nil, targetProcessIdentifier: 42)
            Issue.record("Expected route refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.projection.retrySafe)
        }
        #expect(keyTapCount == 0)
    }

    @Test(arguments: [TypeAction.text("x"), .key(.delete), .clear])
    func `routing refusal after a delivered prefix stays retry unsafe`(action: TypeAction) async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var keyTapCount = 0
        let service = Self.service(coordinationRoot: root, keyTap: { keyTapCount += 1 })

        do {
            _ = try await service.typeActionsTrackingSecureInput(
                [.text("a"), action], cadence: .fixed(milliseconds: 0), snapshotId: nil, targetProcessIdentifier: 42)
            Issue.record("Expected partial delivery failure")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.emittedUnitCount == 1)
            #expect(!error.retrySafe)
            #expect(error.delivery == .init(mechanism: .processTargetedEvents, mode: .background))
        }
        #expect(keyTapCount == 0)
    }

    @Test
    func `unknown driver failure is not reclassified as a safe refusal`() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = TypeService(
            snapshotManager: InMemorySnapshotManager(),
            actionInputDriver: RecordingActionInputDriver(),
            syntheticInputDriver: ClickRecordingSyntheticInputDriver(),
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { _, _, _ in throw TestFailure.unknown },
            targetBundleIdentifier: { _ in nil },
            desktopOperationExecutor: DesktopOperationExecutor(laneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: root)))

        do {
            _ = try await service.typeActionsTrackingSecureInput(
                [.text("x")], cadence: .fixed(milliseconds: 0), snapshotId: nil, targetProcessIdentifier: 42)
            Issue.record("Expected unknown delivery failure")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.emittedUnitCount == nil)
            #expect(!error.retrySafe)
        }
    }

    private enum TestFailure: Error {
        case unknown
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("background-text-refusal-\(UUID().uuidString)", isDirectory: true)
    }

    private static func service(
        coordinationRoot: URL,
        keyTap: @escaping @MainActor () -> Void) -> TypeService
    {
        TypeService(
            snapshotManager: InMemorySnapshotManager(),
            actionInputDriver: RecordingActionInputDriver(),
            syntheticInputDriver: ClickRecordingSyntheticInputDriver(),
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { character, _, delivery in
                if character == "a" {
                    return .dispatched(delivery: delivery, keyPressCount: 1)
                }
                _ = try TextInputRoute.unproven.permitsAccessibilityEditing()
                return .noChange
            },
            targetedSpecialKeyTyper: { _, _, _ in
                _ = try TextInputRoute.unproven.permitsAccessibilityEditing()
                return .noChange
            },
            targetedKeyTapper: { _, _, _ in keyTap() },
            targetedTextReplacer: { _, _, _, _, _ in
                try TextInputRoute.unproven.permitsAccessibilityEditing() ? .accessibilityValue : .unsupported
            },
            targetBundleIdentifier: { _ in nil },
            desktopOperationExecutor: DesktopOperationExecutor(laneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: coordinationRoot)))
    }
}
