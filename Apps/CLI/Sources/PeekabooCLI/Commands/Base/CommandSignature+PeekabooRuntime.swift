import Commander

extension CommandSignature {
    /// Add Peekaboo's standard runtime flags and options (extends Commander defaults).
    func withPeekabooRuntimeFlags() -> CommandSignature {
        let base = self.withStandardRuntimeFlags()

        let bridgeSocketOption = OptionDefinition.make(
            label: "bridge-socket",
            names: [
                .long("bridge-socket"),
                .aliasLong("bridgeSocket"),
            ],
            help: "Override the socket path for a Peekaboo Bridge host",
            parsing: .singleValue
        )

        let noRemoteFlag = FlagDefinition.make(
            label: "no-remote",
            names: [
                .long("no-remote"),
            ],
            help: "Force local execution; skip remote hosts even if available"
        )

        let inputStrategyOption = OptionDefinition.make(
            label: "inputStrategy",
            names: [
                .long("input-strategy"),
                .aliasLong("inputStrategy"),
            ],
            help: "Override UI input strategy: actionFirst, synthFirst, actionOnly, or synthOnly",
            parsing: .singleValue
        )

        return CommandSignature(
            arguments: base.arguments,
            options: base.options + [bridgeSocketOption, inputStrategyOption],
            flags: base.flags + [noRemoteFlag],
            optionGroups: base.optionGroups
        )
    }
}

extension CommanderName {
    var commandLineToken: String {
        switch self {
        case let .short(value), let .aliasShort(value):
            "-\(value)"
        case let .long(value), let .aliasLong(value):
            "--\(value)"
        }
    }
}
