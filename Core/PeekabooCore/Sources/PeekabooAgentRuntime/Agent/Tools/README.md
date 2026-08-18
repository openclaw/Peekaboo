# Agent Tools

This directory contains the modular tool implementations for the Peekaboo agent. Each tool provides a specific capability that the AI agent can use to interact with macOS.

## Tool Categories

### 📸 Vision Tools (`VisionTools.swift`)
- **see** - Primary tool for screen capture and UI element detection
- **screenshot** - Save screenshots to disk
- **window_capture** - Capture specific windows by title or ID

### 🖱️ UI Automation Tools (`UIAutomationTools.swift`)
- **click** - Click elements or coordinates
- **type** - Type text in fields or at cursor
- **scroll** - Scroll in windows or elements
- **press** - Dispatch fresh exact-snapshot background shortcuts or explicitly foreground raw keyboard shortcuts

### 🪟 Window Management (`WindowManagementTools.swift`)
- **list_windows** - List all visible windows
- **focus_window** - Bring windows to front
- **resize_window** - Resize/move windows or use presets

### 📱 Application Tools (`ApplicationTools.swift`)
- **list_apps** - List running applications
- **launch_app** - Launch applications by name

### 🔍 Element Tools (`ElementTools.swift`)
- **find_element** - Find specific UI elements
- **list_elements** - List all interactive elements
- **focused** - Get currently focused element info

### 📋 Menu Tools (`MenuTools.swift`)
- **menu_click** - Click menu bar items
- **list_menus** - List available menu structure

### 💬 Dialog Tools (`DialogTools.swift`)
- **dialog_click** - Click buttons in dialogs/alerts
- **dialog_input** - Enter text in dialog fields

### 🚀 Dock Tools (`DockTools.swift`)
- **dock_launch** - Launch apps from Dock
- **list_dock** - List Dock items

### 💻 Shell Tools (`ShellTools.swift`)
- **shell** - Execute shell commands safely

### ✅ Completion Tools (from `CompletionTools.swift`)
- **done** - Mark task as completed
- **need_info** - Request additional information

## Tool Structure

Each tool follows a consistent pattern using `Tachikoma.AgentTool`:

```swift
func createToolNameTool() -> Tachikoma.AgentTool {
    Tachikoma.AgentTool(
        name: "tool_name",
        description: "What this tool does",
        parameters: Tachikoma.AgentToolParameters(
            properties: [
                Tachikoma.AgentToolParameterProperty(
                    name: "param1",
                    type: .string,
                    description: "Parameter description"),
                Tachikoma.AgentToolParameterProperty(
                    name: "param2",
                    type: .boolean,
                    description: "Optional parameter"),
            ],
            required: ["param1"]),
        execute: { [services] params in
            // Tool implementation
            // Access parameters via params.optionalStringValue("param1")
            // Access services via captured services variable
            // Return .string("Result") or throw errors
        }
    )
}
```

## System Prompt

The `AgentSystemPrompt.swift` file contains the comprehensive system instructions that guide the agent's behavior and tool usage patterns.

## Adding New Tools

1. Create a new Swift file in this directory (e.g., `MyTools.swift`)
2. Add an extension to `PeekabooAgentService`
3. Implement tool creation functions following the pattern above
4. Add the tools to the `createPeekabooTools()` method in `PeekabooAgentService.swift`

## Best Practices

- Keep tool implementations focused and single-purpose
- Provide clear, helpful error messages with recovery suggestions
- Use consistent parameter naming across similar tools
- Validate inputs early and fail fast with clear errors
- Log important operations for debugging
- Consider adding metadata to successful results for better observability
