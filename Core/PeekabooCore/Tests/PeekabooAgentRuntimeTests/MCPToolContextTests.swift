import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct MCPToolContextTests {
    @Test
    @MainActor
    func `shared resolves the configured services`() async {
        let services = PeekabooServices()

        await MCPToolContext.withDefaultContextFactoryForTesting {
            MainActor.preconditionIsolated()
            return MCPToolContext(services: services)
        } perform: {
            let context = MCPToolContext.shared

            #expect(ObjectIdentifier(context.automation as AnyObject) ==
                ObjectIdentifier(services.automation as AnyObject))
            #expect(ObjectIdentifier(context.menu as AnyObject) ==
                ObjectIdentifier(services.menu as AnyObject))
        }
    }

    @Test
    @MainActor
    func `context uses injected services`() {
        let services = PeekabooServices()
        let context = MCPToolContext(services: services)

        #expect(ObjectIdentifier(context.menu as AnyObject) ==
            ObjectIdentifier(services.menu as AnyObject))
        #expect(ObjectIdentifier(context.automation as AnyObject) ==
            ObjectIdentifier(services.automation as AnyObject))
        #expect(context.executionPolicy == .unrestricted)
    }

    @Test
    @MainActor
    func `Agent tool construction captures task-local immutable policy`() throws {
        let agent = try PeekabooAgentService(services: PeekabooServices())
        let owner = MCPToolSnapshotOwner(sessionID: "durable-agent-session")

        let background = PeekabooAgentService.$toolConstructionSnapshotOwner.withValue(owner) {
            PeekabooAgentService.$toolConstructionExecutionPolicy.withValue(.backgroundOnly) {
                agent.makeToolContext()
            }
        }
        let foreground = PeekabooAgentService.$toolConstructionExecutionPolicy.withValue(.foregroundAllowed) {
            agent.makeToolContext()
        }

        #expect(background.executionPolicy == .backgroundOnly)
        #expect(background.uiSnapshots.owner == owner)
        #expect(foreground.executionPolicy == .foregroundAllowed)
        #expect(foreground.uiSnapshots.owner != owner)
        #expect(agent.makeToolContext().executionPolicy == .unrestricted)
    }

    @Test
    @MainActor
    func `legacy contexts share process owner while explicit contexts isolate`() {
        let services = PeekabooServices()
        let first = MCPToolContext(services: services)
        let second = MCPToolContext(services: services)
        let isolated = MCPToolContext(
            services: services,
            snapshotOwner: MCPToolSnapshotOwner())

        #expect(first.uiSnapshots.owner == second.uiSnapshots.owner)
        #expect(first.uiSnapshots.owner != isolated.uiSnapshots.owner)
    }

    @Test
    @MainActor
    func `Agent foreground opt-in cannot execute the real shell tool`() async throws {
        let agent = try PeekabooAgentService(services: PeekabooServices())
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-agent-shell-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        for policy in [MCPToolExecutionPolicy.backgroundOnly, .foregroundAllowed] {
            let tools = await agent.buildToolset(for: .anthropic(.sonnet45), executionPolicy: policy)
            #expect(!tools.contains(where: { $0.name == "shell" }))
            let shell = PeekabooAgentService.$toolConstructionExecutionPolicy.withValue(policy) {
                agent.createShellTool()
            }
            do {
                _ = try await shell.execute(
                    AgentToolArguments(["command": "/usr/bin/touch \(marker.path)"]),
                    context: ToolExecutionContext())
                Issue.record("Expected the Agent shell policy to throw a typed failure")
            } catch let failure as AgentToolExecutionFailure {
                let metadata = try #require(failure.metadata?.objectValue)
                #expect(metadata["error_code"]?.stringValue == MCPToolExecutionPolicy.refusalErrorCode)
                #expect(metadata["mutation_dispatched"]?.boolValue == false)
            }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test
    @MainActor
    func `task local override restores shared value`() async {
        let services = PeekabooServices()

        await MCPToolContext.withDefaultContextFactoryForTesting {
            MCPToolContext(services: services)
        } perform: {
            let baselineContext = MCPToolContext.shared
            let overrideContext = MCPToolContext(services: PeekabooServices())

            await MCPToolContext.withContext(overrideContext) {
                let inside = MCPToolContext.shared
                #expect(ObjectIdentifier(inside.automation as AnyObject) ==
                    ObjectIdentifier(overrideContext.automation as AnyObject))
            }

            let after = MCPToolContext.shared
            #expect(ObjectIdentifier(after.automation as AnyObject) ==
                ObjectIdentifier(baselineContext.automation as AnyObject))
        }
    }

    @Test
    func `sharedOnMainActor resolves from a detached task`() async {
        await MCPToolContext.withDefaultContextFactoryForTesting(nil) {
            let services = PeekabooServices()
            MCPToolContext.configureDefaultContext {
                MainActor.preconditionIsolated()
                return MCPToolContext(services: services)
            }

            let context = await Task.detached {
                await MCPToolContext.sharedOnMainActor()
            }.value

            #expect(ObjectIdentifier(context.automation as AnyObject) ==
                ObjectIdentifier(services.automation as AnyObject))
            #expect(ObjectIdentifier(context.menu as AnyObject) ==
                ObjectIdentifier(services.menu as AnyObject))
        }
    }
}
