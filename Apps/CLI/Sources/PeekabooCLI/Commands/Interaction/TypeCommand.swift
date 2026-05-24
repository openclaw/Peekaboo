import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Types text into focused elements or sends keyboard input using the UIAutomationService.
@available(macOS 14.0, *)
@MainActor
struct TypeCommand: ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable {
    @Argument(help: "Text to type")
    var text: String?

    @Option(name: .customLong("text"), help: "Text to type (alternative to positional argument)")
    var textOption: String?

    @Option(help: "Snapshot ID, or 'latest' (uses latest if not specified)")
    var snapshot: String?

    @Option(help: "Delay between keystrokes in milliseconds")
    var delay: Int = 2

    @Option(name: .customLong("wpm"), help: "Approximate human typing speed (words per minute)")
    var wordsPerMinute: Int?

    @Option(name: .customLong("profile"), help: "Typing profile: human (default) or linear")
    var profileOption: String? = TypingProfile.human.rawValue

    @Flag(names: [.customLong("return"), .long], help: "Press return/enter after typing")
    var pressReturn = false

    @Option(help: "Press tab N times")
    var tab: Int?

    @Flag(help: "Press escape")
    var escape = false

    @Flag(help: "Press delete/backspace")
    var delete = false

    @Flag(help: "Clear the field before typing (Cmd+A, Delete)")
    var clear = false

    @OptionGroup var target: InteractionTargetOptions

    @OptionGroup var focusOptions: FocusCommandOptions
    @RuntimeStorage private var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    private var resolvedRuntime: CommandRuntime {
        guard let runtime else {
            preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
        }
        return runtime
    }

    private var services: any PeekabooServiceProviding {
        self.resolvedRuntime.services
    }

    private var logger: Logger {
        self.resolvedRuntime.logger
    }

    var outputLogger: Logger {
        self.logger
    }

