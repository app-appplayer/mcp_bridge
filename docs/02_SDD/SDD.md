# mcp_bridge — SDD (Software System Design)

> Status: Draft
> Last Updated: 2026-05-04
> Source: `01_SRS/SRS.md`

---

## 1. System Architecture Overview

mcp_bridge is a single-isolate runtime with two cooperating modules: `McpBridge` (orchestrator + transport selection + inline lifecycle) and `MessageRouter` (forwarding logic). The package ships eight built-in transports — three delegated to `mcp_client` / `mcp_server` 2.x factories (`stdio`, `sse`, `streamableHttp`), and five implemented inside `lib/src/transport/` (`websocket`, `tcp`, `serial`, `usb`, `ble`). All eight are selectable by type-name in `McpBridgeConfig`; the consumer never opens a port / socket / device handle directly.

```
                        ┌─ user code (consumer) ─────────────────────┐
                        │  McpBridge(McpBridgeConfig).initialize()  │
                        └──────────────────────────────────────────┬─┘
                                                                  │
              ┌───────────────────────────────────────────────────▼───────────────┐
              │  McpBridge (orchestrator + transport selection + lifecycle)        │
              │   ─ switch on serverTransportType / clientTransportType            │
              │   ─ owns the MessageRouter                                         │
              │   ─ owns close-detection / reconnect / callback dispatch inline    │
              └────────────────────────────────────────────────┬───────────────────┘
                                                               │ owns + drives
                                                               ▼
              ┌────────────────────────────────────────────────────────────────────┐
              │  Transports (each implements mcp_client.ClientTransport /          │
              │  mcp_server.ServerTransport directly)                              │
              │                                                                    │
              │  Delegated to mcp_client/mcp_server factories:                    │
              │    'stdio' · 'sse' · 'streamableHttp'                             │
              │                                                                    │
              │  Implemented in lib/src/transport/:                                │
              │    'websocket'  (dart:io)                                          │
              │    'tcp'        (dart:io)                                          │
              │    'serial'     (libserialport FFI)                                │
              │    'usb'        (libusb FFI)                                       │
              │    'ble'        (bluez D-Bus, Linux only)                          │
              └────────────────────────────────────────────────────────────────────┘
                                                               │
                                                               ▼
                                                       ┌──────────────────┐
                                                       │ MessageRouter    │
                                                       │ (verbatim        │
                                                       │  forward both    │
                                                       │  directions)     │
                                                       └──────────────────┘
```

New transport added later: implement the pair in `lib/src/transport/{name}_{server,client}_transport.dart`, append a switch case in `bridge.dart`, document the type-name + config keys in README.

---

## 2. Module Breakdown

### 2.1 `Bridge` — Orchestrator

**File:** `lib/src/bridge.dart`
**Public class:** `McpBridge`
**Implements SRS:** FR2 (transport selection), FR3 (forwarding), FR4 (lifecycle), FR5 (configuration)

Responsibilities:

