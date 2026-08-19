import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
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
        let selector: InteractionTargetSelector
    }

    @MainActor
    func backgroundTargetRevalidation(
        _ authorization: BackgroundTargetAuthorization,
        toolName: String) async throws -> ToolResponse?
    {
        guard let plan = authorization.targetPlan else { return nil }
        guard let authority = plan.mutationAuthority else {
            return self.executionPolicy.unresolvedTargetRejection(
                toolName: toolName,
                detail: "the selected target has no shared mutation authority")
        }
        let planner = DesktopTargetPlanning.MutationAuthorityPlanner(
            applications: self.applications,
            windows: self.windows)
        do {
            let current = try await planner.revalidate(authority)
            _ = try plan.targetIdentity.coalescing(current.targetIdentity)
            let application = current.application.application
            return self.executionPolicy.systemSurfaceRejection(
                toolName: toolName,
                applicationBundleIdentifier: application.bundleIdentifier,
                applicationName: application.name)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            let detail = plan.targetIdentity.exactWindow == nil
                ? "the selected application changed process generation before dispatch"
                : "the selected window changed identity or bounds before dispatch"
            return self.executionPolicy.unresolvedTargetRejection(
                toolName: toolName,
                detail: detail)
        }
    }

    @MainActor
    func backgroundSnapshotTargetPlan(
        snapshotID: String,
        mirroredSnapshot: UISnapshot,
        detectionResult: ElementDetectionResult) async throws -> AuthorizedDesktopTargetPlan
    {
        let mirroredReceipt = try mirroredSnapshot.targetReceipt()
        let mirroredIdentity = try mirroredReceipt.requireIdentity()
        if let mirroredName = Self.nonEmpty(mirroredReceipt.applicationName),
           let detectionName = Self.nonEmpty(detectionResult.metadata.windowContext?.applicationName),
           mirroredName.caseInsensitiveCompare(detectionName) != .orderedSame
        {
            throw DesktopTargetIdentityError.snapshotSourceMismatch
        }
        guard mirroredIdentity.exactWindow != nil else { throw DesktopTargetIdentityError.incompleteExactWindow }
        let identity = try SnapshotTargetReceiptPlanner.assemble(
            snapshotID: snapshotID,
            detectionResult: detectionResult,
            additionalEvidence: [.init(target: mirroredIdentity)],
            applicationName: mirroredReceipt.applicationName).receipt.requireIdentity()
        let authority = try await self.sharedMutationAuthority(for: identity)
        return try AuthorizedDesktopTargetPlan(mutationAuthority: authority)
    }

    @MainActor
    func sharedMutationAuthority(
        for identity: DesktopTargetIdentity) async throws -> DesktopTargetPlanning.MutationAuthorityPlan
    {
        let planner = DesktopTargetPlanning.MutationAuthorityPlanner(
            applications: self.applications,
            windows: self.windows)
        let authority = try await planner.plan(
            selector: InteractionTargetSelector(
                processIdentifier: Int(identity.processIdentity.processIdentifier),
                windowID: identity.exactWindow?.identity.windowID),
            expectedProcessIdentity: identity.processIdentity)
        _ = try identity.coalescing(authority.targetIdentity)
        return authority
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

    @MainActor
    func backgroundExactWindowTargetAuthorization(
        toolName: String,
        arguments: ToolArguments) async throws -> BackgroundTargetAuthorization?
    {
        guard let selector = try Self.backgroundExactWindowSelector(
            toolName: toolName,
            arguments: arguments)
        else { return nil }

        let planner = DesktopTargetPlanning.MutationAuthorityPlanner(
            applications: self.applications,
            windows: self.windows)
        let authority: DesktopTargetPlanning.MutationAuthorityPlan
        do {
            let automaticSelection: DesktopTargetPlanning.WindowSelectionPolicy =
                toolName == "window" && arguments.getString("action")?.lowercased() == "restore"
                    ? .preferredMutationWindow(.restore)
                    : .preferredMutationWindow(.general)
            authority = try await planner.plan(
                selector: selector.selector,
                requirement: .exactWindow(automaticSelection: automaticSelection))
        } catch {
            throw BackgroundTargetResolutionError(error.localizedDescription)
        }
        guard let windowPlan = authority.window else {
            throw BackgroundTargetResolutionError(
                "background \(toolName) did not resolve one exact window authority")
        }
        let application = authority.application.application
        if let rejection = self.executionPolicy.systemSurfaceRejection(
            toolName: toolName,
            applicationBundleIdentifier: application.bundleIdentifier,
            applicationName: application.name)
        {
            return BackgroundTargetAuthorization(arguments: arguments, rejection: rejection, targetPlan: nil)
        }

        var pinned = Self.argumentsPinnedToProcess(
            arguments,
            toolName: toolName,
            processIdentifier: authority.application.processIdentity.processIdentifier).rawDictionary
        pinned["window_id"] = windowPlan.identity.windowID
        pinned.removeValue(forKey: selector.keys.title)
        pinned.removeValue(forKey: selector.keys.index)
        return try BackgroundTargetAuthorization(
            arguments: ToolArguments(raw: pinned),
            rejection: nil,
            targetPlan: AuthorizedDesktopTargetPlan(mutationAuthority: authority))
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
        guard windowID != nil || applicationSelector.value != nil || pid != nil else {
            throw BackgroundTargetResolutionError(
                "background window mutation requires an application or exact window_id owner")
        }
        return BackgroundExactWindowSelector(
            keys: keys,
            selector: InteractionTargetSelector(
                applicationIdentifier: applicationSelector.value,
                processIdentifier: pid,
                windowID: windowID,
                windowTitle: titleSelector.value,
                windowIndex: windowIndex))
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

    @MainActor
    func resolveApplicationAuthorities(
        _ identifiers: [String]) async throws -> [DesktopTargetPlanning.MutationAuthorityPlan]
    {
        let planner = DesktopTargetPlanning.MutationAuthorityPlanner(
            applications: self.applications,
            windows: self.windows)
        do {
            var resolved: [DesktopTargetPlanning.MutationAuthorityPlan] = []
            var expectedIdentity: ApplicationProcessIdentity?
            for identifier in identifiers {
                let authority = try await planner.plan(
                    selector: InteractionTargetSelector(applicationIdentifier: identifier),
                    expectedProcessIdentity: expectedIdentity)
                expectedIdentity = authority.application.processIdentity
                resolved.append(authority)
            }
            return resolved
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BackgroundTargetResolutionError(
                error.localizedDescription)
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
