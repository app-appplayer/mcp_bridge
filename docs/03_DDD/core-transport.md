# DDD: `core-transport` — Built-In Transports

> Module: `lib/src/transport/`
> Implements SRS: FR2 (built-in transport set)
> SDD section: §3 (built-in transport set), §4 (adding a 9th transport)

---

## 1. Purpose

Five transports beyond the standard mcp_client / mcp_server set ship inside mcp_bridge. Each is a pair of server-side + client-side implementations of `mcp_server.ServerTransport` / `mcp_client.ClientTransport`. The consumer selects them by name in `McpBridgeConfig`; the bridge constructs them from the matching switch case in `bridge.dart` and hands them to the `MessageRouter`.

This file documents the contract every built-in transport satisfies, the per-transport config-key schemas, and the platform-support matrix.

---

## 2. Contract Common to All Built-In Transports

Each implementation MUST satisfy the relevant abstract class:

```dart
// mcp_server.ServerTransport (and mcp_client.ClientTransport — same shape)
abstract class ServerTransport {
  Stream<dynamic> get onMessage;          // decoded JSON-RPC frames
  Future<void> get onClose;               // completes on graceful close / error
  void send(dynamic message);             // encodes + frames + transmits
  void close();                           // tears down resources
}
```

Lifecycle expectations:

- Constructor receives the `Map<String, dynamic>` config and validates required keys synchronously. Missing required keys throw `ArgumentError`.
- The transport SHOULD be ready to receive `send` / emit on `onMessage` after construction (or after an explicit `start()` for transports that need async setup — TCP / WebSocket / serial / USB / BLE all have a `start()` method called by the bridge before forwarding begins).
- Stream errors on the wire surface as stream errors on `onMessage`.
- `onClose` completes when the underlying connection terminates for any reason (graceful peer close, peer disconnect, transport-level error, or local `close()` call).
- `close()` is idempotent.

Framing for byte-stream transports (TCP, serial, USB) is **newline-delimited JSON** — one JSON-RPC frame per line, UTF-8. WebSocket text frames already carry frame boundaries, so each frame is one JSON-RPC message. BLE uses GATT characteristic notifications/writes and packs one frame per characteristic value (chunking handled internally for large frames).

---

## 3. WebSocket Transport (`'websocket'`)

### 3.1 Server-side (`websocket_server_transport.dart`)

Binds an `HttpServer` and upgrades the first connection to a WebSocket. Single-client (the bridge is 1:1 — no multi-client multiplexing in scope).

Config keys:
- `host` (string, default `'localhost'`)
- `port` (int, default `8080`)
- `path` (string, default `'/'`) — only requests matching this path are upgraded
- `authToken` (string, optional) — if set, requires `Authorization: Bearer <token>` header

### 3.2 Client-side (`websocket_client_transport.dart`)

Connects via `WebSocket.connect(url)`.

Config keys:
- `url` (string, required) — `ws://...` or `wss://...`
- `headers` (`Map<String, String>`, optional)
- `protocols` (`List<String>`, optional) — WebSocket subprotocols
- `pingInterval` (int milliseconds, optional)

---

## 4. TCP Transport (`'tcp'`)

### 4.1 Server-side (`tcp_server_transport.dart`)

Binds a `ServerSocket`, accepts the first connection, attaches.

Config keys:
- `host` (string, default `'localhost'`)
- `port` (int, default `0` = OS picks)

### 4.2 Client-side (`tcp_client_transport.dart`)

`Socket.connect(host, port)`.

Config keys:
- `host` (string, required)
- `port` (int, required)
- `timeoutMs` (int, optional)

Both sides do newline-delimited JSON framing.

---

## 5. Serial Transport (`'serial'`)

USB CDC ACM devices appear as serial ports on every OS, so `'serial'` covers them transparently.

### 5.1 Server-side (`serial_server_transport.dart`)

Opens a serial port, reads bytes from `port.stream`, decodes newline-delimited JSON, emits on `onMessage`. `send()` writes `${jsonEncode(msg)}\n` to the port.

### 5.2 Client-side (`serial_client_transport.dart`)

Same as server-side — serial is symmetric. A "client" just connects to a serial-listening MCP device.

Config keys (both directions):
- `port` (string, required) — `/dev/ttyUSB0`, `/dev/cu.usbmodem*`, `COM3`, etc.
- `baudRate` (int, default `115200`)
- `dataBits` (int, default `8`)
- `parity` (string, `'none' | 'odd' | 'even'`, default `'none'`)
- `stopBits` (int, default `1`)
- `flowControl` (string, `'none' | 'rts_cts' | 'xon_xoff'`, default `'none'`)

