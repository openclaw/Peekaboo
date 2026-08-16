import CoreGraphics
import Foundation
import MCP
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

#if !PEEKABOO_SKIP_AUTOMATION
@Suite(
    .serialized,
    .tags(.automation)
)
struct SpaceToolExecutionHostTests {
    @Test
    func `foreground Space switch returns canonical native dispatch metadata`() async throws {
        let testContext = self.makeTestContext()
        let context = self.makeToolContext(
            services: testContext.services,
            executionHost: .local,
            executionPolicy: .foregroundAllowed
        )
        let service = SpaceToolStubSpaceService(spaces: [
            SpaceInfo(
                id: 7,
                type: .user,
                isActive: false,
                displayID: 1,
                name: "Desktop 2",
                ownerPIDs: []
            ),
        ])
        let tool = SpaceTool(testingSpaceService: service, context: context)

        let response = try await context.execute(
            tool: tool,
            arguments: self.makeArguments([
                "action": .string("switch"),
                "to": .int(1),
                "foreground": .bool(true),
            ])
        )

        #expect(!response.isError)
        #expect(service.switchCalls == [7])
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["state"] == .string("dispatched_unverified"))
        #expect(metadata["effect"] == .string("unverifiable"))
        #expect(metadata["delivery_mechanism"] == .string("native_framework"))
        #expect(metadata["delivery_mode"] == .string("foreground"))
        #expect(metadata["dispatch_state"] == .string("dispatched"))
        #expect(metadata["dispatched_unit_count"] == .int(1))
        #expect(metadata["mutation_dispatched"] == .bool(true))
        #expect(metadata["retry_safe"] == .bool(false))
        #expect(metadata["retry_safety"] == .string("unsafe"))
    }

    @Test
    func `Space switch post-dispatch failure returns canonical indeterminate metadata`() async throws {
        let testContext = self.makeTestContext()
        let context = self.makeToolContext(
            services: testContext.services,
            executionHost: .local,
            executionPolicy: .foregroundAllowed
        )
        let service = SpaceToolStubSpaceService(spaces: [
            SpaceInfo(
                id: 7,
                type: .user,
                isActive: false,
                displayID: 1,
                name: "Desktop 2",
                ownerPIDs: []
            ),
        ])
        service.switchFailure = .indeterminate(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Space switch was dispatched, but post-dispatch settling failed."
        )
        let tool = SpaceTool(testingSpaceService: service, context: context)

        let response = try await context.execute(
            tool: tool,
            arguments: self.makeArguments([
                "action": .string("switch"),
                "to": .int(1),
                "foreground": .bool(true),
            ])
        )

        #expect(response.isError)
        #expect(service.switchCalls == [7])
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["state"] == .string("indeterminate"))
        #expect(metadata["effect"] == .string("unverifiable"))
        #expect(metadata["delivery_mechanism"] == .string("native_framework"))
        #expect(metadata["delivery_mode"] == .string("foreground"))
        #expect(metadata["dispatch_state"] == .string("may_have_dispatched"))
        #expect(metadata["dispatched_unit_count"] == .int(1))
        #expect(metadata["mutation_dispatched"] == .bool(true))
        #expect(metadata["retry_safe"] == .bool(false))
        #expect(metadata["retry_safety"] == .string("unsafe"))
    }

    @Test
    func `Space switch requires leaf foreground consent before inventory or dispatch`() async throws {
        let testContext = self.makeTestContext()
        let context = self.makeToolContext(
            services: testContext.services,
            executionHost: .local,
            executionPolicy: .foregroundAllowed
        )
        let service = SpaceToolStubSpaceService(spaces: [])

        let response = try await context.execute(
            tool: SpaceTool(testingSpaceService: service, context: context),
            arguments: self.makeArguments([
                "action": .string("switch"),
                "to": .int(1),
            ])
        )

        #expect(response.isError)
        #expect(service.getAllSpacesCalls == 0)
        #expect(service.switchCalls.isEmpty)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["state"] == .string("refused"))
        #expect(metadata["refusal_reason"] == .string("foreground_consent_required"))
        #expect(metadata["dispatch_state"] == .string("none"))
        #expect(metadata["mutation_dispatched"] == .bool(false))
        #expect(metadata["retry_safe"] == .bool(true))
    }

    @Test
    func `Space move follow requires leaf foreground consent before target discovery`() async throws {
        let testContext = self.makeTestContext()
        let context = self.makeToolContext(
            services: testContext.services,
            executionHost: .local,
            executionPolicy: .foregroundAllowed
        )
        let service = SpaceToolStubSpaceService(spaces: [])

        let response = try await context.execute(
            tool: SpaceTool(testingSpaceService: service, context: context),
            arguments: self.makeArguments([
                "action": .string("move-window"),
                "window_id": .int(testContext.windowInfo.windowID),
                "to": .int(1),
                "follow": .bool(true),
            ])
        )

        #expect(response.isError)
        #expect(testContext.windowService.listCallCount == 0)
        #expect(service.getAllSpacesCalls == 0)
        #expect(service.moveWindowCalls.isEmpty)
        #expect(service.switchCalls.isEmpty)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["state"] == .string("refused"))
        #expect(metadata["refusal_reason"] == .string("foreground_consent_required"))
        #expect(metadata["mutation_dispatched"] == .bool(false))
        #expect(metadata["retry_safe"] == .bool(true))
    }

    @Test
    func `Space move follow preserves confirmed no-change switch and exact move units`() async throws {
        let testContext = self.makeTestContext()
        let context = self.makeToolContext(
            services: testContext.services,
            executionHost: .local,
            executionPolicy: .foregroundAllowed
        )
        let service = SpaceToolStubSpaceService(spaces: [
            SpaceInfo(id: 7, type: .user, isActive: false, displayID: 1, name: "Desktop 2", ownerPIDs: []),
        ])
        service.switchOutcome = .confirmedNoChange()

        let response = try await context.execute(
            tool: SpaceTool(testingSpaceService: service, context: context),
            arguments: self.makeArguments([
                "action": .string("move-window"),
                "window_id": .int(testContext.windowInfo.windowID),
                "to": .int(1),
                "follow": .bool(true),
                "foreground": .bool(true),
            ])
        )

        #expect(!response.isError)
        #expect(service.moveWindowCalls.count == 1)
        #expect(service.switchCalls == [7])
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["state"] == .string("dispatched_unverified"))
        #expect(metadata["delivery_mechanism"] == .string("native_framework"))
        #expect(metadata["delivery_mode"] == .string("background"))
        #expect(metadata["dispatched_unit_count"] == .int(1))
        #expect(metadata["target_receipt"] != nil)
    }

    @Test
    func `Space move follow composes confirmed switch delivery and exact two units`() async throws {
        let testContext = self.makeTestContext()
        let context = self.makeToolContext(
            services: testContext.services,
            executionHost: .local,
            executionPolicy: .foregroundAllowed
        )
        let service = SpaceToolStubSpaceService(spaces: [
            SpaceInfo(id: 7, type: .user, isActive: false, displayID: 1, name: "Desktop 2", ownerPIDs: []),
        ])
        service.switchOutcome = .confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one
        )

        let response = try await context.execute(
            tool: SpaceTool(testingSpaceService: service, context: context),
            arguments: self.makeArguments([
                "action": .string("move-window"),
                "window_id": .int(testContext.windowInfo.windowID),
                "to": .int(1),
                "follow": .bool(true),
                "foreground": .bool(true),
            ])
        )

        #expect(!response.isError)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["state"] == .string("dispatched_unverified"))
        #expect(metadata["delivery_mechanism"] == .string("native_framework"))
        #expect(metadata["delivery_mode"] == .string("foreground"))
        #expect(metadata["dispatched_unit_count"] == .int(2))
        #expect(metadata["target_receipt"] != nil)
    }

    @Test
    func `Space move follow preserves partial switch failure and exact two units`() async throws {
        let testContext = self.makeTestContext()
        let context = self.makeToolContext(
            services: testContext.services,
            executionHost: .local,
            executionPolicy: .foregroundAllowed
        )
        let service = SpaceToolStubSpaceService(spaces: [
            SpaceInfo(id: 7, type: .user, isActive: false, displayID: 1, name: "Desktop 2", ownerPIDs: []),
        ])
        service.switchOutcome = .partial(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one
        )

        let response = try await context.execute(
            tool: SpaceTool(testingSpaceService: service, context: context),
            arguments: self.makeArguments([
                "action": .string("move-window"),
                "window_id": .int(testContext.windowInfo.windowID),
                "to": .int(1),
                "follow": .bool(true),
                "foreground": .bool(true),
            ])
        )

        #expect(response.isError)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["state"] == .string("partial"))
        #expect(metadata["delivery_mechanism"] == .string("native_framework"))
        #expect(metadata["delivery_mode"] == .string("foreground"))
        #expect(metadata["dispatched_unit_count"] == .int(2))
        #expect(metadata["mutation_dispatched"] == .bool(true))
        #expect(metadata["retry_safe"] == .bool(false))
        #expect(metadata["target_receipt"] != nil)
    }

    @Test
    func `override remains usable with a remote execution context`() async throws {
        let context = self.makeTestContext()
        let toolContext = self.makeToolContext(
            services: context.services,
            executionHost: .remote,
            executionPolicy: .unrestricted
        )
        let stubSpaceService = SpaceToolStubSpaceService(spaces: [])
        let tool = SpaceTool(testingSpaceService: stubSpaceService, context: toolContext)
        let args = self.makeArguments([
            "action": .string("move-window"),
            "app": .string(context.appName),
            "to_current": .bool(true),
        ])

        let response = try await tool.execute(arguments: args)

        // Current behavior: SpaceTool issues a move-to-current request even when the
        // space service reports no spaces (the service decides whether to error).
        #expect(response.isError == false)
        #expect(stubSpaceService.moveToCurrentCalls == [CGWindowID(context.windowInfo.windowID)])
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["state"] == .string("dispatched_unverified"))
        #expect(metadata["delivery_mode"] == .string("background"))
        #expect(metadata["target_receipt"] != nil)
    }

    @Test
    func `background Space move refuses a leaf window from a different authorized generation`() async throws {
        let testContext = self.makeTestContext(processGeneration: 222)
        let context = self.makeToolContext(
            services: testContext.services,
            executionHost: .local,
            executionPolicy: .backgroundOnly
        )
        let stubSpaceService = SpaceToolStubSpaceService(spaces: [])
        let tool = SpaceTool(testingSpaceService: stubSpaceService, context: context)
        let authorizedTarget = try DesktopTargetIdentity(processIdentity: ApplicationProcessIdentity(
            processIdentifier: 999,
            processStartIdentity: 111
        ))

        let response = try await AuthorizedDesktopTargetPlan.$current.withValue(
            AuthorizedDesktopTargetPlan(targetIdentity: authorizedTarget)
        ) {
            try await tool.execute(arguments: self.makeArguments([
                "action": .string("move-window"),
                "app": .string(testContext.appName),
                "to_current": .bool(true),
            ]))
        }

        #expect(response.isError)
        #expect(stubSpaceService.moveToCurrentCalls.isEmpty)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["state"] == .string("refused"))
        #expect(metadata["refusal_reason"] == .string("target_unavailable"))
        #expect(metadata["dispatch_state"] == .string("none"))
        #expect(metadata["mutation_dispatched"] == .bool(false))
        #expect(metadata["retry_safe"] == .bool(true))
    }

    @Test
    func `background exact window authorization reaches Space leaf with canonical result`() async throws {
        let testContext = self.makeTestContext()
        let context = self.makeToolContext(
            services: testContext.services,
            executionHost: .local,
            executionPolicy: .backgroundOnly
        )
        let stubSpaceService = SpaceToolStubSpaceService(spaces: [])
        let tool = SpaceTool(testingSpaceService: stubSpaceService, context: context)

        let response = try await context.execute(tool: tool, arguments: self.makeArguments([
            "action": .string("move-window"),
            "window_id": .int(testContext.windowInfo.windowID),
            "to_current": .bool(true),
        ]))

        #expect(response.isError == false)
        #expect(stubSpaceService.moveToCurrentCalls == [CGWindowID(testContext.windowInfo.windowID)])
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["state"] == .string("dispatched_unverified"))
        #expect(metadata["dispatch_state"] == .string("dispatched"))
        #expect(metadata["mutation_dispatched"] == .bool(true))
        #expect(metadata["retry_safe"] == .bool(false))
        #expect(metadata["target_receipt"] != nil)
    }

    @Test
    func `Space move rejects a contradictory foreground service receipt`() async throws {
        let testContext = self.makeTestContext()
        let context = self.makeToolContext(
            services: testContext.services,
            executionHost: .local,
            executionPolicy: .foregroundAllowed
        )
        let service = SpaceToolStubSpaceService(spaces: [])
        service.moveOutcome = .confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one
        )

        let response = try await context.execute(
            tool: SpaceTool(testingSpaceService: service, context: context),
            arguments: self.makeArguments([
                "action": .string("move-window"),
                "window_id": .int(testContext.windowInfo.windowID),
                "to_current": .bool(true),
            ])
        )

        #expect(response.isError)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["state"] == .string("indeterminate"))
        #expect(metadata["delivery_mode"] == .string("foreground"))
        #expect(metadata["dispatched_unit_count"] == .int(1))
        #expect(metadata["mutation_dispatched"] == .bool(true))
        #expect(metadata["retry_safe"] == .bool(false))
        #expect(metadata["target_receipt"] != nil)
    }

    @Test
    func `background Space move refuses ambiguous partial titles before dispatch`() async throws {
        let testContext = self.makeTestContext()
        let sibling = Self.window(
            id: 4041,
            title: "Document Notes",
            index: 1,
            processIdentifier: 999,
            processGeneration: 1234,
            isMain: false
        )
        testContext.windowService.listHandler = { target, _ in
            switch target {
            case .application:
                [testContext.windowInfo, sibling]
            case let .windowId(windowID):
                [testContext.windowInfo, sibling].filter { $0.windowID == windowID }
            default:
                []
            }
        }
        let context = self.makeToolContext(
            services: testContext.services,
            executionHost: .local,
            executionPolicy: .backgroundOnly
        )
        let stubSpaceService = SpaceToolStubSpaceService(spaces: [])

        let response = try await context.execute(
            tool: SpaceTool(testingSpaceService: stubSpaceService, context: context),
            arguments: self.makeArguments([
                "action": .string("move-window"),
                "app": .string(testContext.appName),
                "window_title": .string("Doc"),
                "to_current": .bool(true),
            ])
        )

        #expect(response.isError)
        #expect(stubSpaceService.moveToCurrentCalls.isEmpty)
        #expect(testContext.windowService.listCallCount == 1)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["state"] == .string("refused"))
        #expect(metadata["mutation_dispatched"] == .bool(false))
        #expect(metadata["retry_safe"] == .bool(true))
    }

    @Test
    func `background Space selectors remain pinned when inventory order changes`() async throws {
        let selectors: [[String: Value]] = [
            [:],
            ["window_title": .string("Document")],
            ["window_index": .int(0)],
        ]
        for selector in selectors {
            let testContext = self.makeTestContext()
            let sibling = Self.window(
                id: 4041,
                title: "Sibling",
                index: 1,
                processIdentifier: 999,
                processGeneration: 1234,
                isMain: false
            )
            testContext.windowService.listHandler = { target, call in
                switch target {
                case .application:
                    call == 1 ? [testContext.windowInfo, sibling] : [sibling, testContext.windowInfo]
                case let .windowId(windowID):
                    [sibling, testContext.windowInfo].filter { $0.windowID == windowID }
                default:
                    []
                }
            }
            let context = self.makeToolContext(
                services: testContext.services,
                executionHost: .local,
                executionPolicy: .backgroundOnly
            )
            let stubSpaceService = SpaceToolStubSpaceService(spaces: [])
            var payload: [String: Value] = [
                "action": .string("move-window"),
                "app": .string(testContext.appName),
                "to_current": .bool(true),
            ]
            payload.merge(selector) { _, replacement in replacement }

            let response = try await context.execute(
                tool: SpaceTool(testingSpaceService: stubSpaceService, context: context),
                arguments: self.makeArguments(payload)
            )

            #expect(!response.isError)
            #expect(stubSpaceService.moveToCurrentCalls == [4040])
            #expect(testContext.windowService.listTargets.count == 2)
            #expect(testContext.windowService.listTargets.dropFirst().allSatisfy {
                if case let .windowId(windowID) = $0 {
                    return windowID == 4040
                }
                return false
            })
        }
    }

    @Test
    func `background Space move refuses window identity reuse during exact revalidation`() async throws {
        let testContext = self.makeTestContext()
        let replacement = Self.window(
            id: 4040,
            title: "Replacement",
            index: 0,
            processIdentifier: 999,
            processGeneration: 1235
        )
        testContext.windowService.listHandler = { target, call in
            switch target {
            case .application:
                [testContext.windowInfo]
            case .windowId:
                call == 2 ? [replacement] : [testContext.windowInfo]
            default:
                []
            }
        }
        let context = self.makeToolContext(
            services: testContext.services,
            executionHost: .local,
            executionPolicy: .backgroundOnly
        )
        let stubSpaceService = SpaceToolStubSpaceService(spaces: [])

        let response = try await context.execute(
            tool: SpaceTool(testingSpaceService: stubSpaceService, context: context),
            arguments: self.makeArguments([
                "action": .string("move-window"),
                "app": .string(testContext.appName),
                "to_current": .bool(true),
            ])
        )

        #expect(response.isError)
        #expect(stubSpaceService.moveToCurrentCalls.isEmpty)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["mutation_dispatched"] == .bool(false))
        #expect(metadata["retry_safe"] == .bool(true))
    }

    @Test
    func `unrestricted app plus exact window preserves matching owner assertion`() async throws {
        let testContext = self.makeTestContext()
        let context = self.makeToolContext(
            services: testContext.services,
            executionHost: .local,
            executionPolicy: .unrestricted
        )
        let stubSpaceService = SpaceToolStubSpaceService(spaces: [])
        let tool = SpaceTool(testingSpaceService: stubSpaceService, context: context)

        let response = try await tool.execute(arguments: self.makeArguments([
            "action": .string("move-window"),
            "app": .string(testContext.appName),
            "window_id": .int(testContext.windowInfo.windowID),
            "to_current": .bool(true),
        ]))

        #expect(!response.isError)
        #expect(stubSpaceService.moveToCurrentCalls == [CGWindowID(testContext.windowInfo.windowID)])
    }

    @Test
    func `unrestricted Space selectors reject another app owner before dispatch`() async throws {
        let testContext = self.makeTestContext(
            applicationProcessIdentifier: 998,
            windowOwnerProcessIdentifier: 999
        )
        let context = self.makeToolContext(
            services: testContext.services,
            executionHost: .local,
            executionPolicy: .unrestricted
        )
        let selectors: [[String: Value]] = [
            ["window_id": .int(testContext.windowInfo.windowID)],
            ["window_title": .string(testContext.windowInfo.title)],
            ["window_index": .int(0)],
        ]

        for selector in selectors {
            let stubSpaceService = SpaceToolStubSpaceService(spaces: [])
            var payload: [String: Value] = [
                "action": .string("move-window"),
                "app": .string(testContext.appName),
                "to_current": .bool(true),
            ]
            payload.merge(selector) { _, replacement in replacement }

            let response = try await SpaceTool(
                testingSpaceService: stubSpaceService,
                context: context
            ).execute(arguments: self.makeArguments(payload))

            #expect(response.isError)
            #expect(stubSpaceService.moveToCurrentCalls.isEmpty)
            let metadata = try #require(response.meta?.objectValue)
            #expect(metadata["state"] == .string("refused"))
            #expect(metadata["dispatch_state"] == .string("none"))
            #expect(metadata["mutation_dispatched"] == .bool(false))
            #expect(metadata["retry_safe"] == .bool(true))
        }
    }

    @Test
    func `remote execution refuses list before constructing a local Space service`() async throws {
        let testContext = self.makeTestContext()
        let context = self.makeToolContext(services: testContext.services, executionHost: .remote)

        let response = try await SpaceTool(context: context).execute(arguments: self.makeArguments([
            "action": .string("list"),
        ]))

        #expect(response.isError)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["error_code"] == .string(SpaceTool.remoteExecutionRefusalErrorCode))
        #expect(metadata["execution_host"] == .string("remote"))
    }

    @Test(arguments: [
        [
            "action": Value.string("switch"),
            "to": Value.int(1),
            "foreground": Value.bool(true),
        ],
        [
            "action": Value.string("move-window"),
            "app": Value.string("TextEdit"),
            "to_current": Value.bool(true),
        ],
        [
            "action": Value.string("move-window"),
            "app": Value.string("TextEdit"),
            "to": Value.int(1),
            "follow": Value.bool(true),
            "foreground": Value.bool(true),
        ],
    ])
    func `remote mutations are retry-safe pre-dispatch refusals`(_ payload: [String: Value]) async throws {
        let testContext = self.makeTestContext()
        let context = self.makeToolContext(services: testContext.services, executionHost: .remote)

        let response = try await SpaceTool(context: context).execute(arguments: self.makeArguments(payload))

        #expect(response.isError)
        #expect(testContext.windowService.listCallCount == 0)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["error_code"] == .string(SpaceTool.remoteExecutionRefusalErrorCode))
        #expect(metadata["execution_host"] == .string("remote"))
        #expect(metadata["effect"] == .string("refused"))
        #expect(metadata["dispatch_state"] == .string("none"))
        #expect(metadata["mutation_dispatched"] == .bool(false))
        #expect(metadata["retry_safe"] == .bool(true))
        #expect(metadata["retry_safety"] == .string("safe"))
    }

    // MARK: - Helpers

    private func makeArguments(_ payload: [String: Value]) -> ToolArguments {
        ToolArguments(value: .object(payload))
    }

    private static func window(
        id: Int,
        title: String,
        index: Int,
        processIdentifier: Int32,
        processGeneration: UInt64,
        isMain: Bool = true
    ) -> ServiceWindowInfo {
        let bounds = CGRect(x: 100, y: 100, width: 600, height: 400)
        return ServiceWindowInfo(
            windowID: id,
            title: title,
            bounds: bounds,
            isMainWindow: isMain,
            index: index,
            mutationIdentity: WindowMutationIdentity(
                windowID: id,
                ownerProcessIdentifier: processIdentifier,
                ownerProcessStartIdentity: processGeneration,
                capturedBounds: bounds
            )
        )
    }

    @MainActor
    private func makeTestContext(
        processGeneration: UInt64 = 1234,
        applicationProcessIdentifier: Int32 = 999,
        windowOwnerProcessIdentifier: Int32? = nil
    ) -> (
        services: PeekabooServices,
        appName: String,
        windowInfo: ServiceWindowInfo,
        windowService: SpaceToolRecordingWindowService
    ) {
        let appName = "TextEdit"
        let bundleID = "com.apple.TextEdit"
        let appInfo = ServiceApplicationInfo(
            processIdentifier: applicationProcessIdentifier,
            processStartIdentity: processGeneration,
            bundleIdentifier: bundleID,
            name: appName,
            bundlePath: "/System/Applications/TextEdit.app",
            isActive: true,
            isHidden: false,
            windowCount: 1
        )

        let windowInfo = ServiceWindowInfo(
            windowID: 4040,
            title: "Document",
            bounds: CGRect(x: 100, y: 100, width: 600, height: 400),
            isMinimized: false,
            isMainWindow: true,
            windowLevel: 0,
            alpha: 1.0,
            index: 0,
            spaceID: 1,
            spaceName: "Desktop 1",
            screenIndex: 0,
            screenName: "Built-in",
            mutationIdentity: WindowMutationIdentity(
                windowID: 4040,
                ownerProcessIdentifier: windowOwnerProcessIdentifier ?? applicationProcessIdentifier,
                ownerProcessStartIdentity: processGeneration,
                capturedBounds: CGRect(x: 100, y: 100, width: 600, height: 400)
            )
        )

        let windowsByApp = [appName: [windowInfo]]
        let windowService = SpaceToolRecordingWindowService(windowsByApp: windowsByApp)
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [appInfo], windowsByApp: windowsByApp),
            windows: windowService
        )

        return (services, appName, windowInfo, windowService)
    }

    @MainActor
    private func makeToolContext(
        services: PeekabooServices,
        executionHost: PeekabooServiceExecutionHost,
        executionPolicy: MCPToolExecutionPolicy = .backgroundOnly
    ) -> MCPToolContext {
        MCPToolContext(
            automation: services.automation,
            menu: services.menu,
            windows: services.windows,
            applications: services.applications,
            dialogs: services.dialogs,
            dock: services.dock,
            screenCapture: services.screenCapture,
            desktopObservation: services.desktopObservation,
            snapshots: services.snapshots,
            screens: services.screens,
            agent: services.agent,
            permissions: services.permissions,
            clipboard: services.clipboard,
            browser: services.browser,
            permissionsStatusProvider: services,
            executionPolicy: executionPolicy,
            executionHost: executionHost
        )
    }
}

