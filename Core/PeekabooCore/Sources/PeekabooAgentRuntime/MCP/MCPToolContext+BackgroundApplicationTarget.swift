import Foundation
import PeekabooAutomationKit
import TachikomaMCP

extension MCPToolContext {
    private struct BackgroundExactWindowSelectorKeys {
        let application: String
        let pid: String?
        let title: String
        let index: String
    }

    private struct BackgroundExactWindowSelector {
        let keys: BackgroundExactWindowSelectorKeys
        let applicationIdentifier: String?
        let selection: ExactWindowSelectorResolver.Selection
        let windowID: Int?
    }

    func backgroundTargetRevalidation(
        _ authorization: BackgroundTargetAuthorization,
        toolName: String) async -> ToolResponse?
    {
        guard let plan = authorization.targetPlan else { return nil }
        let identity = plan.processIdentity
        do {
            let application = try await self.applications.findApplication(
                identifier: "PID:\(identity.processIdentifier)")
            guard application.processStartIdentity == identity.processStartIdentity else {
                return self.executionPolicy.unresolvedTargetRejection(
                    toolName: toolName,
                    detail: "the selected application changed process generation before dispatch")
            }
            if let rejection = self.executionPolicy.systemSurfaceRejection(
                toolName: toolName,
                applicationBundleIdentifier: application.bundleIdentifier,
                applicationName: application.name)
            {
                return rejection
            }
        } catch {
            return self.executionPolicy.unresolvedTargetRejection(
                toolName: toolName,
                detail: "the selected application disappeared before dispatch")
        }

        guard let expectedWindow = plan.targetIdentity.exactWindow else { return nil }
        do {
            let windows = try await self.windows.listWindows(target: .windowId(expectedWindow.identity.windowID))
            guard windows.count == 1,
                  let currentWindow = windows.first,
                  let currentIdentity = currentWindow.mutationIdentity,
                  currentIdentity.hasSameStableReceipt(as: expectedWindow.identity),
                  currentIdentity.capturedBounds == currentWindow.bounds,
                  currentWindow.bounds == expectedWindow.bounds
            else {
                return self.executionPolicy.unresolvedTargetRejection(
                    toolName: toolName,
                    detail: "the selected window changed identity or bounds before dispatch")
            }
        } catch {
            return self.executionPolicy.unresolvedTargetRejection(
                toolName: toolName,
                detail: "the selected window disappeared before dispatch")
        }
        return nil
    }

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
        case "dialog", "paste", "type":
            BackgroundApplicationTargetSchema(
                stringKeys: ["app"],
                pidKeys: ["pid"],
                windowIDKeys: ["window_id"])
        case "window":
            BackgroundApplicationTargetSchema(stringKeys: ["app"], pidKeys: [], windowIDKeys: ["window_id"])
        case "menu":
            BackgroundApplicationTargetSchema(stringKeys: ["app"], pidKeys: [], windowIDKeys: [])
        case "space":
            BackgroundApplicationTargetSchema(stringKeys: ["app"], pidKeys: [], windowIDKeys: ["window_id"])
        default:
            nil
        }
    }

    func backgroundExactWindowTargetAuthorization(
        toolName: String,
        arguments: ToolArguments) async throws -> BackgroundTargetAuthorization?
    {
        guard let selector = try Self.backgroundExactWindowSelector(
            toolName: toolName,
            arguments: arguments)
        else { return nil }

        let explicitlyResolvedApplications = try await self.resolveApplications(
            selector.applicationIdentifier.map { [$0] } ?? [])
        let inventoryTarget: WindowTarget
        if let windowID = selector.windowID {
            inventoryTarget = .windowId(windowID)
        } else if let application = explicitlyResolvedApplications.first {
            inventoryTarget = .application("PID:\(application.processIdentifier)")
        } else {
            throw BackgroundTargetResolutionError(
                "the selected application owner could not be resolved before dispatch")
        }

        let windows: [ServiceWindowInfo]
        do {
            windows = try await self.windows.listWindows(target: inventoryTarget)
        } catch {
            throw BackgroundTargetResolutionError("the selected window inventory could not be resolved before dispatch")
        }
        let selectedWindow: ServiceWindowInfo
        do {
            selectedWindow = try ExactWindowSelectorResolver.select(
                from: windows,
                selection: selector.selection,
                operation: "Background \(toolName)")
        } catch {
            throw BackgroundTargetResolutionError(error.localizedDescription)
        }

        let exactWindowTarget: DesktopTargetIdentity
        do {
            exactWindowTarget = try DesktopTargetIdentity(
                exactWindow: UIAutomationTarget.ExactWindow(window: selectedWindow))
        } catch {
            throw BackgroundTargetResolutionError(
                "the selected window has no generation-pinned identity with immutable bounds")
        }
        let ownerApplications: [ServiceApplicationInfo] = if explicitlyResolvedApplications.isEmpty {
            try await self.resolveApplications([
                "PID:\(exactWindowTarget.processIdentity.processIdentifier)",
            ])
        } else {
            explicitlyResolvedApplications
        }
        let processIdentity = try Self.validatedProcessIdentity(
            applications: ownerApplications,
            windowProcessIdentities: [exactWindowTarget.processIdentity])
        for application in ownerApplications {
            if let rejection = self.executionPolicy.systemSurfaceRejection(
                toolName: toolName,
                applicationBundleIdentifier: application.bundleIdentifier,
                applicationName: application.name)
            {
                return BackgroundTargetAuthorization(arguments: arguments, rejection: rejection, targetPlan: nil)
            }
        }

        let processTarget = try DesktopTargetIdentity(processIdentity: processIdentity)
        let authorizedTarget: DesktopTargetIdentity
        do {
            authorizedTarget = try processTarget.coalescing(exactWindowTarget)
        } catch {
            throw BackgroundTargetResolutionError(
                "the selected application and window identify different process-generation owners")
        }

        var pinned = Self.argumentsPinnedToProcess(
            arguments,
            toolName: toolName,
            processIdentifier: processIdentity.processIdentifier).rawDictionary
        pinned["window_id"] = selectedWindow.windowID
        pinned.removeValue(forKey: selector.keys.title)
        pinned.removeValue(forKey: selector.keys.index)
        return BackgroundTargetAuthorization(
            arguments: ToolArguments(raw: pinned),
            rejection: nil,
            targetPlan: AuthorizedDesktopTargetPlan(
                targetIdentity: authorizedTarget,
                selectedWindow: selectedWindow))
    }

    private static func backgroundExactWindowSelector(
        toolName: String,
        arguments: ToolArguments) throws -> BackgroundExactWindowSelector?
    {
        guard let keys = self.backgroundExactWindowSelectorKeys(toolName: toolName, arguments: arguments) else {
            return nil
        }
        let applicationSelector = self.strictString(arguments, key: keys.application)
        let titleSelector = self.strictString(arguments, key: keys.title)
        guard !applicationSelector.isInvalid else {
            throw BackgroundTargetResolutionError("app must be a nonempty application identifier")
        }
        guard !titleSelector.isInvalid else {
            throw BackgroundTargetResolutionError("\(keys.title) must be a nonempty window title")
        }

        let pid = try keys.pid.flatMap { try arguments.validatedInt($0) }
        guard pid.map({ $0 > 0 && Int32(exactly: $0) != nil }) ?? true else {
            throw BackgroundTargetResolutionError("pid must be a valid positive process identifier")
        }
        guard applicationSelector.value == nil || pid == nil else {
            throw BackgroundTargetResolutionError("app and pid are mutually exclusive")
        }
        let applicationIdentifier = applicationSelector.value ?? pid.map { "PID:\($0)" }

        let windowID = try arguments.validatedInt("window_id")
        let windowIndex = try arguments.validatedInt(keys.index)
        guard windowID.map({ $0 > 0 && UInt32(exactly: $0) != nil }) ?? true else {
            throw BackgroundTargetResolutionError("window_id must be a valid positive WindowServer identifier")
        }
        guard windowIndex.map({ $0 >= 0 }) ?? true else {
            throw BackgroundTargetResolutionError("\(keys.index) must be zero or greater")
        }
        let selectorCount = [windowID != nil, titleSelector.value != nil, windowIndex != nil].count(where: { $0 })
        guard selectorCount <= 1 else {
            throw BackgroundTargetResolutionError("window_id, \(keys.title), and \(keys.index) are mutually exclusive")
        }
        if toolName == "paste", selectorCount == 0 {
            return nil
        }
        guard windowID != nil || applicationIdentifier != nil else {
            throw BackgroundTargetResolutionError(
                "background window mutation requires an application or exact window_id owner")
        }

        let selection: ExactWindowSelectorResolver.Selection = if let windowID {
            .id(windowID)
        } else if let title = titleSelector.value {
            .title(title)
        } else if let windowIndex {
            .index(windowIndex)
        } else {
            .automatic
        }
        return BackgroundExactWindowSelector(
            keys: keys,
            applicationIdentifier: applicationIdentifier,
            selection: selection,
            windowID: windowID)
    }

    private static func backgroundExactWindowSelectorKeys(
        toolName: String,
        arguments: ToolArguments) -> BackgroundExactWindowSelectorKeys?
    {
        switch (toolName, arguments.getString("action")?.lowercased()) {
        case let ("window", action?) where action != "list":
            BackgroundExactWindowSelectorKeys(application: "app", pid: nil, title: "title", index: "index")
        case ("space", "move-window"):
            BackgroundExactWindowSelectorKeys(
                application: "app",
                pid: nil,
                title: "window_title",
                index: "window_index")
        case ("paste", _):
            BackgroundExactWindowSelectorKeys(
                application: "app",
                pid: "pid",
                title: "window_title",
                index: "window_index")
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

    func windowTargetIdentities(
        arguments: ToolArguments,
        keys: [String]) async throws -> [DesktopTargetIdentity]
    {
        var identities: [DesktopTargetIdentity] = []
        for key in keys {
            guard let windowID = arguments.getInt(key) else { continue }
            let windows: [ServiceWindowInfo]
            do {
                windows = try await self.windows.listWindows(target: .windowId(windowID))
            } catch {
                throw BackgroundTargetResolutionError("window_id owner could not be resolved before dispatch")
            }
            guard windows.count == 1, let window = windows.first else {
                throw BackgroundTargetResolutionError(
                    "window_id does not identify exactly one window")
            }
            do {
                try identities.append(DesktopTargetIdentity(
                    exactWindow: UIAutomationTarget.ExactWindow(window: window)))
            } catch {
                throw BackgroundTargetResolutionError(
                    "window_id does not identify one generation-pinned exact window with immutable bounds")
            }
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
        case "dialog", "paste", "type":
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
