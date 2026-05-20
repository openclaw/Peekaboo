import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Manage Peekaboo configuration files and settings.
@available(macOS 14.0, *)
@MainActor
struct ConfigCommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "config",
        abstract: "Manage Peekaboo configuration",
        discussion: """
        The config command helps you manage Peekaboo's configuration files.

        Configuration locations:
        • Config file: ~/.peekaboo/config.json
        • Credentials: ~/.peekaboo/credentials

        The configuration file uses JSONC format (JSON with Comments) and supports:
        • Comments using // and /* */
        • Environment variable expansion using ${VAR_NAME}
        • Tilde expansion for home directories

        Configuration precedence (highest to lowest):
        1. Command-line arguments
        2. Environment variables
        3. Credentials file (for API keys or OAuth tokens)
        4. Configuration file
        5. Built-in defaults

        API keys should be stored in the credentials file or set as environment variables,
        not in the configuration file.
        """,
        subcommands: [
            InitCommand.self,
            ShowCommand.self,
            StatusCommand.self,
            EditCommand.self,
            ValidateCommand.self,
            AddCommand.self,
            LoginCommand.self,
            SetCredentialCommand.self,
            AddProviderCommand.self,
            ListProvidersCommand.self,
            TestProviderCommand.self,
            RemoveProviderCommand.self,
            ModelsProviderCommand.self,
        ],
        showHelpOnEmptyInvocation: true
    )
}