- Construct from `McpBridgeConfig`.
- Resolve `serverTransportType` to a `mcp_server.ServerTransport` via `mcp_server.McpServer.createTransport(TransportConfig.{stdio,sse,streamableHttp}(...))`.
- Resolve `clientTransportType` to a `mcp_client.ClientTransport` via `mcp_client.McpClient.create{Stdio,Sse,StreamableHttp}Transport(...)`.
- Throw `UnknownTransportTypeException` on unrecognised type name, naming the supplied value and the supported set.
- Open both transports and start the `MessageRouter` (its forwarding loops bind to both transports' `onMessage` streams).
- Own the lifecycle directly — close detection, reconnect orchestration, callback dispatch all live inside `McpBridge`. There is intentionally no separate `LifecycleManager` class.

The bridge does NOT instantiate `mcp_client.Client` or `mcp_server.Server`. It is a dumb-pipe forwarder — the two endpoints (the consuming app on one side, the backend MCP server on the other) own their own `Client` / `Server` instances and the bridge only passes JSON-RPC frames between them.

Public surface (preserved from the previously-published baseline):

- `Future<void> initialize()`
- `Future<void> shutdown()`
- `bool get isInitialized`, `bool get isServerActive`, `bool get isWaitingForServerReconnection`
- `String get serverTransportType`, `String get clientTransportType`
- `ServerShutdownBehavior get serverShutdownBehavior`
- `void setAutoReconnect({bool enabled, int maxAttempts, Duration delay})`
- `void setServerReconnectionOptions({int maxAttempts, Duration checkInterval})`
- Static convenience factories: `createStdioToSseBridge(...)`, `createSseToStdioBridge(...)`
- Constructor accepts `McpBridgeConfig`
- `MCPBridge` typedef alias retained for old casing

### 2.2 Transport Selection (private to Bridge)

**Implements SRS:** FR2

Two private helpers inside `bridge.dart` map transport-type names to either:

- a `mcp_server` / `mcp_client` 2.x factory call (delegated transports), or
- a constructor of an internal class in `lib/src/transport/` that implements `mcp_server.ServerTransport` / `mcp_client.ClientTransport` directly.

```dart
Future<server.ServerTransport> _buildServerTransport(
    String type, Map<String, dynamic> cfg) async {
  switch (type) {
    case 'stdio':           // delegated
    case 'sse':             // delegated
    case 'streamableHttp':  // delegated
    case 'websocket':       return WebSocketServerTransport(cfg)..start();
    case 'tcp':             return TcpServerTransport(cfg)..start();
    case 'serial':          return SerialServerTransport(cfg)..start();
    case 'usb':             return UsbServerTransport(cfg)..start();
    case 'ble':
      if (!Platform.isLinux) {
        throw UnsupportedError("'ble' transport is Linux-only in 0.2.0");
      }
      return BleServerTransport(cfg)..start();
    default:
      throw UnknownTransportTypeException(type, 'server', _supportedTransportTypes);
  }
}
```

`UnknownTransportTypeException` carries `name`, `side` (`'server'` | `'client'`), and `supported` (the list of recognised type names). Adding a 9th transport later: implement `lib/src/transport/foo_{server,client}_transport.dart` (each implementing the relevant abstract class), append the switch case here, append the name to `_supportedTransportTypes`, document in README.

### 2.3 `MessageRouter` — Forwarding Logic

**File:** `lib/src/router.dart`
**Implements SRS:** FR3 (bidirectional forwarding)

Two forwarding loops, one per direction:

1. **Server → Client direction** (client requests reaching the bridge from the front door, forwarded to the backend):
   - Subscribe to `serverTransport.onMessage`.
   - For each message: `clientTransport.send(message)`.

2. **Client → Server direction** (responses + server-initiated requests + notifications coming back from the backend):
   - Subscribe to `clientTransport.onMessage`.
   - For each message: `serverTransport.send(message)`.

Request-response correlation: the JSON-RPC `id` is preserved verbatim across the bridge — no rewriting. The bridge's only job is verbatim forwarding plus lifecycle.

Bidirectional concerns:

- **Sampling forwarding (FR3.3):** The 2.0-wave `Server.requestClientSampling` is just a JSON-RPC request from server → client over the same transport. The bridge forwards it like any other message — no special handling needed.
- **Roots forwarding (FR3.4):** Same — `Server.requestClientRoots` is JSON-RPC over the wire. Bridge forwards verbatim.
- **Elicitation forwarding (FR3.5):** Same.
- **Notification forwarding (FR3.6):** No `id` correlation needed; just forward.

Router holds the two transports as `mcp_server.ServerTransport` / `mcp_client.ClientTransport` directly — both expose compatible `onMessage` streams and `send` methods.

### 2.4 Lifecycle (inside `McpBridge`)

**Implements SRS:** FR4

Lifecycle handling lives directly inside `McpBridge` (no separate class or file). The orchestrator owns:

- The four lifecycle callbacks from `McpBridgeConfig` (also settable on the bridge instance via direct field assignment).
- Subscriptions to both transports' `onClose` futures, set up by `_setupForwarding` after `initialize`. On close:
  - Invoke `TransportClosedCallback(side)`.
  - Apply `ServerShutdownBehavior` policy:
    - `shutdownBridge` → call `shutdown()`, which cancels router subscriptions and closes the other transport.
    - `waitForReconnection` → close the client side, then loop in `_handleServerDisconnection`. Each iteration invokes `ServerReconnectRequestedCallback` and awaits its `Future<bool>`. If `true`, re-build both transports via the same private factory helpers, restart forwarding, fire `TransportReconnectedCallback`. If `false` or max attempts exhausted, fall through to `shutdown()`.
- Client-side auto-reconnect on transient close (off by default, enabled via `setAutoReconnect`): retries `_attemptClientReconnect` up to `_maxReconnectAttempts` with `_reconnectDelay` between attempts.
- Transport errors surface from `MessageRouter.onError` and the bridge's catch blocks; both call `TransportErrorCallback(side, error, stackTrace?)`.

### 2.5 `McpBridgeConfig` — Construction-Time Configuration

**File:** `lib/src/config.dart`
**Public class:** `McpBridgeConfig`
**Implements SRS:** FR5
**Detailed design:** `03_DDD/core-config.md`

Passive value object carrying the bridge's construction-time inputs: transport type-name pair (server / client), per-transport configs (`Map<String, dynamic>` pass-through to mcp_client / mcp_server factories), `ServerShutdownBehavior`, and the four optional lifecycle callbacks. No logic — `Bridge` (§2.1) consumes it at `initialize()` and reads the callbacks during runtime.

The previously-published field set is preserved (FR5.1, PRD G6 — surface compat). The four optional callback fields are added with `null` defaults; existing `McpBridgeConfig(...)` literals from prior callers compile unchanged.

`McpBridgeConfig` is intentionally `const`-constructible and immutable; mutating the underlying maps after construction is undefined.

---

## 3. Built-In Transport Set

Eight transports ship with mcp_bridge 0.2.0. The first three are delegated; the remaining five are implemented inside `lib/src/transport/`.

### 3.1 Delegated (calls into mcp_client / mcp_server 2.x)

| Type-name | Server-side | Client-side |
|-----------|-------------|--------------|
| `'stdio'` | `mcp_server.McpServer.createTransport(TransportConfig.stdio())` | `mcp_client.McpClient.createStdioTransport(command:, arguments:, ...)` |
| `'sse'` | `TransportConfig.sse(host:, port:, endpoint:, messagesEndpoint:, fallbackPorts:, authToken:)` | `createSseTransport(serverUrl:, headers:)` |
| `'streamableHttp'` | `TransportConfig.streamableHttp(host:, port:, endpoint:, messagesEndpoint:, fallbackPorts:, authToken:, isJsonResponseEnabled:)` | `createStreamableHttpTransport(baseUrl:, headers:, timeout:, maxConcurrentRequests:, useHttp2:)` |

### 3.2 Implemented in `lib/src/transport/`

Each non-delegated transport ships as a server-side + client-side pair. Both directly implement `mcp_server.ServerTransport` / `mcp_client.ClientTransport` — same Stream<dynamic> onMessage / void send(dynamic) / Future<void> onClose / void close() shape the framework uses elsewhere. No intermediate adapter.

| Type-name | Server-side file | Client-side file | Backing | Framing |
|-----------|-------------------|-------------------|---------|---------|
| `'websocket'` | `websocket_server_transport.dart` | `websocket_client_transport.dart` | `dart:io` `HttpServer` + `WebSocketTransformer` / `WebSocket.connect` | WebSocket text frames carry one JSON-RPC message each |
| `'tcp'` | `tcp_server_transport.dart` | `tcp_client_transport.dart` | `dart:io` `ServerSocket` + `Socket` / `Socket.connect` | newline-delimited JSON |
| `'serial'` | `serial_server_transport.dart` | `serial_client_transport.dart` | `libserialport` Dart FFI (USB CDC included) | newline-delimited JSON |
| `'usb'` | `usb_server_transport.dart` | `usb_client_transport.dart` | `libusb` Dart FFI, bulk endpoints | newline-delimited JSON |
| `'ble'` | `ble_server_transport.dart` | `ble_client_transport.dart` | `bluez` D-Bus (Linux only); other OSes throw `UnsupportedError` at constructor or `start()` | newline-delimited JSON over GATT characteristic notifications + writes |

Per-transport config keys are documented in README's "Built-In Transports" section. The bridge passes the `serverConfig` / `clientConfig` maps verbatim to the implementations.

---

## 4. Adding a 9th Transport

The package is not designed for third-party transport plugins (PRD NG1). When a new transport is needed, it's added INSIDE mcp_bridge:

1. Write `lib/src/transport/foo_server_transport.dart` (extends `mcp_server.ServerTransport`) and `lib/src/transport/foo_client_transport.dart` (extends `mcp_client.ClientTransport`). Each handles its own connect / disconnect / framing / error surface.
2. Append a `case 'foo':` branch to both `_buildServerTransport` and `_buildClientTransport` in `bridge.dart`.
3. Append `'foo'` to `_supportedTransportTypes`.
4. Document the type-name + config keys in README's platform support table.
5. Add tests — at minimum a fake-driven unit test for forwarding correctness. Integration / loopback tests if the transport's resources allow them in CI (e.g. `'tcp'` and `'websocket'` can; `'ble'` typically cannot).
6. Bump mcp_bridge minor version (additive change).

If the transport requires Flutter (platform channels for iOS / Android), it goes in a sibling `flutter_mcp_bridge` package, not here.

---

## 5. Bidirectional Sequence Diagrams

### 5.1 Client-initiated request (FR3.1, FR3.2)

```
client app ──tools/call──> serverTransport ──> [Bridge.MessageRouter] ──> clientTransport ──> backend MCP server
                                                                                                ↓
client app <──response─── serverTransport <── [Bridge.MessageRouter] <── clientTransport <── (response)
```

### 5.2 Server-initiated sampling (FR3.3)

```
backend MCP server ──requestClientSampling──> clientTransport ──> [Bridge.MessageRouter] ──> serverTransport ──> client app (or host LLM via autoBridgeSampling)
                                                                                                  ↓
backend MCP server <──sampling result──── clientTransport <── [Bridge.MessageRouter] <── serverTransport <── (LLM response)
```

The bridge does not interpret the request — it forwards verbatim. The bridge is a dumb pipe; it does not own a `Client` or `Server` instance, so any host-LLM auto-sampling lives on whichever endpoint instantiates the `Client` (typically the consuming app on the front-door side), via `MCPClientConfig.autoBridgeSampling`.

### 5.3 Notification (FR3.6)

```
backend MCP server ──notifications/tools/list_changed──> clientTransport ──> [Bridge.MessageRouter] ──> serverTransport ──> client app
```

No response expected. Bridge forwards and forgets.

---

## 6. Module Dependency Graph

```
   ┌──────────────────┐
   │ McpBridgeConfig  │  ← input from caller (passive value)
   └────────┬─────────┘
            │ consumed at init()
            ▼
       ┌─────────────────────────────────────┐
       │  McpBridge (orchestrator + lifecycle│
       │             + transport selection)  │
       └──┬─────────────────────────┬────────┘
          │ owns + drives           │ holds router
          ▼                         ▼
    ┌──────────────────┐    ┌──────────────┐
    │  Transport pair  │    │ MessageRouter│
    │  (one server-side│    │ (forward I/O,│
    │   + one client-  │    │  verbatim)   │
    │   side)          │    └──────────────┘
    └────────┬─────────┘
             │ implementations:
             ▼
   ┌─────────────────────────────────────────────────────────┐
   │ Delegated:                                               │
   │   stdio · sse · streamableHttp                          │
   │   → mcp_client.McpClient.createXxxTransport(...)        │
   │   → mcp_server.McpServer.createTransport(TConfig.xxx()) │
   │                                                          │
   │ Implemented inside lib/src/transport/:                  │
   │   websocket   (dart:io)                                  │
   │   tcp         (dart:io)                                  │
   │   serial      (libserialport FFI)                        │
   │   usb         (libusb FFI)                               │
   │   ble         (bluez D-Bus, Linux only)                  │
   └─────────────────────────────────────────────────────────┘
```

Every transport — delegated or built-in — implements `mcp_server.ServerTransport` / `mcp_client.ClientTransport` directly. The router holds those types; no intermediate adapter.

---

## 7. Error Strategy

- **Transport-level errors** — surfaced via `TransportErrorCallback`. Bridge does not auto-recover; the application decides via `ServerReconnectRequestedCallback`.
- **Routing errors** (e.g. malformed JSON from a transport) — log via `Logger`, drop the message, continue. JSON-RPC requires the receiving side to handle malformed inbound, not the bridge.
- **Configuration errors** — unknown transport-type name throws `UnknownTransportTypeException` synchronously at `initialize()`; missing required config field throws whatever the underlying mcp_client / mcp_server factory throws (typically `ArgumentError` or a `Result.failure` Exception). Either way: never partial-init.
- **Reconnection failure** — invoke `TransportClosedCallback` then proceed to bridge shutdown.

---

## 8. Track-to-Module Mapping

| Track (PRD §4) | Modules touched |
|----------------|-----------------|
| Dependency Modernization | `McpBridge` (deps bump · 2.0-wave message handling absorbed · lifecycle inlined) · `McpBridgeConfig` (4 callback fields added, optional) · `MessageRouter` (verbatim forwarding). |
| Built-In Transport Zoo | `lib/src/transport/` populated with 5 transport pairs (`websocket` · `tcp` · `serial` · `usb` · `ble`). `'streamableHttp'` switch case added (delegated). pubspec gains `libserialport` / `libusb` / `bluez` deps. README plus core-transport.md document config keys + platform support. |
| Bidirectional Forwarding | `MessageRouter` already forwards verbatim — track is largely test additions verifying FR3.3–FR3.6 end-to-end. |
| Stability Declaration | API freeze; no new modules. |

Release scheduling — which tracks ship together, in what order — is recorded in `50_CHANGELOG/CHANGELOG.md`.

---

## 9. Open Design Questions

- **OQ1.** Should `UnknownTransportTypeException` carry the side (`'server'` / `'client'`) as a separate field, or just bake it into the message string? Decision: separate field — programmatic handlers (e.g. config validators) may want to inspect.
- **OQ2.** When `mcp_client` and `mcp_server` add a new transport, should mcp_bridge's switch update be automatic (e.g. via reflection) or manual (one-line addition per release)? Decision: manual. Reflection adds runtime cost and complicates the type signature; one line per new transport is acceptable maintenance.
- **OQ3.** Should the per-transport config-key contract live in mcp_bridge's README or only in `mcp_client` / `mcp_server` docs? Decision: cross-link. mcp_bridge README lists the names + a brief key summary; the underlying packages own the authoritative contract.
