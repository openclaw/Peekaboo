import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Types text into focused elements or sends keyboard input using the UIAutomationService.
@available(macOS 14.0, *)
@MainActor
struct TypeCommand: ActionOutputFormattable, ErrorHandlingCommand, OutputFormattable, RuntimeBackedCommand {
    @Argument(help: "Text to type")
    var text: String?

    @Option(name: .customLong("text"), help: "Text to type (alternative to positional argument)")
    var textOption: String?

    @Option(help: "Snapshot ID (or explicit 'latest'); no snapshot is inferred when omitted")
    var snapshot: String?

    @Option(help: "Delay between keystrokes (bare values are milliseconds)")
    var delay: CLIDuration = .milliseconds(0)

    @Option(name: .customLong("wpm"), help: "Approximate human typing speed (words per minute)")
    var wordsPerMinute: Int?

    @Option(name: .customLong("profile"), help: "Typing profile: linear (default) or human")
    var profileOption: String?

    @Flag(help: "Clear the field before typing (Cmd+A, Delete)")
    var clear = false

    @OptionGroup var target: InteractionTargetOptions

    @OptionGroup var focusOptions: FocusCommandOptions
    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    private var resolvedText: String? {
        if let primary = text, !primary.isEmpty {
            return primary
        }
        return self.textOption
    }

    private static let defaultHumanWPM = 140

    private var resolvedProfile: TypingProfile {
        if let profileOption,
           let selection = TypingProfile(rawValue: profileOption.lowercased()) {
            return selection
        }
        return self.wordsPerMinute == nil ? .linear : .human
    }

    private var resolvedWordsPerMinute: Int {
        self.wordsPerMinute ?? Self.defaultHumanWPM
    }