System dep: **`libserialport`** must be installed (`apt install libserialport-dev`, `brew install libserialport`, or vcpkg on Windows).

---

## 6. USB Transport (`'usb'`)

Direct USB endpoint access via libusb FFI — for vendor-specific protocols not exposed as CDC.

### 6.1 Server-side (`usb_server_transport.dart`)

Opens the USB device by vendor:product, claims an interface, reads from a bulk-in endpoint, writes to a bulk-out endpoint. Newline-delimited JSON.

### 6.2 Client-side (`usb_client_transport.dart`)

Symmetric to server-side.

Config keys (both directions):
- `vendorId` (int, required) — hex like `0x1234`
- `productId` (int, required)
- `interface` (int, default `0`)
- `inEndpoint` (int, required) — typically `0x81` for bulk in
- `outEndpoint` (int, required) — typically `0x01` for bulk out
- `timeoutMs` (int, default `1000`) — per-transfer timeout
- `serialNumber` (string, optional) — for disambiguating multiple identical devices

System deps:
- **`libusb`** native library installed
- Linux: udev rule granting non-root access to the device
- Windows: WinUSB driver bound to the device (use Zadig or vendor's installer)
- macOS: device must not be claimed by an existing kernel extension

---

## 7. BLE Transport (`'ble'`) — Linux only in 0.2.0

### 7.1 Server-side (`ble_server_transport.dart`)

Acts as a BLE peripheral or central depending on config (see `role`). On Linux, uses `bluez` D-Bus to register a GATT service with two characteristics: one notify (server → client) and one write (client → server). Newline-delimited JSON over the characteristic values.

### 7.2 Client-side (`ble_client_transport.dart`)

Acts as the opposite role. Linux: `bluez` D-Bus client connects to the peripheral, subscribes to notifications, writes to the write characteristic.

Config keys:
- `role` (string, `'central' | 'peripheral'`, default `'central'`)
- `deviceAddress` (string, required for `'central'`) — e.g. `AA:BB:CC:DD:EE:FF`
- `serviceUuid` (string, required) — UUID of the GATT service carrying MCP
- `notifyCharUuid` (string, required) — characteristic for receive (notifications)
- `writeCharUuid` (string, required) — characteristic for send

### 7.3 Platform handling

`Platform.isLinux` is checked at construction:
- Linux → uses `bluez` package
- macOS / Windows → throws `UnsupportedError("'ble' transport is Linux-only in 0.2.0")` at constructor

---

## 8. Platform Support Matrix (mirror in README)

| Transport | Linux | macOS | Windows | Notes |
|-----------|:-----:|:-----:|:-------:|-------|
| `'stdio'` | ✓ | ✓ | ✓ | mcp_client / mcp_server |
| `'sse'` | ✓ | ✓ | ✓ | mcp_client / mcp_server |
| `'streamableHttp'` | ✓ | ✓ | ✓ | mcp_client / mcp_server |
| `'websocket'` | ✓ | ✓ | ✓ | dart:io |
| `'tcp'` | ✓ | ✓ | ✓ | dart:io |
| `'serial'` | ✓ | ✓ | ✓ | requires system `libserialport` |
| `'usb'` | ✓ | ✓ | ✓ | requires system `libusb` + driver setup |
| `'ble'` | ✓ | ✗ | ✗ | macOS / Windows throw `UnsupportedError` |

---

## 9. Test Doubles and Strategy

For each built-in transport, tests come in two flavors:

- **Unit tests against fakes** — substitute `_FakeServerTransport` / `_FakeClientTransport` (in-test classes implementing the abstract interfaces) into the bridge via the `@visibleForTesting` `McpBridge.testWithTransports(...)` constructor. These verify forwarding / lifecycle without touching any real I/O.
- **Loopback integration tests** — for transports that can run end-to-end on the test machine without external deps (`'tcp'`, `'websocket'`), spin up a server-side instance on a free port and connect a client-side instance to it. Verify a JSON-RPC frame round-trips intact.

Hardware transports (`'serial'`, `'usb'`, `'ble'`) are not loopback-testable in CI — they're verified manually before release using real devices, and the example CLI demonstrates each. The factory-call shape is unit-tested via mocked FFI bindings where practical.

---

## 10. Adding the 9th Transport

Per SDD §4 — same pattern: write the pair, add the switch case, append the supported list, document, test, bump.
