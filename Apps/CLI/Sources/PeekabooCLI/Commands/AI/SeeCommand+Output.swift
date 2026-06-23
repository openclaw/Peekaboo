import Foundation
import PeekabooCore

@available(macOS 14.0, *)
@MainActor
extension SeeCommand {
    func renderResults(context: SeeCommandRenderContext) throws {
        try Task.checkCancellation()
        if self.jsonOutput {
            try self.outputJSONResults(context: context)
        } else {
            try self.outputTextResults(context: context)
        }
    }

    /// Fetches the menu bar summary only when verbose output is requested, with a short timeout.
    func fetchMenuBarSummaryIfEnabled() async -> MenuBarSummary? {
        guard self.verbose else { return nil }

        do {
            return try await Self.withWallClockTimeout(seconds: 2.5) {
                try Task.checkCancellation()
                return await self.getMenuBarItemsSummary()
            }
        } catch {
            self.logger.debug(
                "Skipping menu bar summary",
                category: "Menu",
                metadata: ["reason": error.localizedDescription]
            )
            return nil
        }
    }

    /// Drives the deadline independently while the MainActor operation is suspended.
    /// Synchronous MainActor calls cannot be preempted.
    static func withWallClockTimeout<T: Sendable>(
        seconds: TimeInterval,
        timeoutErrorSeconds: TimeInterval? = nil,
        interactionMutationTracker: InteractionMutationTracker? = nil,
        operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        try await withMainActorCommandTimeout(
            seconds: seconds,
            operationName: "see",
            timeoutError: { CaptureError.detectionTimedOut(timeoutErrorSeconds ?? seconds) },
            interactionMutationTracker: interactionMutationTracker,
            operation: { try await operation() }
        )
    }

    func performAnalysisDetailed(imagePath: String, prompt: String) async throws -> SeeAnalysisData {
        let ai = PeekabooAIService()
        let res = try await ai.analyzeImageFileDetailed(at: imagePath, question: prompt, model: nil)
        return SeeAnalysisData(provider: res.provider, model: res.model, text: res.text)
    }

    private func outputJSONResults(context: SeeCommandRenderContext) throws {
        let uiElements: [UIElementSummary] = context.elements.all.map { element in
            UIElementSummary(
                id: element.id,
                role: element.type.rawValue,
                title: element.attributes["title"],
                label: element.label,
                description: element.attributes["description"],
                role_description: element.attributes["roleDescription"],
                help: element.attributes["help"],
                identifier: element.attributes["identifier"],
                bounds: UIElementBounds(element.bounds),
                is_actionable: element.isEnabled,
                keyboard_shortcut: element.attributes["keyboardShortcut"]
            )
        }

        let snapshotPaths = self.snapshotPaths(for: context)

        let output = SeeResult(
            snapshot_id: context.snapshotId,
            screenshot_raw: snapshotPaths.raw,
            screenshot_annotated: snapshotPaths.annotated,
            ui_map: snapshotPaths.map,
            application_name: context.metadata.windowContext?.applicationName,
            window_title: context.metadata.windowContext?.windowTitle,
            is_dialog: context.metadata.isDialog,
            element_count: context.metadata.elementCount,
            interactable_count: context.elements.all.count { $0.isEnabled },
            capture_mode: self.determineMode().rawValue,
            analysis: context.analysis,
            execution_time: context.executionTime,
            ui_elements: uiElements,
            menu_bar: context.menuBar,
            truncation: SeeTruncationSummary(metadata: context.metadata),
            observation: context.observation
        )

        outputSuccessCodable(data: output, logger: self.outputLogger)
    }

    private func getMenuBarItemsSummary() async -> MenuBarSummary {
        var menuExtras: [MenuExtraInfo] = []

        do {
            menuExtras = try await self.services.menu.listMenuExtras()
        } catch {
            menuExtras = []
        }

        let menus = menuExtras.map { extra in
            MenuBarSummary.MenuSummary(
                title: extra.title,
                item_count: 1,
                enabled: true,
                items: [
                    MenuBarSummary.MenuItemSummary(
                        title: extra.title,
                        enabled: true,
                        keyboard_shortcut: nil
                    )
                ]
            )
        }

        return MenuBarSummary(menus: menus)
    }

    private func outputTextResults(context: SeeCommandRenderContext) throws {
        try Task.checkCancellation()
        print("🖼️  Screenshot saved to: \(context.screenshotPath)")
        if let annotatedPath = context.annotatedPath {
            print("📝 Annotated screenshot: \(annotatedPath)")
        }

        if let appName = context.metadata.windowContext?.applicationName {
            print("📱 Application: \(appName)")
        }
        if let windowTitle = context.metadata.windowContext?.windowTitle {
            let windowType = context.metadata.isDialog ? "Dialog" : "Window"
            let icon = context.metadata.isDialog ? "🗨️" : "[win]"
            print("\(icon) \(windowType): \(windowTitle)")
        }
        print("🧊 Detection method: \(context.metadata.method)")
        print("📊 UI elements detected: \(context.metadata.elementCount)")
        print("⚙️  Interactable elements: \(context.elements.all.count { $0.isEnabled })")
        if let truncationInfo = context.metadata.truncationInfo, truncationInfo.isTruncated {
            print("⚠️  \(truncationInfo.remediationMessage(budget: context.metadata.windowContext?.traversalBudget))")
        }
        let formattedDuration = String(format: "%.2f", context.executionTime)
        print("⏱️  Execution time: \(formattedDuration)s")

        if let analysis = context.analysis {
            print("\n🤖 AI Analysis\n\(analysis.text)")
        }

        if context.metadata.elementCount > 0 {
            print("\n🔍 Element Summary")
            for element in context.elements.all.prefix(10) {
                let summaryLabel = element.label ?? element.attributes["title"] ?? element.value ?? "Untitled"
                print("• \(element.id) (\(element.type.rawValue)) - \(summaryLabel)")
            }

            if context.metadata.elementCount > 10 {
                print("  ...and \(context.metadata.elementCount - 10) more elements")
            }
        }

        if self.annotate, context.annotatedPath != nil {
            print("\n📝 Annotated screenshot created")
        }

        print("\nSnapshot ID: \(context.snapshotId)")

        let terminalCapabilities = TerminalDetector.detectCapabilities()
        if terminalCapabilities.recommendedOutputMode == .minimal {
            print("Agent: Use a tool like view_image to inspect it.")
        }
    }

    private func snapshotPaths(for context: SeeCommandRenderContext) -> SnapshotPaths {
        let publishesScreenshotPaths = !self.usesTemporaryScreenshotOutput
        return SnapshotPaths(
            raw: publishesScreenshotPaths ? context.screenshotPath : "",
            annotated: publishesScreenshotPaths ? context.annotatedPath ?? "" : "",
            map: self.services.snapshots.getSnapshotStoragePath() + "/\(context.snapshotId)/snapshot.json"
        )
    }
}
