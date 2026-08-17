import Foundation
import PeekabooAutomation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

extension SeeCommandRuntimeTests {
    @Test
    @MainActor
    func `legacy menu bar OCR fallback publishes its canonical no-change outcome`() throws {
        let result = SeeCommand.legacyMenuBarOCRDetectionResult(
            snapshotID: "legacy-menubar-ocr",
            elements: [],
            metadata: DetectionMetadata(
                detectionTime: 0.1,
                elementCount: 0,
                method: "OCR"
            )
        )

        let receipt = try SeeExecutionReceipt.validated(
            result,
            operation: "Legacy menu bar OCR",
            requiresOutcome: true,
            requiresTarget: false
        )

        #expect(result.outcome == .confirmedNoChange())
        #expect(receipt.outcome == .confirmedNoChange())
        #expect(receipt.targetReceipt == nil)
    }

    @Test
    @MainActor
    func `web focus See publishes its observation outcome and exact target receipt`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            automation.nextDetectionResult = fixture.detectionResult
            let (context, outputURL) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )
            defer { try? FileManager.default.removeItem(at: outputURL) }

            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--app", fixture.applicationInfo.name,
                    "--web-focus",
                    "--path", outputURL.path,
                    "--json",
                ],
                services: context.services
            )
            let data = try #require(result.stdout.data(using: .utf8))
            let response = try JSONDecoder().decode(CodableJSONResponse<SeeResult>.self, from: data)
            let outcome = try #require(response.outcome)
            let target = try #require(response.target_receipt)

            #expect(result.exitStatus == 0)
            #expect(response.effect == .unverifiable)
            #expect(outcome.state == .dispatchedUnverified)
            #expect(outcome.deliveryMechanism == .capturePipeline)
            #expect(outcome.deliveryMode == .background)
            #expect(outcome.dispatchedUnitCount == .one)
            #expect(target.processIdentifier == fixture.applicationInfo.processIdentifier)
            #expect(target.processStartIdentity == fixture.applicationInfo.processStartIdentity)
            #expect(target.windowID == fixture.windowInfo.windowID)

            let humanResult = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--app", fixture.applicationInfo.name,
                    "--web-focus",
                    "--path", outputURL.path,
                ],
                services: context.services
            )
            #expect(humanResult.exitStatus == 0)
            #expect(humanResult.stdout.contains("See conditional mutation dispatched but not verified"))
            #expect(humanResult.stdout.contains("Target receipt: pid=4242"))
        }
    }

    @Test
    @MainActor
    func `capture to prepare cancellation preserves conditional mutation receipt`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            automation.nextDetectionResult = fixture.detectionResult
            let (context, outputURL) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )
            defer { try? FileManager.default.removeItem(at: outputURL) }

            nonisolated(nonsending) func runCommand() async throws -> CommandRunResult {
                try await InProcessCommandRunner.run(
                    [
                        "see",
                        "--app", fixture.applicationInfo.name,
                        "--web-focus",
                        "--path", outputURL.path,
                        "--json",
                    ],
                    services: context.services
                )
            }
            let result = try await SeeCommandPreparationContext.$didCapture.withValue(
                { withUnsafeCurrentTask { $0?.cancel() } },
                operation: runCommand
            )
            let envelope = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            let outcome = try #require(envelope["outcome"] as? [String: Any])
            let target = try #require(envelope["target_receipt"] as? [String: Any])
            let error = try #require(envelope["error"] as? [String: Any])

            #expect(result.exitStatus == 1)
            #expect(outcome["state"] as? String == "dispatched_unverified")
            #expect(outcome["dispatched_unit_count"] as? Int == 1)
            #expect(target["pid"] as? Int == Int(fixture.applicationInfo.processIdentifier))
            #expect(target["window_id"] as? Int == fixture.windowInfo.windowID)
            #expect(error["mutation_dispatched"] as? Bool == true)
            #expect(error["retry_safe"] as? Bool == false)
        }
    }

    @Test
    @MainActor
    func `web focus timeout preserves mutation uncertainty and exact target receipt`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let suspension = SeeReceiptObservationSuspension()
            let automation = StubAutomationService()
            automation.detectElementsHandler = { _, _, _ in
                await suspension.wait()
                return fixture.detectionResult
            }
            let (context, outputURL) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )
            defer { try? FileManager.default.removeItem(at: outputURL) }

            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--app", fixture.applicationInfo.name,
                    "--web-focus",
                    "--timeout", "500ms",
                    "--path", outputURL.path,
                    "--json",
                ],
                services: context.services
            )
            await suspension.release()
            let envelope = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            let outcome = try #require(envelope["outcome"] as? [String: Any])
            let target = try #require(envelope["target_receipt"] as? [String: Any])
            let error = try #require(envelope["error"] as? [String: Any])

            #expect(result.exitStatus == 1)
            #expect(outcome["state"] as? String == "indeterminate")
            #expect(outcome["delivery_mechanism"] as? String == "capture_pipeline")
            #expect(outcome["delivery_mode"] as? String == "background")
            #expect(target["pid"] as? Int == Int(fixture.applicationInfo.processIdentifier))
            #expect(target["process_start_identity_decimal"] as? String == "4242")
            #expect(target["window_id"] as? Int == fixture.windowInfo.windowID)
            #expect(error["mutation_dispatched"] as? Bool == true)
            #expect(error["retry_safe"] as? Bool == false)
            #expect((error["message"] as? String)?.contains("conditional") == true)
        }
    }

    @Test
    @MainActor
    func `tree only web focus uses result adapter and publishes exact receipt`() async throws {
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
                    "--web-focus",
                    "--json",
                ],
                services: context.services
            )
            let data = try #require(result.stdout.data(using: .utf8))
            let response = try JSONDecoder().decode(CodableJSONResponse<SeeResult>.self, from: data)
            let outcome = try #require(response.outcome)
            let target = try #require(response.target_receipt)

            #expect(result.exitStatus == 0)
            #expect(outcome.state == .dispatchedUnverified)
            #expect(outcome.deliveryMechanism == .accessibilityAction)
            #expect(outcome.deliveryMode == .background)
            #expect(target.processIdentifier == fixture.applicationInfo.processIdentifier)
            #expect(target.processStartIdentity == fixture.applicationInfo.processStartIdentity)
            #expect(target.windowID == fixture.windowInfo.windowID)
            #expect(automation.inspectAccessibilityTreeCalls.count == 1)
        }
    }

    @Test
    @MainActor
    func `tree only See rejects every nonpublishable returned provider outcome`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let delivery = DesktopActionOutcome.Delivery(
                mechanism: .accessibilityAction,
                mode: .background
            )
            let outcomes: [DesktopActionOutcome?] = [
                .refused(reason: .permissionDenied),
                .partial(delivery: delivery, unitCount: DesktopActionOutcome.DispatchUnitCount(2)),
                .suspectedNoop(delivery: delivery, unitCount: .one),
                .indeterminate(
                    delivery: delivery,
                    evidence: .completionUnknown,
                    unitCount: DesktopActionOutcome.DispatchUnitCount(3)
                ),
                nil,
            ]

            for outcome in outcomes {
                let automation = ResultAwareSeeAutomationService()
                automation.inspectionResult = try UIAutomationActionResult(
                    payload: fixture.detectionResult,
                    outcome: outcome,
                    targetIdentity: Self.seeFixtureTargetIdentity(fixture)
                )
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
                        "--web-focus",
                        "--json",
                    ],
                    services: context.services
                )
                let envelope = try #require(
                    JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
                )
                let projected = try #require(envelope["outcome"] as? [String: Any])
                let target = try #require(envelope["target_receipt"] as? [String: Any])
                let expectedState = outcome?.state.rawValue ?? DesktopActionOutcome.State.indeterminate.rawValue

                #expect(result.exitStatus == 1)
                #expect(projected["state"] as? String == expectedState)
                #expect(target["pid"] as? Int == Int(fixture.applicationInfo.processIdentifier))
                #expect(target["window_id"] as? Int == fixture.windowInfo.windowID)
            }
        }
    }

    @Test
    @MainActor
    func `tree only See publishes every admitted returned provider outcome`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let delivery = DesktopActionOutcome.Delivery(
                mechanism: .accessibilityAction,
                mode: .background
            )
            let outcomes: [DesktopActionOutcome] = [
                .confirmedChange(delivery: delivery, unitCount: .one),
                .confirmedNoChange(),
                .dispatchedUnverified(delivery: delivery, evidence: .deliveryAccepted, unitCount: .one),
            ]

            for outcome in outcomes {
                let automation = ResultAwareSeeAutomationService()
                automation.inspectionResult = try UIAutomationActionResult(
                    payload: fixture.detectionResult,
                    outcome: outcome,
                    targetIdentity: Self.seeFixtureTargetIdentity(fixture)
                )
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
                        "--web-focus",
                        "--json",
                    ],
                    services: context.services
                )
                let response = try JSONDecoder().decode(
                    CodableJSONResponse<SeeResult>.self,
                    from: Data(result.stdout.utf8)
                )

                #expect(result.exitStatus == 0)
                #expect(response.outcome?.state == outcome.state)
            }
        }
    }

    @Test
    @MainActor
    func `tree only postprocessing failure preserves provider outcome and target`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = ResultAwareSeeAutomationService()
            let incomplete = ElementDetectionResult(
                snapshotId: fixture.snapshotId,
                screenshotPath: "",
                elements: fixture.detectionResult.elements,
                metadata: DetectionMetadata(
                    detectionTime: 0.1,
                    elementCount: fixture.detectionResult.elements.all.count,
                    method: "stub",
                    windowContext: WindowContext(
                        applicationName: fixture.applicationInfo.name,
                        applicationProcessId: fixture.applicationInfo.processIdentifier,
                        windowTitle: fixture.windowInfo.title,
                        windowID: fixture.windowInfo.windowID,
                        windowBounds: fixture.windowInfo.bounds
                    )
                )
            )
            automation.inspectionResult = try UIAutomationActionResult(
                payload: incomplete,
                outcome: .dispatchedUnverified(
                    route: .bridge,
                    delivery: .init(mechanism: .accessibilityAction, mode: .background),
                    evidence: .deliveryAccepted,
                    unitCount: .one
                ),
                targetIdentity: Self.seeFixtureTargetIdentity(fixture)
            )
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
                    "--web-focus",
                    "--json",
                ],
                services: context.services
            )
            let envelope = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            let outcome = try #require(envelope["outcome"] as? [String: Any])
            let target = try #require(envelope["target_receipt"] as? [String: Any])
            let error = try #require(envelope["error"] as? [String: Any])

            #expect(result.exitStatus == 1)
            #expect(outcome["state"] as? String == "dispatched_unverified")
            #expect(outcome["route"] as? String == "bridge")
            #expect(target["pid"] as? Int == Int(fixture.applicationInfo.processIdentifier))
            #expect(target["process_start_identity_decimal"] as? String == "4242")
            #expect(target["window_id"] as? Int == fixture.windowInfo.windowID)
            #expect(error["retry_safe"] as? Bool == false)
            #expect(error["mutation_dispatched"] as? Bool == true)
            #expect((error["message"] as? String)?.contains("conditional desktop mutation") == true)

            let humanResult = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--app", fixture.applicationInfo.name,
                    "--tree",
                    "--no-screenshot",
                    "--web-focus",
                ],
                services: context.services
            )
            #expect(humanResult.exitStatus == 1)
            #expect(humanResult.stderr.contains("Target receipt: pid=4242"))
            #expect(humanResult.stderr.contains("process_start_identity=4242 window_id=101"))
        }
    }

    @Test
    @MainActor
    func `multi capture receipt composition aggregates only compatible outcomes`() throws {
        let targetA = DesktopActionTargetReceipt(processIdentifier: 10, processStartIdentity: 20, windowID: 30)
        let targetB = DesktopActionTargetReceipt(processIdentifier: 10, processStartIdentity: 20, windowID: 31)
        let delivery = DesktopActionOutcome.Delivery(mechanism: .capturePipeline, mode: .background)
        let compatible = SeeExecutionReceipt.combining([
            SeeExecutionReceipt(
                outcome: .confirmedChange(delivery: delivery, unitCount: .one),
                targetReceipt: targetA
            ),
            SeeExecutionReceipt(
                outcome: .confirmedChange(delivery: delivery, unitCount: .one),
                targetReceipt: targetB
            ),
        ])

        #expect(compatible.outcome?.state == .confirmedChange)
        #expect(compatible.outcome?.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(2))
        #expect(compatible.targetReceipt == nil)

        let mixedMechanisms = SeeExecutionReceipt.combining([
            SeeExecutionReceipt(
                outcome: .confirmedChange(delivery: delivery, unitCount: .one),
                targetReceipt: targetA
            ),
            SeeExecutionReceipt(
                outcome: .confirmedChange(
                    delivery: .init(mechanism: .accessibilityAction, mode: .background),
                    unitCount: .one
                ),
                targetReceipt: targetA
            ),
        ])
        #expect(mixedMechanisms.outcome?.state == .confirmedChange)
        #expect(mixedMechanisms.outcome?.delivery?.mechanism == .composite)
        #expect(mixedMechanisms.outcome?.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(2))
        #expect(mixedMechanisms.targetReceipt == targetA)

        let incompatible = SeeExecutionReceipt.combining([
            SeeExecutionReceipt(
                outcome: .confirmedChange(delivery: delivery, unitCount: .one),
                targetReceipt: targetA
            ),
            SeeExecutionReceipt(
                outcome: .confirmedChange(route: .bridge, delivery: delivery, unitCount: .one),
                targetReceipt: targetA
            ),
        ])
        #expect(incompatible.outcome == nil)
        #expect(incompatible.targetReceipt == targetA)

        let missingOutcome = SeeExecutionReceipt.combining([
            SeeExecutionReceipt(
                outcome: .confirmedChange(route: .bridge, delivery: delivery, unitCount: .one),
                targetReceipt: targetA
            ),
            SeeExecutionReceipt(outcome: nil, targetReceipt: targetA),
        ])
        #expect(missingOutcome.outcome?.state == .indeterminate)
        #expect(missingOutcome.outcome?.route == .bridge)
        #expect(missingOutcome.outcome?.dispatchState == .mayHaveDispatched(
            unitCount: DesktopActionOutcome.DispatchUnitCount(2)
        ))
        #expect(missingOutcome.targetReceipt == targetA)

        let partial = SeeExecutionReceipt.combining([
            SeeExecutionReceipt(
                outcome: .partial(route: .bridge, delivery: delivery, unitCount: .one),
                targetReceipt: targetA
            ),
            SeeExecutionReceipt(
                outcome: .confirmedNoChange(route: .bridge),
                targetReceipt: targetA
            ),
        ])
        #expect(partial.outcome?.state == .partial)
        #expect(partial.outcome?.dispatchState.unitCount == .one)
        #expect(partial.targetReceipt == targetA)

        let processTarget = try DesktopTargetIdentity(processIdentity: ApplicationProcessIdentity(
            processIdentifier: 10,
            processStartIdentity: 20
        ))
        let processBound = SeeExecutionReceipt(
            UIAutomationActionResult(payload: true, outcome: nil, targetIdentity: processTarget),
            fallbackTargetReceipt: targetA
        )
        #expect(processBound.targetReceipt == DesktopActionTargetReceipt(
            processIdentifier: 10,
            processStartIdentity: 20
        ))
    }

    @Test
    func `typed predispatch postprocessing failure preserves prior dispatch`() throws {
        let target = DesktopActionTargetReceipt(
            processIdentifier: 40,
            processStartIdentity: 50,
            windowID: 60
        )
        let receipt = SeeExecutionReceipt(
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .capturePipeline, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: DesktopActionOutcome.DispatchUnitCount(2)
            ),
            targetReceipt: target
        )
        let laterFailure = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Postprocessing target disappeared"
        )

        let failure = try #require(
            receipt.preservingFailure(laterFailure, operation: "see") as? DesktopActionFailure
        )

        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.targetReceipt == target)
    }

    @Test
    func `confirmed no-change survives a later untyped publication failure`() throws {
        let target = DesktopActionTargetReceipt(
            processIdentifier: 40,
            processStartIdentity: 50,
            windowID: 60
        )
        let preserved = SeeExecutionReceipt(
            outcome: .confirmedNoChange(route: .bridge),
            targetReceipt: target
        )
        .preservingFailure(
            CocoaError(.fileWriteUnknown),
            operation: "see publication"
        )
        let envelopeError = try #require(preserved as? any ResultEnvelopeError)
        let metadata = actionErrorEnvelopeMetadata(for: preserved, isActionCommand: true)

        #expect(envelopeError.envelopeActionFailure == nil)
        #expect(metadata.outcome == .confirmedNoChange(route: .bridge))
        #expect(metadata.retrySafe == true)
        #expect(metadata.mutationDispatched == false)
        #expect(metadata.targetReceipt == target)
    }

    @Test
    func `two dispatched See phases drop incompatible targets and sum units`() throws {
        let priorTarget = DesktopActionTargetReceipt(
            processIdentifier: 41,
            processStartIdentity: 51,
            windowID: 61
        )
        let receipt = SeeExecutionReceipt(
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .capturePipeline, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one
            ),
            targetReceipt: priorTarget
        )
        let laterFailure = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .capturePipeline, mode: .background),
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "Postprocessing dispatch completion is unknown"
        ).attributed(to: DesktopActionTargetReceipt(
            processIdentifier: 41,
            processStartIdentity: 51,
            windowID: 62
        ))

        let failure = try #require(
            receipt.preservingFailure(laterFailure, operation: "see") as? DesktopActionFailure
        )

        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 3)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.targetReceipt == nil)
    }

    @Test
    func `See failure target follows only phases that dispatched`() throws {
        let diagnosticTarget = DesktopActionTargetReceipt(
            processIdentifier: 42,
            processStartIdentity: 52,
            windowID: 63
        )
        let laterDispatch = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .capturePipeline, mode: .background),
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "Unknown later dispatch target"
        )
        let laterOnly = try #require(
            SeeExecutionReceipt(
                outcome: .confirmedNoChange(),
                targetReceipt: diagnosticTarget
            ).preservingFailure(laterDispatch, operation: "see") as? DesktopActionFailure
        )
        #expect(laterOnly.targetReceipt == nil)
        #expect(laterOnly.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(laterOnly.outcome.retrySafety == .unsafe)

        let priorOnly = try #require(
            SeeExecutionReceipt(
                outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .capturePipeline, mode: .background),
                    evidence: .deliveryAccepted,
                    unitCount: .one
                ),
                targetReceipt: nil
            ).preservingFailure(
                DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Later diagnostic target"
                ).attributed(to: diagnosticTarget),
                operation: "see"
            ) as? DesktopActionFailure
        )
        #expect(priorOnly.targetReceipt == nil)
        #expect(priorOnly.outcome.dispatchState.unitCount == .one)
        #expect(priorOnly.outcome.retrySafety == .unsafe)
    }

    @Test
    func `no prior See receipt leaves later failure unchanged`() throws {
        let laterFailure = DesktopActionFailure.preDispatchRefusal(
            reason: .permissionDenied,
            message: "Postprocessing was refused"
        ).attributed(to: DesktopActionTargetReceipt(
            processIdentifier: 43,
            processStartIdentity: 53
        ))

        let preserved = try #require(
            SeeExecutionReceipt.none.preservingFailure(laterFailure, operation: "see") as? DesktopActionFailure
        )

        #expect(preserved == laterFailure)
        #expect(SeeExecutionReceipt.none.preservingFailure(
            CancellationError(),
            operation: "see"
        ) is CancellationError)
    }

    @Test
    func `local See receipt rejects provider and payload target mismatch`() throws {
        let fixture = Self.makeSeeCommandRuntimeFixture()
        let providerTarget = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 9991,
            processStartIdentity: 9992
        ))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2)
        )

        do {
            _ = try SeeExecutionReceipt.validated(
                UIAutomationActionResult(
                    payload: fixture.detectionResult,
                    outcome: outcome,
                    targetIdentity: providerTarget
                ),
                operation: "Local See",
                requiresOutcome: true,
                requiresTarget: true
            )
            Issue.record("Expected mismatched local See targets to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt == nil)
        }
    }

    @Test
    func `local See receipt coalesces compatible process and exact payload target`() throws {
        let fixture = Self.makeSeeCommandRuntimeFixture()
        let processStartIdentity = try #require(fixture.applicationInfo.processStartIdentity)
        let providerTarget = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: fixture.applicationInfo.processIdentifier,
            processStartIdentity: processStartIdentity
        ))

        let receipt = try SeeExecutionReceipt.validated(
            UIAutomationActionResult(
                payload: fixture.detectionResult,
                outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .accessibilityAction, mode: .background),
                    evidence: .deliveryAccepted,
                    unitCount: .one
                ),
                targetIdentity: providerTarget
            ),
            operation: "Local See",
            requiresOutcome: true,
            requiresTarget: true
        )

        #expect(
            receipt.targetReceipt?.processIdentifier == fixture.applicationInfo.processIdentifier
        )
        #expect(receipt.targetReceipt?.windowID == fixture.windowInfo.windowID)
    }

    @Test
    @MainActor
    func `foreground pixel focus fails before exact window dispatch`() {
        do {
            try SeeCommand.requireSupportedPixelCaptureFocus(.foreground, target: .windowID(42))
            Issue.record("Expected exact-window foreground focus to fail closed")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .operationUnsupported)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

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

    private static func seeFixtureTargetIdentity(_ fixture: RuntimeFixture) throws -> DesktopTargetIdentity {
        let identity = try #require(fixture.windowInfo.mutationIdentity)
        return try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: fixture.windowInfo.bounds
        ))
    }
}

private actor SeeReceiptObservationSuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !self.released else { return }
        await withCheckedContinuation { self.continuation = $0 }
    }

    func release() {
        self.released = true
        self.continuation?.resume()
        self.continuation = nil
    }
}

@MainActor
private final class ResultAwareSeeAutomationService:
    StubAutomationService,
    UIAutomationObservationActionResultProviding {
    var inspectionResult: UIAutomationActionResult<ElementDetectionResult>?

    func detectElementsActionResult(
        in imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?,
        requestTimeoutSec _: TimeInterval?
    ) async throws -> UIAutomationActionResult<ElementDetectionResult> {
        try await UIAutomationActionResult(
            payload: super.detectElements(
                in: imageData,
                snapshotId: snapshotId,
                windowContext: windowContext
            ),
            outcome: nil
        )
    }

    func inspectAccessibilityTreeActionResult(
        windowContext _: WindowContext?
    ) async throws -> UIAutomationActionResult<ElementDetectionResult> {
        guard let inspectionResult else {
            throw TestStubError.unimplemented(#function)
        }
        return inspectionResult
    }
}
