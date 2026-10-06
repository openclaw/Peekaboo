import Foundation
import PeekabooFoundation

/// The original explicit owner selector for application-owned status items.
public struct MenuBarApplicationScope: Codable, Equatable, Sendable {
    public let applicationIdentifier: String?
    public let processIdentifier: Int32?

    public init(applicationIdentifier: String) throws {
        let identifier = applicationIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { throw PeekabooError.invalidInput("Menu bar --app must not be empty") }
        if identifier.uppercased().hasPrefix("PID:") {
            guard let pid = Int32(identifier.dropFirst(4)), pid > 0 else {
                throw PeekabooError.invalidInput("Menu bar application PID must be a positive process identifier")
            }
        }
        self.applicationIdentifier = identifier
        self.processIdentifier = nil
    }

    public init(processIdentifier: Int32) throws {
        guard processIdentifier > 0 else {
            throw PeekabooError.invalidInput("Menu bar --pid must be a positive process identifier")
        }
        self.applicationIdentifier = nil
        self.processIdentifier = processIdentifier
    }

    public var identifier: String {
        if let applicationIdentifier {
            return applicationIdentifier
        }
        guard let processIdentifier else { preconditionFailure("Validated menu scope has no owner selector") }
        return "PID:\(processIdentifier)"
    }

    public var explicitProcessIdentifier: Int32? {
        if let processIdentifier {
            return processIdentifier
        }
        guard let applicationIdentifier, applicationIdentifier.uppercased().hasPrefix("PID:") else { return nil }
        return Int32(applicationIdentifier.dropFirst(4))
    }

    func matches(_ application: ServiceApplicationInfo) -> Bool {
        guard let kind = ApplicationIdentifierMatcher.matchKind(
            for: .init(application), identifier: self.identifier)
        else { return false }
        return [.processIdentifier, .bundleIdentifier, .exactName].contains(kind)
    }

    private enum CodingKeys: String, CodingKey { case applicationIdentifier, processIdentifier }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let app = try values.decodeIfPresent(String.self, forKey: .applicationIdentifier)
        let pid = try values.decodeIfPresent(Int32.self, forKey: .processIdentifier)
        do {
            if let app, pid == nil {
                try self.init(applicationIdentifier: app)
            } else if let pid, app == nil {
                try self.init(processIdentifier: pid)
            } else {
                throw PeekabooError.invalidInput("Menu bar application scope requires exactly one app or PID")
            }
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .applicationIdentifier, in: values, debugDescription: error.localizedDescription)
        }
    }
}

/// Read-only preparation inside one explicitly selected application, never a global AX sweep.
public struct MenuBarItemPreparationRequest: Codable, Equatable, Sendable {
    public let name: String
    public let applicationScope: MenuBarApplicationScope

    public init(name: String, applicationScope: MenuBarApplicationScope) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PeekabooError.invalidInput("A scoped menu bar click requires an item name")
        }
        self.name = name
        self.applicationScope = applicationScope
    }

    private enum CodingKeys: String, CodingKey { case name, applicationScope }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                name: values.decode(String.self, forKey: .name),
                applicationScope: values.decode(MenuBarApplicationScope.self, forKey: .applicationScope))
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: values, debugDescription: error.localizedDescription)
        }
    }
}
