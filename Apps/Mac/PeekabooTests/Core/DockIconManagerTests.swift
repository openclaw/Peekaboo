import AppKit
import Testing
@testable import Peekaboo

@Suite(.tags(.unit, .fast))
@MainActor
struct DockIconManagerTests {
    @Test(arguments: [false, true])
    func `startup applies policy before settings connect`(backgroundHost: Bool) {
        let recorder = ActivationPolicyRecorder()
        _ = DockIconManager(
            isBackgroundBridgeHost: backgroundHost,
            applyActivationPolicy: recorder.apply)

        #expect(recorder.policies == [backgroundHost ? .accessory : .regular])
    }

    @Test(arguments: [false, true])
    func `connecting and changing the preference reconciles ordinary launch`(showInDock: Bool) {
        let recorder = ActivationPolicyRecorder()
        let manager = DockIconManager(isBackgroundBridgeHost: false, applyActivationPolicy: recorder.apply)
        let settings = DockPreferences(showInDock: showInDock)

        manager.connectToSettings(settings)
        settings.showInDock.toggle()
        manager.updateDockVisibility()
        settings.showInDock.toggle()
        manager.updateDockVisibility()

        let preferred: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        let toggled: NSApplication.ActivationPolicy = showInDock ? .accessory : .regular
        #expect(recorder.policies == [.regular, preferred, toggled, preferred])
    }

    @Test(arguments: [false, true], [false, true])
    func `presentation and later reconciliation honor the preference`(showInDock: Bool, backgroundHost: Bool) {
        let recorder = ActivationPolicyRecorder()
        let manager = DockIconManager(
            isBackgroundBridgeHost: backgroundHost,
            applyActivationPolicy: recorder.apply)
        manager.connectToSettings(DockPreferences(showInDock: showInDock))
        recorder.policies.removeAll()

        manager.prepareForPresentation()
        manager.updateDockVisibility()
        manager.prepareForPresentation()

        let preferred: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        #expect(recorder.policies == [preferred, preferred, preferred])
    }

    @Test
    func `settings and mode reconciliation cannot present an unattended host`() {
        let recorder = ActivationPolicyRecorder()
        let manager = DockIconManager(isBackgroundBridgeHost: true, applyActivationPolicy: recorder.apply)
        let settings = DockPreferences(showInDock: true)

        manager.connectToSettings(settings)
        settings.showInDock = false
        manager.updateDockVisibility()
        settings.showInDock = true
        manager.updateDockVisibility()
        manager.setBackgroundBridgeHostMode(true)

        #expect(recorder.policies == [.accessory, .accessory, .accessory, .accessory, .accessory])
    }

    @Test
    func `explicit presentation survives late settings and repeated background setup`() {
        let recorder = ActivationPolicyRecorder()
        let manager = DockIconManager(isBackgroundBridgeHost: true, applyActivationPolicy: recorder.apply)

        manager.prepareForPresentation()
        manager.setBackgroundBridgeHostMode(true)
        let settings = DockPreferences(showInDock: false)
        manager.connectToSettings(settings)
        manager.updateDockVisibility()
        settings.showInDock = true
        manager.updateDockVisibility()

        #expect(recorder.policies == [.accessory, .regular, .regular, .accessory, .accessory, .regular])
    }

    @Test
    func `leaving background mode clears the explicit presentation latch`() {
        let recorder = ActivationPolicyRecorder()
        let manager = DockIconManager(isBackgroundBridgeHost: true, applyActivationPolicy: recorder.apply)
        manager.connectToSettings(DockPreferences(showInDock: true))
        manager.prepareForPresentation()
        recorder.policies.removeAll()

        manager.setBackgroundBridgeHostMode(false)
        manager.setBackgroundBridgeHostMode(true)
        manager.updateDockVisibility()
        manager.prepareForPresentation()

        #expect(recorder.policies == [.regular, .accessory, .accessory, .regular])
    }
}

@MainActor
private final class DockPreferences: DockIconPreferences {
    var showInDock: Bool

    init(showInDock: Bool) {
        self.showInDock = showInDock
    }
}

@MainActor
private final class ActivationPolicyRecorder {
    var policies: [NSApplication.ActivationPolicy] = []

    func apply(_ policy: NSApplication.ActivationPolicy) {
        self.policies.append(policy)
    }
}
