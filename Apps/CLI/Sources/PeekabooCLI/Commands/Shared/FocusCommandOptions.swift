import Commander
import Foundation
import PeekabooCore

/// CLI-facing wrapper that maps command-line flags to core focus options.
struct FocusCommandOptions: CommanderParsable, FocusOptionsProtocol {
    @Flag(name: .long, help: "Disable automatic focus before interaction (not recommended)")
    var noAutoFocus = false

    @Option(name: .long, help: "Timeout for focus operations in seconds")
    var focusTimeoutSeconds: TimeInterval?

    @Option(name: .long, help: "Number of retries for focus operations")
    var focusRetryCount: Int?

    @Flag(name: .long, help: "Switch to window's Space if on different Space")
    var spaceSwitch = false

    @Flag(name: .long, help: "Bring window to current Space instead of switching")
    var bringToCurrentSpace = false

    @RuntimeStorage private var focusBackgroundStorage: Bool?

    var focusBackground: Bool {
        get { self.focusBackgroundStorage ?? false }
        set { self.focusBackgroundStorage = newValue }
    }

    var backgroundDeliveryExplicitlyRequested: Bool {
        self.focusBackgroundStorage == true
    }

    var hasForegroundFocusOverrides: Bool {
        self.noAutoFocus ||
            self.focusTimeoutSeconds != nil ||
            self.focusRetryCount != nil ||
            self.spaceSwitch ||
            self.bringToCurrentSpace
    }

    init() {}

    // MARK: FocusOptionsProtocol

    var autoFocus: Bool {
        !self.noAutoFocus
    }

    var focusTimeout: TimeInterval? {
        self.focusTimeoutSeconds
    }

    // MARK: Bridging helper

    /// Convert to the core FocusOptions value type.
    var asFocusOptions: FocusOptions {
        FocusOptions(
            autoFocus: self.autoFocus,
            focusTimeout: self.focusTimeout,
            focusRetryCount: self.focusRetryCount,
            spaceSwitch: self.spaceSwitch,
            bringToCurrentSpace: self.bringToCurrentSpace
        )
    }
}