    private var typingCadence: TypingCadence {
        switch self.resolvedProfile {
        case .human:
            .human(wordsPerMinute: self.resolvedWordsPerMinute)
        case .linear:
            .fixed(milliseconds: self.delay.roundedMilliseconds)
        }
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.prepare(using: runtime)
        try self.validate()
        let startTime = Date()
        do {
            let actions = try self.buildActions()
            let observation = await self.resolveObservationContext()
            do {
                try await observation.validateIfExplicit(using: self.services.snapshots)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                throw self.preDispatchActionError(for: error)
            }
            let backgroundTarget: UIAutomationTarget?
            do {
                backgroundTarget = try await self.backgroundKeyboardTarget(snapshotId: observation.snapshotId)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                throw self.preDispatchActionError(for: error, reason: .targetUnavailable)
            }
            let deliveryTarget: UIAutomationTarget
            do {
                deliveryTarget = try await self.pinningCurrentFocusedElement(on: backgroundTarget) ?? .foreground
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                throw self.preDispatchActionError(for: error, reason: .targetUnavailable)
            }
            let targetPID = deliveryTarget.processIdentifier
            self.resolvedRuntime.beginInteractionMutation()
            let actionSequence = CommandActionSequenceAccumulator()
            let actionRoute = commandActionRoute(for: self.services)
            if targetPID == nil {
                let focusSnapshotID = observation.focusSnapshotId(for: self.target)
                if let focusResult = try await ensureConfirmedForegroundFocus(
                    snapshotId: focusSnapshotID,
                    target: self.target,
                    options: self.focusOptions,
                    services: self.services,
                    operation: "Typing setup focus"
                ) {
                    try actionSequence.record(focusResult, operation: "Typing setup focus")
                }
            }
            let actionResult: UIAutomationActionResult<TypeResult>
            do {
                actionResult = try await self.executeTypeActions(
                    actions: actions,
                    snapshotId: observation.snapshotId,
                    target: deliveryTarget
                )
                let receiptlessStep = DesktopActionSequenceAccumulator.Step.dispatched(
                    route: actionRoute,
                    delivery: Self.delivery(for: deliveryTarget),
                    unitCount: .one
                )
                if deliveryTarget.processIdentifier == nil {
                    try actionSequence.recordExactTargetLeaf(
                        outcome: actionResult.outcome,
                        targetIdentity: actionResult.targetIdentity,
                        operation: "Typing",
                        receiptlessStep: receiptlessStep
                    )
                } else {
                    try actionSequence.record(
                        actionResult,
                        operation: "Typing",
                        receiptlessStep: receiptlessStep
                    )
                }
            } catch let failure as DesktopActionFailure {
                let composed = actionSequence.preservingFailure(
                    failure,
                    fallbackRoute: actionRoute,
                    message: "Typing failed after foreground setup may have changed focus.",
                    hint: "Observe the target before deciding whether to retry typing."
                )
                throw composed
            } catch let error as InputDeliveryIndeterminateError {
                let delivery = Self.delivery(for: deliveryTarget)
                let composed = actionSequence.preservingFailure(
                    error.desktopActionFailure(delivery: delivery, route: actionRoute),
                    fallbackRoute: actionRoute,
                    message: "Typing outcome is indeterminate.",
                    hint: "Observe the target before deciding whether to retry typing."
                )
                throw composed
            } catch {
                let composed = actionSequence.preservingFailure(
                    error,
                    fallbackRoute: actionRoute,
                    message: "Typing failed after foreground setup may have changed focus.",
                    hint: "Observe the target before deciding whether to retry typing."
                )
                throw composed
            }
            await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: self.resolvedRuntime.interactionMutationTargets,
                logger: self.logger,
                reason: "type"
            )
            let compositeResult = actionSequence.result(payload: actionResult.payload)
            self.renderResult(
                compositeResult.payload,
                outcome: compositeResult.outcome,
                targetIdentity: compositeResult.targetIdentity,
                actions: actions,
                startTime: startTime,
                target: deliveryTarget
            )
        } catch {
            if let failure = error as? DesktopActionFailure {
                await self.invalidateAfterFailedMutation(failure)
            }
            self.handleError(error)
            throw ExitCode.failure
        }
    }

    private mutating func prepare(using runtime: CommandRuntime) {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)
    }

    private func buildActions() throws -> [TypeAction] {
        var actions: [TypeAction] = []

        if self.clear {
            actions.append(.clear)
        }

        if let textToType = self.resolvedText {
            actions.append(contentsOf: Self.processTextWithEscapes(textToType))
        }

        guard !actions.isEmpty else {
            throw ValidationError("No input specified. Provide text or use --clear.")
        }

        return actions
    }

    private func resolveObservationContext() async -> InteractionObservationContext {
        // With an explicit app/window target, `type` focuses that target and avoids reusing
        // a potentially unrelated latest snapshot for the keystroke injection path.
        await InteractionObservationContext.resolve(
            explicitSnapshot: self.snapshot,
            fallbackToLatest: false,
            snapshots: self.services.snapshots
        )
    }

    mutating func validate() throws {
        try self.target.validate()
        if self.text != nil, self.textOption != nil {
            throw ValidationError("Provide text either positionally or with --text, not both")
        }
        try KeyboardDeliverySupport.validateForegroundFlags(
            foreground: self.focusOptions.foreground,
            focusOptions: self.focusOptions
        )
        if let option = self.profileOption,
           TypingProfile(rawValue: option.lowercased()) == nil {
            throw ValidationError("--profile must be either 'human' or 'linear'")
        }

        if let wpm = self.wordsPerMinute {
            guard (80...220).contains(wpm) else {
                throw ValidationError("--wpm must be between 80 and 220 to stay believable")
            }
            guard self.resolvedProfile == .human else {
                throw ValidationError("--wpm is only valid when --profile human")
            }
        }
    }

    private func executeTypeActions(
        actions: [TypeAction],
        snapshotId: String?,
        target: UIAutomationTarget
    ) async throws -> UIAutomationActionResult<TypeResult> {
        let request = TypeActionsRequest(actions: actions, cadence: self.typingCadence, snapshotId: snapshotId)
        return try await AutomationServiceBridge.typeActions(
            automation: self.services.automation,
            request: request,
            target: target
        )
    }

    private func backgroundKeyboardTarget(snapshotId: String?) async throws -> UIAutomationTarget? {
        guard !self.focusOptions.foreground else {
            return nil
        }

        return try await KeyboardDeliverySupport.requireBackgroundKeyboardTarget(
            target: self.target,
            snapshotId: snapshotId,
            services: self.services
        )
    }

    private func pinningCurrentFocusedElement(on target: UIAutomationTarget?) async throws -> UIAutomationTarget? {
        guard let target, target.exactWindow != nil else { return target }
        guard let exactService = self.services.automation as? any ExactWindowTargetedKeyboardServiceProtocol,
              exactService.supportsExactWindowTargetedKeyboard,
              self.services.automation is any UIAutomationActionOutcomeProviding,
              self.services.automation is any TargetedFocusedElementServiceProtocol
        else {
            throw PreDispatchActionError(
                message: "This automation host does not support receipt-pinned exact-window background typing.",
                code: .INTERACTION_FAILED,
                hint: "Update the Peekaboo host and retry with a fresh exact-window target.",
                reason: .runtimeIncompatible
            )
        }
        return try await target.pinningCurrentFocusedElement(using: self.services.automation)
    }

    private func renderResult(
        _ typeResult: TypeResult,
        outcome: DesktopActionOutcome?,
        targetIdentity: DesktopTargetIdentity?,
        actions: [TypeAction],
        startTime: Date,
        target: UIAutomationTarget
    ) {
        let targetProcessIdentifier = target.processIdentifier
        let targetWindowID = target.exactWindow?.identity.windowID
        let specialKeys = max(typeResult.keyPresses - typeResult.totalCharacters, 0)
        let result = TypeCommandResult(
            requestedText: self.resolvedText,
            typedText: self.resolvedText,
            keyPresses: typeResult.keyPresses,
            totalCharacters: typeResult.totalCharacters,
            literalCharactersTyped: typeResult.totalCharacters,
            specialKeyPresses: specialKeys,
            actions: actions.map(Self.actionSummary),
            executionTime: Date().timeIntervalSince(startTime),
            wordsPerMinute: self.resolvedProfile == .human ? self.resolvedWordsPerMinute : nil,
            profile: self.resolvedProfile.rawValue,
            deliveryMode: targetProcessIdentifier == nil ? KeyboardDeliveryMode.foreground.rawValue :
                KeyboardDeliveryMode.background.rawValue,
            targetPID: targetProcessIdentifier.map(Int.init),
            targetWindowID: targetWindowID
        )

        output(result, outcome: outcome, targetIdentity: targetIdentity) {
            if let outcome {
                print(ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: "Typing"))
            } else {
                print("✅ Typing completed")
            }
            if let typed = self.resolvedText {
                print("⌨️  Typed: \"\(typed)\"")
            }
            if specialKeys > 0 {
                print("🔑 Special keys: \(specialKeys)")
            }
            if let targetProcessIdentifier {
                print("🎯 Mode: background to PID \(targetProcessIdentifier)")
            }
            if let targetWindowID {
                print("🪟 Window: \(targetWindowID)")
            }
            print("📊 Total characters: \(typeResult.totalCharacters)")
            switch self.resolvedProfile {
            case .human:
                print("🏃‍♀️ Human cadence: \(self.resolvedWordsPerMinute) WPM")
            case .linear:
                print("⚙️  Fixed delay: \(self.delay.roundedMilliseconds)ms between keys")
            }
            print("⏱️  Completed in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
        }
    }

    private static func actionSummary(_ action: TypeAction) -> TypeCommandActionSummary {
        switch action {
        case let .text(text):
            TypeCommandActionSummary(kind: "text", value: text)
        case let .key(key):
            TypeCommandActionSummary(kind: "key", value: key.rawValue)
        case .clear:
            TypeCommandActionSummary(kind: "clear", value: nil)
        }
    }

    private static func delivery(for target: UIAutomationTarget) -> DesktopActionOutcome.Delivery {
        if target.exactWindow != nil {
            return .init(mechanism: .windowTargetedEvents, mode: .background)
        }
        return target.processIdentifier == nil
            ? .init(mechanism: .globalEvents, mode: .foreground)
            : .init(mechanism: .processTargetedEvents, mode: .background)
    }

    private func invalidateAfterFailedMutation(_ failure: DesktopActionFailure) async {
        guard failure.outcome.dispatchState.mutationDispatched else { return }
        await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: self.resolvedRuntime.interactionMutationTargets,
            logger: self.logger,
            reason: "type failure"
        )
    }
}

