//
//  ToolFormatterRegistry.swift
//  PeekabooCore
//

import Foundation

/// Main registry for tool formatters with comprehensive result formatting
public final class ToolFormatterRegistry: @unchecked Sendable {
    /// Singleton instance for global access
    public static let shared = ToolFormatterRegistry()

    /// Dictionary of formatters by tool type
    private var formatters: [ToolType: any ToolFormatter] = [:]

    // MARK: - Initialization

    public init() {
        self.registerAllFormatters()
    }

    // MARK: - Registration

    private func registerAllFormatters() {
        // Register all formatters with comprehensive output

        // Application tools
        let appFormatter = ApplicationToolFormatter(toolType: .launchApp)
        self.register(appFormatter, for: [
            .app, .list,
            .launchApp, .listApps, .quitApp, .focusApp, .hideApp, .unhideApp, .switchApp,
        ])

        // Vision tools
        let visionFormatter = VisionToolFormatter(toolType: .see)
        self.register(visionFormatter, for: [.see, .image, .capture, .screenshot, .windowCapture, .analyze])

        // UI Automation tools
        let uiFormatter = UIAutomationToolFormatter(toolType: .click)
        self.register(uiFormatter, for: [
            .click,
            .type, .paste, .scroll, .hotkey, .press,
            .move,
        ])

        // Menu and dialog tools
        let menuSystemFormatter = MenuSystemToolFormatter(toolType: .menuClick)
        self.register(menuSystemFormatter, for: [
            .menu, .dialog, .dock,
            .menuClick, .listMenus,
            .dialogInput, .dialogClick,
        ])

        // System tools
        let systemFormatter = SystemToolFormatter(toolType: .shell)
        self.register(systemFormatter, for: [
            .browser, .permissions, .sleep, .agent,
            .shell, .wait, .clipboard, .copyToClipboard, .pasteFromClipboard,
        ])

        // Dock tools
        let dockFormatter = DockToolFormatter(toolType: .listDock)
        self.register(dockFormatter, for: [
            .listDock, .dockClick, .dockLaunch,
        ])

        // Window management tools (use standard for now)
        let windowFormatter = WindowToolFormatter(toolType: .focusWindow)
        self.register(windowFormatter, for: [
            .window, .space,
            .focusWindow, .resizeWindow, .listWindows,
            .minimizeWindow, .maximizeWindow, .listScreens,
            .listSpaces, .switchSpace, .moveWindowToSpace,
        ])

        // Element query tools (use standard for now)
        let elementFormatter = ElementToolFormatter(toolType: .findElement)
        self.register(
            elementFormatter,
            for: [.setValue, .action, .performAction, .findElement, .listElements, .focused, .inspectUI, .verifyState])

        // Communication tools (use standard)
        let commFormatter = CommunicationToolFormatter(toolType: .taskCompleted)
        self.register(commFormatter, for: [.done, .taskCompleted, .needMoreInformation, .needInfo])

        // Additional tools that might not have specific formatters yet
        self.registerRemainingTools()
    }

    private func registerRemainingTools() {
        // Register any remaining tools with appropriate formatters
        for toolType in ToolType.allCases where self.formatters[toolType] == nil {
            let formatter = self.createDefaultFormatter(for: toolType)
            self.formatters[toolType] = formatter
        }
    }

    private func createDefaultFormatter(for toolType: ToolType) -> any ToolFormatter {
        // Create appropriate formatter based on tool category
        switch toolType.category {
        case .vision:
            VisionToolFormatter(toolType: toolType)
        case .automation:
            UIAutomationToolFormatter(toolType: toolType)
        case .ui:
            UIAutomationToolFormatter(toolType: toolType)
        case .app:
            ApplicationToolFormatter(toolType: toolType)
        case .application:
            ApplicationToolFormatter(toolType: toolType)
        case .window:
            WindowToolFormatter(toolType: toolType)
        case .menu:
            MenuSystemToolFormatter(toolType: toolType)
        case .dialog:
            MenuSystemToolFormatter(toolType: toolType)
        case .dock:
            DockToolFormatter(toolType: toolType)
        case .element:
            ElementToolFormatter(toolType: toolType)
        case .query:
            ElementToolFormatter(toolType: toolType)
        case .system, .browser:
            SystemToolFormatter(toolType: toolType)
        case .completion:
            CommunicationToolFormatter(toolType: toolType)
        }
    }

    private func register(_ formatter: any ToolFormatter, for toolTypes: [ToolType]) {
        for toolType in toolTypes {
            // Create a new instance with the correct tool type
            let specificFormatter = self.createFormatterInstance(formatter, for: toolType)
            self.formatters[toolType] = specificFormatter
        }
    }

    private func createFormatterInstance(_ formatter: any ToolFormatter, for toolType: ToolType) -> any ToolFormatter {
        // Create appropriate formatter instance based on type
        switch formatter {
        // Note: These cases are no longer needed since we replaced the base classes
        // but keeping for backward compatibility if needed
        case is ApplicationToolFormatter:
            ApplicationToolFormatter(toolType: toolType)
        case is VisionToolFormatter:
            VisionToolFormatter(toolType: toolType)
        case is UIAutomationToolFormatter:
            UIAutomationToolFormatter(toolType: toolType)
        case is MenuSystemToolFormatter:
            MenuSystemToolFormatter(toolType: toolType)
        case is WindowToolFormatter:
            WindowToolFormatter(toolType: toolType)
        case is DockToolFormatter:
            DockToolFormatter(toolType: toolType)
        case is ElementToolFormatter:
            ElementToolFormatter(toolType: toolType)
        case is SystemToolFormatter:
            SystemToolFormatter(toolType: toolType)
        case is CommunicationToolFormatter:
            CommunicationToolFormatter(toolType: toolType)
        default:
            BaseToolFormatter(toolType: toolType)
        }
    }

    // MARK: - Lookup

    /// Get formatter for a specific tool type
    public func formatter(for toolType: ToolType) -> any ToolFormatter {
        // Get formatter for a specific tool type
        self.formatters[toolType] ?? BaseToolFormatter(toolType: toolType)
    }

    /// Get formatter for a tool name (backward compatibility)
    public func formatter(for toolName: String) -> (any ToolFormatter)? {
        // Get formatter for a tool name (backward compatibility)
        guard let toolType = ToolType(toolName: toolName) else {
            return nil
        }
        return self.formatter(for: toolType)
    }
}
