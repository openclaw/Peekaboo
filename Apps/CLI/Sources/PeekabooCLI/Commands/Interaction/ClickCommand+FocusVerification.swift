import Foundation
import PeekabooCore
import PeekabooFoundation

struct FrontmostApplicationIdentity: Equatable {
    let name: String?
    let bundleIdentifier: String?
    let processIdentifier: Int32?

    init(
        name: String? = nil,
        bundleIdentifier: String? = nil,
        processIdentifier: Int32? = nil
    ) {
        self.name = name?.nilIfEmpty
        self.bundleIdentifier = bundleIdentifier?.nilIfEmpty
        self.processIdentifier = processIdentifier
    }

    init(application: ServiceApplicationInfo?) {
        self.init(
            name: application?.name,
            bundleIdentifier: application?.bundleIdentifier,
            processIdentifier: application?.processIdentifier
        )
    }

    var displayDescription: String {
        var components: [String] = []
        if let name = self.name {
            components.append("'\(name)'")
        }
        if let bundleIdentifier = self.bundleIdentifier {
            components.append(bundleIdentifier)
        }
        if let processIdentifier = self.processIdentifier {
            components.append("PID \(processIdentifier)")
        }
        if components.isEmpty {
            return "unknown application"
        }
        return components.joined(separator: " ")
    }
}

struct FocusedWindowIdentity: Equatable {
    let windowID: Int?
    let title: String?

    init(
        windowID: Int? = nil,
        title: String? = nil
    ) {
        self.windowID = windowID
        self.title = title?.nilIfEmpty
    }

    init(window: ServiceWindowInfo?) {
        self.init(
            windowID: window?.windowID,
            title: window?.title
        )
    }

    var displayDescription: String {
        var components: [String] = []
        if let title = self.title {
            components.append("'\(title)'")
        }
        if let windowID = self.windowID {
            components.append("window \(windowID)")
        }
        if components.isEmpty {
            return "unknown window"
        }
        return components.joined(separator: " ")
    }
}

enum CoordinateClickFocusVerifier {
    static func mismatchMessage(
        targetApp: String?,
        targetPID: Int32?,
        frontmost: FrontmostApplicationIdentity,
        targetWindowID: Int? = nil,
        targetWindowTitle: String? = nil,
        focusedWindow: FocusedWindowIdentity? = nil
    ) -> String? {
        guard targetApp != nil || targetPID != nil || targetWindowID != nil else {
            return nil
        }

        if let targetWindowID {
            if focusedWindow?.windowID == targetWindowID {
                return nil
            }

            let targetDescription = self.targetDescription(
                targetApp: targetApp,
                targetPID: targetPID,
                targetWindowID: targetWindowID,
                targetWindowTitle: targetWindowTitle
            )
            let focusedWindowDescription = focusedWindow?.displayDescription ?? "unknown window"
            let frontmostDescription = frontmost.displayDescription

            return """
            \(targetDescription) is not focused before the coordinate click. Focused window: \(
                focusedWindowDescription
            ). Currently frontmost: \(frontmostDescription).
            The coordinate click would land on the focused/frontmost window instead.

            Hints:
              - Ensure no other window is overlapping the target
              - Try clicking by element ID (--on) instead of coordinates
              - Close or minimize interfering windows first
            """
        }

        if let targetPID, frontmost.processIdentifier == targetPID {
            return nil
        }

        if let targetApp, self.matches(targetApp: targetApp, frontmost: frontmost) {
            return nil
        }

        let targetDescription = self.targetDescription(
            targetApp: targetApp,
            targetPID: targetPID,
            targetWindowID: targetWindowID,
            targetWindowTitle: targetWindowTitle
        )
        let frontmostDescription = frontmost.displayDescription

        return """
        \(targetDescription) is not frontmost before the coordinate click. Currently frontmost: \(frontmostDescription).
        The coordinate click would land on the frontmost window instead.

        Hints:
          - Ensure no other window is overlapping the target
          - Try clicking by element ID (--on) instead of coordinates
          - Close or minimize interfering windows first
        """
    }

    static func targetDescription(
        targetApp: String?,
        targetPID: Int32?,
        targetWindowID: Int? = nil,
        targetWindowTitle: String? = nil
    ) -> String {
        if let targetWindowID {
            if let targetWindowTitle {
                return "Target window \(targetWindowID) '\(targetWindowTitle)'"
            }
            return "Target window \(targetWindowID)"
        }
        if let targetApp {
            return "Target app '\(targetApp)'"
        }
        if let targetPID {
            return "Target PID \(targetPID)"
        }
        return "Target application"
    }

    private static func matches(targetApp: String, frontmost: FrontmostApplicationIdentity) -> Bool {
        let trimmedTarget = targetApp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty else {
            return false
        }

        if let pid = self.parsePID(trimmedTarget), frontmost.processIdentifier == pid {
            return true
        }

        if let bundleIdentifier = frontmost.bundleIdentifier,
           bundleIdentifier.caseInsensitiveCompare(trimmedTarget) == .orderedSame {
            return true
        }

        if let name = frontmost.name,
           name.caseInsensitiveCompare(trimmedTarget) == .orderedSame {
            return true
        }

        return false
    }

    private static func parsePID(_ identifier: String) -> Int32? {
        guard identifier.hasPrefix("PID:") else {
            return nil
        }
        return Int32(identifier.dropFirst(4))
    }
}

@available(macOS 14.0, *)
@MainActor
extension ClickCommand {
    /// Verify that the resolved target is actually focused before dispatching a coordinate click.
    func verifyFocusForCoordinateClick(coordinateResolution: InteractionCoordinateResolution?) async throws {
        let frontmostInfo = try? await self.services.applications.getFrontmostApplication()
        let frontmost = FrontmostApplicationIdentity(application: frontmostInfo)
        let targetWindowID = coordinateResolution?.targetWindowID
        let focusedWindow = if targetWindowID != nil {
            await FocusedWindowIdentity(window: try? self.services.windows.getFocusedWindow())
        } else {
            nil as FocusedWindowIdentity?
        }
        let targetApp = coordinateResolution?.targetApplicationName ?? self.target.app
        let targetPID = coordinateResolution?.targetProcessIdentifier ?? self.target.pid
        if let message = CoordinateClickFocusVerifier.mismatchMessage(
            targetApp: targetApp,
            targetPID: targetPID,
            frontmost: frontmost,
            targetWindowID: targetWindowID,
            targetWindowTitle: coordinateResolution?.targetWindowTitle,
            focusedWindow: focusedWindow
        ) {
            let targetDescription = CoordinateClickFocusVerifier.targetDescription(
                targetApp: targetApp,
                targetPID: targetPID,
                targetWindowID: targetWindowID,
                targetWindowTitle: coordinateResolution?.targetWindowTitle
            )
            self.outputLogger.warn(
                "Coordinate click focus mismatch for " +
                    "\(targetDescription). " +
                    "Frontmost is \(frontmost.displayDescription)."
            )
            throw PeekabooError.clickFailed(message)
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}
