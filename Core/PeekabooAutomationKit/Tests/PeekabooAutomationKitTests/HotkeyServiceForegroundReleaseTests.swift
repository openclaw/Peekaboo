import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct HotkeyServiceForegroundReleaseTests {
    @Test(arguments: ["shift,tab", "cmd,shift,l", "ctrl,alt,delete", "fn,f1", "return"], [0, 50])
    func `foreground chords clear their flags on the only key up`(keys: String, holdDuration: Int) async throws {
        let fixture = ForegroundHotkeyFixture()
        defer { fixture.removeCoordinationDirectory() }
        let service = fixture.makeService()

        let result = try await service.hotkey(keys: keys, holdDuration: holdDuration)

        let expected: (keyCode: Int64, flags: CGEventFlags) = switch keys {
        case "shift,tab": (0x30, .maskShift)
        case "cmd,shift,l": (0x25, [.maskCommand, .maskShift])
        case "ctrl,alt,delete": (0x33, [.maskControl, .maskAlternate])
        case "fn,f1": (0x7A, .maskSecondaryFn)
        default: (0x24, [])
        }
        #expect(fixture.events == [
            .init(type: .keyDown, keyCode: expected.keyCode, flags: expected.flags),
            .init(type: .keyUp, keyCode: expected.keyCode, flags: []),
        ])
        #expect(fixture.sleeps == [holdDuration > 0 ? 50_000_000 : 10_000_000])
        #expect(fixture.eventCountsAtSleep == [holdDuration > 0 ? 1 : 2])
        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
        #expect(result.outcome.evidence == .deliveryAccepted)
    }

    @Test(arguments: [0, 50])
    func `cancelled foreground hold or settlement releases once and retains dispatch`(holdDuration: Int) async throws {
        let fixture = ForegroundHotkeyFixture(sleepError: CancellationError())
        defer { fixture.removeCoordinationDirectory() }
        let service = fixture.makeService()

        do {
            _ = try await service.hotkey(keys: "shift,tab", holdDuration: holdDuration)
            Issue.record("Expected cancellation after foreground dispatch")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.operation == .hotkey)
            #expect(error.emittedUnitCount == fixture.events.count)
            #expect(error.emittedUnitCount == 2)
            #expect(error.delivery == .init(mechanism: .globalEvents, mode: .foreground))
            #expect(!error.retrySafe)
            let failure = error.desktopActionFailure(delivery: nil)
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
            #expect(failure.outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
        }
        #expect(fixture.events == [
            .init(type: .keyDown, keyCode: 0x30, flags: .maskShift),
            .init(type: .keyUp, keyCode: 0x30, flags: []),
        ])
        #expect(fixture.eventCountsAtSleep == [holdDuration > 0 ? 1 : 2])
    }

    @Test
    func `foreground sleeper failure releases the key before returning an indeterminate error`() async throws {
        let fixture = ForegroundHotkeyFixture(sleepError: ForegroundHotkeyProbeError.failed)
        defer { fixture.removeCoordinationDirectory() }

        do {
            _ = try await fixture.makeService().hotkey(keys: "cmd,shift,l", holdDuration: 50)
            Issue.record("Expected foreground hold failure")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.emittedUnitCount == fixture.events.count)
            #expect(error.emittedUnitCount == 2)
            #expect(error.causeDescription == ForegroundHotkeyProbeError.failed.localizedDescription)
        }
        #expect(fixture.events.map(\.type) == [.keyDown, .keyUp])
        #expect(fixture.events.last?.flags == [])
    }

    @Test
    func `cancellation during foreground preparation posts no events`() async throws {
        let fixture = ForegroundHotkeyFixture()
        defer { fixture.removeCoordinationDirectory() }
        let service = fixture.makeService()
        let task = Task { @MainActor in
            try await service.hotkeyWithLanePreparation(
                keys: "shift,tab",
                holdDuration: 50,
                lanePreparation: {
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }

        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(fixture.events.isEmpty)
        #expect(fixture.sleeps.isEmpty)
    }

    @Test(arguments: ["", "shift", "cmd,unknown-key", "a,b"])
    func `invalid foreground chord posts no events`(keys: String) async throws {
        let fixture = ForegroundHotkeyFixture()
        defer { fixture.removeCoordinationDirectory() }

        await #expect(throws: PeekabooError.self) {
            _ = try await fixture.makeService().hotkey(keys: keys, holdDuration: 50)
        }
        #expect(fixture.events.isEmpty)
        #expect(fixture.sleeps.isEmpty)
    }

    @Test
    func `overflowing foreground hold posts no events`() async throws {
        let fixture = ForegroundHotkeyFixture()
        defer { fixture.removeCoordinationDirectory() }

        await #expect(throws: PeekabooError.self) {
            _ = try await fixture.makeService().hotkey(keys: "shift,tab", holdDuration: Int.max)
        }
        #expect(fixture.events.isEmpty)
        #expect(fixture.sleeps.isEmpty)
    }
}

private enum ForegroundHotkeyProbeError: Error {
    case failed
}

@MainActor
private final class ForegroundHotkeyFixture {
    struct PostedEvent: Equatable {
        let type: CGEventType
        let keyCode: Int64
        let flags: CGEventFlags
    }

    private let coordinationRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("foreground-hotkey-release-\(UUID())")
    private let sleepError: (any Error)?
    private(set) var events: [PostedEvent] = []
    private(set) var sleeps: [UInt64] = []
    private(set) var eventCountsAtSleep: [Int] = []

    init(sleepError: (any Error)? = nil) {
        self.sleepError = sleepError
    }

    func makeService() -> HotkeyService {
        HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: {
                Issue.record("Foreground fixture unexpectedly checked targeted input access")
                return false
            },
            eventPoster: { _, _ in Issue.record("Foreground fixture unexpectedly posted targeted input") },
            foregroundEventPoster: { event in
                self.events.append(PostedEvent(
                    type: event.type,
                    keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                    flags: event.flags))
            },
            frontmostApplicationResolver: { nil },
            holdSleeper: { nanoseconds in
                self.sleeps.append(nanoseconds)
                self.eventCountsAtSleep.append(self.events.count)
                if let sleepError = self.sleepError {
                    throw sleepError
                }
            },
            desktopOperationExecutor: DesktopOperationExecutor(
                laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: self.coordinationRoot)))
    }

    func removeCoordinationDirectory() {
        try? FileManager.default.removeItem(at: self.coordinationRoot)
    }
}
