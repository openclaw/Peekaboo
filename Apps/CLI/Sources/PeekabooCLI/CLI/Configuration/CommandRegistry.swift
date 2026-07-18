//
//  CommandRegistry.swift
//  PeekabooCLI
//

import Commander

struct CommandRegistryEntry {
    enum Category: String, Codable, CaseIterable {
        case core
        case interaction
        case system
        case vision
        case ai
        case mcp
    }

    let type: any ParsableCommand.Type
    let category: Category
}

struct CommandDefinition: Codable {
    let name: String
    let typeName: String
    let category: CommandRegistryEntry.Category
    let abstract: String
    let discussion: String?
    let version: String?
    let subcommandCount: Int
}

enum CommandRegistry {
    @MainActor
    static let entries: [CommandRegistryEntry] = [
        .init(type: ImageCommand.self, category: .core),
        .init(type: CaptureCommand.self, category: .core),
        .init(type: BridgeCommand.self, category: .core),
        .init(type: DaemonCommand.self, category: .core),
        .init(type: ListCommand.self, category: .core),
        .init(type: ScreenCommand.self, category: .core),
        .init(type: ToolsCommand.self, category: .core),
        .init(type: ConfigCommand.self, category: .core),
        .init(type: PermissionsCommand.self, category: .core),
        .init(type: LearnCommand.self, category: .core),
        .init(type: SeeCommand.self, category: .vision),
        .init(type: ClickCommand.self, category: .interaction),
        .init(type: TypeCommand.self, category: .interaction),
        .init(type: SetValueCommand.self, category: .interaction),
        .init(type: PerformActionCommand.self, category: .interaction),
        .init(type: PressCommand.self, category: .interaction),
        .init(type: ScrollCommand.self, category: .interaction),
        .init(type: HotkeyCommand.self, category: .interaction),
        .init(type: PasteCommand.self, category: .interaction),
        .init(type: SwipeCommand.self, category: .interaction),
        .init(type: DragCommand.self, category: .interaction),
        .init(type: MoveCommand.self, category: .interaction),
        .init(type: RunCommand.self, category: .core),
        .init(type: SleepCommand.self, category: .core),
        .init(type: CleanCommand.self, category: .core),
        .init(type: WindowCommand.self, category: .system),
        .init(type: MenuCommand.self, category: .system),
        .init(type: MenuBarCommand.self, category: .system),
        .init(type: AppCommand.self, category: .system),
        .init(type: OpenCommand.self, category: .system),
        .init(type: DockCommand.self, category: .system),
        .init(type: DialogCommand.self, category: .system),
        .init(type: SpaceCommand.self, category: .system),
        .init(type: VisualizerCommand.self, category: .system),
        .init(type: ClipboardCommand.self, category: .system),
        .init(type: CompletionsCommand.self, category: .core),
        .init(type: CommanderCommand.self, category: .core),
        .init(type: AgentCommand.self, category: .ai),
        .init(type: BrowserCommand.self, category: .mcp),
        .init(type: InspectUICommand.self, category: .mcp),
        .init(type: MCPCommand.self, category: .mcp),
    ]

    @MainActor
    static var rootCommandTypes: [any ParsableCommand.Type] {
        self.entries.map(\.type)
    }

    @MainActor
    static func definitions() -> [CommandDefinition] {
        self.entries.map { entry in
            let description = entry.type.commandDescription
            return CommandDefinition(
                name: description.commandName ?? String(describing: entry.type),
                typeName: String(reflecting: entry.type),
                category: entry.category,
                abstract: description.abstract,
                discussion: description.discussion,
                version: description.version,
                subcommandCount: description.subcommands.count
            )
        }
    }
}
