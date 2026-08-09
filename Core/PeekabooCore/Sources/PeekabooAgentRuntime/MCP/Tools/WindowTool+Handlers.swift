import Foundation
import MCP
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

extension WindowTool {
    // MARK: - Action Handlers

    func handleClose(
        service: any WindowManagementServiceProtocol,
        target: WindowActionTarget,
        appName: String?,
        allowForegroundFallback: Bool,
        startTime: Date) async throws -> ToolResponse
    {
        let windows = try await service.listWindows(target: target.target)
        guard let windowInfo = windows.first else {
            return ToolResponse.error("No matching window found to close")
        }
        let exactTarget = WindowTarget.windowId(windowInfo.windowID)
        guard let mutationIdentity = windowInfo.mutationIdentity else {
            throw PeekabooError.commandFailed(
                "Window \(windowInfo.windowID) did not include a process-generation identity")
        }
        try self.validateWindowOwner(mutationIdentity, expected: target.expectedOwnerIdentity)

        try await service.closeWindow(
            target: exactTarget,
            expectedIdentity: mutationIdentity,
            allowForegroundFallback: allowForegroundFallback)

        let executionTime = Date().timeIntervalSince(startTime)
        let message = self.successMessage(action: "Closed window '\(windowInfo.title)'", duration: executionTime)
        return self.windowResponse(
            message: message,
            appName: appName,
            windowInfo: windowInfo,
            actionDescription: "Window Close",
            baseMeta: ["execution_time": .double(executionTime)])
    }

    func handleMinimize(
        service: any WindowManagementServiceProtocol,
        target: WindowActionTarget,
        appName: String?,
        startTime: Date) async throws -> ToolResponse
    {
        let windows = try await service.listWindows(target: target.target)
        guard let windowInfo = windows.first else {
            return ToolResponse.error("No matching window found to minimize")
        }
        guard let mutationIdentity = windowInfo.mutationIdentity else {
            throw PeekabooError.commandFailed(
                "Window \(windowInfo.windowID) did not include a process-generation identity")
        }
        try self.validateWindowOwner(mutationIdentity, expected: target.expectedOwnerIdentity)

        try await service.minimizeWindow(
            target: .windowId(windowInfo.windowID),
            expectedIdentity: mutationIdentity)

        let executionTime = Date().timeIntervalSince(startTime)
        let message = self.successMessage(action: "Minimized window '\(windowInfo.title)'", duration: executionTime)
        return self.windowResponse(
            message: message,
            appName: appName,
            windowInfo: windowInfo,
            actionDescription: "Window Minimize",
            baseMeta: ["execution_time": .double(executionTime)])
    }

    func handleRestore(
        service: any WindowManagementServiceProtocol,
        target: WindowActionTarget,
        appName: String?,
        startTime: Date) async throws -> ToolResponse
    {
        let windows = try await service.listWindows(target: target.target)
        guard let windowInfo = windows.first else {
            return ToolResponse.error("No matching window found to restore")
        }
        guard let mutationIdentity = windowInfo.mutationIdentity else {
            throw PeekabooError.commandFailed(
                "Window \(windowInfo.windowID) did not include a process-generation identity")
        }
        try self.validateWindowOwner(mutationIdentity, expected: target.expectedOwnerIdentity)

        let exactTarget = WindowTarget.windowId(windowInfo.windowID)
        try await service.restoreWindow(target: exactTarget, expectedIdentity: mutationIdentity)
        let refreshedWindowInfo = try await service.listWindows(target: exactTarget).first ?? windowInfo

        let executionTime = Date().timeIntervalSince(startTime)
        let message = self.successMessage(
            action: "Restored window '\(refreshedWindowInfo.title)'",
            duration: executionTime)
        return self.windowResponse(
            message: message,
            appName: appName,
            windowInfo: refreshedWindowInfo,
            actionDescription: "Window Restore",
            baseMeta: ["execution_time": .double(executionTime)])
    }

