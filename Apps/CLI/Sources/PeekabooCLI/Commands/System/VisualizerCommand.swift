import AppKit
import Commander
import CoreGraphics
import Foundation
import os
import PeekabooCore
import PeekabooFoundation
import PeekabooVisualizer

@MainActor
struct VisualizerCommand: RuntimeBackedCommand, OutputFormattable, ErrorHandlingCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "visualizer",
                abstract: "Exercise Peekaboo visual feedback animations",
                discussion: """
                Runs a lightweight smoke sequence for the agent cursor, app-anchored input HUD,
                and capture indicators.
                """,
                showHelpOnEmptyInvocation: false
            )
        }
    }

    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)

        let startTime = Date()
        self.logger.info("Starting visualizer smoke sequence")

        let report = try await VisualizerSmokeSequence(
            logger: self.logger,
            screens: self.resolvedRuntime.services.screens
        ).run()
        let duration = Date().timeIntervalSince(startTime)

        if report.failedSteps.isEmpty {
            self.output(report) {
                print("✅ Visualizer smoke sequence dispatched \(report.dispatchedCount)/\(report.totalSteps) events")
                print("⏱️  Completed in \(String(format: "%.2f", duration))s")
            }
            self.logger.info("Visualizer smoke sequence finished")
            return
        }

        if !self.jsonOutput {
            print("Visualizer smoke sequence dispatched \(report.dispatchedCount)/\(report.totalSteps) events")
            print("Failed steps:")
            for step in report.failedSteps {
                print("- \(step)")
            }
        }

        self.handleError(
            PeekabooError.commandFailed(
                "Visualizer events were not dispatched. Ensure Peekaboo.app is running and visual feedback is enabled."
            ),
            customCode: .INTERACTION_FAILED
        )
        throw ExitCode.failure
    }
}

@MainActor
private struct VisualizerSmokeSequence {
    let logger: Logger
    let screens: any ScreenServiceProtocol

    private static let stepNames = [
        "Agent cursor movement",
        "Click pulse",
        "Window-anchored input HUD",
        "Capture border",
        "Live capture indicator",
    ]

    struct StepReport: Codable {
        let name: String
        let dispatched: Bool
    }

    struct Report: Codable {
        let steps: [StepReport]
        let dispatchedCount: Int
        let totalSteps: Int
        let failedSteps: [String]
    }

    func run() async throws -> Report {
        let client = VisualizationClient.shared
        client.connect()

        guard client.canDispatchEvents else {
            self.logger.debug("VisualizerSmoke: visualizer unavailable; skipping paced event sequence")
            return Report(
                steps: [],
                dispatchedCount: 0,
                totalSteps: Self.stepNames.count,
                failedSteps: Self.stepNames
            )
        }

        let screenFrame = VisualizerSmokeLayout.screenFrame(using: self.screens)
        let primaryRect = screenFrame.insetBy(dx: screenFrame.width * 0.25, dy: screenFrame.height * 0.25)
        let point = CGPoint(x: primaryRect.midX, y: primaryRect.midY)
        let target = VisualizerSmokeLayout.activeTargetWindow()

        var steps: [StepReport] = []

        try await steps.append(self.step("Agent cursor movement") {
            await client.showMouseMovement(
                from: CGPoint(x: point.x - 120, y: point.y - 50),
                to: CGPoint(x: point.x + 120, y: point.y + 50),
                duration: 0.8
            )
        })

        try await steps.append(self.step("Click pulse") {
            await client.showClickFeedback(at: point, type: .single, target: target)
        })

        try await steps.append(self.step("Window-anchored input HUD") {
            guard let target else { return false }
            return await client.showHotkeyDisplay(
                keys: ["Cmd", "Shift", "T"],
                duration: 1.2,
                target: target
            )
        })

        try await steps.append(self.step("Capture border") {
            await client.showScreenshotFlash(in: target?.frame ?? primaryRect)
        })

        try await steps.append(self.step("Live capture indicator") {
            await client.showWatchCapture(in: target?.frame ?? primaryRect)
        })

        let failedSteps = steps.filter { !$0.dispatched }.map(\.name)
        return Report(
            steps: steps,
            dispatchedCount: steps.filter(\.dispatched).count,
            totalSteps: Self.stepNames.count,
            failedSteps: failedSteps
        )
    }

    private func step(_ name: String, action: @escaping @MainActor () async -> Bool) async throws -> StepReport {
        self.logger.debug("VisualizerSmoke: \(name)")
        let dispatched = await action()
        self.logger.debug("VisualizerSmokeResult: \(name) dispatched=\(dispatched)")
        if dispatched {
            try await Task.sleep(for: .milliseconds(250))
        }
        return StepReport(name: name, dispatched: dispatched)
    }
}

enum VisualizerSmokeLayout {
    static let fallbackFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @MainActor
    static func screenFrame(using screens: any ScreenServiceProtocol) -> CGRect {
        screens.primaryScreen?.frame ?? screens.listScreens().first?.frame ?? self.fallbackFrame
    }

    @MainActor
    static func activeTargetWindow() -> VisualizerTargetWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let windows = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]],
              let info = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier &&
                      ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 &&
                      (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
              }),
              let number = info[kCGWindowNumber as String] as? NSNumber,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else {
            return nil
        }
        return VisualizerTargetWindow(
            processIdentifier: app.processIdentifier,
            windowID: number.uint32Value,
            frame: VisualizerScreenGeometry.appKitRect(
                fromGlobalDisplay: frame,
                primaryScreenFrame: NSScreen.screens.first?.frame
            )
        )
    }
}

extension VisualizerCommand: AsyncRuntimeCommand {}
