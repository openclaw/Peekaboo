import Foundation
import PeekabooCore

@MainActor
extension SeeCommand {
    func focusIfNeeded(appIdentifier: String) async throws {
        switch captureFocus {
        case .background:
            return
        case .auto:
            if try await self.hasVisibleCaptureWindow(appIdentifier: appIdentifier) {
                return
            }
            if windowTitle == nil, try await self.isAlreadyFrontmost(appIdentifier: appIdentifier) {
                return
            }
            let focusIdentifier = try await resolveFocusIdentifier(appIdentifier: appIdentifier)
            let options = FocusOptions(autoFocus: true, spaceSwitch: false, bringToCurrentSpace: false)
            try await withCaptureFocusMutation {
                try await ensureFocused(
                    applicationName: focusIdentifier,
                    windowTitle: self.windowTitle,
                    options: options,
                    services: self.services
                )
            }
        case .foreground:
            let focusIdentifier = try await resolveFocusIdentifier(appIdentifier: appIdentifier)
            let options = FocusOptions(autoFocus: true, spaceSwitch: true, bringToCurrentSpace: true)
            try await withCaptureFocusMutation {
                try await ensureFocused(
                    applicationName: focusIdentifier,
                    windowTitle: self.windowTitle,
                    options: options,
                    services: self.services
                )
            }
        }
    }

    private func hasVisibleCaptureWindow(appIdentifier: String) async throws -> Bool {
        guard let app = try await FocusFailurePolicy.optional({
            try await services.applications.findApplication(identifier: appIdentifier)
        }) else {
            return false
        }

        let lookupIdentifier = app.bundleIdentifier ?? app.name
        guard let response = try await FocusFailurePolicy.optional({
            try await services.applications.listWindows(for: lookupIdentifier, timeout: 1)
        }) else {
            return false
        }

        // Auto focus should not block fast background captures when the app already exposes
        // a renderable window; explicit foreground mode still opts into forced activation.
        let candidates = ObservationTargetResolver.captureCandidates(from: response.data.windows)
        guard !candidates.isEmpty else {
            return false
        }

        guard let windowTitle = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !windowTitle.isEmpty
        else {
            return true
        }

        return candidates.contains {
            $0.title.localizedCaseInsensitiveContains(windowTitle)
        }
    }

    private func isAlreadyFrontmost(appIdentifier: String) async throws -> Bool {
        guard let frontmost = try await FocusFailurePolicy.optional({
            try await services.applications.getFrontmostApplication()
        }),
            let target = try await FocusFailurePolicy.optional({
                try await services.applications.findApplication(identifier: appIdentifier)
            })
        else {
            return false
        }

        return frontmost.processIdentifier == target.processIdentifier
    }

    private func resolveFocusIdentifier(appIdentifier: String) async throws -> String {
        guard let app = try await FocusFailurePolicy.optional({
            try await services.applications.findApplication(identifier: appIdentifier)
        }) else {
            return appIdentifier
        }
        return "PID:\(app.processIdentifier)"
    }
}
