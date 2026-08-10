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

    @Option(help: "Snapshot ID, or 'latest'")
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
            try await observation.validateIfExplicit(using: self.services.snapshots)
            let targetPID = try await self.backgroundProcessIdentifier(snapshotId: observation.snapshotId)
            self.resolvedRuntime.beginInteractionMutation()
            if targetPID == nil {
                try await self.focusIfNeeded(snapshotId: observation.focusSnapshotId(for: self.target))
            }
            let typeResult = try await self.executeTypeActions(
                actions: actions,
                snapshotId: observation.snapshotId,
                targetProcessIdentifier: targetPID
            )
            await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: self.resolvedRuntime.interactionMutationTargets,
                logger: self.logger,
                reason: "type"
            )
            self.renderResult(typeResult, actions: actions, startTime: startTime, targetProcessIdentifier: targetPID)
        } catch {
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

    private func focusIfNeeded(snapshotId: String?) async throws {
        try await ensureFocused(
            snapshotId: snapshotId,
            target: self.target,
            options: self.focusOptions,
            services: self.services
        )
    }

    private func executeTypeActions(
        actions: [TypeAction],
        snapshotId: String?,
        targetProcessIdentifier: pid_t?
    ) async throws -> TypeResult {
        let request = TypeActionsRequest(actions: actions, cadence: self.typingCadence, snapshotId: snapshotId)
        if let targetProcessIdentifier {
            return try await AutomationServiceBridge.typeActions(
                automation: self.services.automation,
                request: request,
                targetProcessIdentifier: targetProcessIdentifier
            )
        }
        return try await AutomationServiceBridge.typeActions(automation: self.services.automation, request: request)
    }

    private func backgroundProcessIdentifier(snapshotId: String?) async throws -> pid_t? {
        guard !self.focusOptions.foreground else {
            return nil
        }

        return try await KeyboardDeliverySupport.requireBackgroundProcessIdentifier(
            target: self.target,
            snapshotId: snapshotId,
            services: self.services
        )
    }

    private func renderResult(
        _ typeResult: TypeResult,
        actions: [TypeAction],
        startTime: Date,
        targetProcessIdentifier: pid_t?
    ) {
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
            targetPID: targetProcessIdentifier.map(Int.init)
        )

        output(result) {
            print("✅ Typing completed")
            if let typed = self.resolvedText {
                print("⌨️  Typed: \"\(typed)\"")
            }
            if specialKeys > 0 {
                print("🔑 Special keys: \(specialKeys)")
            }
            if let targetProcessIdentifier {
                print("🎯 Mode: background to PID \(targetProcessIdentifier)")
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

@MainActor
extension TypeCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "type",
                abstract: "Type text into an app or UI element",
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
                      Window selectors require --foreground because process-targeted events
                      cannot prove which window owns the focused element. Without a target,
                      --foreground is required for intentional global keyboard input.

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
