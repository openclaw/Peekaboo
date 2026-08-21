import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

extension SeeCommandRuntimeTests {
    func runApplicationPartialSeeAssertions() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let processStartIdentity = try #require(fixture.applicationInfo.processStartIdentity)
            let automation = StubAutomationService()
            let partialElement = try #require(fixture.detectionResult.elements.all.first)
            let fallbackResult: (DetectedElements) -> ElementDetectionResult = { elements in
                ElementDetectionResult(
                    snapshotId: "application-partial",
                    screenshotPath: "",
                    elements: elements,
                    metadata: DetectionMetadata(
                        detectionTime: 0.5,
                        elementCount: elements.all.count,
                        method: "AXorcist",
                        warnings: [DetectionMetadata.applicationScopedAccessibilityFallbackWarning],
                        windowContext: WindowContext(
                            applicationName: fixture.applicationInfo.name,
                            applicationBundleId: fixture.applicationInfo.bundleIdentifier,
                            applicationProcessId: fixture.applicationInfo.processIdentifier,
                            applicationProcessStartIdentity: fixture.applicationInfo.processStartIdentity
                        ),
                        truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true),
                        applicationScopedAccessibilityFallbackOrigin:
                        ApplicationScopedAccessibilityFallbackOrigin(windowIdentity: WindowMutationIdentity(
                            windowID: fixture.windowInfo.windowID,
                            ownerProcessIdentifier: fixture.applicationInfo.processIdentifier,
                            ownerProcessStartIdentity: processStartIdentity,
                            capturedBounds: fixture.windowInfo.bounds
                        ))
                    )
                )
            }
            automation.inspectAccessibilityTreeHandler = { _ in
                fallbackResult(DetectedElements(buttons: [partialElement]))
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
                    "--window-id", String(fixture.windowInfo.windowID),
                    "--tree",
                    "--no-screenshot",
                    "--json",
                ],
                services: context.services
            )
            let envelope = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            let data = try #require(envelope["data"] as? [String: Any])
            let targetReceipt = try #require(envelope["target_receipt"] as? [String: Any])

            #expect(result.exitStatus == 0)
            #expect(data["snapshot_id"] is NSNull)
            #expect(data["snapshot_reusable"] as? Bool == false)
            #expect(data["semantic_scope"] as? String == "application_partial")
            #expect(data["mutation_targeting_available"] as? Bool == false)
            let elements = try #require(data["ui_elements"] as? [[String: Any]])
            #expect(elements.count == 1)
            #expect(elements.first?["is_actionable"] as? Bool == false)
            #expect(elements.first?["is_value_settable"] == nil)
            #expect(data["interactable_count"] as? Int == 0)
            #expect(targetReceipt["pid"] as? Int == Int(fixture.applicationInfo.processIdentifier))
            #expect(targetReceipt["window_id"] == nil)
            #expect(try await context.snapshots.listSnapshots().isEmpty)

            let human = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--app", fixture.applicationInfo.name,
                    "--window-id", String(fixture.windowInfo.windowID),
                    "--tree",
                    "--no-screenshot",
                ],
                services: context.services
            )
            #expect(human.exitStatus == 0)
            #expect(human.stdout.contains("Interactable elements: 0"))
            #expect(human.stdout.contains("no reusable snapshot or mutation authority"))

            automation.inspectAccessibilityTreeHandler = { _ in fallbackResult(DetectedElements()) }
            let empty = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--app", fixture.applicationInfo.name,
                    "--window-id", String(fixture.windowInfo.windowID),
                    "--tree",
                    "--no-screenshot",
                    "--json",
                ],
                services: context.services
            )
            let emptyEnvelope = try #require(
                JSONSerialization.jsonObject(with: Data(empty.stdout.utf8)) as? [String: Any]
            )
            let emptyError = try #require(emptyEnvelope["error"] as? [String: Any])
            #expect(empty.exitStatus == 1)
            #expect(emptyError["code"] as? String == "ACCESSIBILITY_INCOMPLETE")
        }
    }
}
