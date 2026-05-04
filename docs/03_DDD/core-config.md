# DDD: `core-config` — McpBridgeConfig

> Module: `lib/src/config.dart`
> Public class: `McpBridgeConfig`
> Implements SRS: FR5
> SDD section: §2.1

---

## 1. Purpose

Construction-time configuration for `McpBridge`. Carries the transport selections, their per-transport configs, the shutdown behavior, and the four lifecycle callbacks.

---

## 2. Public Surface

```dart
class McpBridgeConfig {
  /// Transport-type name for the server side. Mapped at
  /// [McpBridge.initialize] time to a `mcp_server` 2.x transport
  /// factory call. Recognised values: `'stdio'`, `'sse'`,
  /// `'streamableHttp'`.
  final String serverTransportType;

  /// Transport-specific configuration. Passed verbatim to the
  /// underlying mcp_server transport factory.
  final Map<String, dynamic> serverConfig;

  /// Transport-type name for the client side. Mapped at
  /// [McpBridge.initialize] time to a `mcp_client` 2.x transport
  /// factory call.
  final String clientTransportType;

  /// Transport-specific configuration for the client side.
  final Map<String, dynamic> clientConfig;

  /// What happens when the server-side transport closes.
  final ServerShutdownBehavior serverShutdownBehavior;

  /// Optional lifecycle callbacks. Invoked synchronously by the bridge's
  /// internal dispatchers. All four are optional; the same names also
  /// exist as public fields on `McpBridge` itself, and instance fields
  /// take precedence at dispatch time.
  final TransportErrorCallback? onTransportError;
  final TransportClosedCallback? onTransportClosed;
  final TransportReconnectedCallback? onTransportReconnected;
  final ServerReconnectRequestedCallback? onServerReconnectRequested;

  const McpBridgeConfig({
    required this.serverTransportType,
    required this.clientTransportType,
    required this.serverConfig,
    required this.clientConfig,
    this.serverShutdownBehavior = ServerShutdownBehavior.shutdownBridge,
    this.onTransportError,
    this.onTransportClosed,
    this.onTransportReconnected,
    this.onServerReconnectRequested,
  });

  /// JSON round-trip helpers (callbacks not preserved — JSON cannot
  /// carry function references).
  factory McpBridgeConfig.fromJson(Map<String, dynamic> json);
  Map<String, dynamic> toJson();
}
```

---

## 3. Compatibility with the Previously-Published Surface

The previously-published surface had:

```dart
McpBridgeConfig({
  required String serverTransportType,
  required String clientTransportType,
  required Map<String, dynamic> serverConfig,
  required Map<String, dynamic> clientConfig,
  ServerShutdownBehavior serverShutdownBehavior = ServerShutdownBehavior.shutdownBridge,
});
```

The four optional callback fields (with `null` defaults) are an additive change — source-compat preserved.

---

## 4. Validation

`McpBridgeConfig` itself does NOT validate transport names — that happens at `McpBridge.initialize()` time, where the type-name is matched against the bridge's switch and an `UnknownTransportTypeException` thrown on miss. The config object is a passive value carrier; construction succeeds with any string.

`serverConfig` / `clientConfig` are `Map<String, dynamic>` — completely permissive at config-construction time. The underlying mcp_server / mcp_client transport factory validates its own config when the bridge initializes; missing required keys throw whatever that factory throws (typically `ArgumentError` or a `Result.failure` Exception).

---

## 5. Per-Transport Config Schemas

Schemas are owned by `mcp_client` / `mcp_server` 2.x — mcp_bridge passes the maps through without interpretation. README §"Built-In Transports" lists the recognised type-names and the keys each underlying factory expects, for consumer convenience; the authoritative contract lives in those packages.

A new transport added to `mcp_client` / `mcp_server` is gained by mcp_bridge with a one-line case addition in the bridge's transport-selection switch. Its config-key contract is whatever the underlying factory documents.

---

## 6. Immutability

`McpBridgeConfig` is `const`-constructible. Once passed to `McpBridge`, the config is treated as immutable — the bridge stores a reference and reads from it during initialize. Mutating the underlying maps (`serverConfig`, `clientConfig`) after construction is undefined behavior.

---

## 7. Test Hooks

No special test surface needed — tests construct `McpBridgeConfig` directly with built-in transport-type names (`'stdio'`, `'sse'`, `'streamableHttp'`) and the relevant config keys, then either drive against real underlying transports (loopback / `cat` subprocess / SSE on a test port) or pass through a `@visibleForTesting` seam that lets tests substitute fake `mcp_server.ServerTransport` / `mcp_client.ClientTransport` instances directly.

---

## 8. Future Extensions

Possible additions deferred:

- `ReconnectPolicy` config (max attempts, backoff curve).
- Per-side `Logger` override.
- Observability / metrics hooks.
- Multi-route config (one bridge fronting N backend servers — out of scope per PRD §8).

These are NOT in scope for the current improvement initiative. Add only if real consumer demand emerges.
