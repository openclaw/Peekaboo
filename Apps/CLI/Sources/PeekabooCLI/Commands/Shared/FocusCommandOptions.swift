import Commander
import Foundation
import PeekabooCore

/// CLI-facing wrapper that maps command-line flags to core focus options.
struct FocusCommandOptions: CommanderParsable, FocusOptionsProtocol {
    @Flag(name: .long, help: "Focus the target and use foreground delivery where supported")
    var foreground = false

    @Flag(name: .long, help: "Send input to the target process without focusing it")
    var focusBackground = false

    @Flag(name: .long, help: "Disable automatic foreground focus (requires --foreground)")
    var noAutoFocus = false

    @Option(name: .customLong("focus-timeout"), help: "Timeout for focus operations (bare values are milliseconds)")
    var focusTimeoutDuration: CLIDuration?

    @Option(name: .long, help: "Number of retries for focus operations")
    var focusRetryCount: Int?

    @Flag(name: .long, help: "Switch to window's Space if on different Space")
    var spaceSwitch = false

    @Flag(name: .long, help: "Bring window to current Space instead of switching")
    var bringToCurrentSpace = false

    var backgroundDeliveryExplicitlyRequested: Bool {
        self.focusBackground
    }

    var hasForegroundFocusOverrides: Bool {
        self.noAutoFocus ||
            self.focusTimeoutDuration != nil ||
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
        self.focusTimeoutDuration?.seconds
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
