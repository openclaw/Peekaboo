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

    func executeTypeCommand(
        _ step: ScriptStep,
        snapshotId: String?,
        backgroundKeyboardDestinationProof: BackgroundKeyboardDestinationProof?) async throws -> StepExecutionResult
    {
        // Extract type parameters - should already be normalized
        guard case let .type(typeParams) = step.params else {
            throw PeekabooError.invalidInput(field: "params", reason: "Invalid parameters for type command")
        }

        let context = try await self.resolveInteractionContext(
            .init(typeParams),
            inheritedSnapshot: snapshotId,
            backgroundKeyboardDestinationProof: backgroundKeyboardDestinationProof)
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
        var expectedFocusedElement = context.expectedFocusedElement
        if let field = typeParams.field {
            try await self.performClick(target: .query(field), clickType: .single, context: context)
            if context.requiresFocusedElementProof {
                guard let processID = context.processId,
                      let windowID = context.windowId,
                      let snapshotID = context.snapshotId,
                      let focused = await self.focusedDestinationIdentity(
                          after: .query(field),
                          snapshotID: snapshotID,
                          processID: processID,
                          windowID: windowID)
                else {
                    throw PeekabooError.invalidInput(
                        field: "target",
                        reason: "The background field click did not prove that its destination received focus")
                }
                expectedFocusedElement = focused
            }
        }
        if context.requiresFocusedElementProof {
            _ = try await self.performExactWindowTypeActions(
                actions,
                context: context,
                expectedFocusedElement: expectedFocusedElement)
        } else {
            _ = try await self.performTypeActions(actions, context: context)
        }

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

    func executeHotkeyCommand(
        _ step: ScriptStep,
        snapshotId: String?,
        backgroundKeyboardDestinationProof: BackgroundKeyboardDestinationProof?) async throws -> StepExecutionResult
    {
        // Extract hotkey parameters - should already be normalized
        guard case let .hotkey(hotkeyParams) = step.params else {
            throw PeekabooError.invalidInput(field: "params", reason: "Invalid parameters for hotkey command")
        }
        let context = try await self.resolveInteractionContext(
            .init(hotkeyParams),
            inheritedSnapshot: snapshotId,
            backgroundKeyboardDestinationProof: backgroundKeyboardDestinationProof)

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
        if context.requiresFocusedElementProof {
            try await self.performExactWindowHotkey(keyCombo, context: context)
        } else {
            try await self.performHotkey(keyCombo, context: context)
        }

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
        let windowBounds: CGRect?
        let windowIdentity: WindowMutationIdentity?
        let expectedFocusedElement: FocusedElementIdentity?
        let app: String?
        let foreground: Bool
        let requiresFocusedElementProof: Bool

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
        let hasFieldTarget: Bool
        let requiresSnapshotContext: Bool

        init(_ params: ProcessCommandParameters.ClickParameters) {
            self.app = params.app
            self.pid = params.pid
            self.windowId = params.windowId
            self.snapshot = params.snapshot
            self.foreground = params.foreground
            self.command = "click"
            self.hasFieldTarget = false
            self.requiresSnapshotContext = params.windowId != nil
        }

        init(_ params: ProcessCommandParameters.TypeParameters) {
            self.app = params.app
            self.pid = params.pid
            self.windowId = params.windowId
            self.snapshot = params.snapshot
            self.foreground = params.foreground
            self.command = "type"
            self.hasFieldTarget = params.field?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            self.requiresSnapshotContext = params.windowId != nil || self.hasFieldTarget
        }

        init(_ params: ProcessCommandParameters.ScrollParameters) {
            self.app = params.app
            self.pid = params.pid
            self.windowId = params.windowId
            self.snapshot = params.snapshot
            self.foreground = params.foreground
            self.command = "scroll"
            self.hasFieldTarget = false
            self.requiresSnapshotContext = params.windowId != nil ||
                params.target?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }

        init(_ params: ProcessCommandParameters.HotkeyParameters) {
            self.app = params.app
            self.pid = params.pid
            self.windowId = params.windowId
            self.snapshot = params.snapshot
            self.foreground = params.foreground
            self.command = "hotkey"
            self.hasFieldTarget = false
            self.requiresSnapshotContext = params.windowId != nil
        }
    }

    private func resolveInteractionContext(
        _ request: InteractionTargetRequest,
        inheritedSnapshot: String?,
        backgroundKeyboardDestinationProof: BackgroundKeyboardDestinationProof? = nil) async throws
        -> InteractionContext
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
        let effectiveSnapshot = snapshot ??
            (hasExplicitTarget && !request.requiresSnapshotContext ? nil : inheritedSnapshot)
        var snapshotPID: pid_t?
        var snapshotWindowID: Int?
        var snapshotWindowBounds: CGRect?
        var snapshotWindowIdentity: WindowMutationIdentity?
        if let effectiveSnapshot {
            if let automationSnapshot = try await self.snapshotManager.getUIAutomationSnapshot(
                snapshotId: effectiveSnapshot)
            {
                snapshotPID = automationSnapshot.applicationProcessId.map { pid_t($0) }
                snapshotWindowID = automationSnapshot.windowID.map(Int.init)
                snapshotWindowBounds = automationSnapshot.windowBounds
                snapshotWindowIdentity = automationSnapshot.windowMutationIdentity
            } else if let detection = try await self.snapshotManager.getDetectionResult(snapshotId: effectiveSnapshot) {
                snapshotPID = detection.metadata.windowContext?.applicationProcessId.map { pid_t($0) }
                snapshotWindowID = detection.metadata.windowContext?.windowID
                snapshotWindowBounds = detection.metadata.windowContext?.windowBounds
                snapshotWindowIdentity = detection.metadata.windowContext?.windowMutationIdentity
            } else {
                throw PeekabooError.snapshotNotFound(effectiveSnapshot)
            }
        }
        if let windowId, let snapshotWindowID, windowId != snapshotWindowID {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: "\(command) windowId \(windowId) does not match snapshot window \(snapshotWindowID)")
        }

        let useForeground = foreground ?? false
        if !useForeground,
           command == "type" || command == "hotkey",
           windowId != nil,
           effectiveSnapshot == nil
        {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: "Background \(command) cannot safely target a specific window without a focused-element " +
                    "proof. Use a snapshot-scoped field or exact-window click, target app/pid without a window " +
                    "selector, or set foreground: true")
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

        let resolvedPID = candidates.first
        if !useForeground, resolvedPID == nil {
            throw Self.explicitForegroundRequired(
                command: "targetless \(command)",
                reason: "background delivery needs app, pid, windowId, or a process-scoped snapshot")
        }

        let resolvedWindowID = windowId ?? snapshotWindowID
        let windowIdentity: WindowMutationIdentity? = if !useForeground,
                                                         let resolvedWindowID,
                                                         let resolvedPID,
                                                         let windowBounds = snapshotWindowBounds,
                                                         let identity = snapshotWindowIdentity,
                                                         identity.windowID == resolvedWindowID,
                                                         identity.ownerProcessIdentifier == resolvedPID,
                                                         let cgWindowID = CGWindowID(exactly: resolvedWindowID),
                                                         let currentWindow = self
                                                             .systemWindowIdentityProvider(cgWindowID),
                                                             currentWindow.ownerProcessIdentifier == resolvedPID,
                                                             currentWindow.bounds == windowBounds,
                                                             self.windowMutationIdentityProvider(cgWindowID) == identity
        {
            identity
        } else {
            nil
        }
        if !useForeground, resolvedWindowID != nil, windowIdentity == nil {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: "Exact-window identity changed; capture a fresh snapshot before background input")
        }
        let windowScopedKeyboard = !useForeground &&
            (command == "type" || command == "hotkey") &&
            resolvedWindowID != nil
        let proofMatches = if let proof = backgroundKeyboardDestinationProof,
                              let effectiveSnapshot,
                              let resolvedPID,
                              let resolvedWindowID,
                              let windowIdentity
        {
            proof.snapshotID == effectiveSnapshot &&
                proof.processID == resolvedPID &&
                proof.windowID == resolvedWindowID &&
                proof.windowIdentity == windowIdentity
        } else {
            false
        }
        let fieldCanProveDestination = command == "type" &&
            request.hasFieldTarget &&
            effectiveSnapshot != nil &&
            snapshotWindowBounds != nil
        if windowScopedKeyboard, !proofMatches, !fieldCanProveDestination {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: "Background \(command) cannot safely target a specific window without a focused-element " +
                    "proof. Use a snapshot-scoped type field, immediately follow a successful exact-window " +
                    "click, target app/pid without a window selector, or set foreground: true")
        }

        return InteractionContext(
            snapshotId: effectiveSnapshot,
            processId: resolvedPID,
            windowId: resolvedWindowID,
            windowBounds: snapshotWindowBounds,
            windowIdentity: windowIdentity,
            expectedFocusedElement: proofMatches ? backgroundKeyboardDestinationProof?.focusedElement : nil,
            app: app,
            foreground: useForeground,
            requiresFocusedElementProof: windowScopedKeyboard)
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

    func backgroundKeyboardDestinationProof(
        after step: ScriptStep,
        result: StepExecutionResult) async -> BackgroundKeyboardDestinationProof?
    {
        guard let normalizedStep = try? self.normalizeStepParameters(step) else {
            return nil
        }
        guard normalizedStep.command.lowercased() == "click",
              case let .click(params) = normalizedStep.params,
              params.foreground != true,
              let snapshotID = result.snapshotId
        else {
            return nil
        }

        let processID: pid_t?
        let windowID: Int?
        let windowBounds: CGRect?
        let capturedWindowIdentity: WindowMutationIdentity?
        if let snapshot = try? await self.snapshotManager.getUIAutomationSnapshot(snapshotId: snapshotID) {
            processID = snapshot.applicationProcessId.map { pid_t($0) }
            windowID = snapshot.windowID.map(Int.init)
            windowBounds = snapshot.windowBounds
            capturedWindowIdentity = snapshot.windowMutationIdentity
        } else if let detection = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotID) {
            processID = detection.metadata.windowContext?.applicationProcessId.map { pid_t($0) }
            windowID = detection.metadata.windowContext?.windowID
            windowBounds = detection.metadata.windowContext?.windowBounds
            capturedWindowIdentity = detection.metadata.windowContext?.windowMutationIdentity
        } else {
            return nil
        }

        guard let processID,
              let windowID,
              let windowBounds,
              let capturedWindowIdentity,
              capturedWindowIdentity.windowID == windowID,
              capturedWindowIdentity.ownerProcessIdentifier == processID,
              let cgWindowID = CGWindowID(exactly: windowID),
              let currentWindow = self.systemWindowIdentityProvider(cgWindowID),
              currentWindow.ownerProcessIdentifier == processID,
              currentWindow.bounds == windowBounds,
              self.windowMutationIdentityProvider(cgWindowID) == capturedWindowIdentity
        else {
            return nil
        }

        let clickTarget: ClickTarget
        if let label = params.label {
            clickTarget = .query(label)
        } else if let x = params.x, let y = params.y {
            clickTarget = .coordinates(CGPoint(x: x, y: y))
        } else {
            return nil
        }
        guard let focusedElement = await self.focusedDestinationIdentity(
            after: clickTarget,
            snapshotID: snapshotID,
            processID: processID,
            windowID: windowID)
        else {
            return nil
        }

        // A successful exact-window click authorizes only the immediately following keyboard step.
        // The exact keyboard operation remains the proof boundary: it atomically revalidates the
        // focused element's PID, CGWindowID, and bounds before dispatching any input.
        return BackgroundKeyboardDestinationProof(
            snapshotID: snapshotID,
            processID: processID,
            windowID: windowID,
            windowIdentity: capturedWindowIdentity,
            focusedElement: focusedElement)
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

        if context.windowId != nil {
            guard let exact = targeted as? any ExactWindowTargetedClickServiceProtocol,
                  exact.supportsExactWindowTargetedClicks,
                  let windowIdentity = context.windowIdentity,
                  let windowBounds = context.windowBounds
            else {
                throw PeekabooError.serviceUnavailable(
                    "Background click for windowId requires exact-window targeting support")
            }
            try await exact.click(
                target: target,
                clickType: clickType,
                snapshotId: context.snapshotId,
                expectedWindowIdentity: windowIdentity,
                expectedWindowBounds: windowBounds)
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

    private func performExactWindowTypeActions(
        _ actions: [TypeAction],
        context: InteractionContext,
        expectedFocusedElement: FocusedElementIdentity?) async throws -> TypeResult
    {
        guard context.processId != nil,
              context.windowId != nil,
              let windowBounds = context.windowBounds,
              let windowIdentity = context.windowIdentity,
              let expectedFocusedElement,
              let atomic = self.uiAutomationService as? any ExactWindowTargetedKeyboardServiceProtocol,
              atomic.supportsExactWindowTargetedKeyboard
        else {
            throw PeekabooError.serviceUnavailable(
                "Exact-window background typing requires atomic focus validation and dispatch")
        }
        return try await atomic.typeActions(
            actions,
            cadence: .fixed(milliseconds: 50),
            snapshotId: context.snapshotId,
            target: ExactWindowKeyboardTarget(
                windowIdentity: windowIdentity,
                windowBounds: windowBounds,
                focusedElement: expectedFocusedElement))
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

    private func performExactWindowHotkey(_ keys: String, context: InteractionContext) async throws {
        guard context.processId != nil,
              context.windowId != nil,
              let windowBounds = context.windowBounds,
              let windowIdentity = context.windowIdentity,
              let expectedFocusedElement = context.expectedFocusedElement,
              let atomic = self.uiAutomationService as? any ExactWindowTargetedKeyboardServiceProtocol,
              atomic.supportsExactWindowTargetedKeyboard
        else {
            throw PeekabooError.serviceUnavailable(
                "Exact-window background hotkeys require atomic focus validation and dispatch")
        }
        try await atomic.hotkey(
            keys: keys,
            holdDuration: 0,
            target: ExactWindowKeyboardTarget(
                windowIdentity: windowIdentity,
                windowBounds: windowBounds,
                focusedElement: expectedFocusedElement))
    }

    private func focusedDestinationIdentity(
        after target: ClickTarget,
        snapshotID: String,
        processID: pid_t,
        windowID: Int) async -> FocusedElementIdentity?
    {
        guard let focusedService = self.uiAutomationService as? any TargetedFocusedElementServiceProtocol,
              let focused = await focusedService.getFocusedElement(targetProcessIdentifier: processID),
              let identity = FocusedElementIdentity(focused),
              identity.processIdentifier == processID,
              identity.windowID == windowID
        else { return nil }

        let expectedElement: DetectedElement?
        switch target {
        case let .coordinates(point):
            return focused.frame.contains(point) ? identity : nil
        case let .elementId(elementID):
            let detection = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotID)
            expectedElement = detection?.elements.findById(elementID)
        case let .query(query):
            let detection = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotID)
            expectedElement = detection.flatMap { ClickService.resolveTargetElement(query: query, in: $0) }
        }

        guard let expectedElement else { return nil }
        if let expectedIdentifier = expectedElement.attributes["identifier"],
           !expectedIdentifier.isEmpty,
           let focusedIdentifier = identity.identifier,
           focusedIdentifier != expectedIdentifier
        {
            return nil
        }
        let framesMatch = expectedElement.bounds == identity.frame ||
            expectedElement.bounds.contains(CGPoint(x: identity.frame.midX, y: identity.frame.midY)) ||
            identity.frame.contains(CGPoint(x: expectedElement.bounds.midX, y: expectedElement.bounds.midY))
        return framesMatch ? identity : nil
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
