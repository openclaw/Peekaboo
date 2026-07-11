import Darwin
import Foundation

/// Comprehensive terminal capability detection for progressive enhancement
struct TerminalCapabilities {
    /// Whether stdin is connected to a terminal and can drive an interactive input loop.
    let isInputInteractive: Bool
    let isInteractive: Bool
    let supportsColors: Bool
    let supportsTrueColor: Bool
    let width: Int
    let height: Int
    let termType: String?
    let isCI: Bool
    let isPiped: Bool

    /// Detect optimal output mode based on terminal capabilities
    var recommendedOutputMode: OutputMode {
        // Explicit overrides handled elsewhere

        // Environment-based fallbacks
        if !self.isInteractive || self.isCI || self.isPiped {
            return .minimal
        }

        // Prefer enhanced output when color is available
        return self.supportsColors ? .enhanced : .compact
    }
}

/// Terminal detection utilities following modern CLI best practices
enum TerminalDetector {
    @TaskLocal
    static var standardOutputFileDescriptor: Int32?

    /// Detect comprehensive terminal capabilities
    static func detectCapabilities() -> TerminalCapabilities {
        // Detect comprehensive terminal capabilities
        let isInputInteractive = self.isInteractiveTerminal(STDIN_FILENO)
        let outputFileDescriptor = self.standardOutputFileDescriptor ?? STDOUT_FILENO
        let isInteractive = self.isInteractiveTerminal(outputFileDescriptor)
        let (width, height) = self.getTerminalDimensions(outputFileDescriptor)
        let termType = ProcessInfo.processInfo.environment["TERM"]
        let isCI = self.isCIEnvironment()
        let isPiped = self.isPipedOutput(outputFileDescriptor)

        let supportsColors = self.detectColorSupport(termType: termType, isInteractive: isInteractive)
        let supportsTrueColor = self.detectTrueColorSupport()
        return TerminalCapabilities(
            isInputInteractive: isInputInteractive,
            isInteractive: isInteractive,
            supportsColors: supportsColors,
            supportsTrueColor: supportsTrueColor,
            width: width,
            height: height,
            termType: termType,
            isCI: isCI,
            isPiped: isPiped
        )
    }

    // MARK: - Core Detection Methods

    /// Check if stdout is connected to an interactive terminal
    private static func isInteractiveTerminal(_ outputFileDescriptor: Int32) -> Bool {
        // Check if stdout is connected to an interactive terminal
        isatty(outputFileDescriptor) != 0
    }

    /// Check if output is being piped or redirected
    private static func isPipedOutput(_ outputFileDescriptor: Int32) -> Bool {
        // Check if output is being piped or redirected
        isatty(outputFileDescriptor) == 0
    }

    /// Detect CI/automation environments
    private static func isCIEnvironment() -> Bool {
        // Detect CI/automation environments
        let ciVariables = [
            "CI", "CONTINUOUS_INTEGRATION",
            "GITHUB_ACTIONS", "GITHUB_WORKSPACE",
            "GITLAB_CI", "GITLAB_USER_LOGIN",
            "TRAVIS", "TRAVIS_BUILD_ID",
            "CIRCLECI", "CIRCLE_BUILD_NUM",
            "JENKINS_URL", "BUILD_NUMBER",
            "BUILDKITE", "BUILDKITE_BUILD_ID",
            "AZURE_PIPELINES", "TF_BUILD",
            "BITBUCKET_COMMIT", "BITBUCKET_BUILD_NUMBER",
            "DRONE", "DRONE_BUILD_NUMBER",
            "SEMAPHORE", "SEMAPHORE_BUILD_NUMBER",
        ]

        let env = ProcessInfo.processInfo.environment
        return ciVariables.contains { env[$0] != nil }
    }

    /// Get terminal dimensions using ioctl
    private static func getTerminalDimensions(_ outputFileDescriptor: Int32) -> (width: Int, height: Int) {
        // Get terminal dimensions using ioctl
        var windowSize = winsize()

        guard ioctl(outputFileDescriptor, TIOCGWINSZ, &windowSize) == 0 else {
            // Fallback to environment variables
            let width = Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "80") ?? 80
            let height = Int(ProcessInfo.processInfo.environment["LINES"] ?? "24") ?? 24
            return (width, height)
        }

