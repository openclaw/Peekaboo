import Foundation
import PeekabooAutomation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

extension SeeCommandRuntimeTests {
    @Test
    @MainActor
    func `tree only See publishes elements only with an exact action receipt`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            automation.inspectAccessibilityTreeHandler = { _ in fixture.detectionResult }
            let (context, _) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )

            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--app", fixture.applicationInfo.name,
                    "--tree",
                    "--no-screenshot",
                    "--json",
                ],
                services: context.services
            )
            let data = try #require(result.stdout.data(using: .utf8))
            let response = try JSONDecoder().decode(CodableJSONResponse<SeeResult>.self, from: data)
            let stored = try #require(
                context.snapshots.detectionResults[response.data.snapshot_id]?.metadata.windowContext
            )

            #expect(result.exitStatus == 0)
            #expect(response.data.ui_elements.map(\.id) == ["B1"])
            #expect(stored.applicationProcessId == fixture.applicationInfo.processIdentifier)
            #expect(stored.windowID == fixture.windowInfo.windowID)
            #expect(stored.windowBounds == fixture.windowInfo.bounds)
            #expect(stored.windowMutationIdentity == fixture.windowInfo.mutationIdentity)
        }
    }

    @Test
    @MainActor
    func `tree only See refuses incomplete action receipts before snapshot publication`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let fixtureContext = try #require(fixture.detectionResult.metadata.windowContext)
            let invalidIdentities: [WindowMutationIdentity?] = [
                nil,
                WindowMutationIdentity(
                    windowID: fixture.windowInfo.windowID,
                    ownerProcessIdentifier: fixture.applicationInfo.processIdentifier,
                    ownerProcessStartIdentity: 4242,
                    capturedBounds: nil
                ),
                WindowMutationIdentity(
                    windowID: fixture.windowInfo.windowID,
                    ownerProcessIdentifier: fixture.applicationInfo.processIdentifier,
                    ownerProcessStartIdentity: 0,
                    capturedBounds: fixture.windowInfo.bounds
                ),
            ]

            for invalidIdentity in invalidIdentities {
                let automation = StubAutomationService()
                automation.inspectAccessibilityTreeHandler = { _ in
                    ElementDetectionResult(
                        snapshotId: "incomplete-receipt-tree",
                        screenshotPath: "",
                        elements: fixture.detectionResult.elements,
                        metadata: DetectionMetadata(
                            detectionTime: 0.1,
                            elementCount: fixture.detectionResult.elements.all.count,
                            method: "stub",
                            windowContext: WindowContext(
                                applicationName: fixtureContext.applicationName,
                                applicationBundleId: fixtureContext.applicationBundleId,
                                applicationProcessId: fixtureContext.applicationProcessId,
                                windowTitle: fixtureContext.windowTitle,
                                windowID: fixtureContext.windowID,
                                windowBounds: fixtureContext.windowBounds,
                                windowMutationIdentity: invalidIdentity
                            )
                        )
                    )
                }
                let (context, _) = Self.makeSeeCommandRuntimeContext(
                    automation: automation,
                    screenCapture: fixture.screenCapture,
                    applicationInfo: fixture.applicationInfo,
                    windowInfo: fixture.windowInfo
                )

                let result = try await InProcessCommandRunner.run(
                    [
                        "see",
                        "--app", fixture.applicationInfo.name,
                        "--tree",
                        "--no-screenshot",
                        "--json",
                    ],
                    services: context.services
                )

                #expect(result.exitStatus == 1)
                #expect(result.combinedOutput.contains("exact process-generation, window, and bounds receipt"))
                #expect(!result.combinedOutput.contains("\"snapshot_id\""))
                #expect(!result.combinedOutput.contains("\"ui_elements\""))
                #expect(context.snapshots.detectionResults.isEmpty)
                #expect(try await context.snapshots.listSnapshots().isEmpty)
            }
        }
    }
}
