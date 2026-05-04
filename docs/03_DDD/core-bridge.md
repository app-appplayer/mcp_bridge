# DDD: `core-bridge` — McpBridge Class

> Module: `lib/src/bridge.dart`
> Public class: `McpBridge`
> Implements SRS: FR2 (transport selection), FR3 (forwarding), FR4 (lifecycle), FR5 (configuration)
> SDD section: §2.1, §2.2, §2.4

---

## 1. Purpose

`McpBridge` is the orchestrator class. A consumer instantiates it from an `McpBridgeConfig`, calls `initialize()` to start forwarding, and `shutdown()` to tear down. The bridge also owns:

- **Transport selection** — maps `serverTransportType` / `clientTransportType` strings to `mcp_server` / `mcp_client` 2.x factory calls.
- **Lifecycle** — close detection, reconnect orchestration, callback dispatch, all inline (no separate manager class).

The bridge is a dumb pipe: it does NOT instantiate `mcp_client.Client` or `mcp_server.Server`. It opens two raw transport instances (`mcp_server.ServerTransport` + `mcp_client.ClientTransport`), wires them together via `MessageRouter`, and forwards JSON-RPC frames verbatim. The endpoints on either side own their own `Client` / `Server` instances.

---

## 2. Public Interface

```dart
class McpBridge {
  McpBridge(McpBridgeConfig config);

  /// True after `initialize()` has completed and both transports are open.
  bool get isInitialized;

  /// True while the server-side transport is open and forwarding.
  bool get isServerActive;

  /// True while [_handleServerDisconnection] is awaiting a reconnect
  /// decision (only when behavior is `waitForReconnection`).
  bool get isWaitingForServerReconnection;

  /// The configured server / client transport names.
  String get serverTransportType;
  String get clientTransportType;

  /// The shutdown behavior in effect (mirrors config).
  ServerShutdownBehavior get serverShutdownBehavior;

  /// Open both transports, wire up the message router, and start
  /// forwarding. Throws [UnknownTransportTypeException] if either
  /// transport type-name is not recognised. Throws transport-specific
  /// exceptions on connection failure.
  Future<void> initialize();

  /// Close both transports and release resources. Idempotent.
  Future<void> shutdown();

  /// Configure client-side auto-reconnect on transient close.
  void setAutoReconnect({
    bool enabled = true,
    int maxAttempts = 3,
    Duration delay = const Duration(seconds: 2),
  });

  /// Configure server-side reconnect loop options. Only consulted when
  /// `serverShutdownBehavior == waitForReconnection`.
  void setServerReconnectionOptions({
    int maxAttempts = 0, // 0 = unbounded
    Duration checkInterval = const Duration(seconds: 5),
  });

  // Lifecycle callbacks. Either set directly on the instance, or pass
  // them through `McpBridgeConfig`. Both paths work; instance fields
  // win when both are set.
  TransportErrorCallback? onTransportError;
  TransportClosedCallback? onTransportClosed;
  TransportReconnectedCallback? onTransportReconnected;
  ServerReconnectRequestedCallback? onServerReconnectRequested;

  // Convenience constructors for the two most common topologies.
  static Future<McpBridge> createStdioToSseBridge({...});
  static Future<McpBridge> createSseToStdioBridge({...});
}

typedef TransportErrorCallback = void Function(
  TransportSource source,
  Object error,
  StackTrace? stackTrace,
);
typedef TransportClosedCallback = void Function(TransportSource source);
typedef TransportReconnectedCallback = void Function(TransportSource source);
typedef ServerReconnectRequestedCallback = Future<bool> Function();

/// Compatibility alias retained from the previously-published surface.
typedef MCPBridge = McpBridge;

/// Thrown by [McpBridge.initialize] when a transport-type name is not
/// in the supported set. Carries the side and the supported list so
/// the message can suggest alternatives.
class UnknownTransportTypeException implements Exception {
  final String name;
  final String side;        // 'server' or 'client'
  final List<String> supported;
  const UnknownTransportTypeException(this.name, this.side, this.supported);
  @override
  String toString() =>
      'Unknown $side transport type: "$name". '
      'Supported: ${supported.join(", ")}';
}
```

---

## 3. Internal State

