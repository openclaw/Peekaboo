import Foundation
import PeekabooAutomationKit
import TachikomaMCP

extension MCPToolContext {
    struct BackgroundApplicationTargetSchema {
        let stringKeys: [String]
        let pidKeys: [String]
        let windowIDKeys: [String]
    }

    struct BackgroundTargetResolutionError: Error {
        let detail: String

        init(_ detail: String) {
            self.detail = detail
        }
    }

    static func backgroundApplicationTargetSchema(toolName: String) -> BackgroundApplicationTargetSchema? {
        // MCP window/space selectors encode a PID as app="PID:<n>"; unlike their CLI adapters they expose no pid key.
        switch toolName {
        case "app":
            BackgroundApplicationTargetSchema(stringKeys: ["name", "bundleId"], pidKeys: [], windowIDKeys: [])
        case "dialog", "type":
            BackgroundApplicationTargetSchema(
                stringKeys: ["app"],
                pidKeys: ["pid"],
                windowIDKeys: ["window_id"])
        case "window":
            BackgroundApplicationTargetSchema(stringKeys: ["app"], pidKeys: [], windowIDKeys: ["window_id"])
        case "menu", "space":
            BackgroundApplicationTargetSchema(stringKeys: ["app"], pidKeys: [], windowIDKeys: [])
        default:
            nil
        }
    }

    static func applicationIdentifiers(
        arguments: ToolArguments,
        schema: BackgroundApplicationTargetSchema) throws -> [String]
    {
        var identifiers: [String] = []
        for key in schema.stringKeys {
            let selector = Self.strictString(arguments, key: key)
            guard !selector.isInvalid else {
                throw BackgroundTargetResolutionError("\(key) must be a nonempty application identifier")
            }
            if let value = selector.value {
                identifiers.append(value)
            }
        }
        for key in schema.pidKeys {
            if let pid = arguments.getInt(key), pid > 0 {
                identifiers.append("PID:\(pid)")
            }
        }
        return identifiers
    }

    func windowProcessIdentities(
        arguments: ToolArguments,
        keys: [String]) async throws -> [ApplicationProcessIdentity]
    {
        var identities: [ApplicationProcessIdentity] = []
        for key in keys {
            guard let windowID = arguments.getInt(key) else { continue }
            let windows: [ServiceWindowInfo]
            do {
                windows = try await self.windows.listWindows(target: .windowId(windowID))
            } catch {
                throw BackgroundTargetResolutionError("window_id owner could not be resolved before dispatch")
            }
            let owners = windows.compactMap { window -> ApplicationProcessIdentity? in
                guard let identity = window.mutationIdentity else { return nil }
                return ApplicationProcessIdentity(
                    processIdentifier: identity.ownerProcessIdentifier,
                    processStartIdentity: identity.ownerProcessStartIdentity)
            }
            guard owners.count == windows.count,
                  let owner = owners.first,
                  owners.allSatisfy({ $0 == owner })
            else {
                throw BackgroundTargetResolutionError(
                    "window_id does not identify one process-generation-pinned owner")
            }
            identities.append(owner)
        }
        return identities
    }

    func resolveApplications(_ identifiers: [String]) async throws -> [ServiceApplicationInfo] {
        do {
            var resolved: [ServiceApplicationInfo] = []
            for identifier in identifiers {
                try await resolved.append(self.applications.findApplication(identifier: identifier))
            }
            return resolved
        } catch {
            throw BackgroundTargetResolutionError(
                "the selected application owner could not be resolved before dispatch")
        }
    }

    static func validatedProcessIdentity(
        applications: [ServiceApplicationInfo],
        windowProcessIdentities: [ApplicationProcessIdentity]) throws -> ApplicationProcessIdentity
    {
        guard Set(applications.map(\.processIdentifier)).count == 1 else {
            throw BackgroundTargetResolutionError(
                "the supplied application and window selectors identify different owners")
        }
        let identities = applications.compactMap { application -> ApplicationProcessIdentity? in
            guard let processStartIdentity = application.processStartIdentity else { return nil }
            return ApplicationProcessIdentity(
                processIdentifier: application.processIdentifier,
                processStartIdentity: processStartIdentity)
        }
        guard identities.count == applications.count,
              let identity = identities.first,
              identities.allSatisfy({ $0 == identity }),
              windowProcessIdentities.allSatisfy({ $0 == identity })
        else {
            throw BackgroundTargetResolutionError(
                "the selected owner has no stable process-generation receipt")
        }
        return identity
    }

    static func argumentsPinnedToProcess(
        _ arguments: ToolArguments,
        toolName: String,
        processIdentifier: Int32) -> ToolArguments
    {
        var pinned = arguments.rawDictionary
        switch toolName {
        case "app":
            pinned["name"] = "PID:\(processIdentifier)"
            pinned.removeValue(forKey: "bundleId")
        case "dialog", "type":
            pinned["pid"] = Int(processIdentifier)
            pinned.removeValue(forKey: "app")
        case "menu", "space", "window":
            pinned["app"] = "PID:\(processIdentifier)"
        default:
            break
        }
        return ToolArguments(raw: pinned)
    }
}
