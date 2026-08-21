import PeekabooAutomation
import PeekabooCore

@MainActor
enum RuntimeServiceFactory {
    static func makeLocalServices(options: CommandRuntimeOptions) -> PeekabooServices {
        PeekabooServices(
            snapshotManager: SnapshotManager(
                desktopMutationWatermarkStore: DesktopMutationWatermarkStore()
            ),
            inputPolicy: PeekabooAutomation.ConfigurationManager.shared.getUIInputPolicy(
                cliStrategy: options.inputStrategy
            ),
            initializeAgentService: options.requiresAgentService
        )
    }
}
