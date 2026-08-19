import Darwin
import Foundation
import PeekabooCLI

@main
struct Main {
    static func main() async {
        do {
            try AgentExecutionReleaseGate.waitIfConfigured()
        } catch {
            let message = "Peekaboo Agent release gate refused execution: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Darwin.exit(EX_CONFIG)
        }
        await runPeekabooCLI()
    }
}
