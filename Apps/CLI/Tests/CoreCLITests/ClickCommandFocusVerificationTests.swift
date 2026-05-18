import Testing
@testable import PeekabooCLI

struct ClickCommandFocusVerificationTests {
    @Test
    func `Exact app name match passes`() {
        let frontmost = FrontmostApplicationIdentity(
            name: "Claude",
            bundleIdentifier: "com.anthropic.claudedesktop",
            processIdentifier: 41
        )

        let message = CoordinateClickFocusVerifier.mismatchMessage(
            targetApp: "Claude",
            targetPID: nil,
            frontmost: frontmost
        )

        #expect(message == nil)
    }

    @Test
    func `Exact bundle identifier match passes`() {
        let frontmost = FrontmostApplicationIdentity(
            name: "Claude",
            bundleIdentifier: "com.anthropic.claudedesktop",
            processIdentifier: 41
        )

        let message = CoordinateClickFocusVerifier.mismatchMessage(
            targetApp: "com.anthropic.claudedesktop",
            targetPID: nil,
            frontmost: frontmost
        )

        #expect(message == nil)
    }

    @Test
    func `PID targets pass when the frontmost PID matches`() {
        let frontmost = FrontmostApplicationIdentity(
            name: "Claude",
            bundleIdentifier: "com.anthropic.claudedesktop",
            processIdentifier: 41
        )

        let directPIDMessage = CoordinateClickFocusVerifier.mismatchMessage(
            targetApp: nil,
            targetPID: 41,
            frontmost: frontmost
        )
        #expect(directPIDMessage == nil)

        let pidStringMessage = CoordinateClickFocusVerifier.mismatchMessage(
            targetApp: "PID:41",
            targetPID: nil,
            frontmost: frontmost
        )
        #expect(pidStringMessage == nil)
    }

    @Test
    func `Partial app-name matches still fail`() {
        let frontmost = FrontmostApplicationIdentity(
            name: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            processIdentifier: 99
        )

        let message = CoordinateClickFocusVerifier.mismatchMessage(
            targetApp: "Code",
            targetPID: nil,
            frontmost: frontmost
        )

        #expect(message != nil)
        #expect(message?.contains("'Xcode'") == true)
    }

    @Test
    func `Mismatch includes the frontmost application details`() {
        let frontmost = FrontmostApplicationIdentity(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            processIdentifier: 512
        )

        let message = CoordinateClickFocusVerifier.mismatchMessage(
            targetApp: "Claude",
            targetPID: nil,
            frontmost: frontmost
        )

        #expect(message?.contains("Target app 'Claude'") == true)
        #expect(message?.contains("'Google Chrome'") == true)
        #expect(message?.contains("com.google.Chrome") == true)
        #expect(message?.contains("PID 512") == true)
    }

    @Test
    func `Resolved focused window match passes`() {
        let frontmost = FrontmostApplicationIdentity(
            name: "OpenClaw Settings",
            bundleIdentifier: "com.openclaw.settings",
            processIdentifier: 99
        )
        let focusedWindow = FocusedWindowIdentity(windowID: 59620, title: "Settings")

        let message = CoordinateClickFocusVerifier.mismatchMessage(
            targetApp: "OpenClaw Settings",
            targetPID: 99,
            frontmost: frontmost,
            targetWindowID: 59620,
            targetWindowTitle: "Settings",
            focusedWindow: focusedWindow
        )

        #expect(message == nil)
    }

    @Test
    func `Resolved focused window mismatch fails`() {
        let frontmost = FrontmostApplicationIdentity(
            name: "Discord",
            bundleIdentifier: "com.hnc.Discord",
            processIdentifier: 512
        )
        let focusedWindow = FocusedWindowIdentity(windowID: 123, title: "Discord")

        let message = CoordinateClickFocusVerifier.mismatchMessage(
            targetApp: "OpenClaw Settings",
            targetPID: 99,
            frontmost: frontmost,
            targetWindowID: 59620,
            targetWindowTitle: "Settings",
            focusedWindow: focusedWindow
        )

        #expect(message?.contains("Target window 59620 'Settings'") == true)
        #expect(message?.contains("'Discord' window 123") == true)
        #expect(message?.contains("com.hnc.Discord") == true)
    }
}
