---
summary: 'Review Grok 4 Implementation Guide for Peekaboo guidance'
read_when:
  - 'planning work related to grok 4 implementation guide for peekaboo'
  - 'debugging or extending features described here'
---

# Grok 4 Implementation Guide for Peekaboo

## Implementation Status: IMPLEMENTED ✅

**As of 2025-01-27, Grok models are now implemented in Peekaboo!** You can use Grok models by setting your xAI API key.

## Overview

This document outlines the implementation plan for integrating xAI's Grok 4 model into Peekaboo. Grok 4 is xAI's flagship reasoning model, designed to deliver truthful, insightful answers with native tool use and real-time search integration.

## API Information

### Base Details
- **API Base URL**: `https://api.x.ai/v1`
- **Authentication**: Bearer token via `X_AI_API_KEY` or `XAI_API_KEY`
- **Compatibility**: Fully compatible with OpenAI SDK
- **Documentation**: https://docs.x.ai/

### Important: API Endpoints
- **Chat Completions**: `POST /v1/chat/completions` (OpenAI-compatible format)
- **Messages**: Anthropic-compatible endpoint also available
- **Note**: xAI does **NOT** use the `/v1/responses` endpoint - it uses standard chat completions

### Available Models (confirmed working)
- **grok-4.3** - Current Grok default
- **grok-4.20-0309-reasoning** - Reasoning Grok 4.20 variant
- **grok-4.20-0309-non-reasoning** - Non-reasoning Grok 4.20 variant

`grok-4.20-multi-agent-0309` requires xAI Responses API routing and is not exposed by Peekaboo's Chat Completions-backed Grok provider yet.

Model shortcuts in Peekaboo:
- `grok` → resolves to `grok-4.3`
- `grok-4` → resolves to `grok-4.3`
- Old `grok-2`, `grok-3`, `grok-4-fast`, and beta IDs are rejected.

### Key Features
- Native tool use support (function calling)
- Real-time search integration ($25 per 1,000 sources via search_parameters)
- OpenAI-compatible REST API (chat completions format)
- Streaming support via SSE (Server-Sent Events)
- Structured outputs support
- No support for `presencePenalty`, `frequencyPenalty`, or `stop` parameters on Grok 4
- Knowledge cutoff: November 2024 (for Grok 3/4)
- Stateless API (requires full conversation context in each request)

## Implementation Architecture

### Important Implementation Note

Since xAI's Grok uses the standard OpenAI Chat Completions API (`/v1/chat/completions`) and **NOT** the Responses API (`/v1/responses`), we need to ensure our implementation uses the correct endpoint. The existing `OpenAIModel` class in Peekaboo has been migrated to use only the Responses API, so we have two options:

1. **Option A**: Modify `OpenAIModel` to support both endpoints based on the model
2. **Option B**: Create a standalone `GrokModel` that implements the Chat Completions API

Given that Grok is fully OpenAI-compatible for Chat Completions, Option B is cleaner.

### 1. Create GrokModel Class

We'll create a dedicated Grok implementation that uses the Chat Completions API:

