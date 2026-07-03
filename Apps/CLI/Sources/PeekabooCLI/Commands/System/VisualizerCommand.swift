import Commander
import CoreGraphics
import Foundation
import os
import PeekabooCore
import PeekabooFoundation
import PeekabooVisualizer

@MainActor
struct VisualizerCommand: RuntimeOptionsConfigurable, OutputFormattable, ErrorHandlingCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "visualizer",
                abstract: "Exercise Peekaboo visual feedback animations",
                discussion: """
                Runs a lightweight smoke sequence that fires every visualizer event so you can verify
                Peekaboo.app is rendering overlays.
                """,
                showHelpOnEmptyInvocation: false
            )
        }
    }

    @RuntimeStorage private var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    private var resolvedRuntime: CommandRuntime {
        guard let runtime else {
            preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
        }
        return runtime
    }

    private var configuration: CommandRuntime.Configuration {
        if let runtime {
            return runtime.configuration
        }
        return self.runtimeOptions.makeConfiguration()
    }

    private var logger: Logger {
        self.resolvedRuntime.logger
    }

    var outputLogger: Logger {
        self.logger
    }

    var jsonOutput: Bool {
        self.configuration.jsonOutput
    }

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
        "Screenshot flash",
        "Watch capture HUD",
        "Click ripple",
        "Typing indicator",
        "Scroll indicator",
        "Mouse movement trail",
        "Swipe gesture",
        "Hotkey heads-up display",
        "Window move overlay",
        "App launch icon bounce",
        "App quit animation",
        "Menu breadcrumb highlight",
        "Dialog interaction highlight",
        "Space switch indicator",
        "Element detection overlay"
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

        var steps: [StepReport] = []

        try await steps.append(self.step("Screenshot flash") {
            await client.showScreenshotFlash(in: primaryRect)
        })

        try await steps.append(self.step("Watch capture HUD") {
            await client.showWatchCapture(in: primaryRect)
        })

        try await steps.append(self.step("Click ripple") {
            await client.showClickFeedback(at: point, type: .single)
        })

        try await steps.append(self.step("Typing indicator") {
            await client.showTypingFeedback(
                keys: ["H", "i", "!"],
                duration: 1.5,
                cadence: .human(wordsPerMinute: 60)
            )
        })

        try await steps.append(self.step("Scroll indicator") {
            await client.showScrollFeedback(at: point, direction: .down, amount: 3)
        })

        try await steps.append(self.step("Mouse movement trail") {
            await client.showMouseMovement(
                from: point,
                to: CGPoint(x: point.x + 180, y: point.y + 120),
                duration: 0.8
            )
        })

        try await steps.append(self.step("Swipe gesture") {
            await client.showSwipeGesture(
                from: CGPoint(x: point.x - 120, y: point.y),
                to: CGPoint(x: point.x + 120, y: point.y),
                duration: 0.6
            )
        })

        try await steps.append(self.step("Hotkey heads-up display") {
            await client.showHotkeyDisplay(keys: ["Cmd", "Shift", "T"], duration: 1.2)
        })

        try await steps.append(self.step("Window move overlay") {
            await client.showWindowOperation(.move, windowRect: primaryRect, duration: 0.7)
        })

        try await steps.append(self.step("App launch icon bounce") {
            await client.showAppLaunch(appName: "Visualizer Smoke Test", iconPath: nil)
        })

        try await steps.append(self.step("App quit animation") {
            await client.showAppQuit(appName: "Visualizer Smoke Test", iconPath: nil)
        })

        try await steps.append(self.step("Menu breadcrumb highlight") {
            await client.showMenuNavigation(menuPath: ["File", "New", "Window"])
        })

        try await steps.append(self.step("Dialog interaction highlight") {
            await client.showDialogInteraction(
                element: .button,
                elementRect: CGRect(origin: point, size: CGSize(width: 160, height: 40)),
                action: .clickButton
            )
        })

        try await steps.append(self.step("Space switch indicator") {
            await client.showSpaceSwitch(from: 1, to: 2, direction: .right)
        })

        try await steps.append(self.step("Element detection overlay") {
            let sampleElements: [String: CGRect] = [
                "B1": CGRect(x: primaryRect.minX + 20, y: primaryRect.minY + 20, width: 140, height: 44),
                "T1": CGRect(x: primaryRect.midX - 80, y: primaryRect.midY, width: 200, height: 40)
            ]
            return await client.showElementDetection(elements: sampleElements)
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
}

extension VisualizerCommand: AsyncRuntimeCommand {}
