import Commander

@available(macOS 14.0, *)
extension ConfigCommand.InitCommand: AsyncRuntimeCommand {}
@MainActor
extension ConfigCommand.InitCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.force = values.flag("force")
        if let timeout: CLIDuration = try values.decodeOption("timeout", as: CLIDuration.self) {
            self.timeout = timeout
        }
    }
}

@available(macOS 14.0, *)
extension ConfigCommand.ShowCommand: AsyncRuntimeCommand {}
@MainActor
extension ConfigCommand.ShowCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.effective = values.flag("effective")
        if let timeout: CLIDuration = try values.decodeOption("timeout", as: CLIDuration.self) {
            self.timeout = timeout
        }
    }
}

@available(macOS 14.0, *)
extension ConfigCommand.StatusCommand: AsyncRuntimeCommand {}
@MainActor
extension ConfigCommand.StatusCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        if let timeout: CLIDuration = try values.decodeOption("timeout", as: CLIDuration.self) {
            self.timeout = timeout
        }
    }
}

@available(macOS 14.0, *)
extension ConfigCommand.EditCommand: AsyncRuntimeCommand {}
@MainActor
extension ConfigCommand.EditCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.editor = values.singleOption("editor")
        self.printPath = values.flag("print-path")
    }
}

@available(macOS 14.0, *)
extension ConfigCommand.ValidateCommand: AsyncRuntimeCommand {}
@MainActor
extension ConfigCommand.ValidateCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        _ = values
    }
}

@available(macOS 14.0, *)
extension ConfigCommand.CredentialSetCommand: AsyncRuntimeCommand {}
@MainActor
extension ConfigCommand.CredentialSetCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.keyOrProvider = try values.decodePositional(0, label: "keyOrProvider")
        self.value = try values.decodePositional(1, label: "value")
        if let timeout: CLIDuration = try values.decodeOption("timeout", as: CLIDuration.self) {
            self.timeout = timeout
        }
    }
}

@available(macOS 14.0, *)
extension ConfigCommand.LoginCommand: AsyncRuntimeCommand {}
@MainActor
extension ConfigCommand.LoginCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.provider = try values.decodePositional(0, label: "provider")
        if let timeout: CLIDuration = try values.decodeOption("timeout", as: CLIDuration.self) {
            self.timeout = timeout
        }
        self.noBrowser = values.flag("no-browser")
    }
}

@available(macOS 14.0, *)
@available(macOS 14.0, *)
extension ConfigCommand.AddProviderCommand: AsyncRuntimeCommand {}
@MainActor
extension ConfigCommand.AddProviderCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.providerId = try values.decodePositional(0, label: "providerId")
        self.type = try values.requireOption("type", as: String.self)
        self.name = try values.requireOption("name", as: String.self)
        self.baseUrl = try values.requireOption("baseUrl", as: String.self)
        self.apiKey = try values.requireOption("apiKey", as: String.self)
        self.description = values.singleOption("description")
        self.headers = values.singleOption("headers")
        self.force = values.flag("force")
        self.dryRun = values.flag("dryRun")
    }
}

@available(macOS 14.0, *)
extension ConfigCommand.ListProvidersCommand: AsyncRuntimeCommand {}
@MainActor
extension ConfigCommand.ListProvidersCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        _ = values
    }
}

@available(macOS 14.0, *)
extension ConfigCommand.TestProviderCommand: AsyncRuntimeCommand {}
@MainActor
extension ConfigCommand.TestProviderCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.providerId = try values.decodePositional(0, label: "providerId")
    }
}

@available(macOS 14.0, *)
extension ConfigCommand.RemoveProviderCommand: AsyncRuntimeCommand {}
@MainActor
extension ConfigCommand.RemoveProviderCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.providerId = try values.decodePositional(0, label: "providerId")
        self.force = values.flag("force")
        self.dryRun = values.flag("dryRun")
    }
}

@available(macOS 14.0, *)
extension ConfigCommand.ModelsProviderCommand: AsyncRuntimeCommand {}
@MainActor
extension ConfigCommand.ModelsProviderCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.providerId = try values.decodePositional(0, label: "providerId")
        self.discover = values.flag("discover")
        self.save = values.flag("save")
    }
}
