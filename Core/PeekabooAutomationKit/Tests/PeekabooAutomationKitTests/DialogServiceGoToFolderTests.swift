@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct DialogServiceGoToFolderTests {
    @Test
    func `go to folder stops before typing when opening hotkey fails`() async {
        let driver = FailingDialogSyntheticInputDriver(failingHotkeyCall: 1)
        let service = DialogService(syntheticInputDriver: driver)

        await #expect(throws: DialogInputError.hotkeyFailed(1)) {
            try await service.performGoToFolderKeyboardNavigation(directoryPath: "/tmp/target") {}
        }

        #expect(driver.events == [
            .hotkey(keys: ["cmd", "shift", "g"], holdDuration: 0.05),
        ])
    }

    @Test
    func `go to folder stops before typing when selection hotkey fails`() async {
        let driver = FailingDialogSyntheticInputDriver(failingHotkeyCall: 2)
        let service = DialogService(syntheticInputDriver: driver)

        await #expect(throws: DialogInputError.hotkeyFailed(2)) {
            try await service.performGoToFolderKeyboardNavigation(directoryPath: "/tmp/target") {}
        }

        #expect(driver.events == [
            .hotkey(keys: ["cmd", "shift", "g"], holdDuration: 0.05),
            .hotkey(keys: ["cmd", "a"], holdDuration: 0.05),
        ])
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

    private let failingHotkeyCall: Int
    private var hotkeyCallCount = 0
    private(set) var events: [Event] = []

    init(failingHotkeyCall: Int) {
        self.failingHotkeyCall = failingHotkeyCall
    }

    func click(at _: CGPoint, button _: MouseButton, count _: Int) throws {}
    func click(at _: CGPoint, button _: MouseButton, count _: Int, targetProcessIdentifier _: pid_t) async throws {}
    func move(to _: CGPoint) throws {}
    func currentLocation() -> CGPoint? {
        nil
    }

    func pressHold(at _: CGPoint, button _: MouseButton, duration _: TimeInterval) throws {}
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
}