```dart
class McpBridge {
  final McpBridgeConfig _config;
  final Logger _logger;

  server.ServerTransport? _serverTransport;
  client.ClientTransport? _clientTransport;
  MessageRouter? _router;

  bool _isInitialized = false;
  bool _isShuttingDown = false;
  bool _isServerActive = false;
  bool _isWaitingForServerReconnection = false;

  // Auto-reconnect state.
  bool _autoReconnect = false;
  int _maxReconnectAttempts = 3;
  Duration _reconnectDelay = const Duration(seconds: 2);
  int _clientReconnectAttempts = 0;
  int _serverReconnectAttempts = 0;
  int _maxServerReconnectAttempts = 0;
  Duration _serverReconnectCheckInterval = const Duration(seconds: 5);
}
```

---

## 4. `initialize()` Sequence

1. Reject if already initialized; log warning and return.
2. Build the client transport via `_buildClientTransport(_config.clientTransportType, _config.clientConfig)`. Throws `UnknownTransportTypeException` on miss.
3. Build the server transport via `_buildServerTransport(_config.serverTransportType, _config.serverConfig)`.
4. Set `_isServerActive = true`.
5. Call `_setupForwarding`: construct `MessageRouter`, start it, subscribe to both transports' `onClose` futures for lifecycle hooks.
6. Mark `_isInitialized = true`.

If any step fails, dispatch the error to `onTransportError`, call `shutdown()` to release whatever was already opened, and rethrow.

### 4.1 `_buildServerTransport` (private)

```dart
Future<server.ServerTransport> _buildServerTransport(
    String type, Map<String, dynamic> cfg) async {
  switch (type) {
    case 'stdio':
      final r = server.McpServer.createTransport(server.TransportConfig.stdio());
      if (r.isFailure) throw r.failureOrNull!;
      return await r.successOrNull!;
    case 'sse':
      final r = server.McpServer.createTransport(server.TransportConfig.sse(
        endpoint: cfg['endpoint'] as String? ?? '/sse',
        messagesEndpoint: cfg['messagesEndpoint'] as String? ?? '/message',
        host: cfg['host'] as String? ?? 'localhost',
        port: cfg['port'] as int? ?? 8080,
        fallbackPorts: (cfg['fallbackPorts'] as List?)?.cast<int>() ?? const [],
        authToken: cfg['authToken'] as String?,
      ));
      if (r.isFailure) throw r.failureOrNull!;
      return await r.successOrNull!;
    case 'streamableHttp':
      final r = server.McpServer.createTransport(server.TransportConfig.streamableHttp(
        endpoint: cfg['endpoint'] as String? ?? '/mcp',
        messagesEndpoint: cfg['messagesEndpoint'] as String? ?? '/messages',
        host: cfg['host'] as String? ?? 'localhost',
        port: cfg['port'] as int? ?? 8080,
        fallbackPorts: (cfg['fallbackPorts'] as List?)?.cast<int>() ?? const [],
        authToken: cfg['authToken'] as String?,
        isJsonResponseEnabled: cfg['isJsonResponseEnabled'] as bool? ?? false,
      ));
      if (r.isFailure) throw r.failureOrNull!;
      return await r.successOrNull!;
    default:
      throw UnknownTransportTypeException(
          type, 'server', const ['stdio', 'sse', 'streamableHttp']);
  }
}
```

### 4.2 `_buildClientTransport` (private)

Analogous. Calls `mcp_client.McpClient.createStdioTransport(...)` / `createSseTransport(...)` / `createStreamableHttpTransport(...)`.

### 4.3 Adding a new transport-type name

When a new wire format is needed (say `'modbus'`):

1. Write `lib/src/transport/modbus_server_transport.dart` (extends `mcp_server.ServerTransport`) and `lib/src/transport/modbus_client_transport.dart` (extends `mcp_client.ClientTransport`). Each owns its own connect / disconnect / framing / error surface.
2. Add `case 'modbus':` branches to both `_buildServerTransport` and `_buildClientTransport`. Each constructs the new class and (for transports that need async setup) awaits a `start()` method.
3. Append `'modbus'` to `_supportedTransportTypes`.
4. Document the type-name + config keys in README's "Built-In Transports" section.
5. Add tests — fake-driven unit + loopback integration if practical.
6. Bump mcp_bridge minor version (additive change).

If the transport requires Flutter (platform channels for iOS / Android), it goes in a sibling `flutter_mcp_bridge` package, not here.

---

