@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct ScrollServiceTargetResolutionTests {
    @Test
    @MainActor
    func `action-first missing snapshot fails as stale instead of falling back`() async {
        let service = ScrollService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst))

        do {
            try await service.scroll(ScrollRequest(
                direction: .down,
                amount: 1,
                target: "S1",
                smooth: false,
                delay: 0,
                snapshotId: "missing"))
            Issue.record("Expected stale element error for missing action snapshot.")
        } catch let error as ActionInputError {
            #expect(error == .staleElement)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    @MainActor
    func `synthetic scroll treats explicit missing snapshot as authoritative`() async {
        let synthetic = ScrollRecordingSyntheticInputDriver()
        let service = ScrollService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthFirst),
            syntheticInputDriver: synthetic)

        do {
            try await service.scroll(ScrollRequest(
                direction: .down,
                amount: 1,
                target: "missing-\(UUID().uuidString)",
                smooth: false,
                delay: 2,
                snapshotId: "missing"))
            Issue.record("Expected stale element error for missing synthetic snapshot.")
        } catch let error as ActionInputError {
            #expect(error == .staleElement)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `action-first unresolved snapshot target falls back to coordinate scroll`() async throws {
        let element = DetectedElement(
            id: "S1",
            type: .other,
            label: "peekaboo-unresolved-scroll-target-\(UUID().uuidString)",
            value: nil,
            bounds: .init(x: 200, y: 240, width: 60, height: 40),
            isEnabled: true,
            isSelected: nil,
            attributes: [:])
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(other: [element]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 1, method: "test"))
        let synthetic = ScrollRecordingSyntheticInputDriver()
        let service = ScrollService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            syntheticInputDriver: synthetic)

        let result = try await service.scroll(ScrollRequest(
            direction: .down,
            amount: 1,
            target: "S1",
            smooth: false,
            delay: 0,
            snapshotId: "snapshot"))

        #expect(result.path == .synth)
        #expect(result.fallbackReason == .missingElement)
        #expect(synthetic.events == [
            .move(CGPoint(x: 230, y: 260)),
            .scroll(deltaX: 0, deltaY: -50, at: CGPoint(x: 230, y: 260)),
        ])
    }

    @Test
    func `action-first scroll preserves explicit page count`() {
        #expect(ScrollService.actionScrollPages(amount: 3, strategy: .actionFirst) == 3)
        #expect(ScrollService.actionScrollPages(amount: -3, strategy: .actionFirst) == 3)
        #expect(ScrollService.actionScrollPages(amount: 0, strategy: .actionFirst) == 1)
    }

    @Test
    func `smooth or delayed scroll requires synthetic semantics`() {
        #expect(!ScrollService.requiresSyntheticScrollSemantics(ScrollRequest(
            direction: .down,
            amount: 3,
            target: "S1",
            smooth: false,
            delay: 0,
            snapshotId: "snapshot")))
        #expect(ScrollService.requiresSyntheticScrollSemantics(ScrollRequest(
            direction: .down,
            amount: 3,
            target: "S1",
            smooth: true,
            delay: 0,
            snapshotId: "snapshot")))
        #expect(ScrollService.requiresSyntheticScrollSemantics(ScrollRequest(
            direction: .down,
            amount: 3,
            target: "S1",
            smooth: false,
            delay: 2,
            snapshotId: "snapshot")))
    }

    @Test
    func `action-only scroll preserves explicit page count`() {
        #expect(ScrollService.actionScrollPages(amount: 3, strategy: .actionOnly) == 3)
        #expect(ScrollService.actionScrollPages(amount: -3, strategy: .actionOnly) == 3)
        #expect(ScrollService.actionScrollPages(amount: 0, strategy: .actionOnly) == 1)
    }

    @Test
    @MainActor
    func `action-only scroll without target reports unsupported action`() async {
        let service = ScrollService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly))

        do {
            try await service.scroll(ScrollRequest(
                direction: .down,
                amount: 1,
                target: "   ",
                smooth: false,
                delay: 0,
                snapshotId: nil))
            Issue.record("Expected unsupported action error for targetless action-only scroll.")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.actionUnsupported))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@MainActor
private final class ScrollRecordingSyntheticInputDriver: SyntheticInputDriving {
    enum Event: Equatable {
        case click(point: CGPoint, button: MouseButton, count: Int)
        case move(CGPoint)
        case currentLocation
        case scroll(deltaX: Double, deltaY: Double, at: CGPoint?)
    }

    private(set) var events: [Event] = []

    func click(at point: CGPoint, button: MouseButton, count: Int) throws {
        self.events.append(.click(point: point, button: button, count: count))
    }

    func click(at point: CGPoint, button: MouseButton, count: Int, targetProcessIdentifier _: pid_t) async throws {
        self.events.append(.click(point: point, button: button, count: count))
    }

    func move(to point: CGPoint) throws {
        self.events.append(.move(point))
    }

    func currentLocation() -> CGPoint? {
        self.events.append(.currentLocation)
        return nil
    }

    func pressHold(at _: CGPoint, button _: MouseButton, duration _: TimeInterval) async throws {}

    func scroll(deltaX: Double, deltaY: Double, at point: CGPoint?) throws {
        self.events.append(.scroll(deltaX: deltaX, deltaY: deltaY, at: point))
    }

    func type(_: String, delayPerCharacter _: TimeInterval) throws {}

    func tapKey(_: SpecialKey, modifiers _: CGEventFlags) throws {}

    func hotkey(keys _: [String], holdDuration _: TimeInterval) throws {}
}
