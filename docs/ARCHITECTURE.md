---
summary: 'Package boundaries, runtime ownership, and execution contracts for Peekaboo.'
read_when:
  - 'finding the owner of an automation, agent, Bridge, or UI change'
  - 'integrating Peekaboo services into a host'
---

# Peekaboo architecture

Peekaboo is a macOS automation system with a CLI, a menu-bar app, and an MCP server. The apps share automation
services and result contracts; Tachikoma supplies model providers and streaming. The [project vision](https://github.com/openclaw/Peekaboo/blob/main/VISION.md)
sets the platform and reliability scope. [Platform support](platform-support.md) lists the declared runtime floors.

## Package boundaries

| Package or product | Owns |
| --- | --- |
| `PeekabooFoundation` | Shared errors and low-level value types. |
| `PeekabooProtocols` | Cross-module protocols and transport-safe models. |
| `PeekabooExternalDependencies` | The shared AXorcist, Commander, Algorithms, Logging, System, and Collections dependency boundary. |
| `PeekabooAutomationKit` | Capture, desktop observation, input, application/menu/window services, snapshots, and typed automation models. |
| `PeekabooAutomation` | AutomationKit re-exports, configuration, Tachikoma model resolution, and visualizer feedback adapters. |
| `PeekabooBridge` | Authenticated host/client transport, request validation, capabilities, and operation receipts. |
| `PeekabooVisualizer` | Visual feedback events, presets, and delivery to the app, independent of the agent runtime. |
| `PeekabooUICore` | Shared SwiftUI inspector and overlay components. |
| `PeekabooAgentRuntime` | Agent execution, MCP tools and catalogs, browser sessions, and tool formatting. |
| `PeekabooCore` | Umbrella imports and the `PeekabooServices` container used by apps and the CLI. |
| `Tachikoma` | Model providers, request configuration, and streaming. |

Automation behavior belongs in AutomationKit; agent and MCP adapters belong in AgentRuntime. Put shared UI in UICore
and visual feedback in Visualizer. The public root `Package.swift` exports Foundation, Protocols, AutomationKit, and
Bridge without the agent runtime or Tachikoma. Internal apps can link the umbrella or focused products as needed.

The repository uses submodules for AXorcist, Commander, Swiftdansi, Tachikoma, and TauTUI. Change these in their owning
repositories before updating Peekaboo's pointers. The [build guide](building.md#commander-dependency-resolution)
describes checkout-local dependency setup and the distinction between internal and public package resolution.

## Service ownership

`PeekabooServices` is a main-actor container. Its default initializer constructs the production services; its injected
initializer accepts service implementations for hosts and tests. The container does not install global agent defaults
automatically. A host that uses the default MCP context or tool registry installs its services explicitly:

```swift
let services = PeekabooServices()
services.installAgentRuntimeDefaults()
```

Keep that instance alive while its installed factories are used: they capture it without retaining it. Tests and
embedded hosts can instead pass explicit service contexts. See
[`PeekabooServiceProviding`](../Core/PeekabooCore/Sources/PeekabooAgentRuntime/Support/PeekabooServiceProviding.swift)
for the installation boundary and [agent chat](agent-chat.md) for execution lifecycle.

`PeekabooAIService` resolves configured provider strings to Tachikoma `LanguageModel` values. Configuration and provider
selection are documented in [configuration](configuration.md) and [providers](providers.md), rather than duplicated here.
The app and CLI share `~/.peekaboo/credentials`; `config.json` holds settings. A configured `PEEKABOO_CONFIG_DIR` changes
that root. Credential persistence and migration rules belong to the configuration guide.

## Runtime hosting and routing

| Runtime | State and permissions | Transport |
| --- | --- | --- |
| Reusable daemon | Warm services, snapshots, tracking, and browser state; daemon process TCC grants. | `daemon.sock` or a build-scoped daemon socket. |
| Peekaboo.app | GUI lifecycle and the app's TCC grants. | `bridge.sock`. |
| MCP server | Services owned by the MCP client process. | stdio, without a Bridge listener. |
| Local CLI | Services owned by one CLI invocation. | In-process calls. |

Implicit CLI routing prefers a suitable daemon or GUI host and can start a daemon. Build-sensitive capture, AX,
browser, and snapshot commands prefer the current CLI build's daemon. Explicit Bridge sockets and `--no-remote`
constrain selection. Local fallback is operation-dependent; it does not make failed host actions safe to replay.
[Daemon routing](daemon.md#runtime-ownership) is the detailed authority for host preference and migration.

Actionable snapshots use `ps1_` followed by 32 lowercase hexadecimal digits. A concrete reference selects its unique
authenticated producer, overriding ordinary host preference. Missing, unreachable, incompatible, or multiple owners
cause refusal before dispatch. An explicit socket restricts ownership lookup to that host; `--no-remote` restricts it
to caller-local services. Snapshots are not interchangeable between processes. See
[Bridge snapshot authority](bridge-host.md#snapshot-authority) for the full protocol and compatibility contract.

Each Bridge listener holds an exclusive lease, publishes its socket atomically, and removes only the filesystem object
it owns. Browser sessions also retain caller, connection, and target identity; see [browser MCP](browser-mcp.md).

## Observation, actions, and concurrency

A typical workflow observes a target, receives an identity-bound snapshot or result, and dispatches an action against
that exact target. `DesktopObservationService` coordinates capture and optional element detection. Input services
select the supported delivery mechanism and return evidence describing what happened. The CLI, MCP, and Bridge adapters
preserve that evidence instead of inferring success from an absence of errors.

The default agent/MCP authority is background-only. Foreground operations require explicit consent, and catalogs expose
only actions supported by the session's authority. Once an action may have been dispatched, later validation or cleanup
failure must preserve uncertainty and retry safety. See [automation](automation.md), [security](security.md), and
[background computer-use testing](https://github.com/openclaw/Peekaboo/blob/main/docs/testing/background-computer-use.md) for the action contract and proof requirements.

Service orchestration and AppKit-facing state use `MainActor`. Blocking native work and socket waits use bounded workers
or transport queues so they do not hold the main actor or Swift's cooperative executor. A timeout does not necessarily
stop an underlying native call: for example, the application-inventory worker keeps its slot until that call returns,
refusing new work instead of growing a queue behind it.

Checked dialog, focus, and window-identity probes use AXorcist's MainActor `Element.withMessagingTimeout` owner.
Application and returned child references need separate scopes. Dialog scope failures propagate before fallback;
optional focus/identity probes fail closed, while optional AX identifier failure can retain exact CG metadata.
After successful setup, the synchronous scope attempts to reset to zero (not the previous timeout); reset failure
overrides the operation's result or error. Cancellation must be thrown by the operation. Detached raw AX workers retain
unchecked `AXChildWindowMessagingTimeout` scopes so their blocking calls stay off MainActor.

## Presentation and verification

Automation feedback adapters submit `VisualizerEvent` values to the visualizer event store and notify Peekaboo.app.
The app's receiver and coordinator render the overlays. Automation can continue without a running visualizer host;
visual feedback is not proof that an action reached its target. See [visualizer](visualizer.md) for event delivery.

Agent and Mac tool summaries share the [tool formatter registry](https://github.com/openclaw/Peekaboo/blob/main/docs/tool-formatter-architecture.md). New result shapes
should be handled at that shared boundary rather than independently in each app.

Use [building](building.md) for source setup, [testing tools](https://github.com/openclaw/Peekaboo/blob/main/docs/testing/tools.md) for manual recipes, and the focused
contracts under `docs/testing/` for live qualification. Historical timing ranges and archived captures do not establish
current performance or correctness; record the command, built revision, and observed result for the change being tested.
