# DDD: `core-lifecycle` — Lifecycle Handling

> Module: inline in `lib/src/bridge.dart`
> Implements SRS: FR4 (lifecycle and error handling)
> SDD section: §2.5

---

## 1. Purpose

Manage the bridge's transport lifecycle — close events, errors, reconnection — and surface them to the consumer through the four callback typedefs.

---

## 2. Why Inline (No Separate Class)

There is intentionally no `LifecycleManager` class. Every lifecycle decision (`shutdownBridge` vs `waitForReconnection`, client auto-reconnect, dispatcher precedence between instance fields and config) reads or mutates `McpBridge`'s state machine (`_isInitialized`, `_isShuttingDown`, `_isServerActive`, `_isWaitingForServerReconnection`, the reconnect counters). Splitting into a separate class would mean either:

- Passing those flags by reference between two objects (fragile, easy to desync), or
- Duplicating the state on the manager and then maintaining bidirectional synchronisation.

Both options add cost without abstraction value. The bridge is small enough — about 350 lines including convenience constructors — that keeping the orchestrator and lifecycle in one class is the simpler design.

---

## 3. Surface

The lifecycle surface is the public part of `McpBridge` in `core-bridge.md` §2:

- Four callback fields settable directly on the instance: `onTransportError`, `onTransportClosed`, `onTransportReconnected`, `onServerReconnectRequested`. Same names exist on `McpBridgeConfig`; instance fields take precedence at dispatch time.
- `setAutoReconnect({enabled, maxAttempts, delay})` — client-side reconnect on transient close.
- `setServerReconnectionOptions({maxAttempts, checkInterval})` — server-side reconnect loop tuning when behavior is `waitForReconnection`.
- `serverShutdownBehavior` getter (mirrors config).

---

## 4. Internal Methods (private)

| Method | Triggered by | Responsibility |
|--------|--------------|----------------|
| `_setupForwarding` | end of `initialize()`; end of successful reconnect | Build & start `MessageRouter`; subscribe to both `onClose` futures; wire each close to `_dispatchClosed(side)` plus the shutdown-behavior policy |
| `_handleServerDisconnection` | server-side `onClose` when behavior is `waitForReconnection` | Close client side; loop calling `onServerReconnectRequested`; on `true` re-resolve factories, re-open both transports, re-run `_setupForwarding`, fire `_dispatchReconnected(server)` |
| `_attemptClientReconnect` | client-side `onClose` when `_autoReconnect` is enabled | Wait `_reconnectDelay`; re-open client transport; restart router; fire `_dispatchReconnected(client)`; retry up to `_maxReconnectAttempts` |
| `_dispatchError(side, e, st)` | router `onError` callback; bridge catch blocks | Read `onTransportError` (instance, then config); call with stack trace |
| `_dispatchClosed(side)` | both transport `onClose` futures | Read `onTransportClosed` (instance, then config); invoke once |
| `_dispatchReconnected(side)` | end of `_handleServerDisconnection` / `_attemptClientReconnect` | Read `onTransportReconnected` (instance, then config); invoke once |

---

## 5. Reconnect Policy

### 5.1 Server-side (`waitForReconnection`)

```
loop {
  if max attempts reached (>0) → shutdown
  shouldRetry = onServerReconnectRequested?.call() ?? true
  if !shouldRetry → shutdown
  try {
    re-open server transport via factory
    re-open client transport via factory
    setup forwarding
    fire onTransportReconnected(server)
    return
  } catch (e) {
    fire onTransportError(server, e)
    sleep _serverReconnectCheckInterval
  }
}
```

Multiple reconnect attempts: the loop continues until success, hard cap, or callback returns `false`. The default `_maxServerReconnectAttempts = 0` means unbounded; set via `setServerReconnectionOptions(maxAttempts: N)`.

### 5.2 Client-side auto-reconnect

```
if shutting down or server inactive → skip
if attempts > _maxReconnectAttempts → skip
sleep _reconnectDelay
try {
  re-open client transport
  restart router
  reset attempts; fire onTransportReconnected(client)
} catch (e) {
  fire onTransportError(client, e)
  if server still active → recursive retry
}
```

Default disabled. Enable via `setAutoReconnect(enabled: true, maxAttempts: N, delay: D)`.

---

## 6. Error Routing

Transport errors surface through three paths, all eventually hitting `_dispatchError`:

1. **`MessageRouter` stream errors** (`_onServerError` / `_onClientError`) — caught by listener, logged, dispatched.
2. **`send()` exceptions** — caught at the router's `_forwardServerToClient` / `_forwardClientToServer` try blocks, dispatched with the destination side as `TransportSource`.
3. **`open()` failures** — caught at `initialize()` and at reconnect attempts, dispatched.

`_dispatchError` is the single fan-in point. It receives `(TransportSource side, Object error, StackTrace? stackTrace)` and reads instance-then-config for the callback. The `StackTrace?` is non-null in most paths (caught from `try/catch (e, st)`) — null only when the call site has just an error object without context.

---

## 7. Test Strategy

Tests verify lifecycle by either:

- **Real transport pairs against loopback** — e.g. STDIO client against `cat`, SSE on an OS-picked port. Drive the underlying process / socket to provoke close events.
- **`@visibleForTesting` seam** — substitute fake `mcp_server.ServerTransport` / `mcp_client.ClientTransport` instances built directly inside tests (small classes with controllable `onMessage` / `send` / `onClose`) for paths that are hard to provoke from real transports (e.g. server reconnect after callback returns true).

See `test/mcp_bridge_test.dart` groups `Lifecycle callbacks (FR4)` and `Reconnect (FR4.4 / FR4.5)`.