@MainActor
extension TypeCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.text = try values.decodeOptionalPositional(0, label: "text")
        // Commander labels options by property name, so prefer that label and fall back to the
        // custom long name for safety.
        self.textOption = values.singleOption("textOption") ?? values.singleOption("text")
        self.snapshot = values.singleOption("snapshot")
        if let delay: CLIDuration = try values.decodeOption("delay", as: CLIDuration.self) {
            self.delay = delay
        }
        if let wpm: Int = try values.decodeOption("wordsPerMinute", as: Int.self) ?? values.decodeOption(
            "wpm",
            as: Int.self
        ) {
            self.wordsPerMinute = wpm
        }
        if let profile = values.singleOption("profileOption") ?? values.singleOption("profile") {
            self.profileOption = profile
        }
        self.clear = values.flag("clear")
        self.target = try values.makeInteractionTargetOptions()
        self.focusOptions = try values.makeFocusOptions(includeBackgroundDelivery: true)
    }
}

// MARK: - Conformances

extension TypeCommand: PreRuntimeValidatingCommand {
    func validateBeforeRuntime() throws {
        var command = self
        try command.validate()
        _ = try command.buildActions()
        try KeyboardDeliverySupport.validateBackgroundTargetRequirement(
            target: self.target,
            snapshotId: self.snapshot,
            foreground: self.focusOptions.foreground
        )
    }
}