@MainActor
final class SpaceToolRecordingWindowService: StubWindowService {
    private(set) var listCallCount = 0
    private(set) var listTargets: [WindowTarget] = []
    var listHandler: ((WindowTarget, Int) -> [ServiceWindowInfo])?

    override func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        self.listCallCount += 1
        self.listTargets.append(target)
        if let listHandler {
            return listHandler(target, self.listCallCount)
        }
        return try await super.listWindows(target: target)
    }
}

@MainActor
final class SpaceToolStubSpaceService: SpaceManaging {
    var spaces: [SpaceInfo]
    private(set) var getAllSpacesCalls = 0
    var moveToCurrentCalls: [CGWindowID] = []
    var moveWindowCalls: [(windowID: CGWindowID, spaceID: CGSSpaceID)] = []
    var switchCalls: [CGSSpaceID] = []
    var switchOutcome: DesktopActionOutcome = .dispatchedUnverified(
        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
        evidence: .deliveryAccepted,
        unitCount: .one
    )
    var moveOutcome: DesktopActionOutcome = .dispatchedUnverified(
        delivery: .init(mechanism: .nativeFramework, mode: .background),
        evidence: .deliveryAccepted,
        unitCount: .one
    )
    var switchFailure: DesktopActionFailure?

    init(spaces: [SpaceInfo]) {
        self.spaces = spaces
    }

