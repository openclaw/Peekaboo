import Commander

extension ParsableCommand {
    static func parse(_ arguments: [String]) throws -> Self {
        let instance = Self()
        let declaredSignature = if let provider = Self.self as? any CommanderSignatureProviding.Type {
            provider.commanderSignature()
        } else {
            CommandSignature.describe(instance)
        }
        let signature = declaredSignature.withPeekabooRuntimeFlags()
        let parser = CommandParser(signature: signature)
        let parsedValues = try parser.parse(arguments: arguments)
        return try CommanderCLIBinder.instantiateCommand(ofType: Self.self, parsedValues: parsedValues)
    }
}
