import Foundation

/// Parser-neutral syntax for one application/window target.
///
/// The raw optional strings intentionally preserve whether a caller supplied an empty value. Surface
/// adapters keep their shipped error wording while sharing normalization and combination rules here.
public struct InteractionTargetSelector: Equatable, Sendable {
    public enum WindowSelector: Equatable, Sendable {
        case id(Int)
        case title(String)
        case index(Int)
    }

    public enum Policy: Equatable, Sendable {
        /// CLI and MCP interaction grammar.
        case interaction
        /// Dialog grammar, including its existing nonempty-string requirements.
        case dialogOwnerRequired
        /// MCP Window compatibility grammar, where a title may be global and legacy selector precedence remains.
        case windowGlobalTitleAllowed
        /// CLI Window compatibility grammar, including redundant `--app PID:n --pid n` support.
        case windowCLI(allowMissingTarget: Bool = false)
        /// Strict syntax for mutation planners. Selection and dispatch are deliberately outside this value.
        case mutationSafe
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case applicationAndProcessIdentifier
        case conflictingProcessIdentifiers(application: Int32, explicit: Int32)
        case invalidApplicationProcessIdentifier
        case multipleWindowSelectors
        case windowSelectorRequiresApplication
        case missingTarget
        case emptyApplication
        case emptyWindowTitle
        case invalidProcessIdentifier
        case invalidWindowID
        case invalidWindowIndex
    }

    /// Original application channel, before whitespace normalization.
    public let applicationIdentifier: String?
    /// Original PID channel. `Int` retains out-of-range input until policy validation.
    public let rawProcessIdentifier: Int?
    /// Original window-id channel.
    public let windowID: Int?
    /// Original title channel, before whitespace normalization.
    public let windowTitle: String?
    /// Original index channel.
    public let windowIndex: Int?

    public init(
        applicationIdentifier: String? = nil,
        processIdentifier: Int? = nil,
        windowID: Int? = nil,
        windowTitle: String? = nil,
        windowIndex: Int? = nil)
    {
        self.applicationIdentifier = applicationIdentifier
        self.rawProcessIdentifier = processIdentifier
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.windowIndex = windowIndex
    }

    public var normalizedApplicationIdentifier: String? {
        Self.normalized(self.applicationIdentifier)
    }

    public var processIdentifier: Int32? {
        self.rawProcessIdentifier.flatMap(Int32.init(exactly:))
    }

    public var normalizedWindowTitle: String? {
        Self.normalized(self.windowTitle)
    }

    public var hasAnyInput: Bool {
        self.applicationIdentifier != nil || self.rawProcessIdentifier != nil || self.windowID != nil ||
            self.windowTitle != nil || self.windowIndex != nil
    }

    public var hasOwnerInput: Bool {
        self.applicationIdentifier != nil || self.rawProcessIdentifier != nil
    }

    public var hasWindowInput: Bool {
        self.windowID != nil || self.windowTitle != nil || self.windowIndex != nil
    }

    /// Returns the normalized selector using the shipped precedence for the requested surface.
    /// Policies that require exclusivity validate before returning.
    public func normalizedWindowSelector(policy: Policy) throws -> WindowSelector? {
        try self.validate(policy: policy)
        if let windowID = self.windowID {
            return .id(windowID)
        }
        if let title = self.normalizedWindowTitle {
            return .title(title)
        }
        if let windowIndex = self.windowIndex {
            return .index(windowIndex)
        }
        return nil
    }

    /// Resolves only the selector syntax. It does not look up or select an application.
    public func normalizedApplicationTarget(policy: Policy) throws -> String? {
        try self.validate(policy: policy)
        switch (self.applicationIdentifier, self.rawProcessIdentifier) {
        case (nil, nil):
            return nil
        case (_?, nil):
            return self.normalizedApplicationIdentifier
        case (nil, let processIdentifier?):
            guard let pid = Int32(exactly: processIdentifier) else {
                throw ValidationError.invalidProcessIdentifier
            }
            return "PID:\(pid)"
        case let (application?, processIdentifier?):
            guard case .windowCLI = policy else {
                throw ValidationError.applicationAndProcessIdentifier
            }
            guard let explicitPID = Int32(exactly: processIdentifier), explicitPID > 0 else {
                throw ValidationError.invalidProcessIdentifier
            }
            guard let applicationPID = Self.pid(fromApplicationIdentifier: application) else {
                if Self.looksLikePIDIdentifier(application) {
                    throw ValidationError.invalidApplicationProcessIdentifier
                }
                throw ValidationError.applicationAndProcessIdentifier
            }
            guard applicationPID == explicitPID else {
                throw ValidationError.conflictingProcessIdentifiers(
                    application: applicationPID,
                    explicit: explicitPID)
            }
            return self.normalizedApplicationIdentifier
        }
    }