@MainActor
extension TypeCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "type",
                abstract: "Type text into a targeted app process or the foreground focus",
                discussion: """
                    The 'type' command sends keyboard input to a targeted app or snapshot
                    process. Background delivery is the default and requires a process target.
                    Use --foreground for intentional global input.

                    EXAMPLES:
                      peekaboo type "Hello World" --app TextEdit # Background-target TextEdit
                      peekaboo type "user@example.com" --foreground
                      peekaboo type "text" --app TextEdit --delay 0ms
                      peekaboo type "text" --app TextEdit --delay 50ms
                      peekaboo type "text" --app TextEdit --wpm 150
                      peekaboo type "text" --app TextEdit --clear
                      peekaboo type "Line 1\nLine 2" --app TextEdit
                      peekaboo type "Name:\tJohn" --app TextEdit
                      peekaboo type "Path: C:\\data" --app TextEdit

                    KEY PRESSES:
                      Chain `type` with `press` for Return, Tab, Escape, Delete, or chords.
                      Use --clear to clear the current field before typing.

                    ESCAPE SEQUENCES:
                      Supported escape sequences in text:
                      \\n  - Newline/return
                      \\t  - Tab
                      \\b  - Backspace/delete
                      \\e  - Escape
                      \\\\  - Literal backslash

                    FOCUS MANAGEMENT:
                      Provide --app, --pid, or a snapshot for background delivery.
                      Exact window selectors and fresh snapshots stay pinned through native
                      dispatch. App/PID-only background typing is accepted only when the process
                      has at most one eligible window; otherwise add a window selector or snapshot.
                      Without a target, --foreground is required for intentional global input.

                    TYPING CADENCE:
                    Linear typing is the default and uses --delay (0ms by default).
                    Use --profile human or --wpm (80-220) for realistic cadence.
                """,

                showHelpOnEmptyInvocation: true
            )
        }
    }
}

extension TypeCommand: AsyncRuntimeCommand {}