    func handleMaximize(
        service: any WindowManagementServiceProtocol,
        target: WindowActionTarget,
        appName: String?,
        startTime: Date) async throws -> ToolResponse
    {
        let windows = try await service.listWindows(target: target.target)
        guard let windowInfo = windows.first else {
            return ToolResponse.error("No matching window found to maximize")
        }

        let exactTarget = WindowTarget.windowId(windowInfo.windowID)
        guard let mutationIdentity = windowInfo.mutationIdentity else {
            throw PeekabooError.commandFailed(
                "Window \(windowInfo.windowID) did not include a process-generation identity")
        }
        try self.validateWindowOwner(mutationIdentity, expected: target.expectedOwnerIdentity)
        try await service.maximizeWindow(target: exactTarget, expectedIdentity: mutationIdentity)
        guard let refreshedWindowInfo = try await service.listWindows(target: exactTarget).first else {
            return ToolResponse.error("Maximize completed but the exact window could not be read back")
        }

        let executionTime = Date().timeIntervalSince(startTime)
        let message = self.successMessage(
            action: "Maximized window '\(refreshedWindowInfo.title)'",
            duration: executionTime)
        return self.windowResponse(
            message: message,
            appName: appName,
            windowInfo: refreshedWindowInfo,
            actionDescription: "Window Maximize",
            baseMeta: ["execution_time": .double(executionTime)])
    }

    func handleMove(
        service: any WindowManagementServiceProtocol,
        target: WindowActionTarget,
        appName: String?,
        position: CGPoint,
        startTime: Date) async throws -> ToolResponse
    {
        let windows = try await service.listWindows(target: target.target)
        guard let windowInfo = windows.first else {
            return ToolResponse.error("No matching window found to move")
        }
        guard let mutationIdentity = windowInfo.mutationIdentity else {
            throw PeekabooError.commandFailed(
                "Window \(windowInfo.windowID) did not include a process-generation identity")
        }
        try self.validateWindowOwner(mutationIdentity, expected: target.expectedOwnerIdentity)

        try await service.moveWindow(
            target: .windowId(windowInfo.windowID),
            expectedIdentity: mutationIdentity,
            to: position)

        let executionTime = Date().timeIntervalSince(startTime)
        let detail = "Moved window '\(windowInfo.title)' to (\(Int(position.x)), \(Int(position.y)))"
        let message = self.successMessage(action: detail, duration: executionTime)
        return self.windowResponse(
            message: message,
            appName: appName,
            windowInfo: windowInfo,
            actionDescription: "Window Move",
            coordinates: ToolEventSummary.Coordinates(x: Double(position.x), y: Double(position.y)),
            baseMeta: [
                "new_x": .double(Double(position.x)),
                "new_y": .double(Double(position.y)),
                "execution_time": .double(executionTime),
            ])
    }

    func handleResize(
        service: any WindowManagementServiceProtocol,
        target: WindowActionTarget,
        appName: String?,
        size: CGSize,
        startTime: Date) async throws -> ToolResponse
    {
        let windows = try await service.listWindows(target: target.target)
        guard let windowInfo = windows.first else {
            return ToolResponse.error("No matching window found to resize")
        }
        guard let mutationIdentity = windowInfo.mutationIdentity else {
            throw PeekabooError.commandFailed(
                "Window \(windowInfo.windowID) did not include a process-generation identity")
        }
        try self.validateWindowOwner(mutationIdentity, expected: target.expectedOwnerIdentity)

        try await service.resizeWindow(
            target: .windowId(windowInfo.windowID),
            expectedIdentity: mutationIdentity,
            to: size)

        let executionTime = Date().timeIntervalSince(startTime)
        let detail = "Resized window '\(windowInfo.title)' to \(Int(size.width)) × \(Int(size.height))"
        let message = self.successMessage(action: detail, duration: executionTime)
        return self.windowResponse(
            message: message,
            appName: appName,
            windowInfo: windowInfo,
            actionDescription: "Window Resize",
            notes: "\(Int(size.width))×\(Int(size.height))",
            baseMeta: [
                "new_width": .double(Double(size.width)),
                "new_height": .double(Double(size.height)),
                "execution_time": .double(executionTime),
            ])
    }

