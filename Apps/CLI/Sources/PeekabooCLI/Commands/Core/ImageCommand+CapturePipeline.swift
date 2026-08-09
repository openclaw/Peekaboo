import Algorithms
import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
extension ImageCommand {
    func performCapture() async throws -> [ImageCapturedFile] {
        if let appName = self.app?.lowercased() {
            switch appName {
            case "menubar":
                return try await self.captureMenuBar()
            case "frontmost":
                return try await self.captureFrontmost()
            default:
                break
            }
        }

        let captureMode = self.determineMode()
        var results: [ImageCapturedFile] = []

        switch captureMode {
        case .screen:
            results = try await self.captureScreens()
        case .window:
            if let windowId = self.windowId {
                results = try await self.captureWindowById(windowId)
            } else {
                let target = try self.observationApplicationTargetForWindowCapture()
                results = try await self.captureApplicationWindow(target)
            }
        case .multi:
            if self.app != nil || self.pid != nil {
                let identifier = try self.resolveApplicationIdentifier()
                results = try await self.captureAllApplicationWindows(identifier)
            } else {
                results = try await self.captureScreens()
            }
        case .frontmost:
            results = try await self.captureFrontmost()
        case .area:
            results = try await self.captureArea()
        }

        return results
    }

    private func determineMode() -> PeekabooCore.CaptureMode {
        if let mode {
            return mode
        }

        if self.region != nil {
            return .area
        }

        if self.app != nil || self.pid != nil || self.windowTitle != nil || self.windowIndex != nil || self
            .windowId != nil {
            return .window
        }

        return .frontmost
    }

    private func captureWindowById(_ windowId: Int) async throws -> [ImageCapturedFile] {
        let target = try self.observationTargetForExactWindowCapture(windowId)
        let observation = try await self.captureObservation(
            target: target,
            preferredName: "window-\(windowId)",
            index: nil
        )

        let title = observation.capture.metadata.windowInfo?.title
        let preferredName = if let title, !title.isEmpty {
            title
        } else {
            "window-\(windowId)"
        }

        return try [
            self.capturedFile(
                from: observation,
                preferredName: preferredName,
                windowIndex: nil
            ),
        ]
    }

    private func captureScreens() async throws -> [ImageCapturedFile] {
        if let index = self.screenIndex {
            let observation = try await self.captureObservation(
                target: .screen(index: index),
                preferredName: "screen\(index)",
                index: nil
            )
            return try [
                self.capturedFile(
                    from: observation,
                    preferredName: "screen\(index)",
                    windowIndex: nil
                ),
            ]
        }

        let screens = self.services.screens.listScreens()
        let indexes = screens.isEmpty ? [0] : Array(screens.indices)

        var savedFiles: [ImageCapturedFile] = []
        for (ordinal, displayIndex) in indexes.indexed() {
            let observation = try await self.captureObservation(
                target: .screen(index: displayIndex),
                preferredName: "screen\(displayIndex)",
                index: ordinal
            )
            try savedFiles.append(self.capturedFile(
                from: observation,
                preferredName: "screen\(displayIndex)",
                windowIndex: nil
            ))
        }

        return savedFiles
    }

    private func captureApplicationWindow(_ target: ImageWindowObservationTarget) async throws -> [ImageCapturedFile] {
        try await self.focusIfNeeded(appIdentifier: target.focusIdentifier)
        let observation = try await self.captureObservation(
            target: target.target,
            preferredName: target.preferredName,
            index: nil
        )
        let resolvedWindow = observation.target.window
        let resolvedTitle = resolvedWindow?.title.trimmingCharacters(in: .whitespacesAndNewlines)

        let saved = try self.capturedFile(
            from: observation,
            preferredName: self.windowTitle ?? (resolvedTitle?.isEmpty == false ? resolvedTitle : nil) ?? target
                .preferredName,
            windowIndex: resolvedWindow?.index
        )

        return [saved]
    }

    private func captureAllApplicationWindows(_ identifier: String) async throws -> [ImageCapturedFile] {
        try await self.focusIfNeeded(appIdentifier: identifier)

        let windows = try await WindowServiceBridge.listWindows(
            windows: self.services.windows,
            target: .application(identifier)
        )

        let filtered = ObservationTargetResolver.captureCandidates(from: windows)

        guard !filtered.isEmpty else {
            throw PeekabooError.windowNotFound(criteria: "No shareable windows for \(identifier)")
        }

        var savedFiles: [ImageCapturedFile] = []
        for (ordinal, window) in filtered.indexed() {
            let observation = try await self.captureObservation(
                target: .windowID(CGWindowID(window.windowID)),
                preferredName: window.title,
                index: ordinal
            )

            let saved = try self.capturedFile(
                from: observation,
                preferredName: window.title,
                windowIndex: window.index
            )
            savedFiles.append(saved)
        }

        return savedFiles
    }

    private func captureFrontmost() async throws -> [ImageCapturedFile] {
        let observation = try await self.captureObservation(
            target: .frontmost,
            preferredName: "frontmost",
            index: nil
        )
        return try [
            self.capturedFile(
                from: observation,
                preferredName: "frontmost",
                windowIndex: nil
            ),
        ]
    }

    private func captureArea() async throws -> [ImageCapturedFile] {
        let rect = try self.areaCaptureRect()
        let observation = try await self.captureObservation(
            target: .area(rect),
            preferredName: "area",
            index: nil
        )
        return try [
            self.capturedFile(
                from: observation,
                preferredName: "area",
                windowIndex: nil
            ),
        ]
    }

    func areaCaptureRect() throws -> CGRect {
        guard let region = self.region?.trimmingCharacters(in: .whitespacesAndNewlines),
              !region.isEmpty
        else {
            throw ValidationError("Region must be provided when using --mode area")
        }

        let values = region
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard values.count == 4,
              let x = Double(values[0]),
              let y = Double(values[1]),
              let width = Double(values[2]),
              let height = Double(values[3])
        else {
            throw ValidationError("Region must be x,y,width,height")
        }

        guard width > 0, height > 0 else {
            throw ValidationError("Region width and height must be greater than zero")
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func captureMenuBar() async throws -> [ImageCapturedFile] {
        let observation = try await self.captureObservation(
            target: .menubar,
            preferredName: "menubar",
            index: nil
        )
        return try [
            self.capturedFile(
                from: observation,
                preferredName: "menubar",
                windowIndex: nil
            ),
        ]
    }

    private func captureObservation(
        target: DesktopObservationTargetRequest,
        preferredName: String?,
        index: Int?
    ) async throws -> DesktopObservationResult {
        let url = self.makeOutputURL(preferredName: preferredName, index: index)

        return try await self.services.desktopObservation.observe(self.makeObservationRequest(
            target: target,
            outputURL: url
        ))
    }
}
