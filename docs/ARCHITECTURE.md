---
summary: 'Review Peekaboo Architecture Overview guidance'
read_when:
  - 'planning work related to peekaboo architecture overview'
  - 'debugging or extending features described here'
---

# Peekaboo Architecture Overview

This document provides a high-level overview of how Tachikoma and PeekabooCore work together to provide AI-powered macOS automation capabilities.

## System Architecture

### Core Components

```
┌─────────────────┐
│   Tachikoma     │  AI models + streaming
└────────┬────────┘
         │
┌────────▼────────┐      ┌────────────────────┐      ┌────────────────────┐
│ PeekabooAutomation│◄───►│ PeekabooAgentRuntime │◄───►│  PeekabooVisualizer  │
│ UI/system services│      │ Agent + MCP runtime │      │ Visual feedback stack │
└────────┬────────┘      └──────────┬──────────┘      └──────────┬──────────┘
         │                           │                           │
         └───────────────┬───────────┴───────────┬───────────────┘
                         ▼                       ▼
                  ┌─────────────┐        ┌──────────────┐
                  │  PeekabooCore│        │   Apps / CLI │
                  │ (umbrella)   │        │  consumers   │
                  └─────────────┘        └──────────────┘
```

- **PeekabooFoundation** – shared errors and low-level value types used across packages.
- **PeekabooProtocols** – cross-module protocols and transport-safe model contracts.
- **PeekabooExternalDependencies** – central package boundary for AXorcist, Swift Algorithms, Swift Log, Swift System, Commander, and Collections.
- **PeekabooAutomationKit** – owns capture, observation, input, application/menu/window services, snapshot management, and typed automation models.
- **PeekabooAutomation** – re-exports `PeekabooAutomationKit` and adds Peekaboo configuration, Tachikoma model resolution, and visualizer feedback adapters.
- **PeekabooBridge** – request/response transport and host/client plumbing for permission-bearing runtimes.
- **PeekabooVisualizer** – standalone visual feedback layer (`VisualizationClient`, event store, presets) used by automation and apps.
- **PeekabooUICore** – shared SwiftUI inspector and overlay components used by app surfaces.
- **PeekabooAgentRuntime** – MCP tools, ToolRegistry/formatters, and the agent service itself. Depends on `PeekabooAutomation` for services/data models and on `PeekabooVisualizer` for status tokens.
- **PeekabooCore** – thin umbrella (`_exported` imports + `PeekabooServices` convenience container). Apps/CLI keep importing `PeekabooCore`, but large features can now link the more focused products directly. Whoever instantiates `PeekabooServices` is responsible for calling `installAgentRuntimeDefaults()` so MCP tools and the ToolRegistry share that instance.
- **Tachikoma** – still the AI provider surface that the runtime modules call through. See
  [providers.md](providers.md) for the current provider and model catalog.

### Runtime hosting

Permission-bound automation can execute in three runtime shapes:

| Runtime | State and permissions | Transport |
| --- | --- | --- |
| Reusable daemon | Warm snapshots, tracking, browser MCP state; daemon process TCC | `daemon.sock` Bridge protocol |
| Peekaboo.app | GUI-held TCC grants and app lifecycle | `bridge.sock` Bridge protocol |
| MCP server | Process-local services owned by the MCP client | stdio; no Bridge listener |

CLI automation without a snapshot reference resolves a healthy daemon first, then a capable Peekaboo.app host, then
auto-starts the reusable daemon. Operations that permit local fallback can run in the CLI process when no host is
usable. Explicit socket and `--no-remote` flags override this selection.

