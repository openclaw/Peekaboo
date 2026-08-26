import Foundation
import MCP
import PeekabooAutomationKit
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
@MainActor
struct MCPInstalledApplicationCatalogTests {
    @Test
    func `schema advertises installed inventory only when the selected service supports it`() async {
        let unsupported = MockApplicationService(applications: [])
        let supported = InstalledCatalogApplicationService(applications: [])
        let unsupportedTool = await AppTool(context: MCPToolTestHelpers.makeLegacyContext(applications: unsupported))
        let supportedTool = await AppTool(context: MCPToolTestHelpers.makeLegacyContext(applications: supported))

        let unsupportedProperties = Self.properties(unsupportedTool.inputSchema)
        let supportedProperties = Self.properties(supportedTool.inputSchema)

        #expect(unsupportedProperties?["includeInstalled"] == nil)
        guard case let .object(includeInstalled)? = supportedProperties?["includeInstalled"] else {
            Issue.record("Expected includeInstalled schema")
            return
        }
        #expect(includeInstalled["type"] == .string("boolean"))
        #expect(includeInstalled["default"] == .bool(false))
    }

    @Test
    func `list returns installed apps in a separate PID-free sidecar`() async throws {
        let running = ServiceApplicationInfo(
            processIdentifier: 41,
            processStartIdentity: 70,
            bundleIdentifier: "com.example.running",
            name: "Running",
            bundlePath: "/Applications/Running.app")
        let service = InstalledCatalogApplicationService(applications: [running])
        service.installedApplications = [
            ServiceInstalledApplicationInfo(
                name: "Running",
                bundleIdentifier: "COM.EXAMPLE.RUNNING",
                launchPath: "/Applications/Running.app",
                declaredPresentation: .regular),
            ServiceInstalledApplicationInfo(
                name: "Available",
                bundleIdentifier: "com.example.available",
                launchPath: "/Applications/Available.app",
                declaredPresentation: .regular),
            ServiceInstalledApplicationInfo(
                name: "Menu Helper",
                bundleIdentifier: "com.example.menu",
                launchPath: "/Applications/Menu Helper.app",
                declaredPresentation: .uiElement),
            ServiceInstalledApplicationInfo(
                name: "Daemon",
                bundleIdentifier: "com.example.daemon",
                launchPath: "/Applications/Daemon.app",
                declaredPresentation: .backgroundOnly),
        ]
        service.installedWarnings = ["catalog partial"]
        let tool = await AppTool(context: MCPToolTestHelpers.makeLegacyContext(applications: service))

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "list",
            "includeInstalled": true,
        ]))

        #expect(!response.isError)
        #expect(service.installedListCallCount == 1)
        guard case let .object(meta) = response.meta,
              case let .array(runningRows)? = meta["apps"],
              case let .array(installedRows)? = meta["installed_apps"],
              case let .object(firstInstalled)? = installedRows.first
        else {
            Issue.record("Expected separate running and installed application metadata")
            return
        }
        #expect(runningRows.count == 1)
        #expect(installedRows.count == 2)
        #expect(meta["installed_count"] == .double(2))
        #expect(meta["installed_status"] == .string("complete"))
        #expect(firstInstalled["name"] == .string("Available"))
        #expect(firstInstalled["bundle_id"] == .string("com.example.available"))
        #expect(firstInstalled["launch_path"] == .string("/Applications/Available.app"))
        #expect(firstInstalled["declared_presentation"] == .string("regular"))
        #expect(firstInstalled["pid"] == nil)
        #expect(meta["warnings"] == .array([.string("catalog partial")]))

        let text = response.content.compactMap { content -> String? in
            guard case let .text(text, _, _) = content else { return nil }
            return text
        }.joined(separator: "\n")
        #expect(text.contains("Installed but not running (2)"))
        #expect(text.contains("Available"))
        #expect(text.contains("Menu Helper"))
        #expect(!text.contains("Daemon"))
    }

    @Test
    func `absent opt-in preserves running-only behavior without catalog work`() async throws {
        let service = InstalledCatalogApplicationService(applications: [])
        let tool = await AppTool(context: MCPToolTestHelpers.makeLegacyContext(applications: service))

        let response = try await tool.execute(arguments: ToolArguments(raw: ["action": "list"]))

        #expect(!response.isError)
        #expect(service.installedListCallCount == 0)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected list metadata")
            return
        }
        #expect(meta["installed_apps"] == nil)
        #expect(meta["installed_count"] == nil)
    }

    @Test
    func `identity-poor running inventory skips catalog IO`() async throws {
        let service = InstalledCatalogApplicationService(applications: [ServiceApplicationInfo(
            processIdentifier: 41,
            processStartIdentity: 70,
            bundleIdentifier: nil,
            name: "Incomplete",
            bundlePath: "/Applications/Incomplete.app",
            isHiddenKnown: false)])
        service.installedApplications = [ServiceInstalledApplicationInfo(
            name: "Available",
            bundleIdentifier: "com.example.available",
            launchPath: "/Applications/Available.app",
            declaredPresentation: .regular)]
        let tool = await AppTool(context: MCPToolTestHelpers.makeLegacyContext(applications: service))

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "list",
            "includeInstalled": true,
        ]))

        #expect(!response.isError)
        #expect(service.installedListCallCount == 0)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected list metadata")
            return
        }
        #expect(meta["installed_count"] == .double(0))
        #expect(meta["installed_status"] == .string("omitted"))
        #expect(meta["installed_apps"] == .array([]))
        let summary = try #require(meta["summary"]?.objectValue)
        #expect(summary["notes"] == .string(
            "Found 1 running applications; installed status omitted due incomplete live identity"))
        let text = response.content.compactMap { content -> String? in
            guard case let .text(value, _, _) = content else { return nil }
            return value
        }.joined(separator: "\n")
        #expect(text.contains("Installed application status omitted"))
        #expect(!text.contains("No installed-but-not-running applications found"))
        #expect(!text.contains("Installed but not running (0)"))
        #expect(!text.contains("0 installed apps"))
        guard case let .array(warnings)? = meta["warnings"] else {
            Issue.record("Expected omission warning")
            return
        }
        #expect(warnings.contains {
            guard case let .string(value) = $0 else { return false }
            return value.contains("omitted because a live application lacked bundle identity metadata")
        })
    }

    @Test
    func `installed opt-in is rejected for non-list actions`() async throws {
        let service = InstalledCatalogApplicationService(applications: [])
        let tool = await AppTool(context: MCPToolTestHelpers.makeLegacyContext(applications: service))

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "hide",
            "name": "Fixture",
            "includeInstalled": true,
        ]))

        #expect(response.isError)
        #expect(service.installedListCallCount == 0)
    }

    private static func properties(_ schema: Value) -> [String: Value]? {
        guard case let .object(root) = schema,
              case let .object(properties)? = root["properties"]
        else {
            return nil
        }
        return properties
    }
}

@MainActor
private final class InstalledCatalogApplicationService: MockApplicationService,
    InstalledApplicationCatalogProviding
{
    nonisolated let supportsInstalledApplicationCatalog = true
    var installedApplications: [ServiceInstalledApplicationInfo] = []
    var installedWarnings: [String] = []
    private(set) var installedListCallCount = 0

    func listInstalledApplications() async throws -> UnifiedToolOutput<ServiceInstalledApplicationListData> {
        self.installedListCallCount += 1
        return UnifiedToolOutput(
            data: ServiceInstalledApplicationListData(applications: self.installedApplications),
            summary: .init(
                brief: "Fixture catalog",
                status: self.installedWarnings.isEmpty ? .success : .partial),
            metadata: .init(duration: 0, warnings: self.installedWarnings))
    }
}
