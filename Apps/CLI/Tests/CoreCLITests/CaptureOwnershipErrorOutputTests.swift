import Commander
import Foundation
import PeekabooBridge
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
@MainActor
struct CaptureOwnershipErrorOutputTests {
    @Test(arguments: ["default", "modern"], ["command", "entrypoint"])
    func `nonaction see preflight JSON retains selected host and every blocker`(
        engine: String,
        emitter: String
    ) throws {
        var see = SeeCommand()
        see.runtimeOptions = try CommanderCLIBinder.makeRuntimeOptions(
            from: .init(
                positional: [],
                options: engine == "modern" ? ["captureEngine": [engine]] : [:],
                flags: ["json"]
            ),
            commandType: SeeCommand.self,
            environment: [:]
        )
        #expect(see.defaultEffect == nil)
        let error = PreDispatchActionError(
            message: Self.diagnostic.userMessage,
            code: .CAPTURE_FAILED,
            hint: nil,
            reason: .runtimeIncompatible,
            screenCaptureKitOwnershipDiagnostic: Self.diagnostic
        )
        // Use the command's classification without constructing a runtime or accessing its services/logger.
        let output = try Self.captureJSON {
            if emitter == "command" {
                OutputCommand(defaultEffect: see.defaultEffect).handleError(error)
            } else {
                ResultEnvelopeContext.$isActionCommand.withValue(false) {
                    printGenericError(error, jsonOutput: true)
                }
            }
        }
        try Self.expectDiagnostic(output)
        #expect(output.response.outcome == nil)
        #expect(output.response.effect == nil)
        #expect(output.response.error?.retry_safe == nil)
        #expect(output.response.error?.mutation_dispatched == nil)
    }

    @Test(arguments: ["command", "generic", "render", "entrypoint"])
    func `remote leaf failure retains capture code and typed evidence`(emitter: String) throws {
        let failure = DesktopActionFailure.refused(
            route: .bridge,
            reason: .runtimeIncompatible,
            message: Self.diagnostic.userMessage
        ).preservingScreenCaptureKitDiagnostic(Self.diagnostic)
        #expect(failure.standardErrorCode == .captureFailed)
        let output = try Self.emit(failure, using: emitter)
        try Self.expectDiagnostic(output)
        #expect(output.response.outcome == failure.outcome.projection)
        #expect(output.response.error?.retry_safe == true)
        #expect(output.response.error?.mutation_dispatched == false)
    }