    func handleSetBounds(
        service: any WindowManagementServiceProtocol,
        target: WindowActionTarget,
        appName: String?,
        bounds: CGRect,
        startTime: Date) async throws -> ToolResponse
    {
        let windows = try await service.listWindows(target: target.target)
        guard let windowInfo = windows.first else {
            return ToolResponse.error("No matching window found to set bounds")
        }
        guard let mutationIdentity = windowInfo.mutationIdentity else {
            throw PeekabooError.commandFailed(
                "Window \(windowInfo.windowID) did not include a process-generation identity")
        }
        try self.validateWindowOwner(mutationIdentity, expected: target.expectedOwnerIdentity)

        try await service.setWindowBounds(
            target: .windowId(windowInfo.windowID),
            expectedIdentity: mutationIdentity,
            bounds: bounds)

        let executionTime = Date().timeIntervalSince(startTime)
        let detail = "Set bounds for window '\(windowInfo.title)' to (\(Int(bounds.origin.x)), "
            + "\(Int(bounds.origin.y)), \(Int(bounds.width)) × \(Int(bounds.height)))"
        let message = self.successMessage(action: detail, duration: executionTime)
        return self.windowResponse(
            message: message,
            appName: appName,
            windowInfo: windowInfo,
            actionDescription: "Window Set Bounds",
            coordinates: ToolEventSummary.Coordinates(
                x: Double(bounds.origin.x),
                y: Double(bounds.origin.y)),
            notes: "\(Int(bounds.width))×\(Int(bounds.height))",
            baseMeta: [
                "new_x": .double(Double(bounds.origin.x)),
                "new_y": .double(Double(bounds.origin.y)),
                "new_width": .double(Double(bounds.width)),
                "new_height": .double(Double(bounds.height)),
                "execution_time": .double(executionTime),
            ])
    }

    func handleFocus(
        service: any WindowManagementServiceProtocol,
        target: WindowActionTarget,
        appName: String?,
        startTime: Date) async throws -> ToolResponse
    {
        let windows = try await service.listWindows(target: target.target)
        guard let windowInfo = windows.first else {
            return ToolResponse.error("No matching window found to focus")
        }

        if let identity = windowInfo.mutationIdentity {
            try self.validateWindowOwner(identity, expected: target.expectedOwnerIdentity)
        } else if target.expectedOwnerIdentity != nil {
            throw PeekabooError.commandFailed(
                "Window \(windowInfo.windowID) did not include a process-generation identity")
        }
        try await service.focusWindow(target: .windowId(windowInfo.windowID))

        let executionTime = Date().timeIntervalSince(startTime)
        let message = self.successMessage(action: "Focused window '\(windowInfo.title)'", duration: executionTime)
        return self.windowResponse(
            message: message,
            appName: appName,
            windowInfo: windowInfo,
            actionDescription: "Window Focus",
            baseMeta: ["execution_time": .double(executionTime)])
    }

    func successMessage(action: String, duration: TimeInterval) -> String {
        "\(AgentDisplayTokens.Status.success) \(action) in \(String(format: "%.2f", duration))s"
    }

    private func validateWindowOwner(
        _ identity: WindowMutationIdentity,
        expected: ApplicationProcessIdentity?) throws
    {
        guard let expected else { return }
        guard identity.ownerProcessIdentifier == expected.processIdentifier,
              identity.ownerProcessStartIdentity == expected.processStartIdentity
        else {
            throw PeekabooError.windowNotFound(
                criteria: "Window \(identity.windowID) is not owned by the selected application process receipt")
        }
    }

    func windowResponse(
        message: String,
        appName: String?,
        windowInfo: ServiceWindowInfo,
        actionDescription: String,
        coordinates: ToolEventSummary.Coordinates? = nil,
        notes: String? = nil,
        baseMeta: [String: Value]) -> ToolResponse
    {
        var meta = baseMeta
        meta["window_title"] = .string(windowInfo.title)
        meta["window_id"] = .double(Double(windowInfo.windowID))

        let summary = ToolEventSummary(
            targetApp: appName,
            windowTitle: windowInfo.title,
            actionDescription: actionDescription,
            coordinates: coordinates,
            notes: notes)
        return ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: ToolEventSummary.merge(summary: summary, into: .object(meta)))
    }
}
