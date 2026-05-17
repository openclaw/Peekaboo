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

- **PeekabooAutomation** – houses *all* automation-facing code (configuration, capture, application/menu/window services, snapshot management, typed models). Anything that touches Accessibility, ScreenCaptureKit, or on-host configuration lives here.
- **PeekabooVisualizer** – standalone visual feedback layer (`VisualizationClient`, event store, presets) used by automation and apps.
- **PeekabooAgentRuntime** – MCP tools, ToolRegistry/formatters, and the agent service itself. Depends on `PeekabooAutomation` for services/data models and on `PeekabooVisualizer` for status tokens.
- **PeekabooCore** – thin umbrella (`_exported` imports + `PeekabooServices` convenience container). Apps/CLI keep importing `PeekabooCore`, but large features can now link the more focused products directly. Whoever instantiates `PeekabooServices` is responsible for calling `installAgentRuntimeDefaults()` so MCP tools and the ToolRegistry share that instance.
- **Tachikoma** – still the AI provider surface that the runtime modules call through. See
  [providers.md](providers.md) for the current provider and model catalog.

### Dependency Flow

**Tachikoma** (AI Model Management)
- Provides `AIModelProvider` for dependency injection.
- Manages provider/model registry, model selection, and capability metadata.
- Handles API configuration and credential management.

**PeekabooAutomation**
- Depends on Tachikoma for provider metadata and `PeekabooVisualizer` for optional UI feedback.
- Exposes pure Swift protocols (`ApplicationServiceProtocol`, `LoggingServiceProtocol`, etc.) plus concrete implementations (MenuService, ScreenCaptureService, ProcessService, etc.).
- Owns persisted models such as `CaptureTarget`, `AutomationAction`, `UIElement`, `SnapshotInfo`, and shared helper utilities.

**PeekabooAgentRuntime**
- Imports `PeekabooAutomation` for services/models and hosts MCP/agent tooling (`PeekabooAgentService`, `MCPToolContext`, `ToolRegistry`, CLI/MCP formatters).
- Provides a clean `PeekabooServiceProviding` protocol so higher layers (CLI, macOS app, and the MCP server entrypoints) can swap concrete service collections without touching globals.

**PeekabooVisualizer**
- Stays decoupled from automation; only consumes `PeekabooProtocols` data (`DetectedElement`, `LogLevel`) so it can be embedded in other contexts later.
- `VisualizationClient` is still accessed via `PeekabooAutomation` convenience wrappers, but the module boundary keeps visual dependencies out of headless hosts.

## Tachikoma: AI Model Management

### Architecture Pattern: Dependency Injection

Tachikoma has migrated from a singleton pattern to dependency injection for better testability and flexibility:

```swift
// Old (deprecated)
let model = try await Tachikoma.shared.getModel("gpt-4.1")

// New (recommended)
let provider = try AIConfiguration.fromEnvironment()
let model = try provider.getModel("gpt-4.1")
```

### Key Components

#### AIModelProvider
- **Role**: Central registry for AI model instances
- **Pattern**: Immutable collection with functional updates
- **Thread Safety**: Full concurrent access support

#### AIModelFactory
- **Role**: Factory methods for creating model instances
- **Supported Providers**: See [providers.md](providers.md) for the current provider reference
- **Configuration**: Handles API keys, base URLs, and model-specific parameters

#### AIConfiguration
- **Role**: Environment-based automatic configuration
- **Sources**: Environment variables and `~/.tachikoma/credentials` file
- **Auto-Discovery**: Automatically registers all available models

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
let modelProvider = try AIConfiguration.fromEnvironment()
let agent = PeekabooAgentService(
    services: PeekabooServices(),
    modelProvider: modelProvider
)
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