    @Test(arguments: ["command", "generic", "render", "entrypoint"])
    func `ownership blocker never overwrites earlier dispatched failure`(emitter: String) throws {
        let failure = DesktopActionFailure.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one,
            message: "A mutation was dispatched before capture failed"
        ).preservingScreenCaptureKitDiagnostic(Self.diagnostic)
        let output = try Self.emit(failure, using: emitter)
        try Self.expectDiagnostic(output)
        #expect(output.response.outcome == failure.outcome.projection)
        #expect(output.response.error?.retry_safe == false)
        #expect(output.response.error?.mutation_dispatched == true)
    }

    @Test(arguments: ["command", "generic", "entrypoint"])
    func `direct diagnostic emits capture code without action claims`(emitter: String) throws {
        let output = try Self.captureJSON {
            if emitter == "command" {
                OutputCommand(defaultEffect: nil).handleError(Self.diagnostic)
            } else if emitter == "generic" {
                handleGenericError(Self.diagnostic, jsonOutput: true, logger: .shared)
            } else {
                printGenericError(Self.diagnostic, jsonOutput: true)
            }
        }
        try Self.expectDiagnostic(output)
        #expect(output.response.outcome == nil)
        #expect(output.response.error?.mutation_dispatched == nil)
        #expect(OutputCommand(defaultEffect: nil).mapErrorToCode(Self.diagnostic) == .CAPTURE_FAILED)
        #expect(genericErrorCode(for: Self.diagnostic) == .CAPTURE_FAILED)
    }

    @Test
    func `Bridge error envelope retains independent diagnostic`() throws {
        let error = PeekabooBridgeErrorEnvelope(
            code: .internalError,
            message: Self.diagnostic.userMessage,
            context: PeekabooBridgeErrorEnvelope.standardizedErrorContextPrefix +
                StandardErrorCode.captureFailed.rawValue,
            screenCaptureKitOwnershipDiagnostic: Self.diagnostic
        )
        let output = try Self.captureJSON { OutputCommand(defaultEffect: nil).handleError(error) }
        try Self.expectDiagnostic(output)
        #expect(output.response.outcome == nil)
        #expect(output.response.error?.mutation_dispatched == nil)
    }

    @Test
    func `unrelated errors omit diagnostic and old JSON still decodes`() throws {
        let output = try Self.captureJSON {
            OutputCommand(defaultEffect: nil).handleError(Commander.ValidationError("Invalid input"))
        }
        #expect(output.response.error?.code == "VALIDATION_ERROR")
        #expect(output.diagnostic == nil)
        #expect(String(data: output.data, encoding: .utf8)?
            .contains("screen_capture_kit_ownership_diagnostic") == false)
        let old = Data(
            #"{"success":false,"data":null,"debug_logs":[],"error":{"code":"CAPTURE_FAILED","message":"Old error"}}"#
                .utf8
        )
        let decoded = try JSONDecoder().decode(JSONResponse.self, from: old)
        #expect(decoded.error?.message == "Old error")
        #expect(decoded.error?.screen_capture_kit_ownership_diagnostic == nil)
    }

    @Test(arguments: ["command", "generic", "entrypoint"])
    func `wrapped failure retains typed capture evidence and prior mutation`(emitter: String) throws {
        let failure = DesktopActionFailure.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one,
            message: "Capture failed after input",
            hint: "Observe the target before retrying.",
            causeDescription: "Synthetic ownership refusal"
        ).attributed(to: .init(processIdentifier: 3131, processStartIdentity: 4141, windowID: 73))
            .preservingScreenCaptureKitDiagnostic(Self.diagnostic)
        let error = WrappedFailure(failure: failure)
        #expect(screenCaptureKitOwnershipDiagnostic(for: error) == Self.diagnostic)
        #expect(OutputCommand(defaultEffect: .unverifiable).mapErrorToCode(error) == .CAPTURE_FAILED)
        #expect(genericErrorCode(for: error) == .CAPTURE_FAILED)
        let output = try Self.captureJSON {
            switch emitter {
            case "command":
                OutputCommand(defaultEffect: .unverifiable).handleError(error)
            case "generic":
                handleGenericError(error, jsonOutput: true, logger: .shared)
            default:
                ResultEnvelopeContext.$isActionCommand.withValue(true) {
                    printGenericError(error, jsonOutput: true)
                }
            }
        }
        try Self.expectDiagnostic(output)
        #expect(output.response.outcome == failure.outcome.projection)
        #expect(output.response.target_receipt == failure.targetReceipt)
        #expect(output.response.error?.retry_safe == false)
        #expect(output.response.error?.mutation_dispatched == true)
        #expect(output.response.error?.hint == failure.hint)
    }

    @Test
    func `pre-dispatch wrapping preserves the direct ownership diagnostic`() {
        let error = OutputCommand(defaultEffect: nil).preDispatchActionError(for: Self.diagnostic)
        #expect(error.code == .CAPTURE_FAILED)
        #expect(screenCaptureKitOwnershipDiagnostic(for: error) == Self.diagnostic)
    }

    @Test
    func `standalone output diagnostic does not invent action metadata`() throws {
        let output = try Self.captureJSON {
            outputError(
                message: Self.diagnostic.userMessage,
                code: .CAPTURE_FAILED,
                screenCaptureKitOwnershipDiagnostic: Self.diagnostic,
                logger: .shared
            )
        }
        try Self.expectDiagnostic(output)
        #expect(output.response.outcome == nil)
        #expect(output.response.effect == nil)
        #expect(output.response.error?.retry_safe == nil)
        #expect(output.response.error?.mutation_dispatched == nil)
    }

    @Test(arguments: ["command", "generic", "render", "entrypoint"])
    func `known capture failure code survives without new diagnostic`(emitter: String) throws {
        let failure = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .runtimeIncompatible,
            message: "Legacy capture refusal",
            standardErrorCode: .captureFailed
        )
        let output = try Self.emit(failure, using: emitter)
        #expect(output.response.error?.code == "CAPTURE_FAILED")
        #expect(output.diagnostic == nil)
        #expect(String(data: output.data, encoding: .utf8)?
            .contains("screen_capture_kit_ownership_diagnostic") == false)
        #expect(output.response.outcome == failure.outcome.projection)
    }

    private struct WrappedFailure: LocalizedError, ResultEnvelopeError {
        let failure: DesktopActionFailure
        nonisolated var errorDescription: String? {
            self.failure.message
        }

        nonisolated var envelopeCode: ErrorCode? {
            .INTERACTION_FAILED
        }

        nonisolated var envelopeEffect: ActionEffect? {
            self.failure.outcome.effect
        }

        nonisolated var envelopeHint: String? {
            self.failure.hint
        }

        nonisolated var envelopeActionFailure: DesktopActionFailure? {
            self.failure
        }
    }

    private static func emit(_ failure: DesktopActionFailure, using emitter: String) throws -> CapturedOutput {
        try self.captureJSON {
            switch emitter {
            case "command":
                OutputCommand(defaultEffect: .unverifiable).handleError(failure)
            case "generic":
                handleGenericError(failure, jsonOutput: true, logger: .shared)
            case "entrypoint":
                ResultEnvelopeContext.$isActionCommand.withValue(true) {
                    printGenericError(failure, jsonOutput: true)
                }
            default:
                renderDesktopActionFailure(failure, jsonOutput: true, logger: .shared)
            }
        }
    }

    private static func expectDiagnostic(_ output: CapturedOutput) throws {
        #expect(output.response.success == false)
        #expect(output.response.error?.code == "CAPTURE_FAILED")
        #expect(output.diagnostic == self.diagnostic)
        #expect(output.response.error?.screen_capture_kit_ownership_diagnostic == self.diagnostic)
        let legacy = try JSONDecoder().decode(LegacyEnvelope.self, from: output.data)
        #expect(legacy.error.code == "CAPTURE_FAILED")
        #expect(!legacy.error.message.isEmpty)
    }

    private struct OutputCommand: ErrorHandlingCommand, ActionOutputFormattable {
        let jsonOutput = true
        let defaultEffect: ActionEffect?
    }

    private struct CapturedOutput {
        let data: Data
        let response: JSONResponse
        let diagnostic: ScreenCaptureKitOwnershipDiagnostic?
    }

    private struct DiagnosticEnvelope: Decodable {
        struct Failure: Decodable {
            let screen_capture_kit_ownership_diagnostic: ScreenCaptureKitOwnershipDiagnostic?
        }

        let error: Failure
    }

    private struct LegacyEnvelope: Decodable {
        struct Failure: Decodable {
            let code: String
            let message: String
        }

        let error: Failure
    }

    private static func captureJSON(_ body: () -> Void) throws -> CapturedOutput {
        let pipe = Pipe()
        defer { Logger.shared.setJsonOutputMode(false) }
        fflush(stdout)
        let savedOutput = dup(STDOUT_FILENO)
        guard savedOutput >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(savedOutput) }
        guard dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        pipe.fileHandleForWriting.closeFile()
        body()
        fflush(stdout)
        guard dup2(savedOutput, STDOUT_FILENO) >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pipe.fileHandleForReading.closeFile()
        return try CapturedOutput(
            data: data,
            response: JSONDecoder().decode(JSONResponse.self, from: data),
            diagnostic: JSONDecoder().decode(DiagnosticEnvelope.self, from: data)
                .error.screen_capture_kit_ownership_diagnostic
        )
    }

    private static let diagnostic = ScreenCaptureKitOwnershipDiagnostic(
        kind: .uncoordinatedProcesses,
        stage: .entry,
        message: "Potential capture processes do not publish ownership support.",
        operation: "syntheticCapture",
        blockers: [
            .init(processIdentifier: 4242, processStartIdentity: 9001, executablePath: "/synthetic/PotentialHost"),
            .init(
                processIdentifier: 4343,
                processStartIdentity: 9002,
                executablePath: "/synthetic/OtherPotentialHost",
                socketPath: "/synthetic/other.sock",
                buildIdentity: "other-fixture"
            ),
        ],
        selectedHost: .init(
            processIdentifier: 3131,
            processStartIdentity: 4141,
            executablePath: "/synthetic/CurrentGUI",
            socketPath: "/synthetic/selected.sock",
            buildIdentity: "current-fixture",
            codeSignatureHash: "fixture-hash"
        )
    )
}