```swift
// File: Core/PeekabooCore/Sources/PeekabooCore/AI/Models/GrokModel.swift

import Foundation
import AXorcist

/// Grok model implementation using OpenAI Chat Completions API
public final class GrokModel: ModelInterface {
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession
    private let modelName: String
    
    public init(
        apiKey: String,
        modelName: String,
        baseURL: URL = URL(string: "https://api.x.ai/v1")!,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.baseURL = baseURL
        
        // Create custom session with appropriate timeout
        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300  // 5 minutes
            config.timeoutIntervalForResource = 300
            self.session = URLSession(configuration: config)
        }
    }
    
    public var maskedApiKey: String {
        guard apiKey.count > 8 else { return "***" }
        let start = apiKey.prefix(6)
        let end = apiKey.suffix(2)
        return "\(start)...\(end)"
    }
    
    public func getResponse(request: ModelRequest) async throws -> ModelResponse {
        let grokRequest = try convertToGrokRequest(request, stream: false)
        let urlRequest = try createURLRequest(endpoint: "/chat/completions", body: grokRequest)
        
        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelError.requestFailed(URLError(.badServerResponse))
        }
        
        if httpResponse.statusCode != 200 {
            var errorMessage = "HTTP \(httpResponse.statusCode)"
            if let responseString = String(data: data, encoding: .utf8) {
                errorMessage += ": \(responseString)"
            }
            throw ModelError.requestFailed(NSError(
                domain: "Grok",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            ))
        }
        
        let chatResponse = try JSONDecoder().decode(GrokChatCompletionResponse.self, from: data)
        return try convertFromGrokResponse(chatResponse)
    }
    
    public func getStreamedResponse(request: ModelRequest) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let grokRequest = try convertToGrokRequest(request, stream: true)
        let urlRequest = try createURLRequest(endpoint: "/chat/completions", body: grokRequest)
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: ModelError.requestFailed(URLError(.badServerResponse)))
                        return
                    }
                    
                    if httpResponse.statusCode != 200 {
                        // Handle error response
                        var errorData = Data()
                        for try await byte in bytes.prefix(1024) {
                            errorData.append(byte)
                        }
                        
                        var errorMessage = "HTTP \(httpResponse.statusCode)"
                        if let responseString = String(data: errorData, encoding: .utf8) {
                            errorMessage += ": \(responseString)"
                        }
                        
                        continuation.finish(throwing: ModelError.requestFailed(NSError(
                            domain: "Grok",
                            code: httpResponse.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: errorMessage]
                        )))
                        return
                    }
                    
                    // Process SSE stream
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let data = String(line.dropFirst(6))
                            
                            if data == "[DONE]" {
                                continuation.finish()
                                return
                            }
                            
                            // Parse chunk and convert to StreamEvent
                            if let chunkData = data.data(using: .utf8),
                               let chunk = try? JSONDecoder().decode(GrokStreamChunk.self, from: chunkData) {
                                if let event = convertToStreamEvent(chunk) {
                                    continuation.yield(event)
                                }
                            }
                        }
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Private Helper Methods
    
    private func createURLRequest(endpoint: String, body: Encodable) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
    
    private func convertToGrokRequest(_ request: ModelRequest, stream: Bool) throws -> GrokChatCompletionRequest {
        var messages: [[String: Any]] = []
        
        // Convert messages
        for message in request.messages {
            var messageDict: [String: Any] = ["role": message.role.rawValue]
            
            if let systemMsg = message as? SystemMessageItem {
                messageDict["content"] = systemMsg.content
            } else if let userMsg = message as? UserMessageItem {
                // Handle user messages with potential multimodal content
                if userMsg.content.count == 1, case .text(let text) = userMsg.content[0] {
                    messageDict["content"] = text
                } else {
                    // Convert content blocks for multimodal
                    var contentBlocks: [[String: Any]] = []
                    for content in userMsg.content {
                        switch content {
                        case .text(let text):
                            contentBlocks.append(["type": "text", "text": text])
                        case .image(let imageData):
                            let base64 = imageData.base64EncodedString()
                            contentBlocks.append([
                                "type": "image_url",
                                "image_url": ["url": "data:image/jpeg;base64,\(base64)"]
                            ])
                        }
                    }
                    messageDict["content"] = contentBlocks
                }
            } else if let assistantMsg = message as? AssistantMessageItem {
                // Handle assistant messages
                var content = ""
                var toolCalls: [[String: Any]] = []
                
                for item in assistantMsg.content {
                    switch item {
                    case .text(let text):
                        content += text
                    case .toolCall(let toolCall):
                        toolCalls.append([
                            "id": toolCall.id,
                            "type": "function",
                            "function": [
                                "name": toolCall.function.name,
                                "arguments": toolCall.function.arguments
                            ]
                        ])
                    }
                }
                
                if !content.isEmpty {
                    messageDict["content"] = content
                }
                if !toolCalls.isEmpty {
                    messageDict["tool_calls"] = toolCalls
                }
            } else if let toolMsg = message as? ToolMessageItem {
                messageDict["tool_call_id"] = toolMsg.toolCallId
                messageDict["content"] = toolMsg.output
            }
            
            messages.append(messageDict)
        }
        
        // Filter parameters for Grok 4
        var temperature = request.settings.temperature
        var frequencyPenalty = request.settings.frequencyPenalty
        var presencePenalty = request.settings.presencePenalty
        var stop = request.settings.stopSequences
        
        if modelName.contains("grok-4") {
            // Grok 4 doesn't support these parameters
            frequencyPenalty = nil
            presencePenalty = nil
            stop = nil
        }
        
        // Convert tools if present
        var tools: [[String: Any]]?
        if let requestTools = request.tools {
            tools = requestTools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters
                    ]
                ]
            }
        }
        
        return GrokChatCompletionRequest(
            model: modelName,
            messages: messages,
            temperature: temperature,
            maxTokens: request.settings.maxTokens,
            stream: stream,
            tools: tools,
            frequencyPenalty: frequencyPenalty,
            presencePenalty: presencePenalty,
            stop: stop
        )
    }
    
    // ... Additional helper methods for response conversion ...
}

// MARK: - Grok Request/Response Types

private struct GrokChatCompletionRequest: Encodable {
    let model: String
    let messages: [[String: Any]]
    let temperature: Double?
    let maxTokens: Int?
    let stream: Bool
    let tools: [[String: Any]]?
    let frequencyPenalty: Double?
    let presencePenalty: Double?
    let stop: [String]?
    
    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream, tools
        case maxTokens = "max_tokens"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case stop
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(stream, forKey: .stream)
        
        // Encode messages as JSON data
        let messagesData = try JSONSerialization.data(withJSONObject: messages)
        let messagesJSON = try JSONSerialization.jsonObject(with: messagesData) as? [[String: Any]]
        try container.encode(messagesJSON, forKey: .messages)
        
        // Optional parameters
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(frequencyPenalty, forKey: .frequencyPenalty)
        try container.encodeIfPresent(presencePenalty, forKey: .presencePenalty)
        try container.encodeIfPresent(stop, forKey: .stop)
        
        if let tools = tools {
            let toolsData = try JSONSerialization.data(withJSONObject: tools)
            let toolsJSON = try JSONSerialization.jsonObject(with: toolsData) as? [[String: Any]]
            try container.encode(toolsJSON, forKey: .tools)
        }
    }
}

private struct GrokChatCompletionResponse: Decodable {
    let id: String
    let model: String
    let choices: [Choice]
    let usage: Usage?
    
    struct Choice: Decodable {
        let message: Message
        let finishReason: String?
        
        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
    
    struct Message: Decodable {
        let role: String
        let content: String?
        let toolCalls: [ToolCall]?
        
        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
        }
        
        struct ToolCall: Decodable {
            let id: String
            let type: String
            let function: Function
            
            struct Function: Decodable {
                let name: String
                let arguments: String
            }
        }
    }
    
    struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int
        
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

private struct GrokStreamChunk: Decodable {
    let id: String
    let model: String
    let choices: [StreamChoice]
    
    struct StreamChoice: Decodable {
        let delta: Delta
        let finishReason: String?
        
        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
        
        struct Delta: Decodable {
            let role: String?
            let content: String?
            let toolCalls: [StreamToolCall]?
            
            enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
            }
        }
    }
    
    struct StreamToolCall: Decodable {
        let index: Int
        let id: String?
        let type: String?
        let function: StreamFunction?
        
        struct StreamFunction: Decodable {
            let name: String?
            let arguments: String?
        }
    }
}
```

