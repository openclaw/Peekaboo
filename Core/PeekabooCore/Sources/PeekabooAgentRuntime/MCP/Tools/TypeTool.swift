import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

/// MCP tool for typing text
public struct TypeTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "TypeTool")
    private let context: MCPToolContext

    public let name = "type"

    public var description: String {
        let targeting = if self.context.executionPolicy == .backgroundOnly {
            """
            Default background-only MCP/Agent delivery requires an explicit fresh exact non-dialog snapshot receipt.
            An optional element ID must come from that snapshot. App/PID/window-only, implicit-latest, competing
            selector, targetless, and foreground forms are refused before dispatch.
            """
        } else {
            """
            Foreground-capable callers may use snapshot, element, app, PID, or exact-window targeting and set
            foreground=true when focused/global input is intentional.
            """
        }
        return """
        Types text into UI elements, a targeted app process, or one exact background window.
        Supports human typing (--wpm) or fixed-delay (--delay) pacing. Use `press` for key presses and chords.
        \(targeting)
        \(PeekabooMCPVersion.banner) using openai/gpt-5.6
        and anthropic/claude-opus-5
        """
    }

    public var inputSchema: Value {
        let backgroundOnly = self.context.executionPolicy == .backgroundOnly
        var properties: [String: Value] = [
            "text": SchemaBuilder.string(description: "The text to type."),
            "on": SchemaBuilder.string(
                description: backgroundOnly
                    ? "Optional element ID from the required explicit snapshot."
                    : "Optional element ID from a supplied or current snapshot."),
            "snapshot": SchemaBuilder.string(
                description: backgroundOnly
                    ? "Required fresh exact non-dialog snapshot ID from `see` or `inspect_ui`."
                    : "Optional snapshot ID from `see` or `inspect_ui`."),
            "delay": SchemaBuilder.integer(
                description: "Optional. Delay between keystrokes in milliseconds (linear profile). Default: 0.",
                default: 0),
            "profile": SchemaBuilder.string(
                description: "Optional. Typing profile: linear (default) or human."),
            "wpm": SchemaBuilder.integer(
                description: "Optional. Human typing speed (80-220 WPM). Overrides delay when set."),
            "clear": SchemaBuilder.boolean(
                description: "Optional. Clear the field before typing (Cmd+A, Delete).",
                default: false),
        ]
        if !backgroundOnly {
            properties.merge([
                "foreground": SchemaBuilder.boolean(
                    description: "Optional. Focus a supplied target or intentionally send global keyboard input.",
                    default: false),
                "app": SchemaBuilder.string(
                    description: "Optional foreground-capable app target; " +
                        "unavailable with background snapshot typing."),
                "pid": SchemaBuilder.integer(
                    description: "Optional foreground-capable process target; unavailable with background snapshots."),
                "window_id": SchemaBuilder.integer(
                    description: "Optional foreground-capable exact-window target; " +
                        "unavailable with background snapshots."),
                "window_title": SchemaBuilder
                    .string(description: "Optional. Exact window title substring; must resolve uniquely."),
                "window_index": SchemaBuilder
                    .integer(description: "Optional. Window index (0-based); requires app/pid."),
            ]) { _, new in new }
        }
        return SchemaBuilder.object(
            properties: properties,
            required: backgroundOnly ? ["snapshot"] : [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let mutationTracker = TypeMutationTracker()
        do {
            let request = try self.parseRequest(arguments: arguments)
            return try await self.performType(request: request, mutationTracker: mutationTracker)
        } catch let error as TypeToolValidationError {
            return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
                message: error.message,
                reason: error.refusalReason)
        } catch let error as MCPInteractionTargetError {
            return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
                message: error.localizedDescription,
                reason: error.refusalReason)
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: mutationTracker.snapshotId,
                additionalFields: mutationTracker.compatibilityFields)
        } catch let error as InputDeliveryIndeterminateError {
            var additionalFields = mutationTracker.targetFields
            additionalFields["characters_typed"] = mutationTracker.charactersTyped.map(Value.int) ?? .null
            return try await MCPDesktopActionFailureHandler.response(
                for: error.desktopActionFailure(delivery: mutationTracker.delivery),
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: mutationTracker.snapshotId,
                additionalFields: additionalFields)
        } catch {
            self.logger.error("Type execution failed: \(error)")
            return ToolResponse.error("Failed to type text: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func getSnapshot(id: String?) async -> UISnapshot? {
        await self.context.uiSnapshots.getSnapshot(id: id)
    }

    private func parseRequest(arguments: ToolArguments) throws -> TypeRequest {
        let wordsPerMinute = try arguments.validatedInt("wpm")
        let profile = try self.parseProfile(arguments.getString("profile"), wordsPerMinute: wordsPerMinute)
        let target = try MCPInteractionTarget(
            app: arguments.getString("app"),
            pid: arguments.validatedInt("pid"),
            windowTitle: arguments.getString("window_title"),
            windowIndex: arguments.validatedInt("window_index"),
            windowId: arguments.validatedInt("window_id"))

        let request = try TypeRequest(
            text: arguments.getString("text"),
            elementId: arguments.getString("on"),
            snapshotId: arguments.getString("snapshot"),
            delay: arguments.validatedInt("delay") ?? 0,
            profile: profile,
            wordsPerMinute: wordsPerMinute,
            clearField: arguments.getBool("clear") ?? false,
            foreground: arguments.getBool("foreground") ?? false,
            target: target)

        guard request.hasActions else {
            throw TypeToolValidationError("Must specify text to type or clear=true")
        }

        if let wpm = request.wordsPerMinute, !(80...220).contains(wpm) {
            throw TypeToolValidationError("wpm must be between 80 and 220")
        }

        if request.wordsPerMinute != nil, request.profile != .human {
            throw TypeToolValidationError("wpm is only supported with the human profile")
        }

        return request
    }

    private func parseProfile(_ raw: String?, wordsPerMinute: Int?) throws -> TypingProfile {
        guard let raw else { return wordsPerMinute == nil ? .linear : .human }
        guard let profile = TypingProfile(rawValue: raw.lowercased()) else {
            throw TypeToolValidationError("profile must be 'human' or 'linear'")
        }
        return profile
    }

    @MainActor
    private func performType(
        request: TypeRequest,
        mutationTracker: TypeMutationTracker) async throws -> ToolResponse
    {
        let automation = self.context.automation
        let startTime = Date()

        let targetContext = try await self.resolveTargetContext(for: request)
        let snapshotContext = try await self.resolveSnapshotContext(
            for: request,
            targetContext: targetContext)

        let plannedTarget = try await self.backgroundKeyboardTarget(
            request: request,
            snapshot: snapshotContext)
        let targetProcessIdentifier = plannedTarget?.processIdentifier.map(Int.init)
        let targetWindowID = plannedTarget?.exactWindow?.identity.windowID
        let actions = try self.buildActions(for: request)
        let effectiveSnapshotId = snapshotContext?.id
        mutationTracker.snapshotId = effectiveSnapshotId
        mutationTracker.targetWindowId = targetWindowID
        try self.preflightBackgroundType(
            target: plannedTarget,
            requiresElementFocus: targetContext != nil,
            automation: automation)

        let focusResult: TypeFocusResult
        do {
            focusResult = try await self.focusIfNeeded(
                targetContext: targetContext,
                request: request,
                automation: automation,
                target: plannedTarget)
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch let error as InputDeliveryIndeterminateError {
            throw InputDeliveryIndeterminateError(
                operation: .type,
                emittedUnitCount: error.emittedUnitCount,
                causeDescription: error.causeDescription ?? error.localizedDescription)
        }

        var sequence = DesktopActionSequenceAccumulator()
        if focusResult.completed {
            if let outcome = focusResult.outcome {
                sequence.record(.reportedOutcome(
                    outcome,
                    defaultDispatchedUnitCount: .one))
            } else {
                sequence.record(.dispatched(route: nil, delivery: nil, unitCount: Self.singleDispatchUnit))
            }
        }

        let typeActionResult: UIAutomationActionResult<TypeResult>
        mutationTracker.reportsCharactersTyped = true
        do {
            if focusResult.completed {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if let plannedTarget {
                let focusPinnedTarget = try focusResult.focusedElement.map {
                    try plannedTarget.pinningFocusedElement($0)
                } ?? plannedTarget
                let deliveryTarget = try await self.pinningCurrentFocusedElement(
                    on: focusPinnedTarget,
                    using: automation)
                typeActionResult = try await self.performBackgroundType(
                    request: BackgroundTypeRequest(
                        actions: actions,
                        cadence: request.cadence,
                        snapshotId: effectiveSnapshotId,
                        target: deliveryTarget),
                    automation: automation,
                    mutationTracker: mutationTracker)
            } else {
                mutationTracker.delivery = .init(mechanism: .globalEvents, mode: .foreground)
                if let outcomeAutomation = automation as? any UIAutomationActionOutcomeProviding {
                    typeActionResult = try await outcomeAutomation.typeActionsWithOutcome(
                        actions,
                        cadence: request.cadence,
                        snapshotId: effectiveSnapshotId)
                } else {
                    typeActionResult = try await UIAutomationActionResult(
                        payload: automation.typeActions(
                            actions,
                            cadence: request.cadence,
                            snapshotId: effectiveSnapshotId),
                        outcome: nil)
                }
            }
        } catch let failure as DesktopActionFailure {
            throw focusResult.attributing(sequence.failure(
                combining: failure,
                message: "Typing failed after its element focus action completed.",
                hint: "Observe the target before deciding whether to retry typing."))
        } catch let error as InputDeliveryIndeterminateError {
            mutationTracker.charactersTyped = error.emittedUnitCount
            if sequence.mutationDisposition.mutationDispatched {
                mutationTracker.delivery = nil
            }
            let failure = error.desktopActionFailure(delivery: mutationTracker.delivery)
            throw focusResult.attributing(sequence.failure(
                combining: failure,
                message: "Typing failed after its element focus action completed.",
                hint: "Observe the target before deciding whether to retry typing.",
                causeDescription: error.causeDescription ?? error.localizedDescription))
        } catch {
            guard sequence.mutationDisposition.mutationDispatched else { throw error }
            mutationTracker.delivery = nil
            let leaf = DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: error.localizedDescription)
            throw focusResult.attributing(sequence.failure(
                combining: leaf,
                message: "Typing failed after its element focus action completed.",
                hint: "Observe the target before deciding whether to retry typing.",
                causeDescription: error.localizedDescription))
        }

        do {
            try DesktopActionFailure.requireConfirmedIfReported(
                typeActionResult.outcome,
                operation: "Typing")
        } catch let failure as DesktopActionFailure {
            throw focusResult.attributing(sequence.failure(
                combining: failure,
                message: "Typing failed after its element focus action completed.",
                hint: "Observe the target before deciding whether to retry typing."))
        }

        if let outcome = typeActionResult.outcome {
            sequence.record(.reportedOutcome(
                outcome,
                defaultDispatchedUnitCount: .one))
        } else {
            sequence.record(.dispatched(
                route: nil,
                delivery: mutationTracker.delivery,
                unitCount: Self.singleDispatchUnit))
        }
        let sequenceResolution = sequence.successResolution()
        return try await self.successResponse(TypeSuccessInput(
            request: request,
            targetContext: targetContext,
            targetProcessIdentifier: targetProcessIdentifier,
            targetWindowID: targetWindowID,
            snapshotID: effectiveSnapshotId,
            startedAt: startTime,
            actionResult: typeActionResult,
            focusCompleted: focusResult.completed,
            sequenceResolution: sequenceResolution))
    }

    @MainActor
    private func successResponse(_ input: TypeSuccessInput) async throws -> ToolResponse {
        let responseOutcome = input.sequenceResolution.outcome
        let invalidatedSnapshotId = await MCPDesktopActionSnapshotInvalidator.invalidate(
            uiSnapshots: self.context.uiSnapshots,
            snapshotID: input.snapshotID,
            mutationDispatched: input.sequenceResolution.mutationDispatched)
        let executionTime = Date().timeIntervalSince(input.startedAt)
        let typingDispatched = input.actionResult.outcome?.dispatchState.mutationDispatched ?? true
        let charactersTyped = typingDispatched ? input.actionResult.payload.totalCharacters : 0
        let message = self.buildSummary(
            request: input.request,
            executionTime: executionTime,
            result: input.actionResult.payload,
            typingDispatched: typingDispatched)
        var baseMetaDict: [String: Value] = [
            "execution_time": .double(executionTime),
            "characters_typed": .double(Double(charactersTyped)),
        ]
        if !input.focusCompleted {
            baseMetaDict["delivery_mode"] = .string(
                input.targetProcessIdentifier == nil ? "foreground" : "background")
        }
        if let targetProcessIdentifier = input.targetProcessIdentifier {
            baseMetaDict["target_pid"] = .int(targetProcessIdentifier)
        }
        if let targetWindowID = input.targetWindowID {
            baseMetaDict["target_window_id"] = .int(targetWindowID)
        }
        if let invalidatedSnapshotId {
            baseMetaDict["invalidated_snapshot"] = .string(invalidatedSnapshotId)
        }
        if responseOutcome == nil {
            baseMetaDict["mutation_dispatched"] = .bool(input.sequenceResolution.mutationDispatched)
            baseMetaDict["retry_safe"] = .bool(input.sequenceResolution.retrySafe)
            baseMetaDict["requires_fresh_observation"] = .bool(input.sequenceResolution.requiresFreshObservation)
            if input.sequenceResolution.mutationDispatched {
                baseMetaDict["effect"] = .string(DesktopActionOutcome.Effect.unverifiable.rawValue)
            }
        }
        let summary = self.buildEventSummary(
            request: input.request,
            targetContext: input.targetContext,
            typingDispatched: typingDispatched)
        let mergedMeta = try ToolEventSummary.merge(
            summary: summary,
            into: MCPToolResponseMetadataProjector.metadata(
                merging: baseMetaDict,
                outcome: responseOutcome))

        return ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: mergedMeta)
    }

    @MainActor
    private func pinningCurrentFocusedElement(
        on target: UIAutomationTarget,
        using automation: any UIAutomationServiceProtocol) async throws -> UIAutomationTarget
    {
        guard target.exactWindow != nil else { return target }
        do {
            return try await target.pinningCurrentFocusedElement(using: automation)
        } catch {
            throw TypeToolValidationError(
                error.localizedDescription,
                refusalReason: .targetUnavailable)
        }
    }

    @MainActor
    private func preflightBackgroundType(
        target: UIAutomationTarget?,
        requiresElementFocus: Bool,
        automation: any UIAutomationServiceProtocol) throws
    {
        guard target?.exactWindow != nil else { return }
        do {
            _ = try ExactWindowKeyboardRuntime.requireOutcomeProvider(
                automation: automation,
                operation: "Background typing")
        } catch {
            throw TypeToolValidationError(
                error.localizedDescription,
                refusalReason: .runtimeIncompatible)
        }
        let hasReceipt = target?.exactWindow?.focusedElement != nil
        guard hasReceipt || (automation is any TargetedFocusedElementServiceProtocol) else {
            throw TypeToolValidationError(
                "This automation host does not support focused exact-window background typing.",
                refusalReason: .runtimeIncompatible)
        }
        guard requiresElementFocus else { return }
        guard let targetedClick = automation as? any TargetedClickServiceProtocol,
              targetedClick.supportsTargetedClicks,
              targetedClick.supportsProcessGenerationPinnedClicks,
              let exactClick = automation as? any ExactWindowTargetedClickServiceProtocol,
              exactClick.supportsExactWindowTargetedClicks
        else {
            throw TypeToolValidationError(
                "This automation host does not support exact-window background element focus.",
                refusalReason: .runtimeIncompatible)
        }
    }

    @MainActor
    private func focusIfNeeded(
        targetContext: TargetElementContext?,
        request: TypeRequest,
        automation: any UIAutomationServiceProtocol,
        target: UIAutomationTarget?) async throws -> TypeFocusResult
    {
        guard let context = targetContext else {
            if target == nil {
                let focusResult = try await request.target.focusResultIfRequested(
                    windows: self.context.windows,
                    onlyWhenTargeted: true)
                return focusResult.map(TypeFocusResult.completed(focusResult:)) ?? .none
            }
            return .none
        }

        let element = context.element
        if let target, !request.foreground {
            guard let automation = automation as? any TargetedClickServiceProtocol,
                  automation.supportsTargetedClicks,
                  automation.supportsProcessGenerationPinnedClicks
            else {
                throw TypeToolValidationError(
                    "This automation host does not support background element focus.",
                    refusalReason: .runtimeIncompatible)
            }
            if let exactWindow = target.exactWindow {
                guard let exactAutomation = automation as? any ExactWindowTargetedClickServiceProtocol,
                      exactAutomation.supportsExactWindowTargetedClicks
                else {
                    throw TypeToolValidationError(
                        "This automation host does not support exact-window background element focus.",
                        refusalReason: .runtimeIncompatible)
                }
                let expectedFocus = try Self.expectedFocusedElement(
                    element,
                    exactWindow: exactWindow)
                if let focusAutomation = automation as? any ExactWindowFocusedElementServiceProtocol,
                   focusAutomation.supportsExactWindowFocusedElementFocus
                {
                    let result = try await focusAutomation.focusExactElementWithOutcome(
                        target: .elementId(element.id),
                        snapshotId: context.snapshot.id,
                        expectedWindowIdentity: exactWindow.identity,
                        expectedWindowBounds: exactWindow.bounds)
                    try Self.requireConfirmedFocus(result.outcome)
                    try FocusedElementReceiptResolver.validate(result.payload, matches: expectedFocus)
                    return .completed(outcome: result.outcome, focusedElement: result.payload)
                }
                if let outcomeAutomation = automation as? any UIAutomationActionOutcomeProviding {
                    let result = try await outcomeAutomation.clickWithOutcome(
                        target: .elementId(element.id),
                        clickType: .single,
                        snapshotId: context.snapshot.id,
                        expectedWindowIdentity: exactWindow.identity,
                        expectedWindowBounds: exactWindow.bounds)
                    try Self.requireConfirmedFocus(result.outcome)
                    let focusedElement = try await self.observeExactFocusedElement(
                        automation: automation,
                        exactWindow: exactWindow,
                        expected: expectedFocus)
                    return .completed(outcome: result.outcome, focusedElement: focusedElement)
                }
                try await exactAutomation.click(
                    target: .elementId(element.id),
                    clickType: .single,
                    snapshotId: context.snapshot.id,
                    expectedWindowIdentity: exactWindow.identity,
                    expectedWindowBounds: exactWindow.bounds)
                let focusedElement = try await self.observeExactFocusedElement(
                    automation: automation,
                    exactWindow: exactWindow,
                    expected: expectedFocus)
                return .completed(outcome: nil, focusedElement: focusedElement)
            }
            guard let processIdentity = target.processIdentity else {
                throw TypeToolValidationError(
                    "Background element focus has no process-generation receipt.",
                    refusalReason: .targetUnavailable)
            }
            if let outcomeAutomation = automation as? any UIAutomationActionOutcomeProviding {
                let result = try await outcomeAutomation.clickWithOutcome(
                    target: .elementId(element.id),
                    clickType: .single,
                    snapshotId: context.snapshot.id,
                    expectedProcessIdentity: processIdentity)
                try Self.requireConfirmedFocus(result.outcome)
                return .completed(outcome: result.outcome)
            } else {
                try await automation.click(
                    target: .elementId(element.id),
                    clickType: .single,
                    snapshotId: context.snapshot.id,
                    expectedProcessIdentity: processIdentity)
                return .completed(outcome: nil)
            }
        } else if let outcomeAutomation = automation as? any UIAutomationActionOutcomeProviding {
            let result = try await outcomeAutomation.clickWithOutcome(
                target: .elementId(element.id),
                clickType: .single,
                snapshotId: context.snapshot.id)
            try Self.requireConfirmedFocus(result.outcome)
            return .completed(outcome: result.outcome)
        } else {
            try await automation.click(
                target: .elementId(element.id),
                clickType: .single,
                snapshotId: context.snapshot.id)
            return .completed(outcome: nil)
        }
    }

    private static func expectedFocusedElement(
        _ element: UIElement,
        exactWindow: UIAutomationTarget.ExactWindow) throws -> FocusedElementIdentity
    {
        guard !element.frame.isEmpty else {
            throw TypeToolValidationError(
                FocusedElementReceiptError.missingElementFrame.localizedDescription,
                refusalReason: .targetUnavailable)
        }
        guard exactWindow.bounds.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) else {
            throw TypeToolValidationError(
                FocusedElementReceiptError.elementOutsideWindow.localizedDescription,
                refusalReason: .targetUnavailable)
        }
        return FocusedElementIdentity(
            processIdentifier: exactWindow.identity.ownerProcessIdentifier,
            windowID: exactWindow.identity.windowID,
            role: element.role,
            title: element.title,
            identifier: element.identifier,
            frame: element.frame)
    }

    private func observeExactFocusedElement(
        automation: any UIAutomationServiceProtocol,
        exactWindow: UIAutomationTarget.ExactWindow,
        expected: FocusedElementIdentity) async throws -> FocusedElementIdentity
    {
        let observation = try await automation.inspectAccessibilityTree(windowContext: WindowContext(
            applicationProcessId: exactWindow.identity.ownerProcessIdentifier,
            windowID: exactWindow.identity.windowID,
            windowBounds: exactWindow.bounds,
            windowMutationIdentity: exactWindow.identity,
            includeMenuBarElements: false,
            requiresFreshAccessibilityTree: true,
            accessibilityTimeoutSeconds: 2))
        guard let focusedElement = observation.metadata.windowContext?.focusedElement else {
            throw TypeToolValidationError(
                FocusedElementReceiptError.noFocusedElement.localizedDescription,
                refusalReason: .targetUnavailable)
        }
        do {
            try FocusedElementReceiptResolver.validate(focusedElement, matches: expected)
        } catch {
            throw TypeToolValidationError(error.localizedDescription, refusalReason: .targetUnavailable)
        }
        return focusedElement
    }

    private static func requireConfirmedFocus(_ outcome: DesktopActionOutcome?) throws {
        guard let outcome, !outcome.isConfirmed else { return }
        guard let failure = DesktopActionFailure(
            outcome: outcome,
            message: "The element focus action was not confirmed.",
            hint: "Observe the target before deciding whether to retry typing.")
        else { return }
        throw failure
    }

    private func backgroundKeyboardTarget(
        request: TypeRequest,
        snapshot: UISnapshot?) async throws -> UIAutomationTarget?
    {
        guard !request.foreground else { return nil }

        let snapshotProcessIdentity = try await self.snapshotProcessIdentity(snapshot)
        let snapshotExactWindow = try self.snapshotExactWindow(snapshot)
        if request.target.hasTarget, snapshot != nil, snapshotProcessIdentity == nil {
            throw TypeToolValidationError(
                "The selected snapshot has no capture-time process-generation receipt. Capture fresh UI state.",
                refusalReason: .targetUnavailable)
        }
        if request.target.hasTarget || snapshotProcessIdentity != nil {
            do {
                return try await request.target.requireBackgroundKeyboardTarget(
                    applications: self.context.applications,
                    windows: self.context.windows,
                    snapshotProcessIdentity: snapshotProcessIdentity,
                    snapshotExactWindow: snapshotExactWindow)
            } catch let error as MCPInteractionTargetError {
                throw error
            } catch {
                throw TypeToolValidationError(
                    error.localizedDescription,
                    refusalReason: .targetUnavailable)
            }
        }
        if snapshot != nil || request.elementId != nil || request.snapshotId != nil {
            throw TypeToolValidationError(
                "The selected snapshot does not identify a target process. Capture an app/window snapshot or set " +
                    "foreground=true for intentional global input.",
                refusalReason: .targetUnavailable)
        }
        throw TypeToolValidationError(
            "Typing requires on, snapshot, app, or pid targeting. Set foreground=true for intentional global input.")
    }

    @MainActor
    private func performBackgroundType(
        request: BackgroundTypeRequest,
        automation: any UIAutomationServiceProtocol,
        mutationTracker: TypeMutationTracker) async throws -> UIAutomationActionResult<TypeResult>
    {
        if let exactWindow = request.target.exactWindow {
            let outcomeAutomation: any UIAutomationActionOutcomeProviding
            do {
                outcomeAutomation = try ExactWindowKeyboardRuntime.requireOutcomeProvider(
                    automation: automation,
                    operation: "Background typing")
            } catch {
                throw TypeToolValidationError(
                    error.localizedDescription,
                    refusalReason: .runtimeIncompatible)
            }
            guard let focusedElement = exactWindow.focusedElement else {
                throw TypeToolValidationError(
                    "Exact-window background typing requires a focused-element receipt.",
                    refusalReason: .targetUnavailable)
            }
            mutationTracker.delivery = .init(mechanism: .windowTargetedEvents, mode: .background)
            return try await ExactWindowKeyboardRuntime.validateRouteReceipt(
                outcomeAutomation.typeActionsWithOutcome(
                    request.actions,
                    cadence: request.cadence,
                    snapshotId: request.snapshotId,
                    target: ExactWindowKeyboardTarget(
                        windowIdentity: exactWindow.identity,
                        windowBounds: exactWindow.bounds,
                        focusedElement: focusedElement)),
                operation: "Background typing")
        }
        guard let automation = automation as? any TargetedTypeServiceProtocol,
              automation.supportsTargetedTypeActions,
              automation.supportsProcessGenerationPinnedTypeActions,
              let processIdentity = request.target.processIdentity
        else {
            throw TypeToolValidationError(
                "This automation host does not support background typing.",
                refusalReason: .runtimeIncompatible)
        }
        mutationTracker.delivery = .init(mechanism: .processTargetedEvents, mode: .background)
        if let outcomeAutomation = automation as? any UIAutomationActionOutcomeProviding {
            return try await outcomeAutomation.typeActionsWithOutcome(
                request.actions,
                cadence: request.cadence,
                snapshotId: request.snapshotId,
                expectedProcessIdentity: processIdentity)
        }
        return try await UIAutomationActionResult(
            payload: automation.typeActions(
                request.actions,
                cadence: request.cadence,
                snapshotId: request.snapshotId,
                expectedProcessIdentity: processIdentity),
            outcome: nil)
    }

    private func snapshotExactWindow(_ snapshot: UISnapshot?) throws -> UIAutomationTarget.ExactWindow? {
        guard let snapshot else { return nil }
        guard snapshot.windowMutationIdentity != nil else { return nil }
        do {
            guard let exactWindow = try snapshot.targetReceipt().requireIdentity().exactWindow else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            return exactWindow
        } catch {
            throw TypeToolValidationError(
                "The selected snapshot has inconsistent process/window metadata.",
                refusalReason: .targetUnavailable)
        }
    }

    private func snapshotProcessIdentity(_ snapshot: UISnapshot?) async throws -> ApplicationProcessIdentity? {
        guard let snapshot, let processIdentifier = snapshot.applicationProcessId, processIdentifier > 0 else {
            return nil
        }
        do {
            return try snapshot.targetReceipt().requireIdentity().processIdentity
        } catch DesktopTargetIdentityError.missingProcessGeneration,
            DesktopTargetIdentityError.incompleteExactWindow
        {
            throw TypeToolValidationError(
                "The selected snapshot has no capture-time process-generation receipt. Capture fresh UI state.",
                refusalReason: .targetUnavailable)
        } catch {
            throw TypeToolValidationError(
                "The selected snapshot has inconsistent process metadata.",
                refusalReason: .targetUnavailable)
        }
    }

    @MainActor
    private func resolveTargetContext(for request: TypeRequest) async throws -> TargetElementContext? {
        guard let elementId = request.elementId else { return nil }
        guard let snapshot = await self.getSnapshot(id: request.snapshotId) else {
            throw TypeToolValidationError(
                "No active snapshot. Run 'see' or 'inspect_ui' first to capture UI state.",
                refusalReason: .targetUnavailable)
        }

        guard let element = await snapshot.getElement(byId: elementId) else {
            throw TypeToolValidationError(
                "Element '\(elementId)' not found in current snapshot. Run 'see' or 'inspect_ui' to update UI state.",
                refusalReason: .targetUnavailable)
        }
        guard !element.isOCRSemanticEvidence else {
            throw TypeToolValidationError(OCRSemanticEvidencePolicy.interactionRefusalMessage)
        }

        return TargetElementContext(snapshot: snapshot, element: element)
    }

    private func resolveSnapshotContext(
        for request: TypeRequest,
        targetContext: TargetElementContext?) async throws -> UISnapshot?
    {
        if let targetContext {
            return targetContext.snapshot
        }
        guard request.snapshotId != nil else { return nil }
        guard let snapshot = await self.getSnapshot(id: request.snapshotId) else {
            throw TypeToolValidationError(
                "Snapshot not found. Run 'see' or 'inspect_ui' to capture fresh UI state.",
                refusalReason: .targetUnavailable)
        }
        return snapshot
    }
}

