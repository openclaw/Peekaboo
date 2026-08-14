---
summary: 'Use PeekabooError and StandardErrorCode consistently'
read_when:
  - 'adding or mapping errors in Peekaboo services'
  - 'debugging CLI text or JSON error output'
---

# Peekaboo Error Handling Guide

This guide describes the shared error primitives in `PeekabooFoundation` and how the CLI maps them to user-facing output.

## Overview

The error handling system has three main pieces:

1. **`PeekabooError`** — the shared `LocalizedError` used by services.
2. **`StandardErrorCode`** — stable codes exposed by `StandardizedError`.
3. **CLI mapping** — `ErrorHandlingCommand` maps service errors to the CLI's JSON `ErrorCode` values.

## Error Types

### Standard Error Codes

`StandardErrorCode` covers permission, lookup, operation, validation, system, and AI failures. Representative values are:

```swift
case screenRecordingPermissionDenied = "PERMISSION_DENIED_SCREEN_RECORDING"
case accessibilityPermissionDenied = "PERMISSION_DENIED_ACCESSIBILITY"
case applicationNotFound = "APP_NOT_FOUND"
case windowNotFound = "WINDOW_NOT_FOUND"
case elementNotFound = "ELEMENT_NOT_FOUND"
case captureFailed = "CAPTURE_FAILED"
case interactionFailed = "INTERACTION_FAILED"
case accessibilityIncomplete = "ACCESSIBILITY_INCOMPLETE"
case timeout = "TIMEOUT"
case invalidInput = "INVALID_INPUT"
```

`PeekabooError.code` returns one of these values. It also supplies `userMessage`, string-valued `context`, and a recovery suggestion for the cases where the repository defines one.

### Error Categories

`PeekabooError.category` groups errors into `permissions`, `automation`, `session`, `io`, `validation`, `ai`, `configuration`, `network`, or `unknown`.

## Using the Error System

### Creating Errors

Use a concrete `PeekabooError` case or one of its convenience factories:

```swift
throw PeekabooError.permissionDeniedScreenRecording
throw PeekabooError.appNotFound("Safari")
throw PeekabooError.windowNotFound(criteria: "Finder window 2")
throw PeekabooError.elementNotFound("Submit button")
throw PeekabooError.captureFailed("Display disconnected")
throw PeekabooError.timeout(operation: "screenshot", duration: 30)
throw PeekabooError.invalidInput(field: "coordinates", reason: "Outside screen bounds")
throw PeekabooError.ambiguousAppIdentifier(
    "Safari",
    matches: ["Safari", "Safari Technology Preview"])
```

`OperationError` is a typealias for `PeekabooError`; there are no separate `PermissionError`, `NotFoundError`, or `ValidationError` families in `PeekabooFoundation`.

### Standardizing Other Errors

`ErrorStandardizer.standardize(_:)` preserves errors that already conform to `StandardizedError`, converts missing-file Cocoa errors to `PeekabooError.fileIOError`, and wraps other errors as `PeekabooError.operationError`.

```swift
let standardized = ErrorStandardizer.standardize(error)
print(standardized.code.rawValue)
print(standardized.userMessage)
```

## Recovery Suggestions

`StandardizedError.recoverySuggestion` is currently defined for Screen Recording, Accessibility, event-synthesizing permission, missing apps/windows, timeouts, and ambiguous app identifiers. `PeekabooError.suggestedAction` additionally covers a small set of session, AI, and service cases.

```swift
let error = PeekabooError.permissionDeniedScreenRecording
if let suggestion = error.recoverySuggestion {
    print("Suggestion: \(suggestion)")
}
```

## Service Integration

### Example: ScreenCaptureService

`ScreenCaptureServiceProtocol` is `@MainActor` and returns `CaptureResult`. The convenience overload supplies screenshot-flash visualization and logical 1x scaling:

```swift
let result = try await services.screenCapture.captureScreen(displayIndex: nil)
```

The full signature is:

```swift
func captureScreen(
    displayIndex: Int?,
    visualizerMode: CaptureVisualizerMode,
    scale: CaptureScalePreference
) async throws -> CaptureResult
```

Window capture supports either `appIdentifier` plus `windowIndex`, or a concrete `CGWindowID`.

## CLI Integration

### Error Output

Commands conforming to `ErrorHandlingCommand` call `handleError(_:customCode:)`. Text mode writes `Error: <localized message>` to stderr. JSON mode emits the standard response shape:

```json
{
  "success": false,
  "debug_logs": [],
  "error": {
    "message": "Screen Recording permission is required",
    "code": "PERMISSION_ERROR_SCREEN_RECORDING"
  }
}
```

The CLI's `ErrorCode` names are an output contract separate from `StandardErrorCode`; `CommandErrorHandling.swift` owns the explicit mapping between them.

AX-only and combined screenshot+AX observation use `ACCESSIBILITY_INCOMPLETE` only when the exact target was
positively resolved but the Accessibility result contains no usable elements. This includes legacy Bridge results
that omit the incomplete-read marker: an exact empty map is not evidence of completeness. The failure is retry-safe
and mutation-free; combined observation preserves a requested raster without publishing the unusable element
snapshot. It must not replace `TIMEOUT`, permission/target errors, native AX failures, explicit
screenshot-only success, or successful nonempty truncated evidence.

## Best Practices

### 1. Use the Shared Cases

Prefer a specific `PeekabooError` over a generic `NSError` when a shared case fits.

### 2. Preserve Context

Use associated values for the resource, identifier, or reason that helps the caller recover:

```swift
throw PeekabooError.captureFailed("No shareable window matched \(appName)")
```

### 3. Map at the Output Boundary

Services should throw domain errors. CLI commands map those errors to text or JSON at their output boundary rather than embedding terminal formatting in service code.

## Testing Errors

Test the case, standardized code, localized message, context, and CLI mapping that matter for the behavior:

```swift
let error = PeekabooError.appNotFound("TextEdit")
#expect(error.code == .applicationNotFound)
#expect(error.userMessage == "Application 'TextEdit' not found")
#expect(error.context["app"] == "TextEdit")
```