A concrete snapshot reference changes the authority rule from preference to producer affinity. Actionable references
have the exact grammar `ps1_` followed by 32 lowercase hexadecimal digits (128 random bits). The resolver asks the
caller-local store and every authenticated live daemon, Peekaboo.app, Claude.app, and Clawdbot.app Bridge candidate
whether it owns that reference, then proceeds only when exactly one host claims it. Missing, incompatible, unreachable,
or multiple owners are pre-dispatch refusals; Peekaboo does not replay the action against another host or reinterpret
the reference as local state. An explicit socket restricts the ownership check to that listener, while `--no-remote`
restricts it to caller-local services. See [bridge-host.md](bridge-host.md#snapshot-authority) for the handshake and
compatibility contract.

The daemon and GUI app never share a socket. Each Bridge listener holds an exclusive lease, publishes its socket
atomically, and removes only the filesystem object it owns. See [daemon.md](daemon.md) and
[bridge-host.md](bridge-host.md) for lifecycle, migration, security, and TCC troubleshooting.

### Dependency Flow

**Tachikoma** (AI Model Management)
- Provides `LanguageModel`, the `ModelProvider` protocol, provider parsers, and `Tachikoma.generateText`.
- `TachikomaConfiguration` supplies provider credentials and endpoint configuration.
- `PeekabooAIService` resolves configured model strings and calls Tachikoma with the selected `LanguageModel`.

**PeekabooAutomationKit**
- Exposes automation protocols and concrete implementations such as `ScreenCaptureService`, `UIAutomationService`, `MenuService`, and `ProcessService`.
- Owns capture, observation, input, window filtering, snapshot persistence, and their typed models.

**PeekabooAutomation**
- Re-exports `PeekabooAutomationKit` and adds `ConfigurationManager`, `PeekabooAIService`, and `VisualizerAutomationFeedbackClient`.
- Depends on Tachikoma for provider/model execution and on `PeekabooVisualizer` for optional UI feedback.

**PeekabooAgentRuntime**
- Imports `PeekabooAutomation` for services/models and hosts MCP/agent tooling (`PeekabooAgentService`, `MCPToolContext`, `ToolRegistry`, CLI/MCP formatters).
- Provides a clean `PeekabooServiceProviding` protocol so higher layers (CLI, macOS app, and the MCP server entrypoints) can swap concrete service collections without touching globals.

**PeekabooVisualizer**
- Stays decoupled from automation; only consumes `PeekabooProtocols` data (`DetectedElement`, `LogLevel`) so it can be embedded in other contexts later.
- `VisualizationClient` is still accessed via `PeekabooAutomation` convenience wrappers, but the module boundary keeps visual dependencies out of headless hosts.

## Tachikoma: AI Model Management

### Architecture Pattern: Explicit Model Selection

Peekaboo resolves configured provider strings into Tachikoma `LanguageModel` values before executing requests:

```swift
let ai = PeekabooAIService(configuration: .shared)
let model = ai.resolveConfiguredModel("openai/gpt-5.6")
let text = try await ai.generateText(prompt: "Describe this workflow", model: model)
```

### Key Components

#### LanguageModel
- **Role**: Typed model selection with provider identity and capability metadata.
- **Resolution**: `ProviderParser`, `AIProviderParser`, and `LanguageModel.parse(from:)` turn configuration strings into model values.

#### ModelProvider
- **Role**: Provider execution protocol used by Tachikoma and Peekaboo's custom compatible-provider adapter.
- **Supported Providers**: See [providers.md](providers.md) for the current provider reference.

#### TachikomaConfiguration
- **Role**: Provider keys, endpoints, and request configuration for Tachikoma calls.
- **Sources**: Peekaboo's `ConfigurationManager` loads `~/.peekaboo/config.json`, `~/.peekaboo/credentials`, and environment variables, then applies those values to Tachikoma.

## PeekabooCore: Automation Engine

### Architecture Pattern: Service Orchestration

PeekabooCore uses a service locator pattern with specialized service delegation:

```swift
let services = PeekabooServices()
let automation = services.automation  // UIAutomationService
let screenCapture = services.screenCapture  // ScreenCaptureService
let applications = services.applications  // ApplicationService
```

### Service Hierarchy

#### PeekabooServices (Service Locator)
- **Role**: Central registry for all automation services
- **Pattern**: Service locator with dependency injection support
- **Lifecycle**: Manages service initialization and coordination

##### Installing a services instance
`PeekabooServices` no longer registers itself globally. Whoever constructs an instance (CLI runtime, macOS app, integration test, etc.) **must** call `services.installAgentRuntimeDefaults()` immediately after initialization. This wires the container into `MCPToolContext` and `ToolRegistry` so downstream tooling (MCP server, CLI `peekaboo tools`, agent service) can resolve the exact same services without touching singletons. Skipping the install step will cause MCP and ToolRegistry code to fatal because no default factory is configured.

#### UIAutomationService (Orchestrator)
- **Role**: Primary automation interface delegating to specialized services
- **Delegation**: Routes operations to appropriate specialized services
- **Snapshot Management**: Maintains state across automation workflows

#### Specialized Services
Each service handles a specific aspect of automation:

- **ClickService**: Mouse interaction and element targeting
- **TypeService**: Keyboard input and text manipulation
- **ScreenCaptureService**: Display and window capture
- **ApplicationService**: Application discovery and management
- **WindowManagementService**: Window positioning and state control
- **MenuService**: Menu bar navigation and interaction
- **SnapshotManager**: State persistence and element caching

### Threading Model

**Main Thread Requirement**: All UI automation operations run on MainActor due to macOS requirements:

```swift
@MainActor
public final class UIAutomationService: UIAutomationServiceProtocol {
    // All operations are main-thread bound
}
```

### Integration Points

#### AI Integration
PeekabooCore integrates with Tachikoma through `PeekabooAgentService`:

```swift
let services = PeekabooServices()
services.installAgentRuntimeDefaults()
let ai = PeekabooAIService(configuration: services.configuration)
let model = ai.resolveConfiguredModel("anthropic/claude-opus-5") ?? .anthropic(.opus5)
let agent = try PeekabooAgentService(services: services, defaultModel: model)
```

#### Visual Feedback Integration
Services automatically connect to PeekabooVisualizer when available:

```swift
// Automatic visualizer integration
let visualizerClient = VisualizationClient.shared
_ = await visualizerClient.showClickFeedback(at: clickPoint, type: clickType)
```

Behind the scenes the client serializes a `VisualizerEvent` into `~/Library/Application Support/PeekabooShared/VisualizerEvents/<uuid>.json` and posts `boo.peekaboo.visualizer.event` via `NSDistributedNotificationCenter`. When Peekaboo.app is alive its `VisualizerEventReceiver` loads the payload and hands it to `VisualizerCoordinator`; otherwise the event is silently dropped and execution continues.

## Data Flow Architecture

### Automation Workflow

1. **Input**: Natural language task or direct API call
2. **AI Processing**: `PeekabooAgentService` uses Tachikoma models
3. **Service Orchestration**: `UIAutomationService` delegates to specialized services
4. **Platform Integration**: Services use macOS APIs (Accessibility, ScreenCaptureKit)
5. **Visual Feedback**: Operations trigger visualizer animations
6. **Snapshot Management**: State cached for subsequent operations

### Example Flow: "Click the Submit button"

```
User Input ("Click Submit")
    ↓
PeekabooAgentService (AI interpretation)
    ↓
UIAutomationService.detectElements() → ElementDetectionService
    ↓
UIAutomationService.click() → ClickService
    ↓
macOS Accessibility APIs
    ↓
VisualizationClient (click animation)
```

## Performance Characteristics

### Service Performance Ranges
- **Element Detection**: 200-800ms (AI analysis + accessibility correlation)
- **Click Operations**: 10-50ms (accessibility API optimization)
- **Screen Capture**: 20-100ms (ScreenCaptureKit acceleration)
- **Application Discovery**: 20-200ms (depending on system load)
- **Window Management**: 10-200ms (depending on operation complexity)

### Optimization Strategies
- **Snapshot Caching**: Element detection results cached per snapshot
- **Accessibility Timeouts**: Reduced from 6s to 2s to prevent hangs
- **Dual APIs**: Modern ScreenCaptureKit with CGWindowList fallback
- **Visual Feedback**: Async animations don't block automation operations

## Error Handling Strategy

### Layered Error Handling
1. **Service Level**: Individual services handle API-specific errors
2. **Orchestration Level**: UIAutomationService provides unified error handling
3. **Agent Level**: AI agent handles retry logic and error recovery
4. **Client Level**: Applications receive structured error information

### Defensive Programming
- **Permission Validation**: Automatic checks for Screen Recording and Accessibility permissions
- **Timeout Protection**: Configurable timeouts prevent system hangs
- **Graceful Degradation**: Fallback strategies for problematic applications
- **State Validation**: Element existence and accessibility verification

Checked dialog, focus, and window-identity probes use AXorcist's MainActor `Element.withMessagingTimeout` owner.
Application and returned child references need separate scopes. Dialog scope failures propagate before fallback;
optional focus/identity probes fail closed, while optional AX identifier failure can retain exact CG metadata.
After successful setup, the synchronous scope attempts to reset to zero (not the previous timeout); reset failure
overrides the operation's result or error. Cancellation must be thrown by the operation. Detached raw AX workers retain
unchecked `AXChildWindowMessagingTimeout` scopes by design so their blocking calls stay off MainActor.

## Configuration Management

### Multi-Source Configuration
1. **Environment Variables**: `PEEKABOO_AI_PROVIDERS`, `OPENAI_API_KEY`, etc.
2. **Credential Files**: `~/.peekaboo/config.json`, `~/.tachikoma/credentials`
3. **Runtime Parameters**: Method-level configuration overrides
4. **Feature Flags**: `PEEKABOO_USE_MODERN_CAPTURE`, etc.

### Configuration Precedence
```
CLI Arguments > Environment Variables > Credential Files > Config Files > Defaults
```

## Future Architecture Considerations

### Scalability
- Service architecture supports horizontal scaling through additional specialized services
- AI model provider supports multiple concurrent model instances
- Snapshot management designed for multi-user and multi-process scenarios

### Extensibility
- Plugin architecture possible through service locator pattern
- AI model provider supports custom model implementations
- Visual feedback system can be extended with additional visualization types

### Cross-Platform Potential
- Service interfaces abstract platform-specific implementations
- Threading model adaptable to other platforms
- AI integration remains platform-agnostic

---

*This architecture has been designed to be "really easy for other people to understand" while providing the performance and reliability needed for production automation workflows.*