## 5. `shutdown()` Sequence

1. If not initialized or already shutting down, return early.
2. Set `_isShuttingDown = true` to suppress reconnect loops.
3. Stop the `MessageRouter` (cancels both stream subscriptions).
4. Close the server transport, then the client transport.
5. Reset counters and flags. Clear `_isInitialized` and `_isShuttingDown`.

`shutdown()` is idempotent: calling it twice yields no error, no second close attempt.

---

## 6. Lifecycle (Inline)

The bridge handles its own lifecycle directly — there is no separate `LifecycleManager` class. Three private methods carry the work:

- **`_setupForwarding`** — runs at end of `initialize()` and at the end of every successful reconnect cycle. Builds the `MessageRouter`, calls `start()`, and registers `onClose` listeners that route to `_dispatchClosed` plus the `ServerShutdownBehavior` policy.
- **`_handleServerDisconnection`** (used when `serverShutdownBehavior == waitForReconnection`) — closes the client side, then loops: each iteration invokes `onServerReconnectRequested` and awaits its `Future<bool>`. On `true`, re-builds both transports via `_buildServerTransport` / `_buildClientTransport`, re-runs `_setupForwarding`, and fires `_dispatchReconnected(server)`. On `false` or max-attempts exhausted, falls through to `shutdown()`.
- **`_attemptClientReconnect`** (only when `setAutoReconnect(enabled: true)`) — retries up to `_maxReconnectAttempts` with `_reconnectDelay` between attempts.

Three internal dispatchers (`_dispatchError`, `_dispatchClosed`, `_dispatchReconnected`) read either the instance-level callback field or the equivalent from `_config`, whichever is non-null. Instance fields take precedence so direct assignment after construction works.

See `core-lifecycle.md` for the full reconnect policy details.

---

## 7. Backward Compatibility with the Previously-Published Surface

- `McpBridge` constructor and method names unchanged.
- `McpBridgeConfig` field set unchanged.
- `MCPBridge` typedef alias retained for callers using the old casing.
- `ServerShutdownBehavior` enum values unchanged.
- `TransportSource` enum values unchanged.

The DEPENDENCIES change (mcp_client / mcp_server pre-2.0 → 2.x) — that's the breaking change driving the bump. Callers that depended on pre-2.0 mcp_client / mcp_server APIs through mcp_bridge's re-exports may break; mcp_bridge does not re-export those packages so most callers are insulated.

---

## 8. Threading and Async

- All operations are async; no isolate spawning.
- `MessageRouter` runs on the same isolate, dispatching via `Stream` listeners.
- No locks needed — Dart's single-threaded async model handles ordering.
- Hot-loop performance NFR1 (≤ 5 ms p95 forwarding overhead) achieved by avoiding redundant message copies — pass-through references where possible.

---

## 9. Error Handling

| Error | Source | Behavior |
|-------|--------|----------|
| `UnknownTransportTypeException` | `_buildServerTransport` / `_buildClientTransport` on unrecognised type-name | Thrown synchronously from `initialize()`, no partial state |
| `Result.failure` from underlying factory | mcp_client / mcp_server transport factory | Unwrapped via `result.failureOrNull!` and rethrown; `initialize()` calls `shutdown()` then rethrows |
| Transport runtime error | After init, e.g. socket reset, malformed inbound | Surfaces from `MessageRouter.onError`; dispatched via `_dispatchError`; lifecycle policy decides reconnect-or-shutdown |
| Send-side exception | `MessageRouter._forwardServerToClient` / `_forwardClientToServer` try/catch | Dispatched via `_dispatchError(side)` |
| `shutdown()` during `initialize()` | Race | initialize completes / fails first, then shutdown runs |

---

## 10. Test Hooks

The class has no dedicated test-mode constructor. Tests inject behaviour by constructing fake transports directly inside the test (small `mcp_server.ServerTransport` / `mcp_client.ClientTransport` adapters with controllable `onMessage`, `send`, `onClose`) and either:

- Pass them through a `_buildXxxTransport` test seam (a `@visibleForTesting` setter on the bridge), or
- Use a real built-in transport pair against loopback (e.g. STDIO subprocess against `cat`, SSE on a test port).

The latter is what the current test suite mostly does. The former exists where needed to drive specific lifecycle paths (reconnect, close-during-send) that are hard to provoke from real transports.
