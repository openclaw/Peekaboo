import Foundation
import PeekabooCore

@available(macOS 14.0, *)
@MainActor
extension SeeCommand {
    func renderResults(context: SeeCommandRenderContext) async {
        if self.jsonOutput {
            await self.outputJSONResults(context: context)
        } else {
            await self.outputTextResults(context: context)
        }
    }

    /// Fetches the menu bar summary only when verbose output is requested, with a short timeout.
    private func fetchMenuBarSummaryIfEnabled() async -> MenuBarSummary? {
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

    /// Timeout helper that is not MainActor-bound, so it can still fire if the main actor is blocked.
    static func withWallClockTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CaptureError.detectionTimedOut(seconds)
            }

            guard let result = try await group.next() else {
                throw CaptureError.detectionTimedOut(seconds)
            }
            group.cancelAll()
            return result
        }
    }

    func performAnalysisDetailed(imagePath: String, prompt: String) async throws -> SeeAnalysisData {
        let ai = PeekabooAIService()
        let res = try await ai.analyzeImageFileDetailed(at: imagePath, question: prompt, model: nil)
        return SeeAnalysisData(provider: res.provider, model: res.model, text: res.text)
    }

    private func buildMenuSummaryIfNeeded() async -> MenuBarSummary? {
        // Placeholder for future UI summary generation; currently unused.
        nil
    }

    private func outputJSONResults(context: SeeCommandRenderContext) async {
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

        // Menu bar enumeration can be slow or hang on some setups. Only attempt it in verbose
        // mode and bound it with a short timeout so JSON output is responsive by default.
        let menuSummary = await self.fetchMenuBarSummaryIfEnabled()

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
            menu_bar: menuSummary,
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

    private func outputTextResults(context: SeeCommandRenderContext) async {
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

        if let menuSummary = await self.buildMenuSummaryIfNeeded() {
            print("\n🧭 Menu Bar Summary")
            for menu in menuSummary.menus {
                print("- \(menu.title) (\(menu.enabled ? "Enabled" : "Disabled"))")
                for item in menu.items.prefix(5) {
                    let shortcut = item.keyboard_shortcut.map { " [\($0)]" } ?? ""
                    print("    • \(item.title)\(shortcut)")
                }
            }
        }

        print("\nSnapshot ID: \(context.snapshotId)")

        let terminalCapabilities = TerminalDetector.detectCapabilities()
        if terminalCapabilities.recommendedOutputMode == .minimal {
            print("Agent: Use a tool like view_image to inspect it.")
        }
    }

    private func snapshotPaths(for context: SeeCommandRenderContext) -> SnapshotPaths {
        SnapshotPaths(
            raw: context.screenshotPath,
            annotated: context.annotatedPath ?? "",
            map: self.services.snapshots.getSnapshotStoragePath() + "/\(context.snapshotId)/snapshot.json"
        )
    }
}
