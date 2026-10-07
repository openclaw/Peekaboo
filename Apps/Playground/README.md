

# Peekaboo Playground

A comprehensive SwiftUI test application for validating all Peekaboo automation features.

## Overview

Peekaboo Playground is a macOS app designed to test and demonstrate all automation capabilities of Peekaboo. It provides a controlled environment with various UI elements and interactions that can be automated.

## Features

### 1. **Click Testing**
- Single, double, and right-click buttons
- Toggle switches and buttons
- Disabled button states
- Different button sizes (mini to large)
- Nested click targets
- Context menus

### 2. **Text Input Testing**
- Basic text fields with change tracking
- Number-only fields with validation
- Secure text fields
- Pre-filled text fields
- Search fields with clear button
- Multiline text editors
- Special character input
- Focus control
- Hidden web-style fields (AXGroup-wrapped inputs) for hidden-field repros

### 3. **UI Controls**
- Continuous and discrete sliders
- Checkboxes with bulk operations
- Radio button groups
- Segmented controls
- Steppers
- Date pickers
- Progress indicators
- Color pickers

### 4. **Scroll & Gestures**
- Vertical and horizontal scroll views
- Nested scroll views
- Swipe gesture detection
- Pinch/zoom gestures
- Rotation gestures
- Long press detection
- Scroll-to positions

### 5. **Window Management**
- Window state display
- Minimize/maximize controls
- Window positioning (corners)
- Window resizing presets
- Multiple window creation
- Window cascading/tiling
- Full screen toggle

### 6. **Drag & Drop**
- Draggable items
- Drop zones with hover states
- Reorderable lists
- Free-form drag area
- Drag statistics

### 7. **Keyboard Testing**
- Key press detection
- Modifier key tracking
- Hotkey combinations
- Key sequence recording
- Special key handling
- Real-time modifier status

## Logging

All actions are logged using Apple's OSLog framework with the subsystem `boo.peekaboo.playground`. The app provides:

- Real-time action logging
- Categorized logs (Click, Text, Menu, etc.)
- In-app log viewer
- Log export functionality
- Log filtering and search
- Action counters

## Building and Running

Follow the [building guide](../../docs/building.md) for Swift workspace setup before a direct Xcode build.
For background qualification, use the [signed fixture workflow](../../docs/testing/background-computer-use.md), which
records source identity and separates unsigned compilation from signing. Do not launch an unsigned/ad-hoc build against
an existing trusted installation's permissions or Keychain state.

```bash
# From the repository root, build the app with its Xcode project
xcodebuild -project Apps/Playground/Playground.xcodeproj \
  -scheme Playground \
  -configuration Release \
  -derivedDataPath Apps/Playground/.build \
  build

# After signing and verifying the intended artifact, request a background launch.
open -g -n Apps/Playground/.build/Build/Products/Release/Playground.app
```

Confirm the newly launched process generation before treating it as task-owned. A background launch request alone does
not prove noninterference. See the [testing methodology](../../docs/playground-testing.md) for fresh exact-window
observations, result readback, and cleanup; preserve existing user instances and earlier test artifacts.

## Using with Peekaboo

This app is designed to work with Peekaboo's automation features. Each UI element has:
- Unique accessibility identifiers
- Proper labeling for element detection
- Clear visual boundaries
- State indicators

### Example Automation Scenarios

1. **Button Click Test**
   - Target: `single-click-button`
   - Verify click count increases

2. **Text Input Test**
   - Target: `basic-text-field`
   - Type text and verify change logs

3. **Slider Control**
   - Target: `continuous-slider`
   - Drag to specific values

4. **Window Manipulation**
   - Use window control buttons
   - Verify position/size changes

## Viewing Logs

### In-App Log Viewer
- Click "View Logs" button in the header
- Filter by category or search
- Export logs to file

### Using playground-log.sh (Recommended)

Run these commands from the repository root:

```bash
# Use the forwarding wrapper
./scripts/playground-log.sh

# Or directly
./Apps/Playground/scripts/playground-log.sh

# Stream logs in real-time
./scripts/playground-log.sh -f

# Show specific category
./scripts/playground-log.sh -c Click

# Search for specific actions
./scripts/playground-log.sh -s "button"
```

Category and search values are literal text, not shell commands or predicate expressions. Missing option values
exit with status 2 before reading logs; supplied empty or dash-prefixed values are not missing arguments.
`--lines` limits completed text queries only. `--json` preserves the producer's framing, and `--follow` forwards
events without waiting for the stream to finish; neither uses the line limit. Live JSON need not be one document.
Historical `--errors` queries use the native `logType` severity. Failed queries, invalid line limits and output-file
errors remain nonzero, and a failed export never prints a save confirmation. Text output retains category colors
without interpreting backslash escapes inside log messages.

### Using pblog (if available)
```bash
# Stream logs
log stream --predicate 'subsystem == "boo.peekaboo.playground"' --level info

# Show recent logs
log show --predicate 'subsystem == "boo.peekaboo.playground"' --info --last 30m
```

### Log Categories
- **Click**: Button clicks, toggles, click areas
- **Text**: Text input, field changes
- **Menu**: Menu selections, context menus
- **Window**: Window operations
- **Scroll**: Scroll events
- **Drag**: Drag and drop operations
- **Keyboard**: Key presses, hotkeys
- **Focus**: Focus changes
- **Gesture**: Swipes, pinches, rotations
- **Control**: Sliders, pickers, other controls

## Testing Tips

1. **Clear State**: Use reset buttons to restore default states
2. **Action Counter**: Monitor the action counter to verify all actions are logged
3. **Last Action**: Check the status bar for the most recent action
4. **Export Logs**: Use copy/export features to save test results
5. **Accessibility**: All elements have proper identifiers for automation