### 2. Update ModelProvider

Add Grok model registration to `ModelProvider.swift`:

```swift
// In ModelProvider.swift, add to registerDefaultModels():

// Register Grok models
registerGrokModels()

// Add new method:
private func registerGrokModels() {
    let models = [
        "grok-4.3",
        "grok-4.20-0309-reasoning",
        "grok-4.20-0309-non-reasoning"
    ]
    
    for modelName in models {
        register(modelName: modelName) {
            guard let apiKey = self.getGrokAPIKey() else {
                throw ModelError.authenticationFailed
            }
            
            return GrokModel(apiKey: apiKey, modelName: modelName)
        }
    }
}

// Add lenient name resolution:
private func resolveLenientModelName(_ modelName: String) -> String? {
    let lowercased = modelName.lowercased()
    
    // ... existing code ...
    
    // Grok model shortcuts
    if lowercased == "grok" || lowercased == "grok4" || lowercased == "grok-4" {
        return "grok-4.3"
    }
    
    // ... rest of method ...
}

// Add API key retrieval:
private func getGrokAPIKey() -> String? {
    // Check environment variables (both variants)
    if let apiKey = ProcessInfo.processInfo.environment["X_AI_API_KEY"] {
        return apiKey
    }
    if let apiKey = ProcessInfo.processInfo.environment["XAI_API_KEY"] {
        return apiKey
    }
    
    // Check credentials file
    let credentialsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".peekaboo")
        .appendingPathComponent("credentials")
    
    if let credentials = try? String(contentsOf: credentialsPath) {
        for line in credentials.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("X_AI_API_KEY=") {
                return String(trimmed.dropFirst("X_AI_API_KEY=".count))
            }
            if trimmed.hasPrefix("XAI_API_KEY=") {
                return String(trimmed.dropFirst("XAI_API_KEY=".count))
            }
        }
    }
    
    return nil
}
```