extension TypeTool {
    fileprivate static let singleDispatchUnit: DesktopActionOutcome.DispatchUnitCount = .one
}

@MainActor
private final class TypeMutationTracker {
    var snapshotId: String?
    var delivery: DesktopActionOutcome.Delivery?
    var charactersTyped: Int?
    var reportsCharactersTyped = false
    var targetWindowId: Int?

    var targetFields: [String: Value] {
        self.targetWindowId.map { ["target_window_id": .int($0)] } ?? [:]
    }

    var compatibilityFields: [String: Value] {
        var fields = self.targetFields
        if self.reportsCharactersTyped {
            fields["characters_typed"] = self.charactersTyped.map(Value.int) ?? .null
        }
        return fields
    }
}

struct TypeFocusResult {
    let completed: Bool
    let outcome: DesktopActionOutcome?
    let focusedElement: FocusedElementIdentity?
    let focusResult: MCPInteractionFocusResult?

    static let none = Self(completed: false, outcome: nil, focusedElement: nil, focusResult: nil)

    static func completed(
        outcome: DesktopActionOutcome?,
        focusedElement: FocusedElementIdentity? = nil) -> Self
    {
        Self(completed: true, outcome: outcome, focusedElement: focusedElement, focusResult: nil)
    }

    static func completed(focusResult: MCPInteractionFocusResult) -> Self {
        Self(
            completed: true,
            outcome: focusResult.outcome,
            focusedElement: nil,
            focusResult: focusResult)
    }

    func attributing(_ failure: DesktopActionFailure) -> DesktopActionFailure {
        self.focusResult?.attributing(failure) ?? failure
    }
}

private struct BackgroundTypeRequest {
    let actions: [TypeAction]
    let cadence: TypingCadence
    let snapshotId: String?
    let target: UIAutomationTarget
}

private struct TypeSuccessInput {
    let request: TypeRequest
    let targetContext: TargetElementContext?
    let targetProcessIdentifier: Int?
    let targetWindowID: Int?
    let snapshotID: String?
    let startedAt: Date
    let actionResult: UIAutomationActionResult<TypeResult>
    let focusCompleted: Bool
    let sequenceResolution: DesktopActionSequenceAccumulator.Resolution
}