    func getAllSpaces() -> [SpaceInfo] {
        self.getAllSpacesCalls += 1
        return self.spaces
    }

    func moveWindowToCurrentSpaceResult(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity
    ) throws -> UIAutomationActionResult<Void> {
        self.moveToCurrentCalls.append(windowID)
        return try self.result(expectedIdentity: expectedIdentity)
    }

    func moveWindowToSpaceResult(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity,
        spaceID: CGSSpaceID
    ) throws -> UIAutomationActionResult<Void> {
        self.moveWindowCalls.append((windowID, spaceID))
        return try self.result(expectedIdentity: expectedIdentity)
    }

    func switchToSpaceResult(_ spaceID: CGSSpaceID) async throws -> DesktopActionResult<Void> {
        self.switchCalls.append(spaceID)
        if let switchFailure {
            throw switchFailure
        }
        return DesktopActionResult(outcome: self.switchOutcome)
    }

    private func result(expectedIdentity: WindowMutationIdentity) throws -> UIAutomationActionResult<Void> {
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: expectedIdentity,
            bounds: #require(expectedIdentity.capturedBounds)
        )
        return UIAutomationActionResult(
            payload: (),
            outcome: self.moveOutcome,
            targetIdentity: DesktopTargetIdentity(exactWindow: exactWindow)
        )
    }
}
#endif