        return (
            width: Int(windowSize.ws_col),
            height: Int(windowSize.ws_row)
        )
    }

    // MARK: - Color Support Detection

    /// Detect color support using multiple methods
    private static func detectColorSupport(termType: String?, isInteractive: Bool) -> Bool {
        // Detect color support using multiple methods
        guard isInteractive else { return false }

        // Method 1: Check COLORTERM environment variable (most reliable)
        if let colorTerm = ProcessInfo.processInfo.environment["COLORTERM"] {
            return !colorTerm.isEmpty
        }

        // Method 2: Check TERM variable patterns
        if let term = termType {
            let colorTermPatterns = [
                "color", "256color", "truecolor", "24bit",
                "xterm-256", "screen-256", "tmux-256",
            ]

            if colorTermPatterns.contains(where: term.contains) {
                return true
            }

            // Known color-capable terminals
            let colorTerminals = [
                "xterm", "screen", "tmux", "rxvt", "konsole",
                "gnome", "mate", "xfce", "terminology", "kitty",
                "alacritty", "iterm", "hyper", "vscode",
            ]

            if colorTerminals.contains(where: term.contains) {
                return true
            }
        }

        // Method 3: Platform-specific defaults
        #if os(macOS)
        // macOS Terminal.app and most modern terminals support colors
        return true
        #else
        // Conservative fallback for other platforms
        return termType != "dumb" && termType != nil
        #endif
    }

    /// Detect true color (24-bit) support
    private static func detectTrueColorSupport() -> Bool {
        // Detect true color (24-bit) support
        let env = ProcessInfo.processInfo.environment

        // Check COLORTERM for explicit true color support
        if let colorTerm = env["COLORTERM"] {
            return colorTerm.contains("truecolor") || colorTerm.contains("24bit")
        }

        // Check for terminals known to support true color
        if let term = env["TERM"] {
            let trueColorTerminals = [
                "iterm", "kitty", "alacritty", "wezterm",
                "hyper", "vscode", "gnome-terminal",
            ]
            return trueColorTerminals.contains(where: term.contains)
        }

        #if os(macOS)
        // Most modern macOS terminals support true color
        return true
        #else
        return false
        #endif
    }

    // MARK: - Utility Methods

    /// Get a human-readable description of terminal capabilities
    static func capabilitiesDescription(_ caps: TerminalCapabilities) -> String {
        // Get a human-readable description of terminal capabilities
        var features: [String] = []

        if caps.isInteractive {
            features.append("interactive")
        }
        if caps.isInputInteractive {
            features.append("interactive-input")
        }
        if caps.supportsColors {
            features.append("colors")
        }
        if caps.supportsTrueColor {
            features.append("truecolor")
        }
        if caps.isCI {
            features.append("CI-environment")
        }
        if caps.isPiped {
            features.append("piped")
        }

        let sizeInfo = "\(caps.width)x\(caps.height)"
        let termInfo = caps.termType ?? "unknown"

        return "\(termInfo) (\(sizeInfo)) - \(features.joined(separator: ", "))"
    }

    /// Check if we should force a specific output mode based on environment
    static func shouldForceOutputMode() -> OutputMode? {
        // Check if we should force a specific output mode based on environment
        let env = ProcessInfo.processInfo.environment

        // Check for explicit output mode environment variables
        if let mode = env["PEEKABOO_OUTPUT_MODE"] {
            switch mode.lowercased() {
            case "minimal", "simple": return .minimal
            case "compact": return .compact
            case "enhanced", "rich", "tui", "full": return .enhanced
            default: break
            }
        }

        // Check for NO_COLOR standard
        if env["NO_COLOR"] != nil {
            return .minimal
        }

        // Check for explicit color forcing
        if env["FORCE_COLOR"] != nil || env["CLICOLOR_FORCE"] != nil {
            return .enhanced
        }

        return nil
    }
}

// MARK: - Output Mode Extensions

extension OutputMode {
    /// Get a human-readable description of the output mode
    var description: String {
        switch self {
        case .minimal:
            "Minimal (no colors, CI-friendly)"
        case .compact:
            "Compact (colors and icons)"
        case .enhanced:
            "Enhanced (rich formatting and progress)"
        case .quiet:
            "Quiet (results only)"
        case .verbose:
            "Verbose (debug information)"
        }
    }

    /// Check if this mode supports colors
    var supportsColors: Bool {
        switch self {
        case .minimal, .quiet:
            false
        case .compact, .enhanced, .verbose:
            true
        }
    }

    /// Check if this mode supports rich formatting
    var supportsRichFormatting: Bool {
        switch self {
        case .minimal, .quiet, .compact:
            false
        case .enhanced, .verbose:
            true
        }
    }
}
