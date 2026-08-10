//
//  ToolType.swift
//  PeekabooCore
//

import Foundation
import PeekabooAutomation

/// Type-safe enumeration of all Peekaboo tools
public enum ToolType: String, CaseIterable, Sendable {
    // MARK: - Vision Tools

    case see
    case image
    case capture
    case analyze

    // Historical split-tool names retained so persisted sessions keep rich formatting.
    case screenshot
    case windowCapture = "window_capture"

    // MARK: - UI Automation

    case click
    case type
    case setValue = "set_value"
    case action
    case press
    case drag
    case move
    case scroll
    case paste

    // Historical tool names retained so persisted sessions keep rich formatting.
    case performAction = "perform_action"
    case hotkey
    case swipe

    // MARK: - Application Management

    case app

    // Historical split-tool names retained for persisted sessions.
    case launchApp = "launch_app"
    case listApps = "list_apps"
    case quitApp = "quit_app"
    case focusApp = "focus_app"
    case hideApp = "hide_app"
    case unhideApp = "unhide_app"
    case switchApp = "switch_app"

    // MARK: - Window Management

    case window
    case space

    // Historical split-tool names retained for persisted sessions.
    case focusWindow = "focus_window"
    case resizeWindow = "resize_window"
    case listWindows = "list_windows"
    case minimizeWindow = "minimize_window"
    case maximizeWindow = "maximize_window"
    case listScreens = "list_screens"

    // MARK: - Menu & Dialog

    case menu
    case dialog
    case dock

    // Historical split-tool names retained for persisted sessions.
    case menuClick = "menu_click"
    case listMenus = "list_menus"
    case dialogClick = "dialog_click"
    case dialogInput = "dialog_input"

    // MARK: - Dock

    // Historical split-tool names retained for persisted sessions.
    case listDock = "list_dock"
    case dockClick = "dock_click"
    case dockLaunch = "dock_launch"

    // MARK: - Element Query

    case list

    // Historical split-tool names retained for persisted sessions.
    case findElement = "find_element"
    case listElements = "list_elements"
    case focused
    case inspectUI = "inspect_ui"
    case verifyState = "verify_state"

    // MARK: - System

    case browser
    case permissions
    case sleep
    case agent
    case shell

    // Historical split-tool names retained for persisted sessions.
    case wait
    case clipboard
    case copyToClipboard = "copy_to_clipboard"
    case pasteFromClipboard = "paste_from_clipboard"
    case listSpaces = "list_spaces"
    case switchSpace = "switch_space"
    case moveWindowToSpace = "move_window_to_space"

    // MARK: - Communication

    case done

    // Historical completion names retained for persisted sessions.
    case taskCompleted = "task_completed"
    case needMoreInformation = "need_more_information"
    case needInfo = "need_info"

    // MARK: - Properties

    /// The category this tool belongs to
    var category: ToolCategory {
        switch self {
        case .see, .image, .capture, .screenshot, .windowCapture, .analyze:
            .vision
        case .click, .type, .setValue, .action, .press, .drag, .move, .scroll, .paste,
             .performAction, .hotkey, .swipe:
            .ui
        case .app, .launchApp, .listApps, .quitApp, .focusApp, .hideApp, .unhideApp, .switchApp:
            .app
        case .window, .space, .focusWindow, .resizeWindow, .listWindows, .minimizeWindow, .maximizeWindow, .listScreens:
            .window
        case .menu, .dialog, .menuClick, .listMenus, .dialogClick, .dialogInput:
            .menu
        case .dock, .listDock, .dockClick, .dockLaunch:
            .dock
        case .list, .findElement, .listElements, .focused, .inspectUI, .verifyState:
            .element
        case .browser:
            .browser
        case .permissions, .sleep, .agent, .shell, .wait, .clipboard, .copyToClipboard, .pasteFromClipboard,
             .listSpaces,
             .switchSpace,
             .moveWindowToSpace:
            .system
        case .done, .taskCompleted, .needMoreInformation, .needInfo:
            .completion
        }
    }

    /// The icon to display for this tool
    public var icon: String {
        // Special cases first
        switch self {
        case .taskCompleted:
            "\(AgentDisplayTokens.Status.success)"
        case .needMoreInformation, .needInfo:
            "\(AgentDisplayTokens.Status.info)"
        case .wait:
            "\(AgentDisplayTokens.Status.time)"
        case .sleep:
            "\(AgentDisplayTokens.Status.time)"
        case .shell:
            "[sh]"
        case .scroll:
            "[scrl]"
        case .type, .hotkey, .press:
            "[type]"
        case .click, .dialogClick:
            "[tap]"
        default:
            // Use category icon
            self.category.icon
        }
    }

    /// Human-readable display name for the tool
    public var displayName: String {
        switch self {
        case .image: "Capture Image"
        case .capture: "Capture Activity"
        case .setValue: "Set Value"
        case .action: "Action"
        case .performAction: "Perform Action"
        case .paste: "Paste"
        case .app: "Application"
        case .window: "Window"
        case .space: "Space"
        case .menu: "Menu"
        case .dialog: "Dialog"
        case .dock: "Dock"
        case .list: "List System Items"
        case .browser: "Browser"
        case .permissions: "Check Permissions"
        case .sleep: "Sleep"
        case .agent: "Agent"
        case .done: "Done"
        case .launchApp: "Launch Application"
        case .listApps: "List Applications"
        case .quitApp: "Quit Application"
        case .focusApp: "Focus Application"
        case .hideApp: "Hide Application"
        case .unhideApp: "Show Application"
        case .switchApp: "Switch Application"
        case .focusWindow: "Focus Window"
        case .resizeWindow: "Resize Window"
        case .listWindows: "List Windows"
        case .minimizeWindow: "Minimize Window"
        case .maximizeWindow: "Maximize Window"
        case .listScreens: "List Screens"
        case .menuClick: "Click Menu"
        case .listMenus: "List Menus"
        case .dialogClick: "Click Dialog"
        case .dialogInput: "Enter Dialog Input"
        case .listDock: "List Dock Items"
        case .dockClick: "Click Dock Item"
        case .dockLaunch: "Launch from Dock"
        case .findElement: "Find Element"
        case .listElements: "List Elements"
        case .windowCapture: "Capture Window"
        case .taskCompleted: "Task Completed"
        case .needMoreInformation: "Need More Information"
        case .needInfo: "Need Information"
        case .inspectUI: "Inspect UI"
        case .verifyState: "Verify State"
        case .clipboard: "Clipboard"
        case .copyToClipboard: "Copy to Clipboard"
        case .pasteFromClipboard: "Paste from Clipboard"
        case .listSpaces: "List Spaces"
        case .switchSpace: "Switch Space"
        case .moveWindowToSpace: "Move Window to Space"
        default:
            // Default: capitalize and replace underscores
            rawValue
                .split(separator: "_")
                .map(\.capitalized)
                .joined(separator: " ")
        }
    }

    // MARK: - Initialization

    /// Initialize from a string tool name (for backward compatibility)
    init?(toolName: String) {
        // Try direct rawValue match first
        if let tool = ToolType(rawValue: toolName) {
            self = tool
        } else {
            // Handle any legacy naming variations
            switch toolName {
            case "need_info":
                self = .needInfo
            default:
                return nil
            }
        }
    }
}
