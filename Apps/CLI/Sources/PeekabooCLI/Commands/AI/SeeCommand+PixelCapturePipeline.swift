import Algorithms
import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
extension SeeCommand {
    func performPixelCapture(snapshotID: String? = nil) async throws -> [ImageCapturedFile] {
        try Self.requireSupportedPixelCaptureFocus(self.captureFocus, target: .frontmost)
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
            results = try await self.captureScreens(allScreens: false)
        case .window:
            if let windowId = self.windowId {
                results = try await self.captureWindowById(windowId, snapshotID: snapshotID)
            } else {
                let target = try self.observationApplicationTargetForWindowCapture()
                results = try await self.captureApplicationWindow(target)
            }
        case .multi:
            if self.app != nil || self.pid != nil {
                let identifier = try self.resolveApplicationIdentifier()
                results = try await self.captureAllApplicationWindows(identifier)
            } else {
                results = try await self.captureScreens(allScreens: true)
            }
        case .frontmost:
            results = try await self.captureFrontmost()
        case .area:
            results = try await self.captureArea()
        }

        return results
    }

    private func captureWindowById(_ windowId: Int, snapshotID: String?) async throws -> [ImageCapturedFile] {
        let target = try self.observationTargetForExactWindowCapture(windowId)
        let result = try await self.captureObservation(
            target: target,
            preferredName: "window-\(windowId)",
            index: nil,
            snapshotID: snapshotID
        )
        let observation = result.observation

        let title = observation.capture.metadata.windowInfo?.title
        let preferredName = if let title, !title.isEmpty {
            title
        } else {
            "window-\(windowId)"
        }

        return try [
            self.capturedFile(
                from: result,
                preferredName: preferredName,
                windowIndex: nil,
                snapshotID: snapshotID
            ),
        ]
    }

    private func captureScreens(allScreens: Bool) async throws -> [ImageCapturedFile] {
        if let index = self.screenIndex ?? (allScreens ? nil : 0) {
            let result = try await self.captureObservation(
                target: .screen(index: index),
                preferredName: "screen\(index)",
                index: nil
            )
            return try [
                self.capturedFile(
                    from: result,
                    preferredName: "screen\(index)",
                    windowIndex: nil
                ),
            ]
        }

        let screens = self.services.screens.listScreens()
        let indexes = self.pixelScreenIndexes(allScreens: allScreens, availableScreenCount: screens.count)

        var savedFiles: [ImageCapturedFile] = []
        for (ordinal, displayIndex) in indexes.indexed() {
            let result = try await self.captureObservation(
                target: .screen(index: displayIndex),
                preferredName: "screen\(displayIndex)",
                index: ordinal
            )
            try savedFiles.append(self.capturedFile(
                from: result,
                preferredName: "screen\(displayIndex)",
                windowIndex: nil
            ))
        }

        return savedFiles
    }

    func pixelScreenIndexes(allScreens: Bool, availableScreenCount: Int) -> [Int] {
        if let screenIndex {
            return [screenIndex]
        }
        if !allScreens || availableScreenCount == 0 {
            return [0]
        }
        return Array(0..<availableScreenCount)
    }

    private func captureApplicationWindow(_ target: ImageWindowObservationTarget) async throws -> [ImageCapturedFile] {
        try await self.focusIfNeeded(appIdentifier: target.focusIdentifier)
        let result = try await self.captureObservation(
            target: target.target,
            preferredName: target.preferredName,
            index: nil
        )
        let observation = result.observation
        let resolvedWindow = observation.target.window
        let resolvedTitle = resolvedWindow?.title.trimmingCharacters(in: .whitespacesAndNewlines)

        let saved = try self.capturedFile(
            from: result,
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
            let result = try await self.captureObservation(
                target: .windowID(CGWindowID(window.windowID)),
                preferredName: window.title,
                index: ordinal
            )

            let saved = try self.capturedFile(
                from: result,
                preferredName: window.title,
                windowIndex: window.index
            )
            savedFiles.append(saved)
        }

        return savedFiles
    }

    private func captureFrontmost() async throws -> [ImageCapturedFile] {
        let result = try await self.captureObservation(
            target: .frontmost,
            preferredName: "frontmost",
            index: nil
        )
        return try [
            self.capturedFile(
                from: result,
                preferredName: "frontmost",
                windowIndex: nil
            ),
        ]
    }

    private func captureArea() async throws -> [ImageCapturedFile] {
        let rect = try self.areaCaptureRect()
        let result = try await self.captureObservation(
            target: .area(rect),
            preferredName: "area",
            index: nil
        )
        return try [
            self.capturedFile(
                from: result,
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
        let result = try await self.captureObservation(
            target: .menubar,
            preferredName: "menubar",
            index: nil
        )
        return try [
            self.capturedFile(
                from: result,
                preferredName: "menubar",
                windowIndex: nil
            ),
        ]
    }

    private func captureObservation(
        target: DesktopObservationTargetRequest,
        preferredName: String?,
        index: Int?,
        snapshotID: String? = nil
    ) async throws -> SeeObservationActionResult {
        try Self.requireSupportedPixelCaptureFocus(self.captureFocus, target: target)
        let url = self.makeOutputURL(preferredName: preferredName, index: index)
        let request = self.makePixelObservationRequest(
            target: target,
            outputURL: url,
            snapshotID: snapshotID
        )
        let actionResult = try await self.services.desktopObservation.observeResult(request)
        let requiresTarget = switch target {
        case .app, .pid, .windowID, .frontmost:
            true
        case .screen, .allScreens, .area, .menubar, .menubarPopover:
            false
        }
        let receipt = try SeeExecutionReceipt.validated(
            actionResult,
            operation: "See pixel capture",
            requiresOutcome: false,
            requiresTarget: requiresTarget
        )
        return SeeObservationActionResult(observation: actionResult.payload, receipt: receipt)
    }

    static func requireSupportedPixelCaptureFocus(
        _ focus: PeekabooCore.CaptureFocus,
        target: DesktopObservationTargetRequest
    ) throws {
        guard focus != .background else { return }
        let targetDescription = switch target {
        case .windowID, .app(_, .id), .pid(_, .id):
            "exact-window"
        default:
            "pixel"
        }
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .operationUnsupported,
            message: "See \(targetDescription) capture is background-only.",
            hint: "Use a background see capture; foreground focus is not dispatched without a selected-host receipt."
        )
    }
}
