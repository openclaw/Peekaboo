import Commander
import PeekabooCore
import Testing
@testable import PeekabooCLI

@MainActor
struct CaptureCommandEngineSelectionTests {
    @Test(arguments: [CaptureScope.Kind.screen, .window, .frontmost, .region], [true, false])
    func `unselected remote capture does not open an engine scope`(
        kind: CaptureScope.Kind,
        supportsEngineScope: Bool
    ) throws {
        #expect(try CaptureCommandOptionParser.enginePreference(
            cliValue: " \n ",
            configuredValue: nil,
            kind: kind,
            gateOwner: .service,
            supportsEngineScope: supportsEngineScope
        ) == nil)
    }

    @Test(arguments: [CaptureScope.Kind.screen, .window, .frontmost, .region])
    func `explicit remote auto stays auto including region capture`(kind: CaptureScope.Kind) throws {
        #expect(try CaptureCommandOptionParser.enginePreference(
            cliValue: " auto ",
            configuredValue: "modern",
            kind: kind,
            gateOwner: .service,
            supportsEngineScope: true
        ) == .auto)
    }

    @Test(arguments: [CaptureScope.Kind.screen, .window, .frontmost, .region])
    func `caller default retains local region preference`(kind: CaptureScope.Kind) throws {
        #expect(try CaptureCommandOptionParser.enginePreference(
            cliValue: nil,
            configuredValue: nil,
            kind: kind,
            gateOwner: .caller,
            supportsEngineScope: true
        ) == (kind == .region ? .legacy : .auto))
        #expect(try CaptureCommandOptionParser.enginePreference(
            cliValue: nil,
            configuredValue: nil,
            kind: kind,
            gateOwner: .caller,
            supportsEngineScope: false
        ) == nil)
    }

    @Test(arguments: [CaptureTransactionGateOwner.caller, .service])
    func `empty CLI value preserves configured modern even for regions`(owner: CaptureTransactionGateOwner) throws {
        #expect(try CaptureCommandOptionParser.enginePreference(
            cliValue: " \t ",
            configuredValue: " SCKIT ",
            kind: .region,
            gateOwner: owner,
            supportsEngineScope: true
        ) == .modern)
        #expect(ObservationCommandSupport.captureEnginePreference(
            cliValue: "", configuredValue: "modern"
        ) == .modern)
    }

    @Test(arguments: ["cg", "classic", "legacy-only", "false", "0", "no"])
    func `explicit aliases share observation normalization`(engine: String) throws {
        #expect(try CaptureCommandOptionParser.enginePreference(
            cliValue: engine,
            configuredValue: "modern",
            kind: .window,
            gateOwner: .service,
            supportsEngineScope: true
        ) == .legacy)
    }

    @Test(arguments: [CaptureTransactionGateOwner.caller, .service])
    func `unsupported services cannot silently ignore an explicit engine`(owner: CaptureTransactionGateOwner) {
        #expect(throws: ValidationError.self) {
            try CaptureCommandOptionParser.enginePreference(
                cliValue: "auto",
                configuredValue: nil,
                kind: .window,
                gateOwner: owner,
                supportsEngineScope: false
            )
        }
    }

    @Test
    func `unknown configured engine refuses instead of becoming auto`() {
        #expect(throws: ValidationError.self) {
            try CaptureCommandOptionParser.enginePreference(
                cliValue: nil,
                configuredValue: "warp-drive",
                kind: .window,
                gateOwner: .service,
                supportsEngineScope: true
            )
        }
    }
}
