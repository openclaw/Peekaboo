import Algorithms
import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
private struct PreparedPixelCapture {
    let captures: [ImageCapturedFile]
    let analysis: ImageAnalysisData?
}

@MainActor
final class SeePixelCaptureAttempt {
    let deadline: Date
    var snapshotID: String?
    var temporaryOutputURLs: Set<URL> = []
    private let snapshots: any SnapshotManagerProtocol
    private var preparationFinished = false
    private var abandoned = false
    private var cleanupStarted = false
    private var cleanupTask: Task<Void, Never>?

    init(deadline: Date, snapshots: any SnapshotManagerProtocol) {
        self.deadline = deadline
        self.snapshots = snapshots
    }

    func finishPreparation() {
        self.preparationFinished = true
        _ = self.startCleanupIfNeeded()
    }

    func abandon() -> Task<Void, Never>? {
        self.abandoned = true
        return self.startCleanupIfNeeded()
    }

    private func startCleanupIfNeeded() -> Task<Void, Never>? {
        guard self.abandoned, self.preparationFinished, !self.cleanupStarted else { return self.cleanupTask }
        self.cleanupStarted = true
        for url in self.temporaryOutputURLs {
            try? FileManager.default.removeItem(at: url)
        }
        if let snapshotID = self.snapshotID {
            let snapshots = self.snapshots
            self.cleanupTask = Task { @MainActor in
                _ = try? await snapshots.cleanSnapshot(snapshotId: snapshotID)
            }
        }
        return self.cleanupTask
    }
}

@MainActor
extension SeeCommand {
    func runPixelOnlyCapture() async throws {
        try self.validateStdoutStreamingOptions()
        let timeout = self.overallTimeoutSeconds
        let deadline = Date().addingTimeInterval(timeout)
        let attempt = SeePixelCaptureAttempt(deadline: deadline, snapshots: self.services.snapshots)
        var timedCommand = self
        timedCommand.pixelCaptureAttempt = attempt
        let command = timedCommand
        let timeoutError = self.pixelCaptureTimeoutError
        var receipt = SeeExecutionReceipt.none
        do {
            let prepared = try await withMainActorCommandTimeout(
                seconds: timeout,
                operationName: "see pixel capture",
                timeoutError: { timeoutError },
                operation: { try await command.preparePixelCapture(attempt: attempt) }
            )
            receipt = SeeExecutionReceipt.combining(prepared.captures.map(\.receipt))
            SeeCommandPreparationContext.didCapture?()
            // Abandoned capture work must never publish success or raw stdout after the timeout wins.
            try Task.checkCancellation()
            _ = try Self.remainingObservationTimeout(
                until: deadline, overallTimeout: timeout, timeoutError: timeoutError
            )
            if self.streamsImageToStdout {
                try self.outputImageToStdout(prepared.captures)
            } else if let analysis = prepared.analysis {
                try self.outputResultsWithAnalysis(prepared.captures, analysis: analysis)
            } else {
                try self.outputResults(prepared.captures)
            }
        } catch {
            let remaining = deadline.timeIntervalSinceNow
            if let cleanup = attempt.abandon(), remaining > 0 {
                _ = try? await withMainActorCommandTimeout(seconds: remaining, operationName: "see pixel cleanup") {
                    await cleanup.value
                }
            }
            throw receipt.preservingFailure(error, operation: "see pixel publication")
        }
    }

    private var pixelCaptureTimeoutError: PeekabooError {
        .timeout("see pixel capture exceeded \(formatDuration(self.overallTimeoutSeconds))")
    }

    private func preparePixelCapture(attempt: SeePixelCaptureAttempt) async throws -> PreparedPixelCapture {
        // The caller can time out before a cancellation-ignoring provider returns its reservation or file.
        defer { attempt.finishPreparation() }
        var captures: [ImageCapturedFile] = []
        do {
            try Task.checkCancellation()
            if self.publishesPixelCoordinateReceipt {
                attempt.snapshotID = try await self.services.snapshots.createExplicitSnapshot()
            }
            try Task.checkCancellation()
            captures = try await self.performPixelCapture(snapshotID: attempt.snapshotID)
            try Task.checkCancellation()
            try self.validatePixelCaptureForPublishing(captures)
            let analysis: ImageAnalysisData? = if let prompt = self.analyze, let firstCapture = captures.first {
                try await self.analyzeImage(firstCapture.imageData, with: prompt)
            } else {
                nil
            }
            try Task.checkCancellation()
            return PreparedPixelCapture(captures: captures, analysis: analysis)
        } catch {
            let receipt = SeeExecutionReceipt.combining(captures.map(\.receipt))
            throw receipt.preservingFailure(error, operation: "see pixel capture")
        }
    }

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
        try Task.checkCancellation()
        try Self.requireSupportedPixelCaptureFocus(self.captureFocus, target: target)
        let remaining = try self.pixelCaptureAttempt.map {
            try Self.remainingObservationTimeout(
                until: $0.deadline,
                overallTimeout: self.overallTimeoutSeconds,
                timeoutError: self.pixelCaptureTimeoutError
            )
        } ?? self.overallTimeoutSeconds
        let url = self.makeOutputURL(preferredName: preferredName, index: index)
        if self.streamsImageToStdout {
            self.pixelCaptureAttempt?.temporaryOutputURLs.insert(url)
        }
        let request = self.makePixelObservationRequest(
            target: target,
            outputURL: url,
            snapshotID: snapshotID,
            timeoutSeconds: remaining
        )
        let actionResult = try await self.services.desktopObservation.observeResult(request)
        try Task.checkCancellation()
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
