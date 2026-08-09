import PeekabooCore
import PeekabooFoundation

@MainActor
protocol RuntimeBackedCommand: RuntimeOptionsConfigurable {
    var runtime: CommandRuntime? { get set }
}

extension RuntimeBackedCommand {
    var resolvedRuntime: CommandRuntime {
        guard let runtime else {
            preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
        }
        return runtime
    }

    var services: any PeekabooServiceProviding {
        self.resolvedRuntime.services
    }

    var logger: Logger {
        self.resolvedRuntime.logger
    }

    var outputLogger: Logger {
        self.logger
    }

    var jsonOutput: Bool {
        self.runtime?.configuration.jsonOutput ?? self.runtimeOptions.jsonOutput
    }
}
