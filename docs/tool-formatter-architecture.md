---
summary: 'Review Tool Formatter Architecture guidance'
read_when:
  - 'planning work related to tool formatter architecture'
  - 'debugging or extending features described here'
---

# Tool Formatter Architecture

## Overview

The Peekaboo tool formatter system provides a type-safe, modular architecture for formatting tool execution output across both the CLI and Mac app. This document describes the architecture, components, and how to extend the system.

## Architecture Components

### Core Components (PeekabooCore)

The shared formatting infrastructure lives in `PeekabooCore/Sources/PeekabooCore/ToolFormatting/`:

#### 1. PeekabooToolType Enum
```swift
public enum PeekabooToolType: String, CaseIterable, Sendable {
    case see = "see"
    case screenshot = "screenshot"
    case click = "click"
    // ... all 50+ tools
}
```

**Properties:**
- `displayName`: Human-readable name ("Launch Application" vs "launch_app")
- `icon`: Emoji icon for visual representation
- `category`: Tool categorization (vision, ui, app, etc.)
- `isCommunicationTool`: Whether output should be suppressed

#### 2. ToolResultExtractor
Unified utility for extracting values from tool results with automatic unwrapping:

```swift
// Extract with automatic type handling
let count = ToolResultExtractor.int("count", from: result)
let app = ToolResultExtractor.string("app", from: result)
let windows = ToolResultExtractor.array("windows", from: result)
```

Handles both direct values and wrapped values:
- Direct: `{"count": 5}`
- Wrapped: `{"count": {"type": "number", "value": 5}}`

#### 3. FormattingUtilities
Common formatting helpers used across formatters:

```swift
// Format keyboard shortcuts: "cmd+shift+a" → "⌘⇧A"
FormattingUtilities.formatKeyboardShortcut("cmd+shift+a")

// Truncate long text
FormattingUtilities.truncate(longText, maxLength: 50)

// Format file sizes
FormattingUtilities.formatFileSize(1024000) // "1 MB"

// Format durations
FormattingUtilities.formatDetailedDuration(1.5) // "1.5s"
```

### CLI Components

Located in `Apps/CLI/Sources/peekaboo/Commands/AI/ToolFormatting/`:

#### ToolFormatter Protocol
```swift
public protocol ToolFormatter {
    var toolType: ToolType { get }
    func formatStarting(arguments: [String: Any]) -> String
    func formatCompleted(result: [String: Any], duration: TimeInterval) -> String
    func formatError(error: String, result: [String: Any]) -> String
    func formatCompactSummary(arguments: [String: Any]) -> String
    func formatResultSummary(result: [String: Any]) -> String
    func formatForTitle(arguments: [String: Any]) -> String
}
```

#### BaseToolFormatter
Base implementation providing default formatting behavior that specific formatters can override.

#### Specialized Formatters
- `VisionToolFormatter`: Screenshots, screen capture, window capture
- `ApplicationToolFormatter`: App launching, listing, window management
- `UIAutomationToolFormatter`: Click, type, scroll, hotkeys
- `ElementToolFormatter`: Finding and listing UI elements
- `MenuDialogToolFormatter`: Menu and dialog interactions
- `SystemToolFormatter`: Shell commands, waiting
- `WindowToolFormatter`: Window focus, resize, spaces
- `DockToolFormatter`: Dock operations
- `CommunicationToolFormatter`: Internal communication tools

#### Detailed Formatters (Default)
The default formatters provide comprehensive result formatting:
- `DetailedVisionToolFormatter`: Includes element counts, performance metrics, file sizes
- `DetailedApplicationToolFormatter`: Includes memory usage, app states, process info
- `DetailedUIAutomationToolFormatter`: Rich UI interaction details with validation
- `DetailedMenuSystemToolFormatter`: Comprehensive menu, dialog, and system tool output

#### ToolFormatterRegistry
Singleton registry managing all formatters:

```swift
let formatter = ToolFormatterRegistry.shared.formatter(for: .launchApp)
let summary = formatter.formatResultSummary(result: resultDict)
```

### Mac App Components

Located in `Apps/Mac/Peekaboo/Features/Main/ToolFormatters/`:

#### MacToolFormatterProtocol
```swift
protocol MacToolFormatterProtocol {
    var handledTools: Set<String> { get }
    func formatSummary(toolName: String, arguments: [String: Any]) -> String?
    func formatResult(toolName: String, result: [String: Any]) -> String?
}
```

#### Mac-Specific Formatters
Similar structure to CLI but adapted for SwiftUI:
- `VisionToolFormatter`
- `ApplicationToolFormatter`
- `UIAutomationToolFormatter`
- `SystemToolFormatter`
- `ElementToolFormatter`
- `MenuToolFormatter`

#### MacToolFormatterRegistry
Central registry for Mac app formatters.

## Output Modes

The formatter system supports multiple output modes:

### Minimal Mode
Plain text, no colors, CI-friendly:
```
list_apps OK → 29 apps running
```

### Default Mode
Rich formatting with detailed output (formerly "Enhanced Mode"):
```
📱 Listing applications... ✅ → 29 apps running [15 active, 14 background] (1.2s)
```