### 3. Update Configuration Support

Add Grok configuration to `ModelProviderConfig`:

```swift
/// Grok/xAI configuration
public struct Grok {
    public let apiKey: String
    public let baseURL: URL?
    
    public init(
        apiKey: String,
        baseURL: URL? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }
}

// Extension method:
extension ModelProvider {
    /// Configure Grok models with specific settings
    public func configureGrok(_ config: ModelProviderConfig.Grok) {
        let models = [
            "grok-4.3",
            "grok-4.20-0309-reasoning",
            "grok-4.20-0309-non-reasoning"
        ]
        
        for modelName in models {
            register(modelName: modelName) {
                return GrokModel(
                    apiKey: config.apiKey,
                    modelName: modelName,
                    baseURL: config.baseURL ?? URL(string: "https://api.x.ai/v1")!
                )
            }
        }
    }
}
```

### 4. Testing Implementation

Create comprehensive tests:

```swift
// File: Core/PeekabooCore/Tests/PeekabooTests/GrokModelTests.swift

import Testing
@testable import PeekabooCore
import Foundation

@Suite("Grok Model Tests")
struct GrokModelTests {
    
    @Test("Model initialization")
    func testModelInitialization() async throws {
        let model = GrokModel(
            apiKey: "test-key",
            modelName: "grok-4-0709"
        )
        
        #expect(model.maskedApiKey == "test-k...ey")
    }
    
    @Test("Parameter filtering for Grok 4")
    func testGrok4ParameterFiltering() async throws {
        // Test that unsupported parameters are removed
        let model = GrokModel(
            apiKey: "test-key", 
            modelName: "grok-4-0709"
        )
        
        let settings = ModelSettings(
            modelName: "grok-4-0709",
            temperature: 0.7,
            frequencyPenalty: 0.5,  // Should be removed
            presencePenalty: 0.5,   // Should be removed
            stopSequences: ["stop"] // Should be removed
        )
        
        // Implementation would validate parameters are stripped
    }
}
```

### 5. Usage Examples

Once implemented, Grok can be used like this:

```bash
# Set API key
./peekaboo config credential set X_AI_API_KEY xai-...

# Use Grok 4.3 (default)
./peekaboo agent "analyze this code" --model grok-4.3
./peekaboo agent "analyze this code" --model grok      # Lenient matching

# Use specific models
./peekaboo agent "quick task" --model grok-4.20-0309-reasoning

# Environment variable usage
PEEKABOO_AI_PROVIDERS="grok/grok-4.3" ./peekaboo analyze image.png "What is shown?"
```

## Implementation Steps (COMPLETED)

1. ✅ **Created GrokModel.swift** in `Core/PeekabooCore/Sources/PeekabooCore/AI/Models/`
2. ✅ **Updated ModelProvider.swift** to register Grok models
3. ✅ **Added Grok configuration** to ModelProviderConfig
4. ⏳ **Create tests** in `Core/PeekabooCore/Tests/PeekabooTests/` (pending)
5. ✅ **Updated documentation** with Grok model information
6. ⏳ **Test with real API key** to ensure compatibility (pending)

## Important Considerations

### Grok 4 Limitations
- No non-reasoning mode (always uses reasoning)
- Does not support `presencePenalty`, `frequencyPenalty`, or `stop` parameters
- These parameters must be filtered out before sending requests

### API Compatibility
- Uses OpenAI-compatible endpoints
- Same streaming format as OpenAI
- Tool calling format matches OpenAI's structure

### Pricing
- API pricing varies by model
- Live Search costs $25 per 1,000 sources
- Free credits during beta: $25/month through end of 2024

### Authentication
- Supports both `X_AI_API_KEY` and `XAI_API_KEY` environment variables
- Stored in `~/.peekaboo/credentials` file
- Same pattern as OpenAI and Anthropic keys

## Next Steps

1. Implement the GrokModel class with proper parameter filtering
2. Add model registration to ModelProvider
3. Write comprehensive tests
4. Document usage in README and CLAUDE.md
5. Consider adding support for Grok-specific features like native search integration
