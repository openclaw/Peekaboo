import Darwin
import Foundation
import PeekabooCLI

@main
struct Main {
    static func main() async {
        do {
            let gateApplied = try AgentExecutionReleaseGate.waitIfConfigured()
            #if DEBUG
            if gateApplied, CommandLine.arguments.dropFirst() == ["_agent-execution-process-limit-probe"] {
                let probe = AgentExecutionReleaseGate.processCreationProbe()
                let data = try JSONEncoder().encode(probe)
                FileHandle.standardOutput.write(data + Data([0x0A]))
                Darwin.exit(probe.success ? EX_OK : EX_SOFTWARE)
            }
            #endif
        } catch {
            let message = "Peekaboo Agent release gate refused execution: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Darwin.exit(EX_CONFIG)
        }
        await runPeekabooCLI()
    }
}
