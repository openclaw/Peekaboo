import Commander
import Foundation
import Network
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe), .serialized)
struct ConfigModelsProviderTests {
    @Test
    func `Saving provider models preserves configured model capabilities`() async throws {
        try await self.withTempConfigDir {
            let model = Configuration.ModelDefinition(
                name: "Configured Model",
                maxTokens: 32768,
                supportsTools: false,
                supportsVision: false,
                parameters: ["reasoning": "high"]
            )
            let provider = Configuration.CustomProvider(
                name: "Anthropic Proxy",
                type: .anthropic,
                options: .init(
                    baseURL: "https://api.example.com/v1",
                    apiKey: "test-key"
                ),
                models: ["configured-model": model]
            )
            try PeekabooCore.ConfigurationManager.shared.addCustomProvider(provider, id: "anthropic-proxy")

            var command = ConfigCommand.ModelsProviderCommand()
            command.providerId = "anthropic-proxy"
            command.save = true
            try await command.run(using: self.makeRuntime())

            let saved = try #require(
                PeekabooCore.ConfigurationManager.shared
                    .getCustomProvider(id: "anthropic-proxy")?
                    .models?["configured-model"]
            )
            #expect(saved.name == "Configured Model")
            #expect(saved.maxTokens == 32768)
            #expect(saved.supportsTools == false)
            #expect(saved.supportsVision == false)
            #expect(saved.parameters == ["reasoning": "high"])
        }
    }

    @Test
    func `Save without discover does not call the provider API`() async throws {
        try await self.withTempConfigDir {
            let server = try await ModelsProviderHTTPServer.start(
                statusCode: 500,
                body: #"{"error":"must not be called"}"#
            )
            defer { server.stop() }

            let provider = Configuration.CustomProvider(
                name: "OpenAI Proxy",
                type: .openai,
                options: .init(baseURL: server.baseURL, apiKey: "test-key"),
                models: ["configured-model": .init(name: "Configured Model", supportsTools: false)]
            )
            try PeekabooCore.ConfigurationManager.shared.addCustomProvider(provider, id: "openai-proxy")

            var command = ConfigCommand.ModelsProviderCommand()
            command.providerId = "openai-proxy"
            command.save = true
            let output = try await captureStandardOutput {
                try await command.run(using: self.makeRuntime(jsonOutput: true))
            }

            let response = try JSONDecoder().decode(
                ModelsProviderJSONResponse.self,
                from: Data(output.utf8)
            )
            #expect(response.success)
            #expect(response.data.saved)
            #expect(response.data.models == ["configured-model"])

            let saved = try #require(
                PeekabooCore.ConfigurationManager.shared
                    .getCustomProvider(id: "openai-proxy")?
                    .models?["configured-model"]
            )
            #expect(saved.name == "Configured Model")
            #expect(saved.supportsTools == false)
            #expect(server.acceptedRequestCount == 0)
        }
    }

    @Test
    func `Discover save JSON preserves tool opt-in and defaults new models safely`() async throws {
        try await self.withTempConfigDir {
            let server = try await ModelsProviderHTTPServer.start(
                statusCode: 200,
                body: #"{"data":[{"id":"configured-model"},{"id":"new-model"}]}"#
            )
            defer { server.stop() }

            let model = Configuration.ModelDefinition(
                name: "Configured Model",
                maxTokens: 32768,
                supportsTools: true,
                supportsVision: false,
                parameters: ["reasoning": "high"]
            )
            let provider = Configuration.CustomProvider(
                name: "OpenAI Proxy",
                type: .openai,
                options: .init(baseURL: server.baseURL, apiKey: "test-key"),
                models: ["configured-model": model]
            )
            try PeekabooCore.ConfigurationManager.shared.addCustomProvider(provider, id: "openai-proxy")

            var command = ConfigCommand.ModelsProviderCommand()
            command.providerId = "openai-proxy"
            command.discover = true
            command.save = true
            let output = try await captureStandardOutput {
                try await command.run(using: self.makeRuntime(jsonOutput: true))
            }

            let response = try JSONDecoder().decode(
                ModelsProviderJSONResponse.self,
                from: Data(output.utf8)
            )
            #expect(response.success, "Command output: \(output)")
            #expect(response.data.saved)
            #expect(Set(response.data.models) == ["configured-model", "new-model"])
            #expect(!output.contains("[ok]"))

            let savedProvider = try #require(
                PeekabooCore.ConfigurationManager.shared.getCustomProvider(id: "openai-proxy")
            )
            let savedExisting = try #require(savedProvider.models?["configured-model"])
            #expect(savedExisting.name == "Configured Model")
            #expect(savedExisting.maxTokens == 32768)
            #expect(savedExisting.supportsTools == true)
            #expect(savedExisting.supportsVision == false)
            #expect(savedExisting.parameters == ["reasoning": "high"])

            let savedNew = try #require(savedProvider.models?["new-model"])
            #expect(savedNew.name == "new-model")
            #expect(savedNew.maxTokens == nil)
            #expect(savedNew.supportsTools == false)
            #expect(savedNew.supportsVision == nil)
            #expect(savedNew.parameters == nil)
        }
    }

    @Test
    func `Discover API error never saves models`() async throws {
        try await self.withTempConfigDir {
            let server = try await ModelsProviderHTTPServer.start(
                statusCode: 500,
                body: #"{"error":"mock failure"}"#
            )
            defer { server.stop() }

            let model = Configuration.ModelDefinition(
                name: "Configured Model",
                maxTokens: 32768,
                supportsTools: false,
                parameters: ["reasoning": "high"]
            )
            let provider = Configuration.CustomProvider(
                name: "OpenAI Proxy",
                type: .openai,
                options: .init(baseURL: server.baseURL, apiKey: "test-key"),
                models: ["configured-model": model]
            )
            try PeekabooCore.ConfigurationManager.shared.addCustomProvider(provider, id: "openai-proxy")

            var command = ConfigCommand.ModelsProviderCommand()
            command.providerId = "openai-proxy"
            command.discover = true
            command.save = true
            let output = try await captureStandardOutput {
                let exitCode = await #expect(throws: ExitCode.self) {
                    try await command.run(using: self.makeRuntime(jsonOutput: true))
                }
                #expect(exitCode == .failure)
            }

            let response = try JSONDecoder().decode(
                ModelsProviderJSONResponse.self,
                from: Data(output.utf8)
            )
            #expect(!response.success)
            #expect(!response.data.saved)

            let savedProvider = try #require(
                PeekabooCore.ConfigurationManager.shared.getCustomProvider(id: "openai-proxy")
            )
            #expect(savedProvider.models?.count == 1)
            let unchanged = try #require(savedProvider.models?["configured-model"])
            #expect(unchanged.name == "Configured Model")
            #expect(unchanged.maxTokens == 32768)
            #expect(unchanged.supportsTools == false)
            #expect(unchanged.parameters == ["reasoning": "high"])
        }
    }

    private func makeRuntime(jsonOutput: Bool = false) -> CommandRuntime {
        CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: jsonOutput, logLevel: nil),
            services: PeekabooServices()
        )
    }

    private func captureStandardOutput(_ body: () async throws -> Void) async throws -> String {
        let pipe = Pipe()
        let originalStandardOutput = dup(STDOUT_FILENO)
        guard originalStandardOutput >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
            close(originalStandardOutput)
            throw CocoaError(.fileWriteUnknown)
        }
        pipe.fileHandleForWriting.closeFile()

        do {
            try await body()
            fflush(nil)
            _ = dup2(originalStandardOutput, STDOUT_FILENO)
            close(originalStandardOutput)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            pipe.fileHandleForReading.closeFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            fflush(nil)
            _ = dup2(originalStandardOutput, STDOUT_FILENO)
            close(originalStandardOutput)
            pipe.fileHandleForReading.closeFile()
            throw error
        }
    }

    private func withTempConfigDir(_ body: () async throws -> Void) async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cli-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let environmentKeys = [
            "PEEKABOO_CONFIG_DIR",
            "PEEKABOO_CONFIG_NONINTERACTIVE",
            "PEEKABOO_CONFIG_DISABLE_MIGRATION",
        ]
        let previous = Dictionary(uniqueKeysWithValues: environmentKeys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        })

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        setenv("PEEKABOO_CONFIG_NONINTERACTIVE", "1", 1)
        setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
        PeekabooCore.ConfigurationManager.shared.resetForTesting()

        defer {
            for key in environmentKeys {
                if case let value?? = previous[key] {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            PeekabooCore.ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        try await body()
    }
}

private struct ModelsProviderJSONResponse: Decodable {
    let success: Bool
    let data: ModelsProviderJSONData
}

private struct ModelsProviderJSONData: Decodable {
    let models: [String]
    let saved: Bool
}

private final class AcceptedRequestCounter: @unchecked Sendable {
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var count = 0

    nonisolated var value: Int {
        self.lock.withLock { self.count }
    }

    nonisolated func increment() {
        self.lock.withLock {
            self.count += 1
        }
    }
}

private final class ModelsProviderHTTPServer {
    private let listener: NWListener
    private let requestCounter: AcceptedRequestCounter

    private init(listener: NWListener, requestCounter: AcceptedRequestCounter) {
        self.listener = listener
        self.requestCounter = requestCounter
    }

    var baseURL: String {
        guard let port = listener.port else {
            preconditionFailure("HTTP test server must be ready before use")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var acceptedRequestCount: Int {
        self.requestCounter.value
    }

    static func start(statusCode: Int, body: String) async throws -> ModelsProviderHTTPServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "peekaboo.tests.models-provider-http")
        let requestCounter = AcceptedRequestCounter()
        let response = response(statusCode: statusCode, body: body)

        listener.newConnectionHandler = { connection in
            requestCounter.increment()
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                connection.send(
                    content: response,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
            }
        }

        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        return ModelsProviderHTTPServer(listener: listener, requestCounter: requestCounter)
    }

    func stop() {
        self.listener.cancel()
    }

    private static func response(statusCode: Int, body: String) -> Data {
        let reason = statusCode == 200 ? "OK" : "Internal Server Error"
        let bodyData = Data(body.utf8)
        let headers = "HTTP/1.1 \(statusCode) \(reason)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: close\r\n\r\n"
        var data = Data(headers.utf8)
        data.append(bodyData)
        return data
    }
}
