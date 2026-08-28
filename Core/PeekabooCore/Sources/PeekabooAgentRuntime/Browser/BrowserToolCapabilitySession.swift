import Foundation
import MCP
import TachikomaMCP

/// One caller-owned namespace for browser page and element capabilities.
///
/// Chrome DevTools MCP exposes process-local integers and snapshot-local UIDs. They are provider
/// implementation details, not authority. This store keeps those values private and only resolves
/// opaque references minted by the same caller, connection, page, and navigation generation.
actor BrowserToolCapabilitySession {
    struct ElementBinding: Equatable, Sendable {
        let backendNodeID: Int64?
        let frameID: String?
        let loaderID: String?
        let navigationID: String?
    }

    private struct ConnectionBinding: Equatable {
        let sessionBinding: BrowserMCPExecutionSessionBinding
    }

    private struct ElementRecord {
        let providerUID: String
        let snapshotReference: String
        let pageReference: String
        let navigationGeneration: UInt64
        let binding: ElementBinding
    }

    private struct SnapshotRecord {
        let pageReference: String
        let navigationGeneration: UInt64
        var elementReferencesByProviderUID: [String: String]
    }

    private struct PageRecord {
        let reference: String
        let providerPageID: Int
        let connection: ConnectionBinding
        var url: String?
        var title: String?
        var navigationGeneration: UInt64
        var snapshotReferences: Set<String>
    }

    struct ResolvedArguments {
        let arguments: ToolArguments
        let pageReference: String?
        let providerPageID: Int?
        let providerUIDs: Set<String>
    }

    private var pagesByReference: [String: PageRecord] = [:]
    private var pageReferenceByProviderID: [Int: String] = [:]
    private var snapshotsByReference: [String: SnapshotRecord] = [:]
    private var elementsByReference: [String: ElementRecord] = [:]
    private let operationGate = MCPToolSnapshotExecutionGate()
    private var endTask: Task<Void, Never>?
    private var ended = false

    func withExclusiveOperation<Result: Sendable>(
        _ operation: @MainActor @Sendable () async throws -> Result) async throws -> Result
    {
        try await self.operationGate.acquire()
        guard !self.ended else {
            await self.operationGate.release()
            throw BrowserToolCapabilityError.sessionEnded
        }
        do {
            let result = try await operation()
            await self.operationGate.release()
            return result
        } catch {
            await self.operationGate.release()
            throw error
        }
    }

    func resolve(
        action: BrowserAction,
        arguments: ToolArguments,
        sessionBinding: BrowserMCPExecutionSessionBinding?) throws -> ResolvedArguments
    {
        guard !self.ended else { throw BrowserToolCapabilityError.sessionEnded }
        guard Self.actionUsesPage(action, arguments: arguments) else {
            return ResolvedArguments(
                arguments: arguments,
                pageReference: nil,
                providerPageID: nil,
                providerUIDs: [])
        }
        guard let sessionBinding else { throw BrowserToolCapabilityError.connectionUnavailable }
        guard let pageReference = arguments.getString("page_id") else {
            throw BrowserToolCapabilityError.invalidPageReference
        }
        guard let page = self.pagesByReference[pageReference] else {
            throw BrowserToolCapabilityReference.isValid(pageReference, prefix: "bp1")
                ? BrowserToolCapabilityError.stalePageReference
                : BrowserToolCapabilityError.invalidPageReference
        }
        guard page.connection == ConnectionBinding(sessionBinding: sessionBinding) else {
            throw BrowserToolCapabilityError.stalePageReference
        }

        var raw = arguments.rawDictionary
        var providerUIDs = Set<String>()
        raw["page_id"] = page.providerPageID
        if let providerUID = try self.resolveElementArgument("uid", in: &raw, page: page) {
            providerUIDs.insert(providerUID)
        }
        if let providerUID = try self.resolveElementArgument("to_uid", in: &raw, page: page) {
            providerUIDs.insert(providerUID)
        }
        if let json = raw["mcp_args_json"] as? String {
            let toolName = action == .call ? arguments.getString("mcp_tool") : action == .fillForm ? "fill_form" : nil
            if let toolName,
               let contract = BrowserMCPPageRoutingContract.capabilityContract(for: toolName)
            {
                raw["mcp_args_json"] = try self.resolvingElementReferences(
                    inJSON: json,
                    contract: contract,
                    page: page,
                    providerUIDs: &providerUIDs)
            }
        }
        return ResolvedArguments(
            arguments: ToolArguments(raw: raw),
            pageReference: pageReference,
            providerPageID: page.providerPageID,
            providerUIDs: providerUIDs)
    }

    func project(
        _ response: ToolResponse,
        calls: [BrowserMCPMappedCall],
        resolved: ResolvedArguments?,
        sessionBinding: BrowserMCPExecutionSessionBinding?) throws -> ToolResponse
    {
        guard !self.ended else { throw BrowserToolCapabilityError.sessionEnded }
        let contracts = calls.compactMap { call in
            BrowserMCPPageRoutingContract.capabilityContract(for: call.toolName, arguments: call.arguments)
        }
        guard let sessionBinding else {
            self.applyEffects(contracts, resolved: resolved)
            return response
        }
        let selectedPageMappings = self.pageMappings().filter { $0.value == resolved?.pageReference }
        let retainedElementMappings = self.elementMappings(for: resolved?.pageReference)
        let inputElementMappings = retainedElementMappings.filter { resolved?.providerUIDs.contains($0.key) == true }
        self.applyEffects(contracts, resolved: resolved)
        if response.isError {
            return BrowserToolCapabilityProjection.sanitizingProviderError(response)
        }
        let responseProjection = contracts.last?.responseProjection ?? .none
        if Self.responseCreatesSnapshot(responseProjection, response: response) {
            self.invalidateSnapshots(for: resolved?.pageReference)
        }

        let rawStructuredMessage = response.structuredContent?.objectValue?["message"]?.stringValue
        var structured = response.structuredContent
        var textMappings = selectedPageMappings
        if responseProjection == .pages {
            var currentPageMappings: [String: String] = [:]
            if var value = structured {
                currentPageMappings = try self.projectPages(
                    in: &value,
                    connection: ConnectionBinding(sessionBinding: sessionBinding))
                structured = value
            }
            if currentPageMappings.isEmpty {
                currentPageMappings = self.projectPages(
                    inText: Self.textContent(response),
                    connection: ConnectionBinding(sessionBinding: sessionBinding))
            }
            textMappings = currentPageMappings
        }

        var snapshotReference: String?
        var elementMappings: [String: String] = [:]
        if let pageReference = resolved?.pageReference,
           Self.responseMayContainSnapshot(responseProjection, response: response),
           var value = structured
        {
            (snapshotReference, elementMappings) = try self.projectSnapshot(
                in: &value,
                pageReference: pageReference)
            structured = value
        }

        if snapshotReference == nil,
           Self.responseMayContainSnapshot(responseProjection, response: response)
        {
            throw BrowserToolCapabilityError.invalidProviderResponse
        }
        if snapshotReference != nil,
           Self.responseMayContainSnapshot(responseProjection, response: response)
        {
            let snapshotText = responseProjection == .thirdPartySnapshot
                ? BrowserToolCapabilityProjection.thirdPartySnapshotSection(in: Self.textContent(response)) ?? ""
                : Self.textContent(response)
            if !snapshotText.isEmpty,
               !BrowserToolCapabilityProjection.snapshotRowsAreUnambiguous(
                   in: snapshotText,
                   mappings: elementMappings)
            {
                throw BrowserToolCapabilityError.invalidProviderResponse
            }
        }
        if responseProjection == .thirdPartySnapshot,
           ([rawStructuredMessage] + response.content.compactMap { item -> String? in
               guard case let .text(text, _, _) = item else { return nil }
               return text
           }).compactMap(\.self).contains(where: { text in
               BrowserToolCapabilityProjection.containsUnmappedThirdPartyProviderUID(
                   text,
                   mappings: elementMappings)
           })
        {
            throw BrowserToolCapabilityError.invalidProviderResponse
        }
        if calls.contains(where: { $0.toolName == "get_console_message" }),
           BrowserToolCapabilityProjection.containsUnmappedIssueResourceUID(
               in: structured,
               mappings: retainedElementMappings) ||
           response.content.contains(where: { item in
               guard case let .text(text, _, _) = item else { return false }
               return BrowserToolCapabilityProjection.containsUnmappedIssueResourceUID(
                   in: text,
                   mappings: retainedElementMappings)
           })
        {
            throw BrowserToolCapabilityError.invalidProviderResponse
        }

        let thirdPartyMessageProjection: (raw: String, projected: String)? = if
            responseProjection == .thirdPartySnapshot,
            let rawStructuredMessage,
            let projected = BrowserToolCapabilityProjection.projectingThirdPartyJSON(
                rawStructuredMessage,
                mappings: elementMappings)
        {
            (rawStructuredMessage, projected)
        } else {
            nil
        }
        let providerProjection = BrowserToolCapabilityProjection.ProviderProjection(
            pageMappings: responseProjection == .pages ? textMappings : [:],
            structuralElementMappings: elementMappings,
            issueElementMappings: calls.contains(where: { $0.toolName == "get_console_message" })
                ? retainedElementMappings
                : [:],
            phraseElementMappings: calls.contains(where: { $0.toolName == "take_screenshot" })
                ? inputElementMappings
                : [:],
            calls: calls,
            thirdPartyMessage: thirdPartyMessageProjection)
        structured = BrowserToolCapabilityProjection.projectingProviderMessages(
            in: structured,
            projection: providerProjection)

        let projectedPageMappings = textMappings
        let content = BrowserToolCapabilityProjection.projectingContent(
            response.content,
            projection: .init(
                responseProjection: responseProjection,
                provider: providerProjection,
                thirdPartyElementMappings: elementMappings,
                mayContainSnapshot: resolved?.pageReference != nil &&
                    Self.responseMayContainSnapshot(responseProjection, response: response)))

        var meta = response.meta?.objectValue ?? [:]
        if let existing = response.meta, existing.objectValue == nil {
            meta["provider_payload"] = existing
        }
        if let snapshotReference {
            meta["browser_snapshot_ref"] = .string(snapshotReference)
        }
        if !projectedPageMappings.isEmpty {
            meta["browser_page_refs"] = .array(projectedPageMappings.values.sorted().map(Value.string))
        }
        if case let .object(projectedMeta) = BrowserToolCapabilityProjection.projectingProviderMessages(
            in: .object(meta),
            projection: providerProjection)
        {
            meta = projectedMeta
        }
        return ToolResponse(
            content: content,
            isError: response.isError,
            meta: meta.isEmpty ? nil : .object(meta),
            structuredContent: structured)
    }

    func observeStatus(_ status: BrowserMCPStatus) {
        if status.observation == .confirmed, !status.isConnected {
            self.invalidateAll()
            return
        }
        guard let receipt = status.connectionReceipt,
              let providerSessionEpoch = status.providerSessionEpoch
        else {
            self.invalidateAll()
            return
        }
        let connection = ConnectionBinding(sessionBinding: .init(
            connectionReceipt: receipt,
            providerSessionEpoch: providerSessionEpoch))
        let stalePages = self.pagesByReference.values
            .filter { $0.connection != connection }
            .map(\.reference)
        for reference in stalePages {
            self.removePage(reference: reference)
        }
    }

    func end() async {
        if let endTask = self.endTask {
            await endTask.value
            return
        }
        let endTask = Task { await self.finishEnd() }
        self.endTask = endTask
        await endTask.value
    }

    private func finishEnd() async {
        do {
            try await self.operationGate.acquire()
        } catch {
            return
        }
        self.invalidateAll()
        self.ended = true
        await self.operationGate.release()
    }

    func disconnect() {
        self.invalidateAll()
    }

    func invalidateAfterProviderEntry(calls: [BrowserMCPMappedCall], resolved: ResolvedArguments?) {
        let contracts = calls.compactMap { call in
            BrowserMCPPageRoutingContract.capabilityContract(for: call.toolName, arguments: call.arguments)
        }
        self.applyEffects(contracts, resolved: resolved)
    }

    func elementBinding(for reference: String) -> ElementBinding? {
        self.elementsByReference[reference]?.binding
    }

    private func pageMappings() -> [String: String] {
        Dictionary(uniqueKeysWithValues: self.pageReferenceByProviderID.map { (String($0.key), $0.value) })
    }

    private func elementMappings(for pageReference: String?) -> [String: String] {
        guard let pageReference else { return [:] }
        return Dictionary(uniqueKeysWithValues: self.elementsByReference.compactMap { reference, record in
            record.pageReference == pageReference ? (record.providerUID, reference) : nil
        })
    }

    private func resolveElementArgument(
        _ key: String,
        in raw: inout [String: Any],
        page: PageRecord) throws -> String?
    {
        guard let reference = raw[key] as? String else { return nil }
        let providerUID = try self.resolveElement(reference, page: page)
        raw[key] = providerUID
        return providerUID
    }

    private func resolveElement(_ reference: String, page: PageRecord) throws -> String {
        guard let element = self.elementsByReference[reference] else {
            throw BrowserToolCapabilityReference.isValid(reference, prefix: "be1")
                ? BrowserToolCapabilityError.staleElementReference
                : BrowserToolCapabilityError.invalidElementReference
        }
        guard element.pageReference == page.reference,
              element.navigationGeneration == page.navigationGeneration,
              let snapshot = self.snapshotsByReference[element.snapshotReference],
              snapshot.pageReference == page.reference,
              snapshot.navigationGeneration == page.navigationGeneration
        else {
            throw BrowserToolCapabilityError.staleElementReference
        }
        return element.providerUID
    }

    private func resolvingElementReferences(
        inJSON json: String,
        contract: BrowserMCPToolCapabilityContract,
        page: PageRecord,
        providerUIDs: inout Set<String>) throws -> String
    {
        guard let data = json.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw BrowserToolCapabilityError.invalidJSON
        }
        for input in contract.elementInputs {
            switch input {
            case let .direct(key):
                if let reference = object[key] as? String {
                    let providerUID = try self.resolveElement(reference, page: page)
                    object[key] = providerUID
                    providerUIDs.insert(providerUID)
                }
            case let .objectArray(arrayKey, elementKey):
                guard var elements = object[arrayKey] as? [[String: Any]] else { continue }
                for index in elements.indices {
                    if let reference = elements[index][elementKey] as? String {
                        let providerUID = try self.resolveElement(reference, page: page)
                        elements[index][elementKey] = providerUID
                        providerUIDs.insert(providerUID)
                    }
                }
                object[arrayKey] = elements
            case let .stringArray(key):
                guard let references = object[key] as? [String] else { continue }
                object[key] = try references.map { reference in
                    let providerUID = try self.resolveElement(reference, page: page)
                    providerUIDs.insert(providerUID)
                    return providerUID
                }
            case let .decodedSingletonObjectValues(key):
                guard let encodedParameters = object[key] as? String,
                      let data = encodedParameters.data(using: .utf8),
                      var parameters = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                for (parameterName, value) in parameters {
                    guard var referenceObject = value as? [String: Any],
                          referenceObject.count == 1,
                          let reference = referenceObject["uid"] as? String
                    else { continue }
                    let providerUID = try self.resolveElement(reference, page: page)
                    referenceObject["uid"] = providerUID
                    providerUIDs.insert(providerUID)
                    parameters[parameterName] = referenceObject
                }
                let encoded = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
                guard let string = String(data: encoded, encoding: .utf8) else {
                    throw BrowserToolCapabilityError.invalidJSON
                }
                object[key] = string
            }
        }
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let result = String(data: encoded, encoding: .utf8) else {
            throw BrowserToolCapabilityError.invalidJSON
        }
        return result
    }

    private func projectPages(
        in structured: inout Value,
        connection: ConnectionBinding) throws -> [String: String]
    {
        guard case var .object(root) = structured else { return [:] }
        let keys = ["pages", "extensionPages"]
        var liveProviderIDs = Set<Int>()
        var mapping: [String: String] = [:]
        for key in keys {
            guard case var .array(pages)? = root[key] else { continue }
            for index in pages.indices {
                guard case var .object(page) = pages[index],
                      let providerPageID = page["id"]?.intValue
                else { throw BrowserToolCapabilityError.invalidProviderResponse }
                liveProviderIDs.insert(providerPageID)
                let url = page["url"]?.stringValue
                let title = page["title"]?.stringValue
                let reference = self.upsertPage(
                    providerPageID: providerPageID,
                    connection: connection,
                    url: url,
                    title: title)
                page["id"] = .string(reference)
                page["page_ref"] = .string(reference)
                pages[index] = .object(page)
                mapping[String(providerPageID)] = reference
            }
            root[key] = .array(pages)
        }
        if keys.contains(where: { root[$0] != nil }) {
            let stale = self.pageReferenceByProviderID
                .filter { !liveProviderIDs.contains($0.key) }
                .map(\.value)
            for reference in stale {
                self.removePage(reference: reference)
            }
        }
        structured = .object(root)
        return mapping
    }

    private func upsertPage(
        providerPageID: Int,
        connection: ConnectionBinding,
        url: String?,
        title: String?) -> String
    {
        if let reference = self.pageReferenceByProviderID[providerPageID],
           var page = self.pagesByReference[reference],
           page.connection == connection
        {
            if let url, page.url != nil, page.url != url {
                self.invalidateSnapshots(for: reference)
                page.navigationGeneration &+= 1
            }
            page.url = url ?? page.url
            page.title = title ?? page.title
            self.pagesByReference[reference] = page
            return reference
        }
        if let stale = self.pageReferenceByProviderID[providerPageID] {
            self.removePage(reference: stale)
        }
        let reference = Self.reference(prefix: "bp1")
        self.pagesByReference[reference] = PageRecord(
            reference: reference,
            providerPageID: providerPageID,
            connection: connection,
            url: url,
            title: title,
            navigationGeneration: 0,
            snapshotReferences: [])
        self.pageReferenceByProviderID[providerPageID] = reference
        return reference
    }

    private func projectPages(
        inText text: String,
        connection: ConnectionBinding) -> [String: String]
    {
        guard text.contains("## Pages") || text.contains("## Extension Pages") else { return [:] }
        var liveProviderIDs = Set<Int>()
        var mapping: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: ":"),
                  let providerPageID = Int(line[..<separator])
            else { continue }
            liveProviderIDs.insert(providerPageID)
            let suffix = String(line[line.index(after: separator)...])
            let url = Self.lastParenthesizedValue(in: suffix)
            let reference = self.upsertPage(
                providerPageID: providerPageID,
                connection: connection,
                url: url,
                title: nil)
            mapping[String(providerPageID)] = reference
        }
        let stale = self.pageReferenceByProviderID
            .filter { !liveProviderIDs.contains($0.key) }
            .map(\.value)
        for reference in stale {
            self.removePage(reference: reference)
        }
        return mapping
    }

    private func projectSnapshot(
        in structured: inout Value,
        pageReference: String) throws -> (String?, [String: String])
    {
        guard case var .object(root) = structured, var snapshot = root["snapshot"] else {
            return (nil, [:])
        }
        var bindings: [String: ElementBinding] = [:]
        let providerUIDs = Self.collectProviderUIDsAndBindings(from: snapshot, into: &bindings)
        guard !providerUIDs.isEmpty else { return (nil, [:]) }
        let minted = self.mintSnapshot(
            providerUIDs: providerUIDs,
            pageReference: pageReference,
            bindings: bindings)
        snapshot = Self.replacingElementIDs(in: snapshot, mappings: minted.elements)
        root["snapshot"] = snapshot
        root["snapshot_ref"] = .string(minted.reference)
        structured = .object(root)
        return (minted.reference, minted.elements)
    }

    private func mintSnapshot(
        providerUIDs: [String],
        pageReference: String,
        bindings: [String: ElementBinding]) -> (reference: String, elements: [String: String])
    {
        self.invalidateSnapshots(for: pageReference)
        guard var page = self.pagesByReference[pageReference] else {
            return (Self.reference(prefix: "bs1"), [:])
        }
        let snapshotReference = Self.reference(prefix: "bs1")
        var mappings: [String: String] = [:]
        for providerUID in providerUIDs {
            let elementReference = Self.reference(prefix: "be1")
            mappings[providerUID] = elementReference
            self.elementsByReference[elementReference] = ElementRecord(
                providerUID: providerUID,
                snapshotReference: snapshotReference,
                pageReference: pageReference,
                navigationGeneration: page.navigationGeneration,
                binding: bindings[providerUID] ?? ElementBinding(
                    backendNodeID: nil,
                    frameID: nil,
                    loaderID: nil,
                    navigationID: page.url))
        }
        self.snapshotsByReference[snapshotReference] = SnapshotRecord(
            pageReference: pageReference,
            navigationGeneration: page.navigationGeneration,
            elementReferencesByProviderUID: mappings)
        page.snapshotReferences.insert(snapshotReference)
        self.pagesByReference[pageReference] = page
        return (snapshotReference, mappings)
    }

    private func advanceNavigation(for pageReference: String?) {
        guard let pageReference, var page = self.pagesByReference[pageReference] else { return }
        self.invalidateSnapshots(for: pageReference)
        page.navigationGeneration &+= 1
        page.url = nil
        self.pagesByReference[pageReference] = page
    }

    private func invalidateSnapshots(for pageReference: String?) {
        guard let pageReference, var page = self.pagesByReference[pageReference] else { return }
        for snapshotReference in page.snapshotReferences {
            if let snapshot = self.snapshotsByReference.removeValue(forKey: snapshotReference) {
                for elementReference in snapshot.elementReferencesByProviderUID.values {
                    self.elementsByReference.removeValue(forKey: elementReference)
                }
            }
        }
        page.snapshotReferences.removeAll()
        self.pagesByReference[pageReference] = page
    }

    private func removePage(reference: String?) {
        guard let reference, let page = self.pagesByReference[reference] else { return }
        self.invalidateSnapshots(for: reference)
        self.pagesByReference.removeValue(forKey: reference)
        if self.pageReferenceByProviderID[page.providerPageID] == reference {
            self.pageReferenceByProviderID.removeValue(forKey: page.providerPageID)
        }
    }

    private func invalidateAll() {
        self.pagesByReference.removeAll()
        self.pageReferenceByProviderID.removeAll()
        self.snapshotsByReference.removeAll()
        self.elementsByReference.removeAll()
    }

    private func applyEffects(
        _ contracts: [BrowserMCPToolCapabilityContract],
        resolved: ResolvedArguments?)
    {
        if contracts.contains(where: { $0.effect == .invalidateAllPages }) {
            self.invalidateAll()
            return
        }
        for contract in contracts {
            switch contract.effect {
            case .preserve:
                break
            case .invalidateSnapshot:
                self.invalidateSnapshots(for: resolved?.pageReference)
            case .navigate:
                self.advanceNavigation(for: resolved?.pageReference)
            case .removePage:
                self.removePage(reference: resolved?.pageReference)
            case .invalidateAllPages:
                break
            }
        }
    }

    private static func actionUsesPage(_ action: BrowserAction, arguments: ToolArguments) -> Bool {
        switch action {
        case .selectPage, .closePage, .navigate, .waitFor, .snapshot, .click, .fill, .fillForm, .drag, .hover,
             .type, .pressKey, .uploadFile, .handleDialog, .console, .network, .screenshot, .performanceTrace:
            true
        case .call:
            arguments.getValue(for: "page_id") != nil
        case .status, .connect, .disconnect, .listPages, .newPage:
            false
        }
    }

    private static func responseMayContainSnapshot(
        _ projection: BrowserMCPToolCapabilityContract.ResponseProjection,
        response: ToolResponse) -> Bool
    {
        switch projection {
        case .snapshotAlways:
            true
        case let .snapshotWhen(enabled):
            enabled
        case .thirdPartySnapshot:
            response.structuredContent?.objectValue?["snapshot"] != nil ||
                BrowserToolCapabilityProjection.thirdPartySnapshotSection(in: self.textContent(response)) != nil
        case .none, .pages:
            false
        }
    }

    private static func responseCreatesSnapshot(
        _ projection: BrowserMCPToolCapabilityContract.ResponseProjection,
        response: ToolResponse) -> Bool
    {
        self.responseMayContainSnapshot(projection, response: response)
    }

    private static func collectProviderUIDsAndBindings(
        from value: Value,
        into bindings: inout [String: ElementBinding]) -> [String]
    {
        var result: [String] = []
        func walk(_ value: Value) {
            switch value {
            case let .object(fields):
                if let id = fields["id"]?.stringValue {
                    result.append(id)
                    bindings[id] = ElementBinding(
                        backendNodeID: fields["backendNodeId"]?.intValue.map(Int64.init),
                        frameID: fields["frameId"]?.stringValue,
                        loaderID: fields["loaderId"]?.stringValue,
                        navigationID: fields["navigationId"]?.stringValue)
                }
                for child in fields.values {
                    walk(child)
                }
            case let .array(values):
                for child in values {
                    walk(child)
                }
            case .string, .int, .double, .bool, .null, .data:
                break
            }
        }
        walk(value)
        return Array(Set(result)).sorted()
    }

    private static func replacingElementIDs(in value: Value, mappings: [String: String]) -> Value {
        switch value {
        case var .object(fields):
            if let id = fields["id"]?.stringValue, let reference = mappings[id] {
                fields["id"] = .string(reference)
                fields["element_ref"] = .string(reference)
            }
            return .object(fields.mapValues { self.replacingElementIDs(in: $0, mappings: mappings) })
        case let .array(values):
            return .array(values.map { self.replacingElementIDs(in: $0, mappings: mappings) })
        case .string, .int, .double, .bool, .null, .data:
            return value
        }
    }

    private static func textContent(_ response: ToolResponse) -> String {
        response.content.compactMap { item in
            guard case let .text(text, _, _) = item else { return nil }
            return text
        }.joined(separator: "\n")
    }

    private static func lastParenthesizedValue(in text: String) -> String? {
        guard let closing = text.lastIndex(of: ")"),
              let opening = text[..<closing].lastIndex(of: "(")
        else { return nil }
        let value = text[text.index(after: opening)..<closing]
        return value.contains("://") ? String(value) : nil
    }

    private static func reference(prefix: String) -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "\(prefix)_\(token)"
    }
}