    var jsonOutput: Bool {
        self.runtime?.configuration.jsonOutput ?? self.runtimeOptions.jsonOutput
    }

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
        return .human
    }

    private var resolvedWordsPerMinute: Int {
        self.wordsPerMinute ?? Self.defaultHumanWPM
    }

    private var typingCadence: TypingCadence {
        switch self.resolvedProfile {
        case .human:
            .human(wordsPerMinute: self.resolvedWordsPerMinute)
        case .linear:
            .fixed(milliseconds: self.delay)
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
            self.warnIfFocusUnknown(snapshotId: observation.snapshotId)
            try await self.focusIfNeeded(snapshotId: observation.focusSnapshotId(for: self.target))
            let typeResult = try await self.executeTypeActions(actions: actions, snapshotId: observation.snapshotId)
            await InteractionObservationInvalidator.invalidateAfterMutation(
                observation,
                snapshots: self.services.snapshots,
                logger: self.logger,
                reason: "type"
            )
            self.renderResult(typeResult, actions: actions, startTime: startTime)
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

        if let tabCount = tab {
            actions.append(contentsOf: Array(repeating: TypeAction.key(.tab), count: tabCount))
        }

        if self.escape {
            actions.append(.key(.escape))
        }

        if self.delete {
            actions.append(.key(.delete))
        }

        if self.pressReturn {
            actions.append(.key(.return))
        }

        guard !actions.isEmpty else {
            throw ValidationError("No input specified. Provide text or key flags.")
        }

        return actions
    }

    private func resolveObservationContext() async -> InteractionObservationContext {
        // With an explicit app/window target, `type` focuses that target and avoids reusing
        // a potentially unrelated latest snapshot for the keystroke injection path.
        await InteractionObservationContext.resolve(
            explicitSnapshot: self.snapshot,
            fallbackToLatest: !self.target.hasAnyTarget,
            snapshots: self.services.snapshots
        )
    }

    mutating func validate() throws {
        try self.target.validate()
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

    private func warnIfFocusUnknown(snapshotId: String?) {
        guard self.focusOptions.autoFocus, snapshotId == nil, !self.target.hasAnyTarget else { return }
        self.logger.warn(
            """
            Typing without a target (--app/--pid/--window-title/--window-index) or snapshot. \
            We'll inject keys blindly; run 'peekaboo see' or provide a target if you need focus guarantees.
            """
        )
    }

    private func focusIfNeeded(snapshotId: String?) async throws {
        try await ensureFocused(
            snapshotId: snapshotId,
            target: self.target,
            options: self.focusOptions,
            services: self.services
        )
    }

    private func executeTypeActions(actions: [TypeAction], snapshotId: String?) async throws -> TypeResult {
        let request = TypeActionsRequest(actions: actions, cadence: self.typingCadence, snapshotId: snapshotId)
        return try await AutomationServiceBridge.typeActions(automation: self.services.automation, request: request)
    }

    private func renderResult(_ typeResult: TypeResult, actions: [TypeAction], startTime: Date) {
        let specialKeys = max(typeResult.keyPresses - typeResult.totalCharacters, 0)
        let result = TypeCommandResult(
            success: true,
            requestedText: self.resolvedText,
            typedText: self.resolvedText,
            keyPresses: typeResult.keyPresses,
            totalCharacters: typeResult.totalCharacters,
            literalCharactersTyped: typeResult.totalCharacters,
            specialKeyPresses: specialKeys,
            actions: actions.map(Self.actionSummary),
            executionTime: Date().timeIntervalSince(startTime),
            wordsPerMinute: self.resolvedProfile == .human ? self.resolvedWordsPerMinute : nil,
            profile: self.resolvedProfile.rawValue
        )

        output(result) {
            print("✅ Typing completed")
            if let typed = self.resolvedText {
                print("⌨️  Typed: \"\(typed)\"")
            }
            if specialKeys > 0 {
                print("🔑 Special keys: \(specialKeys)")
            }
            print("📊 Total characters: \(typeResult.totalCharacters)")
            switch self.resolvedProfile {
            case .human:
                print("🏃‍♀️ Human cadence: \(self.resolvedWordsPerMinute) WPM")
            case .linear:
                print("⚙️  Fixed delay: \(self.delay)ms between keys")
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
        if let delay: Int = try values.decodeOption("delay", as: Int.self) {
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
        self.tab = try values.decodeOption("tab", as: Int.self)
        self.pressReturn = values.flag("pressReturn")
        self.escape = values.flag("escape")
        self.delete = values.flag("delete")
        self.clear = values.flag("clear")
        self.target = try values.makeInteractionTargetOptions()
        self.focusOptions = try values.makeFocusOptions()
    }
}

// MARK: - Conformances

@MainActor
extension TypeCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "type",
                abstract: "Type text or send keyboard input",
                discussion: """
                    The 'type' command sends keyboard input to the focused element.
                    It can type regular text or send special key combinations.

                    EXAMPLES:
                      peekaboo type "Hello World"           # Type text with human cadence (default: 140 WPM)
                      peekaboo type "user@example.com"      # Type email
                      peekaboo type "text" --delay 0        # Type at maximum speed
                      peekaboo type "text" --delay 50       # Type slower (50ms between keys)
                      peekaboo type "text" --wpm 150       # Type like a fast human (150 WPM)
                      peekaboo type "text" --profile linear # Force deterministic linear cadence
                      peekaboo type "password" --return     # Type and press return
                      peekaboo type --tab 3                 # Press tab 3 times
                      peekaboo type "text" --clear          # Clear field first
                      peekaboo type "Line 1\nLine 2"        # Type with newline
                      peekaboo type "Name:\tJohn"           # Type with tab
                      peekaboo type "Path: C:\\data"       # Type literal backslash

                    SPECIAL KEYS:
                      Use flags for special keys:
                      --return    Press return/enter
                      --tab       Press tab (with optional count)
                      --escape    Press escape
                      --delete    Press delete
                      --clear     Clear current field (Cmd+A, Delete)

                    ESCAPE SEQUENCES:
                      Supported escape sequences in text:
                      \\n  - Newline/return
                      \\t  - Tab
                      \\b  - Backspace/delete
                      \\e  - Escape
                      \\\\  - Literal backslash

                    FOCUS MANAGEMENT:
                      Provide --app/--pid/window targeting or a snapshot for focus guarantees.
                      Without a target, keys are injected into the current focused element.

                    HUMAN TYPING:
                    Use --profile human (default) for realistic cadence; override speed with --wpm (80-220).
                    Use --profile linear for deterministic timing via --delay.
                """,

                showHelpOnEmptyInvocation: true
            )
        }
    }
}

extension TypeCommand: AsyncRuntimeCommand {}
