import PeekabooCore
import SwiftUI

/// Animated SF Symbol icon for tool executions
@available(macOS 15.0, *)
struct AnimatedToolIcon: View {
    let toolName: String
    let isRunning: Bool

    var body: some View {
        switch self.toolName {
        case "see", "screenshot", "window_capture", "click", "dialog_click",
             "launch_app", "dock_launch", "quit_app", "focused":
            // Bounce effects
            Image(systemName: self.symbolName)
                .foregroundStyle(self.iconColor)
                .symbolEffect(.bounce, isActive: self.isRunning)

        case "type", "dialog_input", "hotkey", "find_element", "permissions":
            // Pulse effects
            Image(systemName: self.symbolName)
                .foregroundStyle(self.iconColor)
                .symbolEffect(.pulse, isActive: self.isRunning)

        case "scroll", "shell":
            // Variable color effects
            Image(systemName: self.symbolName)
                .foregroundStyle(self.iconColor)
                .symbolEffect(.variableColor.iterative, isActive: self.isRunning)

        case "resize_window", "move_window", "drag", "swipe", "need_more_information":
            // Wiggle effects
            Image(systemName: self.symbolName)
                .foregroundStyle(self.iconColor)
                .symbolEffect(.wiggle, isActive: self.isRunning)

        case "wait", "sleep":
            // Rotation for clock
            Image(systemName: self.symbolName)
                .foregroundStyle(self.iconColor)
                .symbolEffect(.rotate, isActive: self.isRunning)

        case "list", "list_apps", "list_windows", "list_elements", "list_menus", "list_dock":
            // Appear effect for lists
            Image(systemName: self.symbolName)
                .foregroundStyle(self.iconColor)
                .symbolEffect(.appear, isActive: self.isRunning)

        case "task_completed":
            // Success animation
            Image(systemName: self.symbolName)
                .foregroundStyle(self.iconColor)
                .symbolEffect(.bounce.up, isActive: self.isRunning)

        case "menu", "menu_click":
            // Menu selection pulse
            Image(systemName: self.symbolName)
                .foregroundStyle(self.iconColor)
                .symbolEffect(.pulse, isActive: self.isRunning)

        case "focus_window", "space":
            // Window focus appear
            Image(systemName: self.symbolName)
                .foregroundStyle(self.iconColor)
                .symbolEffect(.appear, isActive: self.isRunning)

        default:
            // Default rotation for gears
            Image(systemName: self.symbolName)
                .foregroundStyle(self.iconColor)
                .symbolEffect(.rotate, isActive: self.isRunning)
        }
    }

    private var symbolName: String {
        switch self.toolName {
        case "see", "screenshot", "window_capture":
            "camera.viewfinder"
        case "click":
            "cursorarrow.click"
        case "type":
            "keyboard"
        case "scroll":
            "arrow.up.and.down.circle"
        case "launch_app":
            "app.dashed"
        case "quit_app":
            "xmark.app"
        case "focus_window":
            "macwindow.on.rectangle"
        case "resize_window":
            "arrow.up.left.and.down.right.magnifyingglass"
        case "move_window":
            "arrow.up.and.down.and.arrow.left.and.right"
        case "hotkey":
            "command"
        case "shell":
            "terminal"
        case "list", "list_apps", "list_windows", "list_elements", "list_menus", "list_dock":
            "list.bullet.rectangle"
        case "menu", "menu_click":
            "filemenu.and.selection"
        case "find_element":
            "magnifyingglass.circle"
        case "focused":
            "target"
        case "dock_launch":
            "dock.rectangle"
        case "dialog_click", "dialog_input":
            "text.bubble"
        case "drag":
            "hand.draw"
        case "swipe":
            "hand.point.up.left"
        case "wait", "sleep":
            "clock"
        case "permissions":
            "lock.shield"
        case "space":
            "squares.leading.rectangle"
        case "task_completed":
            "checkmark.seal"
        case "need_more_information":
            "questionmark.bubble"
        default:
            "gearshape"
        }
    }

    private var iconColor: Color {
        switch self.toolName {
        case "see", "screenshot", "window_capture":
            .blue
        case "click", "dialog_click":
            .purple
        case "type", "dialog_input":
            .indigo
        case "launch_app", "dock_launch":
            .green
        case "quit_app":
            .red
        case "shell":
            .orange
        case "task_completed":
            .green
        case "need_more_information":
            .yellow
        default:
            .primary
        }
    }
}

/// Static icon fallback for older macOS versions
struct StaticToolIcon: View {
    let toolName: String

    var body: some View {
        Text(PeekabooAgent.iconForTool(self.toolName))
            .font(.system(size: 14))
    }
}

/// Enhanced tool icon that shows both animations and status overlays
struct EnhancedToolIcon: View {
    let toolName: String
    let status: ToolExecutionStatus

    var body: some View {
        ZStack {
            // Main tool icon with animations
            if #available(macOS 15.0, *) {
                AnimatedToolIcon(
                    toolName: self.toolName,
                    isRunning: self.status == .running)
            } else {
                StaticToolIcon(toolName: self.toolName)
            }

            // Status overlay for completed/failed/cancelled states
            if self.status != .running {
                self.statusOverlay
                    .offset(x: 6, y: 6)
            }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch self.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white, .green)
                .background(Circle().fill(.white).frame(width: 12, height: 12))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white, .red)
                .background(Circle().fill(.white).frame(width: 12, height: 12))
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white, .orange)
                .background(Circle().fill(.white).frame(width: 12, height: 12))
        case .running:
            EmptyView()
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        // Running tools
        VStack(alignment: .leading, spacing: 10) {
            Text("Running Tools").font(.headline)
            HStack(spacing: 20) {
                EnhancedToolIcon(toolName: "see", status: .running)
                EnhancedToolIcon(toolName: "click", status: .running)
                EnhancedToolIcon(toolName: "type", status: .running)
                EnhancedToolIcon(toolName: "shell", status: .running)
                EnhancedToolIcon(toolName: "launch_app", status: .running)
            }
        }

        // Completed tools
        VStack(alignment: .leading, spacing: 10) {
            Text("Completed Tools").font(.headline)
            HStack(spacing: 20) {
                EnhancedToolIcon(toolName: "see", status: .completed)
                EnhancedToolIcon(toolName: "click", status: .completed)
                EnhancedToolIcon(toolName: "type", status: .completed)
                EnhancedToolIcon(toolName: "shell", status: .completed)
                EnhancedToolIcon(toolName: "launch_app", status: .completed)
            }
        }

        // Failed tools
        VStack(alignment: .leading, spacing: 10) {
            Text("Failed Tools").font(.headline)
            HStack(spacing: 20) {
                EnhancedToolIcon(toolName: "see", status: .failed)
                EnhancedToolIcon(toolName: "click", status: .failed)
                EnhancedToolIcon(toolName: "type", status: .failed)
                EnhancedToolIcon(toolName: "shell", status: .failed)
                EnhancedToolIcon(toolName: "launch_app", status: .failed)
            }
        }

        // Cancelled tools
        VStack(alignment: .leading, spacing: 10) {
            Text("Cancelled Tools").font(.headline)
            HStack(spacing: 20) {
                EnhancedToolIcon(toolName: "see", status: .cancelled)
                EnhancedToolIcon(toolName: "click", status: .cancelled)
                EnhancedToolIcon(toolName: "type", status: .cancelled)
                EnhancedToolIcon(toolName: "shell", status: .cancelled)
                EnhancedToolIcon(toolName: "launch_app", status: .cancelled)
            }
        }
    }
    .padding()
}