enum BrowserMCPProviderSnapshotParser {
    static func providerUIDs(in response: ToolResponse) -> Set<String> {
        var result = Set<String>()
        if let structuredContent = response.structuredContent {
            self.collectIDs(in: structuredContent, into: &result)
        }
        return result
    }

    private static func collectIDs(in value: Value, into result: inout Set<String>) {
        switch value {
        case let .object(fields):
            if let id = fields["id"]?.stringValue {
                result.insert(id)
            }
            for child in fields.values {
                self.collectIDs(in: child, into: &result)
            }
        case let .array(values):
            for child in values {
                self.collectIDs(in: child, into: &result)
            }
        case .string, .int, .double, .bool, .null, .data:
            break
        }
    }
}

enum BrowserToolCapabilityReference {
    static func isValid(_ value: String, prefix: String) -> Bool {
        let expectedPrefix = prefix + "_"
        guard value.hasPrefix(expectedPrefix) else { return false }
        let token = value.dropFirst(expectedPrefix.count)
        return token.count == 32 && token.allSatisfy { character in
            guard let ascii = character.asciiValue else { return false }
            return (48...57).contains(ascii) || (97...102).contains(ascii)
        }
    }
}

enum BrowserToolCapabilityError: LocalizedError, Equatable {
    case sessionEnded
    case connectionUnavailable
    case invalidPageReference
    case stalePageReference
    case invalidElementReference
    case staleElementReference
    case invalidJSON
    case invalidProviderResponse
    case snapshotArtifactUnsupported

    var errorDescription: String? {
        switch self {
        case .sessionEnded:
            "The browser capability session has ended. Start a new session and observe pages again."
        case .connectionUnavailable:
            "Browser page capabilities require an existing exact connection receipt and provider child epoch."
        case .invalidPageReference:
            "page_id must be an opaque page reference returned by this session's latest list_pages or new_page."
        case .stalePageReference:
            "The browser page reference belongs to another or expired provider session. Refresh list_pages."
        case .invalidElementReference:
            "uid must be an opaque element reference returned by this session's latest browser snapshot."
        case .staleElementReference:
            "The browser element reference is stale after a newer snapshot or navigation. Take a fresh snapshot."
        case .invalidJSON:
            "Browser raw arguments must be a JSON object whose uid fields use current opaque element references."
        case .invalidProviderResponse:
            "Chrome DevTools MCP returned malformed structured page identity data."
        case .snapshotArtifactUnsupported:
            "Capability-scoped browser snapshots cannot write provider UIDs to a file. Omit path and save the " +
                "projected response instead."
        }
    }
}