    public func validate(policy: Policy) throws {
        switch policy {
        case .interaction:
            try self.validateInteractionGrammar(allowsGlobalTitle: false, rejectsEmptyStrings: false)

        case .dialogOwnerRequired:
            try self.validateInteractionGrammar(allowsGlobalTitle: false, rejectsEmptyStrings: true)
            try self.validateNumericRanges()

        case .windowGlobalTitleAllowed:
            // Preserve the shipped MCP Window selector precedence in slice 1. Strict mutation syntax
            // is admitted only by `.mutationSafe` in the follow-up planning slice.
            break

        case let .windowCLI(allowMissingTarget):
            if !allowMissingTarget,
               self.applicationIdentifier == nil,
               self.rawProcessIdentifier == nil,
               self.windowID == nil
            {
                throw ValidationError.missingTarget
            }
            if let windowID = self.windowID, windowID <= 0 {
                throw ValidationError.invalidWindowID
            }
            if let windowIndex = self.windowIndex, windowIndex < 0 {
                throw ValidationError.invalidWindowIndex
            }
            if self.applicationIdentifier != nil, self.rawProcessIdentifier != nil {
                _ = try self.normalizedApplicationTargetForWindowCLI()
            }

        case .mutationSafe:
            try self.validateInteractionGrammar(
                allowsGlobalTitle: false,
                rejectsEmptyStrings: true)
            try self.validateNumericRanges()
        }
    }

    private func validateInteractionGrammar(
        allowsGlobalTitle: Bool,
        rejectsEmptyStrings: Bool) throws
    {
        if rejectsEmptyStrings {
            if self.applicationIdentifier != nil, self.normalizedApplicationIdentifier == nil {
                throw ValidationError.emptyApplication
            }
            if self.windowTitle != nil, self.normalizedWindowTitle == nil {
                throw ValidationError.emptyWindowTitle
            }
        }

        do {
            try InteractionTargetSelectorValidator.validate(
                hasApplication: self.applicationIdentifier != nil,
                hasProcessIdentifier: self.rawProcessIdentifier != nil,
                hasWindowID: self.windowID != nil,
                hasWindowTitle: allowsGlobalTitle ? false : self.windowTitle != nil,
                hasWindowIndex: self.windowIndex != nil)
        } catch let error as InteractionTargetSelectorValidationError {
            switch error {
            case .applicationAndProcessIdentifier:
                throw ValidationError.applicationAndProcessIdentifier
            case .multipleWindowSelectors:
                throw ValidationError.multipleWindowSelectors
            case .windowSelectorRequiresApplication:
                throw ValidationError.windowSelectorRequiresApplication
            }
        }

        if allowsGlobalTitle {
            let windowSelectorCount = [self.windowID != nil, self.windowTitle != nil, self.windowIndex != nil]
                .count(where: { $0 })
            if windowSelectorCount > 1 {
                throw ValidationError.multipleWindowSelectors
            }
        }
    }

    private func validateNumericRanges() throws {
        if let processIdentifier = self.rawProcessIdentifier,
           processIdentifier <= 0 || Int32(exactly: processIdentifier) == nil
        {
            throw ValidationError.invalidProcessIdentifier
        }
        if let windowID,
           windowID <= 0 || UInt32(exactly: windowID) == nil
        {
            throw ValidationError.invalidWindowID
        }
        if let windowIndex, windowIndex < 0 {
            throw ValidationError.invalidWindowIndex
        }
    }

    private func normalizedApplicationTargetForWindowCLI() throws -> String? {
        switch (self.applicationIdentifier, self.rawProcessIdentifier) {
        case (nil, nil):
            return nil
        case (let application?, nil):
            return application
        case (nil, let processIdentifier?):
            if let pid = Int32(exactly: processIdentifier) {
                return "PID:\(pid)"
            } else {
                throw ValidationError.invalidProcessIdentifier
            }
        case let (application?, processIdentifier?):
            guard let explicitPID = Int32(exactly: processIdentifier) else {
                throw ValidationError.invalidProcessIdentifier
            }
            guard let applicationPID = Self.pid(fromApplicationIdentifier: application) else {
                if Self.looksLikePIDIdentifier(application) {
                    throw ValidationError.invalidApplicationProcessIdentifier
                }
                throw ValidationError.applicationAndProcessIdentifier
            }
            guard applicationPID == explicitPID else {
                throw ValidationError.conflictingProcessIdentifiers(
                    application: applicationPID,
                    explicit: explicitPID)
            }
            return application
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func looksLikePIDIdentifier(_ value: String) -> Bool {
        value.hasPrefix("PID:")
    }

    private static func pid(fromApplicationIdentifier value: String) -> Int32? {
        guard value.hasPrefix("PID:") else { return nil }
        return Int32(value.dropFirst("PID:".count))
    }
}
