# DDD: `core-router` — MessageRouter

> Module: `lib/src/router.dart`
> Implements SRS: FR3 (bidirectional forwarding)
> SDD section: §2.3

---

## 1. Purpose

Forward MCP JSON-RPC messages between the bridge's two transports. Handles all four message kinds (request · response · server-initiated request · notification) in both directions, preserving JSON-RPC `id` correlation.

---

## 2. Interface

```dart
import 'package:mcp_client/mcp_client.dart' as client;
import 'package:mcp_server/mcp_server.dart' as server;

class MessageRouter {
  MessageRouter({
    required server.ServerTransport serverTransport,
    required client.ClientTransport clientTransport,
    required Logger logger,
    TransportErrorCallback? onError,
  });

  /// Bind to both transports' onMessage streams. Forwarding active until
  /// [stop] is called.
  void start();

  /// Cancel subscriptions; stop forwarding. Idempotent.
  Future<void> stop();
}
```

The router holds `mcp_server.ServerTransport` and `mcp_client.ClientTransport` directly — no intermediate adapter. Both types expose compatible `onMessage` streams (`Stream<dynamic>`) and `send(dynamic)` methods, plus `onClose` futures used by `McpBridge` (not by the router).

The optional `onError` callback receives `(TransportSource destinationSide, Object error, StackTrace stack)` whenever a stream-error or `send()` exception bubbles up. `McpBridge` passes its own `_dispatchError` here so router-level errors flow through the same lifecycle dispatcher as transport-level errors.

`MessageRouter` is internal (`lib/src/`) — consumers never instantiate it directly. `McpBridge` owns the lifecycle.

---

## 3. Forwarding Logic

Two stream subscriptions, one per direction:

```dart
void start() {
  _serverSub = _serverTransport.onMessage.listen(
    _forwardServerToClient,
    onError: _onServerError,
  );
  _clientSub = _clientTransport.onMessage.listen(
    _forwardClientToServer,
    onError: _onClientError,
  );
}

void _forwardServerToClient(dynamic message) {
  // FR3.1, FR3.6 — client-initiated requests + client-side notifications
  // (cancel) all flow this direction.
  _clientTransport.send(message);
}

void _forwardClientToServer(dynamic message) {
  // FR3.2, FR3.3, FR3.4, FR3.5, FR3.6 — responses, server-initiated
  // requests (sampling/roots/elicitation), and backend notifications
  // all flow this direction.
  _serverTransport.send(message);
}
```

The router does NOT classify messages by type — it forwards verbatim. The MCP wire is symmetric for the bridge's purposes; classification (request vs response vs notification) only matters to the endpoints, not the relay.

---

## 4. Why No Special Handling for Sampling / Roots / Elicitation

The 2.0-wave server-initiated request features (FR3.3–FR3.5) are JSON-RPC requests originating from the server, sent over the same transport the responses use. From the bridge's POV, they're just inbound messages on `_clientTransport.onMessage`, indistinguishable from a response to a previous client request. Forwarding them verbatim to `_serverTransport` is correct because:

- The originating client receives them with their original `id` field.
- The originating client responds (sampling result, roots list, elicitation response) — the response flows back through the bridge in the opposite direction.
- The MCP server's request-tracking logic handles the round-trip, not the bridge.

This is why the bidirectional-forwarding track is largely a TEST addition — the forwarding code is already correct from the dependency-modernization track; the work is verifying and locking the behavior.

---

## 5. ID Correlation

JSON-RPC `id` correlation is the endpoints' responsibility. The bridge does not maintain a map of in-flight requests because:

- The originating endpoint generates the `id` and tracks its own outstanding requests.
- The receiving endpoint replies with that same `id`.
- The bridge passes both messages through unchanged.

If the bridge tried to rewrite `id`s (e.g. namespace them), it would have to track every request, increasing complexity and memory. Verbatim pass-through stays simple and correct.

---

## 6. Error Handling

```dart
void _onServerError(Object error, StackTrace stack) {
  _logger.warning('server transport error: $error');
  // Lifecycle invokes TransportErrorCallback separately; router just
  // logs and lets the lifecycle handle reconnection.
}
```

If a `send` fails (transport closed mid-forward), the exception propagates up the stream listener. The bridge's `Lifecycle` then closes the bridge per `ServerShutdownBehavior`.

Malformed inbound JSON-RPC: the transport's `onMessage` may emit malformed data (transport implementation choice). If `send` to the other side fails because the other transport rejects malformed input, the error reaches `_onServerError` / `_onClientError` and is logged. We do NOT pre-validate JSON-RPC structure — that's the endpoints' job.

---

## 7. Backpressure

First-cut: synchronous `send()` calls; relies on each transport's internal buffering. If a transport implementation introduces async send + queue, the router's `listen` callback returns instantly while the transport buffers internally. No router-level queue.

Future consideration: observability hooks on queue depth would help diagnose slow consumers, but it's not in scope for the improvement initiative.

---

## 8. Test Coverage Targets

| Test | Verifies |
|------|----------|
| `forwards client request to backend` | FR3.1 — request flows server→client direction |
| `forwards backend response back` | FR3.2 — response flows client→server direction |
| `forwards server-initiated sampling` | FR3.3 — sampling request flows client→server |
| `forwards sampling result back` | FR3.3 — sampling result flows server→client |
| `forwards roots request` | FR3.4 |
| `forwards elicitation request` | FR3.5 |
| `forwards list_changed notification` | FR3.6 — notification flows in both directions |
| `forwards cancelled notification` | FR3.6 |
| `preserves JSON-RPC id verbatim` | §5 — id correlation |
| `transport send error logs warning` | §6 |
