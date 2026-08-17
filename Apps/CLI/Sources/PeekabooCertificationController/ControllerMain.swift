import Darwin
import Foundation

@main
struct PeekabooCertificationControllerMain {
    private static let help = """
    Run one source-owned Peekaboo multi-target certification controller.

    Usage:
      peekaboo-certification-controller --plan OWNER_PRIVATE_PLAN.json
      peekaboo-certification-controller --observe-only-plan OWNER_PRIVATE_PLAN.json
      peekaboo-certification-controller --held-pointer-plan OWNER_PRIVATE_PLAN.json
      peekaboo-certification-controller --attest-monitor OWNER_PRIVATE_PLAN.json

    The controller performs one exact protocol-1.30 handshake, keeps one Bridge client/session,
    executes the four closed catalog slots for one exact window, and publishes a pass receipt only
    after exactly four listener-signed bundles have been verified and exported.

    Observe-only mode performs three fresh, exact-window Accessibility value reads, emits the closed
    foreground observation/restoration witness, and remains alive until its owner releases it.

    Held-pointer mode runs the embedding-only protocol-1.30 split down/up lifecycle against one
    exact process-generation/window target and publishes six listener-signed operation bundles.

    Monitor attestation verifies an exact Unix peer PID, exchanges one random challenge, and writes
    the closed owner-private response without creating another signing authority.
    """

    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] || arguments == ["-h"] {
                print(self.help)
                return
            }
            guard arguments.count == 2,
                  [
                      "--plan",
                      "--observe-only-plan",
                      "--held-pointer-plan",
                      "--attest-monitor",
                      "--inspect-code",
                  ].contains(arguments[0])
            else {
                throw CertificationControllerError.invalidArguments(self.help)
            }
            let planURL = URL(fileURLWithPath: arguments[1], isDirectory: false)
            let receipt = if arguments[0] == "--plan" {
                try await CertificationControllerRunner.run(planURL: planURL)
            } else if arguments[0] == "--observe-only-plan" {
                try await CertificationObserveOnlyRunner.run(planURL: planURL)
            } else if arguments[0] == "--held-pointer-plan" {
                try await HeldPointerCertificationRunner.run(planURL: planURL)
            } else if arguments[0] == "--attest-monitor" {
                try await CertificationMonitorAttestationRunner.run(planURL: planURL)
            } else {
                try await CertificationCodeIdentityRunner.run(planURL: planURL)
            }
            let output = ["result": "passed", "receipt": receipt.path]
            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            guard let encoded = String(bytes: data, encoding: .utf8) else {
                throw CertificationControllerError.runtimeRefusal("Cannot encode controller result.")
            }
            print(encoded)
        } catch {
            let message = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
            FileHandle.standardError.write(Data("peekaboo-certification-controller: \(message)\n".utf8))
            Darwin.exit(1)
        }
    }
}
