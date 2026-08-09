---
summary: 'Extend the shared tool formatter registry used by CLI and Mac'
read_when:
  - 'adding a tool or changing tool execution summaries'
  - 'debugging differences between agent and Mac tool output'
---

# Tool Formatter Architecture

## Overview

Tool formatting is owned by `PeekabooAgentRuntime` and shared with the Mac app. The live implementation is under:

```text
Core/PeekabooCore/Sources/PeekabooAgentRuntime/ToolFormatting/
```

## Architecture Components

### Shared Components

- `ToolType` is the type-safe list of formatter-facing tool names, display names, icons, and categories.
- `ToolFormatter` defines starting, completion, error, compact-summary, result-summary, and title formatting.
- `BaseToolFormatter` provides fallback behavior.
- `ToolFormatterRegistry` creates and routes formatters for every `ToolType`.
- `ToolEventSummary` extracts stable summaries from structured tool results before formatter-specific fallback.
- `ToolResultExtractor` and `FormattingUtilities` normalize wrapped values and shared display operations.
- `Formatters/` contains the application, communication, dock, element, menu/dialog, system, UI automation, vision, and window formatter families.

The registry is available as `ToolFormatterRegistry.shared` or as a separately initialized registry in tests.

### Mac App Consumption

The Mac app does not maintain its own formatter registry:

- `Apps/Mac/Peekaboo/Core/ToolFormatterBridge.swift` parses JSON arguments/results and delegates to `ToolFormatterRegistry`.
- `Apps/Mac/Peekaboo/Features/Main/ToolFormatter.swift` is a compatibility facade for compact summaries and shared formatting utilities.

Unknown tool names fall back to a title-cased name and raw/pretty-printed JSON rather than being added to a parallel Mac-only stack.

## Adding a New Tool

1. Add the formatter-facing name to `ToolType`.
2. Add or extend the appropriate formatter under `ToolFormatting/Formatters/`.
3. Register the type in `ToolFormatterRegistry.registerAllFormatters()`. Unregistered types receive a category-based default formatter, but explicit routing documents the intended family.
4. Add focused registry/formatter tests under `Core/PeekabooCore/Tests`.
5. Verify both agent output and the Mac facade if the new result shape is user-visible there.

Example lookup:

```swift
let formatter = ToolFormatterRegistry.shared.formatter(for: .launchApp)
let summary = formatter.formatResultSummary(result: resultDictionary)
```

## Best Practices

- Use `ToolResultExtractor` for values that may be direct or wrapped.
- Keep compact summaries short and deterministic.
- Put shared policy in `PeekabooAgentRuntime`; Mac files should remain adapters.
- Prefer `ToolEventSummary` for canonical structured results, then fall back to the registered formatter.
- Test the actual dictionary keys emitted by the tool rather than synthetic result shapes.
