import MCP
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct BrowserMCPPrivateInteropTests {
    @Test
    func `Audited browser routing contract partitions pinned tool catalog`() {
        #expect(BrowserMCPPageRoutingContract.dependencyVersion == "1.6.0")
        #expect(BrowserMCPPageRoutingContract.pageScopedToolNames.count == 31)
        #expect(BrowserMCPPageRoutingContract.explicitPageTargetToolNames.count == 3)
        #expect(BrowserMCPPageRoutingContract.globalToolNames.count == 16)
        #expect(BrowserMCPPageRoutingContract.blockedSelectedPageToolNames == ["trigger_extension_action"])
        #expect(BrowserMCPPageRoutingContract.internalOnlyToolNames == ["get_tab_id"])
        #expect(BrowserMCPPageRoutingContract.allToolNames.count == 52)
        #expect(BrowserMCPPageRoutingContract.pageTargetedToolNames.isDisjoint(
            with: BrowserMCPPageRoutingContract.globalToolNames))
        #expect(BrowserMCPPageRoutingContract.pageTargetedToolNames.isDisjoint(
            with: BrowserMCPPageRoutingContract.blockedSelectedPageToolNames))
        #expect(BrowserMCPPageRoutingContract.globalToolNames.isDisjoint(
            with: BrowserMCPPageRoutingContract.blockedSelectedPageToolNames))
        #expect(BrowserMCPPageRoutingContract.pageTargetedToolNames.isDisjoint(
            with: BrowserMCPPageRoutingContract.internalOnlyToolNames))
        #expect(BrowserMCPPageRoutingContract.globalToolNames.isDisjoint(
            with: BrowserMCPPageRoutingContract.internalOnlyToolNames))
        #expect(BrowserMCPPageRoutingContract.routing(for: "get_tab_id") == nil)
        #expect(BrowserMCPPageRoutingContract.routing(for: "trigger_extension_action") == .blockedSelectedPage)
        #expect(BrowserMCPPageRoutingContract.readOnlyToolNames.count == 27)
        #expect(BrowserMCPPageRoutingContract.mutatingToolNames.count == 23)
        #expect(BrowserMCPPageRoutingContract.argumentDependentToolNames == [
            "performance_start_trace",
            "select_page",
        ])
        #expect(BrowserMCPPageRoutingContract.allSemanticToolNames == BrowserMCPPageRoutingContract.allToolNames)
        #expect(BrowserMCPPageRoutingContract.readOnlyToolNames.isDisjoint(
            with: BrowserMCPPageRoutingContract.mutatingToolNames))
        #expect(BrowserMCPPageRoutingContract.readOnlyToolNames.isDisjoint(
            with: BrowserMCPPageRoutingContract.argumentDependentToolNames))
        #expect(BrowserMCPPageRoutingContract.mutatingToolNames.isDisjoint(
            with: BrowserMCPPageRoutingContract.argumentDependentToolNames))
    }

    @Test
    func `Private tab target call is exact and cannot enter public routing`() {
        let call = BrowserMCPPrivateInterop.targetIDCall(providerPageID: 17)

        #expect(call.toolName == "get_tab_id")
        #expect(call.arguments["pageId"] as? Int == 17)
        #expect(BrowserMCPPageRoutingContract.internalOnlyToolNames.contains(call.toolName))
        #expect(BrowserMCPPageRoutingContract.routing(for: call.toolName) == nil)
        #expect(BrowserMCPPageRoutingContract.capabilityContract(for: call.toolName) == nil)
    }

    @Test
    func `Private tab target parser requires bounded structured identity`() throws {
        let response = ToolResponse(
            content: [.text(text: "Tab identity is private", annotations: nil, _meta: nil)],
            structuredContent: .object(["tabId": .string("A1b2-target_3")]))

        #expect(try BrowserMCPPrivateInterop.targetID(from: response) == "A1b2-target_3")
        #expect(throws: BrowserMCPPrivateInteropError.missingTargetID) {
            _ = try BrowserMCPPrivateInterop.targetID(from: .text("A1b2-target_3"))
        }
        #expect(throws: BrowserMCPPrivateInteropError.invalidTargetID) {
            _ = try BrowserMCPPrivateInterop.targetID(from: ToolResponse(
                content: [],
                structuredContent: .object(["tabId": .string("../../private")])))
        }
        #expect(throws: BrowserMCPPrivateInteropError.providerError) {
            _ = try BrowserMCPPrivateInterop.targetID(from: ToolResponse.error("provider failed"))
        }
    }
}
