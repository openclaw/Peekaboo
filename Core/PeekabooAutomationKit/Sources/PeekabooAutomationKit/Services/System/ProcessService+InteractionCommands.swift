import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
extension ProcessService {
    func executeClickCommand(_ step: ScriptStep, snapshotId: String?) async throws -> StepExecutionResult {
        guard case let .click(clickParams) = step.params else {
            throw PeekabooError.invalidInput(field: "params", reason: "Invalid parameters for click command")
        }
        let context = try await self.resolveInteractionContext(
            .init(clickParams),
            inheritedSnapshot: snapshotId)

        // Determine click type
        let rightClick = clickParams.button == "right"
        let doubleClick = clickParams.button == "double"

        // Determine click target
        let clickTarget: ClickTarget
        if let x = clickParams.x, let y = clickParams.y {
            clickTarget = .coordinates(CGPoint(x: x, y: y))
        } else if let label = clickParams.label {
            clickTarget = .query(label)
        } else {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: "Either coordinates (x,y) or label is required for click command")
        }

        let clickType: ClickType = doubleClick ? .double : (rightClick ? .right : .single)
        try await self.prepareForegroundIfNeeded(context)
        try await self.performClick(
            target: clickTarget,
            clickType: clickType,
            context: context)

        return StepExecutionResult(
            output: self.interactionOutput(message: "Clicked successfully", context: context),
            snapshotId: context.snapshotId)
    }

    func executeTypeCommand(_ step: ScriptStep, snapshotId: String?) async throws -> StepExecutionResult {
        // Extract type parameters - should already be normalized
        guard case let .type(typeParams) = step.params else {
            throw PeekabooError.invalidInput(field: "params", reason: "Invalid parameters for type command")
        }

        let context = try await self.resolveInteractionContext(
            .init(typeParams),
            inheritedSnapshot: snapshotId)
        let clearFirst = typeParams.clearFirst ?? false
        let pressEnter = typeParams.pressEnter ?? false
        var actions: [TypeAction] = []
        if clearFirst {
            actions.append(.clear)
        }
        if !typeParams.text.isEmpty {
            actions.append(.text(typeParams.text))
        }
        if pressEnter {
            actions.append(.key(.return))
        }

        try await self.prepareForegroundIfNeeded(context)
        if let field = typeParams.field {
            try await self.performClick(target: .query(field), clickType: .single, context: context)
        }
        _ = try await self.performTypeActions(actions, context: context)

        return StepExecutionResult(
            output: .data([
                "typed": .success(typeParams.text),
                "cleared": .success(String(clearFirst)),
                "enter_pressed": .success(String(pressEnter)),
                "delivery": .success(context.deliveryName),
                "target_pid": .success(context.processId.map(String.init) ?? ""),
            ]),
            snapshotId: context.snapshotId)
    }

    func executeScrollCommand(_ step: ScriptStep, snapshotId: String?) async throws -> StepExecutionResult {
        // Extract scroll parameters - should already be normalized
        guard case let .scroll(scrollParams) = step.params else {
            throw PeekabooError.invalidInput(field: "params", reason: "Invalid parameters for scroll command")
        }
        let context = try await self.resolveInteractionContext(
            .init(scrollParams),
            inheritedSnapshot: snapshotId)

        let amount = scrollParams.amount ?? 5
        let smooth = false // Not in ScrollParameters, using default
        let delay = 0

        let scrollDirection: PeekabooFoundation.ScrollDirection = switch scrollParams.direction.lowercased() {
        case "up": .up
        case "down": .down
        case "left": .left
        case "right": .right
        default: .down
        }

        if !context.foreground {
            guard scrollParams.target?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw Self.explicitForegroundRequired(
                    command: "targetless scroll",
                    reason: "background scrolling requires an element target")
            }
            guard context.snapshotId != nil else {
                throw PeekabooError.invalidInput(
                    field: "snapshot",
                    reason: "Background scroll requires a snapshot so its element target " +
                        "stays scoped to one app/window")
            }
        }
        try await self.prepareForegroundIfNeeded(context)
        let request = ScrollRequest(
            direction: scrollDirection,
            amount: amount,
            target: scrollParams.target,
            smooth: smooth,
            delay: delay,
            snapshotId: context.snapshotId,
            foreground: context.foreground)
        try await self.uiAutomationService.scroll(request)

        return StepExecutionResult(
            output: .data([
                "scrolled": .success(scrollParams.direction),
                "amount": .success(String(amount)),
                "smooth": .success(String(smooth)),
                "delivery": .success(context.deliveryName),
                "target_pid": .success(context.processId.map(String.init) ?? ""),
            ]),
            snapshotId: context.snapshotId)
    }

    func executeSwipeCommand(_ step: ScriptStep, snapshotId: String?) async throws -> StepExecutionResult {
        guard case let .swipe(swipeParams) = step.params else {
            throw PeekabooError.invalidInput(field: "params", reason: "Invalid parameters for swipe command")
        }
        guard swipeParams.foreground == true else {
            throw Self.explicitForegroundRequired(
                command: "swipe",
                reason: "swipe moves the physical pointer")
        }

        let distance = swipeParams.distance ?? 100.0
        let duration = swipeParams.duration ?? 0.5
        let swipeDirection = self.swipeDirection(from: swipeParams.direction)
        let points = self.swipeEndpoints(
            params: swipeParams,
            direction: swipeDirection,
            distance: distance)

        try await self.uiAutomationService.swipe(
            from: points.start,
            to: points.end,
            duration: Int(duration * 1000),
            steps: 30,
            profile: .linear)

        return StepExecutionResult(
            output: .data([
                "swiped": .success(swipeParams.direction),
                "distance": .success(String(distance)),
                "duration": .success(String(duration)),
            ]),
            snapshotId: snapshotId)
    }

    func executeDragCommand(_ step: ScriptStep, snapshotId: String?) async throws -> StepExecutionResult {
        // Extract drag parameters - should already be normalized
        guard case let .drag(dragParams) = step.params else {
            throw PeekabooError.invalidInput(field: "params", reason: "Invalid parameters for drag command")
        }
        guard dragParams.foreground == true else {
            throw Self.explicitForegroundRequired(
                command: "drag",
                reason: "drag moves the physical pointer")
        }

        let duration = dragParams.duration ?? 1.0
        let modifiers = self.parseModifiers(from: dragParams.modifiers)

        let modifierString = modifiers.map(\.rawValue).joined(separator: ",")

        try await self.uiAutomationService.drag(
            DragOperationRequest(
                from: CGPoint(x: dragParams.fromX, y: dragParams.fromY),
                to: CGPoint(x: dragParams.toX, y: dragParams.toY),
                duration: Int(duration * 1000), // Convert to milliseconds
                steps: 30,
                modifiers: modifierString.isEmpty ? nil : modifierString,
                profile: .linear))

        return StepExecutionResult(
            output: .data([
                "dragged": .success("true"),
                "from_x": .success(String(dragParams.fromX)),
                "from_y": .success(String(dragParams.fromY)),
                "to_x": .success(String(dragParams.toX)),
                "to_y": .success(String(dragParams.toY)),
            ]),
            snapshotId: snapshotId)
    }

    func executeHotkeyCommand(_ step: ScriptStep, snapshotId: String?) async throws -> StepExecutionResult {
        // Extract hotkey parameters - should already be normalized
        guard case let .hotkey(hotkeyParams) = step.params else {
            throw PeekabooError.invalidInput(field: "params", reason: "Invalid parameters for hotkey command")
        }
        let context = try await self.resolveInteractionContext(
            .init(hotkeyParams),
            inheritedSnapshot: snapshotId)

        let modifiers = hotkeyParams.modifiers.compactMap { mod -> ModifierKey? in
            switch mod.lowercased() {
            case "command", "cmd": return .command
            case "shift": return .shift
            case "control", "ctrl": return .control
            case "option", "alt": return .option
            case "function", "fn": return .function
            default: return nil
            }
        }

        let keyCombo = modifiers.map(\.rawValue).joined(separator: ",") + (modifiers.isEmpty ? "" : ",") + hotkeyParams
            .key

        try await self.prepareForegroundIfNeeded(context)
        try await self.performHotkey(keyCombo, context: context)

        return StepExecutionResult(
            output: .data([
                "hotkey": .success(hotkeyParams.key),
                "modifiers": .success(modifiers.map(\.rawValue).joined(separator: ",")),
                "delivery": .success(context.deliveryName),
                "target_pid": .success(context.processId.map(String.init) ?? ""),
            ]),
            snapshotId: context.snapshotId)
    }

    func executeSleepCommand(_ step: ScriptStep) async throws -> StepExecutionResult {
        // Extract sleep parameters - should already be normalized
        guard case let .sleep(sleepParams) = step.params else {
            throw PeekabooError.invalidInput(field: "params", reason: "Invalid parameters for sleep command")
        }

        try await Task.sleep(nanoseconds: UInt64(sleepParams.duration * 1_000_000_000))

        return StepExecutionResult(
            output: .success("Slept for \(sleepParams.duration) seconds"),
            snapshotId: nil)
    }

    private struct InteractionContext {
        let snapshotId: String?
        let processId: pid_t?
        let windowId: Int?
        let app: String?
        let foreground: Bool

        var deliveryName: String {
            self.foreground ? "foreground" : "background"
        }
    }

    private struct InteractionTargetRequest {
        let app: String?
        let pid: Int32?
        let windowId: Int?
        let snapshot: String?
        let foreground: Bool?
        let command: String

        init(_ params: ProcessCommandParameters.ClickParameters) {
            self.app = params.app
            self.pid = params.pid
            self.windowId = params.windowId
            self.snapshot = params.snapshot
            self.foreground = params.foreground
            self.command = "click"
        }

        init(_ params: ProcessCommandParameters.TypeParameters) {
            self.app = params.app
            self.pid = params.pid
            self.windowId = params.windowId
            self.snapshot = params.snapshot
            self.foreground = params.foreground
            self.command = "type"
        }

        init(_ params: ProcessCommandParameters.ScrollParameters) {
            self.app = params.app
            self.pid = params.pid
            self.windowId = params.windowId
            self.snapshot = params.snapshot
            self.foreground = params.foreground
            self.command = "scroll"
        }

        init(_ params: ProcessCommandParameters.HotkeyParameters) {
            self.app = params.app
            self.pid = params.pid
            self.windowId = params.windowId
            self.snapshot = params.snapshot
            self.foreground = params.foreground
            self.command = "hotkey"
        }
    }

    private func resolveInteractionContext(
        _ request: InteractionTargetRequest,
        inheritedSnapshot: String?) async throws -> InteractionContext
    {
        let app = request.app
        let pid = request.pid
        let windowId = request.windowId
        let snapshot = request.snapshot
        let foreground = request.foreground
        let command = request.command
        if app != nil, pid != nil {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: "\(command) accepts one process target; use app or pid, not both")
        }
        if let pid, pid <= 0 {
            throw PeekabooError.invalidInput(field: "pid", reason: "pid must be greater than 0")
        }
        if let windowId, windowId <= 0 {
            throw PeekabooError.invalidInput(field: "windowId", reason: "windowId must be greater than 0")
        }

        let hasExplicitTarget = app != nil || pid != nil || windowId != nil
        let effectiveSnapshot = snapshot ?? (hasExplicitTarget ? nil : inheritedSnapshot)
        var snapshotPID: pid_t?
        var snapshotWindowID: Int?
        if let effectiveSnapshot {
            if let automationSnapshot = try await self.snapshotManager.getUIAutomationSnapshot(
                snapshotId: effectiveSnapshot)
            {
                snapshotPID = automationSnapshot.applicationProcessId.map { pid_t($0) }
                snapshotWindowID = automationSnapshot.windowID.map(Int.init)
            } else if let detection = try await self.snapshotManager.getDetectionResult(snapshotId: effectiveSnapshot) {
                snapshotPID = detection.metadata.windowContext?.applicationProcessId.map { pid_t($0) }
                snapshotWindowID = detection.metadata.windowContext?.windowID
            } else {
                throw PeekabooError.snapshotNotFound(effectiveSnapshot)
            }
        }

        let windowPID = windowId.flatMap(Self.processIdentifierForWindow)
        if let windowId, windowPID == nil {
            throw PeekabooError.windowNotFound(criteria: "window id \(windowId)")
        }
        let appPID: pid_t? = if let app {
            try await pid_t(self.applicationService.findApplication(identifier: app).processIdentifier)
        } else {
            nil
        }
        let explicitPID: pid_t? = pid.map { pid_t($0) }
        let candidates = [explicitPID, appPID, windowPID, snapshotPID].compactMap(\.self)
        if let first = candidates.first, candidates.dropFirst().contains(where: { $0 != first }) {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: "\(command) target fields resolve to different processes")
        }

        let useForeground = foreground ?? false
        let resolvedPID = candidates.first
        if !useForeground, resolvedPID == nil {
            throw Self.explicitForegroundRequired(
                command: "targetless \(command)",
                reason: "background delivery needs app, pid, windowId, or a process-scoped snapshot")
        }

        return InteractionContext(
            snapshotId: effectiveSnapshot,
            processId: resolvedPID,
            windowId: windowId ?? snapshotWindowID,
            app: app,
            foreground: useForeground)
    }

    private func prepareForegroundIfNeeded(_ context: InteractionContext) async throws {
        guard context.foreground else { return }
        if let windowId = context.windowId {
            try await self.windowManagementService.focusWindow(target: .windowId(windowId))
        } else if let app = context.app {
            try await self.applicationService.activateApplication(identifier: app)
        } else if let processId = context.processId {
            try await self.applicationService.activateApplication(identifier: "PID:\(processId)")
        }
    }

    private func performClick(
        target: ClickTarget,
        clickType: ClickType,
        context: InteractionContext) async throws
    {
        if context.foreground {
            try await self.uiAutomationService.click(
                target: target,
                clickType: clickType,
                snapshotId: context.snapshotId)
            return
        }

        guard let processId = context.processId else {
            throw Self.explicitForegroundRequired(command: "click", reason: "no background target was resolved")
        }
        guard let targeted = self.uiAutomationService as? any TargetedClickServiceProtocol,
              targeted.supportsTargetedClicks
        else {
            let reason = (self.uiAutomationService as? any TargetedClickServiceProtocol)?
                .targetedClickUnavailableReason ?? "the selected runtime does not support targeted clicks"
            throw PeekabooError.serviceUnavailable("Background click unavailable: \(reason)")
        }

        if let windowId = context.windowId {
            guard let exact = targeted as? any ExactWindowTargetedClickServiceProtocol,
                  exact.supportsExactWindowTargetedClicks
            else {
                throw PeekabooError.serviceUnavailable(
                    "Background click for windowId requires exact-window targeting support")
            }
            try await exact.click(
                target: target,
                clickType: clickType,
                snapshotId: context.snapshotId,
                targetProcessIdentifier: processId,
                targetWindowID: windowId)
        } else {
            try await targeted.click(
                target: target,
                clickType: clickType,
                snapshotId: context.snapshotId,
                targetProcessIdentifier: processId)
        }
    }

    private func performTypeActions(
        _ actions: [TypeAction],
        context: InteractionContext) async throws -> TypeResult
    {
        guard !actions.isEmpty else {
            throw PeekabooError.invalidInput(field: "text", reason: "type requires text or pressEnter")
        }
        if context.foreground {
            return try await self.uiAutomationService.typeActions(
                actions,
                cadence: .fixed(milliseconds: 50),
                snapshotId: context.snapshotId)
        }

        guard let processId = context.processId else {
            throw Self.explicitForegroundRequired(command: "type", reason: "no background target was resolved")
        }
        guard let targeted = self.uiAutomationService as? any TargetedTypeServiceProtocol,
              targeted.supportsTargetedTypeActions
        else {
            let reason = (self.uiAutomationService as? any TargetedTypeServiceProtocol)?
                .targetedTypeUnavailableReason ?? "the selected runtime does not support targeted typing"
            throw PeekabooError.serviceUnavailable("Background type unavailable: \(reason)")
        }
        return try await targeted.typeActions(
            actions,
            cadence: .fixed(milliseconds: 50),
            snapshotId: context.snapshotId,
            targetProcessIdentifier: processId)
    }

    private func performHotkey(_ keys: String, context: InteractionContext) async throws {
        if context.foreground {
            try await self.uiAutomationService.hotkey(keys: keys, holdDuration: 0)
            return
        }

        guard let processId = context.processId else {
            throw Self.explicitForegroundRequired(command: "hotkey", reason: "no background target was resolved")
        }
        guard let targeted = self.uiAutomationService as? any TargetedHotkeyServiceProtocol,
              targeted.supportsTargetedHotkeys
        else {
            let reason = (self.uiAutomationService as? any TargetedHotkeyServiceProtocol)?
                .targetedHotkeyUnavailableReason ?? "the selected runtime does not support targeted hotkeys"
            throw PeekabooError.serviceUnavailable("Background hotkey unavailable: \(reason)")
        }
        try await targeted.hotkey(keys: keys, holdDuration: 0, targetProcessIdentifier: processId)
    }

    private func interactionOutput(message: String, context: InteractionContext) -> ProcessCommandOutput {
        .data([
            "message": .success(message),
            "delivery": .success(context.deliveryName),
            "target_pid": .success(context.processId.map(String.init) ?? ""),
        ])
    }

    private nonisolated static func explicitForegroundRequired(command: String, reason: String) -> PeekabooError {
        PeekabooError.invalidInput(
            field: "foreground",
            reason: "\(command) requires `foreground: true`: \(reason)")
    }

    private nonisolated static func processIdentifierForWindow(_ windowId: Int) -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else {
            return nil
        }
        return windows.first { window in
            (window[kCGWindowNumber as String] as? NSNumber)?.intValue == windowId
        }.flatMap { window in
            (window[kCGWindowOwnerPID as String] as? NSNumber).map { pid_t($0.intValue) }
        }
    }

    private func parseModifiers(from modifierStrings: [String]?) -> [ModifierKey] {
        guard let modifierStrings else { return [] }

        var modifiers: [ModifierKey] = []

        for modifier in modifierStrings {
            switch modifier.lowercased() {
            case "cmd", "command":
                modifiers.append(.command)
            case "shift":
                modifiers.append(.shift)
            case "option", "alt":
                modifiers.append(.option)
            case "control", "ctrl":
                modifiers.append(.control)
            case "fn", "function":
                modifiers.append(.function)
            default:
                break
            }
        }

        return modifiers
    }

    private func swipeDirection(from rawValue: String) -> SwipeDirection {
        switch rawValue.lowercased() {
        case "up": .up
        case "down": .down
        case "left": .left
        case "right": .right
        default: .right
        }
    }

    private func swipeEndpoints(
        params: ProcessCommandParameters.SwipeParameters,
        direction: SwipeDirection,
        distance: Double) -> (start: CGPoint, end: CGPoint)
    {
        if let x = params.fromX, let y = params.fromY {
            let start = CGPoint(x: x, y: y)
            return (start, self.offsetPoint(start, direction: direction, distance: distance))
        }

        let screenBounds = self.screenService.primaryScreen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let center = CGPoint(x: screenBounds.midX, y: screenBounds.midY)
        let endPoint = self.offsetPoint(center, direction: direction, distance: distance)
        return (center, endPoint)
    }

    private func offsetPoint(_ point: CGPoint, direction: SwipeDirection, distance: Double) -> CGPoint {
        switch direction {
        case .up:
            CGPoint(x: point.x, y: point.y - distance)
        case .down:
            CGPoint(x: point.x, y: point.y + distance)
        case .left:
            CGPoint(x: point.x - distance, y: point.y)
        case .right:
            CGPoint(x: point.x + distance, y: point.y)
        }
    }
}
