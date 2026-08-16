import ApplicationServices
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import struct PeekabooFoundation.DesktopActionFailure
import struct PeekabooFoundation.DesktopActionOutcome
import struct PeekabooFoundation.DesktopActionSequenceAccumulator
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct DialogServiceGoToFolderTests {
    @Test
    func `go to folder stops before typing when opening hotkey fails`() async {
        let driver = FailingDialogSyntheticInputDriver(failingHotkeyCall: 1)
        let service = DialogService(syntheticInputDriver: driver)

        do {
            _ = try await service.performGoToFolderKeyboardNavigation(directoryPath: "/tmp/target") { nil }
            Issue.record("Expected canonical input failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
        } catch {
            Issue.record(error)
        }

        #expect(driver.events == [
            .hotkey(keys: ["cmd", "shift", "g"], holdDuration: 0.05),
        ])
    }

    @Test
    func `go to folder stops before typing when selection hotkey fails`() async {
        let driver = FailingDialogSyntheticInputDriver(failingHotkeyCall: 2)
        let service = DialogService(syntheticInputDriver: driver)

        do {
            _ = try await service.performGoToFolderKeyboardNavigation(directoryPath: "/tmp/target") { nil }
            Issue.record("Expected canonical input failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .init(2)))
        } catch {
            Issue.record(error)
        }

        #expect(driver.events == [
            .hotkey(keys: ["cmd", "shift", "g"], holdDuration: 0.05),
            .hotkey(keys: ["cmd", "a"], holdDuration: 0.05),
        ])
    }

    @Test
    func `go to folder accumulates focus and every keyboard dispatch`() async throws {
        let driver = FailingDialogSyntheticInputDriver(failingHotkeyCall: nil)
        let service = DialogService(syntheticInputDriver: driver)
        let focusOutcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityValue, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)

        let outcome = try await service.performGoToFolderKeyboardNavigation(directoryPath: "/tmp/target") {
            focusOutcome
        }

        #expect(outcome.state == .dispatchedUnverified)
        #expect(outcome.delivery == .init(mechanism: .composite, mode: .foreground))
        #expect(outcome.dispatchState == .dispatched(unitCount: .init(15)))
        #expect(driver.events == [
            .hotkey(keys: ["cmd", "shift", "g"], holdDuration: 0.05),
            .hotkey(keys: ["cmd", "a"], holdDuration: 0.05),
            .type("/tmp/target", delayPerCharacter: 0.005),
            .tapKey(.return, modifiers: []),
        ])
    }

    @Test
    func `Missing path field returns expansion aware target disposition`() async throws {
        let driver = FailingDialogSyntheticInputDriver(failingHotkeyCall: nil)
        let service = DialogService(syntheticInputDriver: driver)
        let dialog = Element(AXUIElementCreateApplication(getpid() + 10000))

        let navigation = try await service.navigateToPath(
            "/tmp/target",
            in: dialog,
            ensureExpanded: false,
            appName: nil)

        #expect(navigation.method == "go_to_folder+auto_expand")
        #expect(
            navigation.targetDisposition ==
                DialogService.FileDialogNavigationResult.TargetDisposition.refreshAfterExpansion)
    }

    @Test
    func `later file-dialog failure preserves completed focus and navigation`() throws {
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.outcome(.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityValue, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)))
        sequence.record(.outcome(.dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .init(3))))

        let error = DialogService.preservingFileDialogFailure(
            DialogInputError.hotkeyFailed(9),
            after: sequence,
            target: nil)
        let failure = try #require(error as? DesktopActionFailure)

        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.delivery == .init(mechanism: .composite, mode: .foreground))
        #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .init(4)))
        #expect(failure.outcome.retrySafety == .unsafe)
    }
}

private enum DialogInputError: Error, Equatable {
    case hotkeyFailed(Int)
}

@MainActor
private final class FailingDialogSyntheticInputDriver: SyntheticInputDriving {
    enum Event: Equatable {
        case hotkey(keys: [String], holdDuration: TimeInterval)
        case type(String, delayPerCharacter: TimeInterval)
        case tapKey(SpecialKey, modifiers: CGEventFlags)
    }

    private let failingHotkeyCall: Int?
    private var hotkeyCallCount = 0
    private(set) var events: [Event] = []

    init(failingHotkeyCall: Int?) {
        self.failingHotkeyCall = failingHotkeyCall
    }

    func click(at _: CGPoint, button _: MouseButton, count _: Int) throws -> DesktopActionOutcome {
        Self.clickOutcome
    }

    func click(
        at _: CGPoint,
        button _: MouseButton,
        count _: Int,
        targetProcessIdentifier _: pid_t) async throws -> DesktopActionOutcome
    {
        Self.clickOutcome
    }

    func move(to _: CGPoint) throws {}
    func currentLocation() -> CGPoint? {
        nil
    }

    func pressHold(at _: CGPoint, button _: MouseButton, duration _: TimeInterval) async throws {}
    func scroll(deltaX _: Double, deltaY _: Double, at _: CGPoint?) throws {}

    func type(_ text: String, delayPerCharacter: TimeInterval) throws {
        self.events.append(.type(text, delayPerCharacter: delayPerCharacter))
    }

    func tapKey(_ key: SpecialKey, modifiers: CGEventFlags) throws {
        self.events.append(.tapKey(key, modifiers: modifiers))
    }

    func hotkey(keys: [String], holdDuration: TimeInterval) throws {
        self.hotkeyCallCount += 1
        self.events.append(.hotkey(keys: keys, holdDuration: holdDuration))
        if self.hotkeyCallCount == self.failingHotkeyCall {
            throw DialogInputError.hotkeyFailed(self.hotkeyCallCount)
        }
    }

    private static let clickOutcome = DesktopActionOutcome.dispatchedUnverified(
        delivery: .init(mechanism: .globalEvents, mode: .foreground),
        evidence: .deliveryAccepted)
}
