import PeekabooCore

@MainActor
protocol InjectedRuntimeBackedCommand {
    var runtime: CommandRuntime? { get set }
}

extension InjectedRuntimeBackedCommand {
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
        self.resolvedRuntime.configuration.jsonOutput
    }
}

@MainActor
protocol RuntimeBackedCommand: InjectedRuntimeBackedCommand, RuntimeOptionsConfigurable {}

extension RuntimeBackedCommand {
    var jsonOutput: Bool {
        self.runtime?.configuration.jsonOutput ?? self.runtimeOptions.jsonOutput
    }
}