### Verbose Mode
Full JSON debug information with detailed arguments and results.

## Adding a New Tool

### 1. Add to PeekabooToolType
```swift
// In PeekabooCore/Sources/PeekabooCore/ToolFormatting/PeekabooToolType.swift
case myNewTool = "my_new_tool"

// Add to displayName
case .myNewTool: return "My New Tool"

// Add to icon
case .myNewTool: return "🆕"

// Add to category
case .myNewTool: return .system
```

### 2. Create or Update Formatter
```swift
// In appropriate formatter file
class SystemToolFormatter: BaseToolFormatter {
    override func formatCompactSummary(arguments: [String: Any]) -> String {
        switch toolType {
        case .myNewTool:
            return "doing something"
        // ...
        }
    }
    
    override func formatResultSummary(result: [String: Any]) -> String {
        switch toolType {
        case .myNewTool:
            let count = ToolResultExtractor.int("count", from: result) ?? 0
            return "→ processed \(count) items"
        // ...
        }
    }
}
```

### 3. Register in ToolFormatterRegistry
```swift
// In ToolFormatterRegistry.init()
ToolType.myNewTool: SystemToolFormatter(toolType: .myNewTool)
```

## Best Practices

### 1. Use ToolResultExtractor
Always use `ToolResultExtractor` instead of direct casting to handle wrapped values:

```swift
// ❌ Bad
let count = result["count"] as? Int

// ✅ Good
let count = ToolResultExtractor.int("count", from: result)
```

### 2. Provide Progressive Detail
Format output based on available information:

```swift
override func formatResultSummary(result: [String: Any]) -> String {
    var parts: [String] = []
    
    // Always provide basic info
    parts.append("→ completed")
    
    // Add details if available
    if let count = ToolResultExtractor.int("count", from: result) {
        parts.append("\(count) items")
    }
    
    if let duration = ToolResultExtractor.double("duration", from: result) {
        parts.append(String(format: "%.1fs", duration))
    }
    
    return parts.joined(separator: " ")
}
```

### 3. Handle Errors Gracefully
Provide helpful error messages with suggestions:

```swift
override func formatError(error: String, result: [String: Any]) -> String {
    if error.contains("not found") {
        return "✗ \(error) - Try checking if the app is installed"
    }
    return "✗ \(error)"
}
```

### 4. Keep Summaries Concise
Compact summaries should be brief but informative:

```swift
// ❌ Too verbose
return "Launching the application named \(appName) with bundle identifier \(bundleId)"

// ✅ Concise
return appName
```

### 5. Use Consistent Icons
Follow the icon conventions:
- 👁 Vision/Screenshots
- 🖱 Clicking/Mouse
- ⌨️ Typing/Keyboard
- 📱 Applications
- 🪟 Windows
- 📋 Menus
- 💻 System/Shell
- ✅ Success/Completion
- ❌ Errors

## Testing Formatters

### Unit Testing
```swift
func testLaunchAppFormatter() {
    let formatter = ApplicationToolFormatter(toolType: .launchApp)
    
    let args = ["app": "Safari"]
    let summary = formatter.formatCompactSummary(arguments: args)
    XCTAssertEqual(summary, "Safari")
    
    let result = ["success": true, "app": "Safari", "pid": 12345]
    let resultSummary = formatter.formatResultSummary(result: result)
    XCTAssertEqual(resultSummary, "→ Launched Safari (PID: 12345)")
}
```

### Integration Testing
Test with actual tool execution:
```bash
# Test formatter output
peekaboo agent "list all apps" --verbose

# Check different output modes
peekaboo agent "take a screenshot" --simple  # Minimal mode
peekaboo agent "click on Safari"            # Default detailed mode
```

## Migration Guide

### Migrating from String-Based Formatting

Old approach:
```swift
switch toolName {
case "launch_app":
    if let app = args["app"] as? String {
        print("Launching \(app)")
    }
// ... many more cases
}
```

New approach:
```swift
let formatter = ToolFormatterRegistry.shared.formatter(for: .launchApp)
let summary = formatter.formatCompactSummary(arguments: args)
print(summary)
```

### Sharing Formatters Between CLI and Mac App

1. Move common logic to PeekabooCore:
```swift
// In PeekabooCore/ToolFormatting/FormattingUtilities.swift
public static func formatAppLaunch(_ app: String, pid: Int?) -> String {
    var result = "Launched \(app)"
    if let pid = pid {
        result += " (PID: \(pid))"
    }
    return result
}
```

2. Use in both CLI and Mac formatters:
```swift
// CLI formatter
return FormattingUtilities.formatAppLaunch(app, pid: pid)

// Mac formatter
return FormattingUtilities.formatAppLaunch(app, pid: pid)
```

## Performance Considerations

- Formatters are lightweight and stateless
- Registry uses lazy initialization
- ToolResultExtractor caches unwrapped values
- Enhanced formatters only process available data

## Future Enhancements

- [ ] Localization support for display names
- [ ] Custom format templates
- [ ] Streaming formatter for real-time updates
- [ ] Format caching for repeated operations
- [ ] Plugin system for custom formatters