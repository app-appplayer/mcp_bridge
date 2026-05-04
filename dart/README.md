# MCP Bridge

A Dart package that translates Model Context Protocol (MCP) traffic between two transports — exotic on one side (serial / USB / BLE / WebSocket / TCP), standard on the other (stdio / SSE / Streamable HTTP). Open the bridge with both transports configured, and JSON-RPC frames flow between them automatically. Aligned with the MCP 2.0 protocol wave (revisions `2024-11-05` / `2025-03-26` / `2025-06-18` / `2025-11-25`).

```dart
final bridge = McpBridge(McpBridgeConfig(
  serverTransportType: 'serial',
  serverConfig: {'port': '/dev/ttyUSB0', 'baudRate': 115200},
  clientTransportType: 'streamableHttp',
  clientConfig: {'baseUrl': 'https://example.com/mcp'},
));
await bridge.initialize();
```

That's the whole consumer surface for a serial-to-HTTP bridge. The package handles port lifecycle, framing, forwarding, and reconnect.

## Features

- **8 built-in transports**, all selectable by type-name in `McpBridgeConfig`. No transport plugin or registry — open the bridge, both ends connect.
- **Verbatim, bidirectional JSON-RPC forwarding** — client requests, server responses, server-initiated requests (sampling / roots / elicitation), and notifications all flow through unchanged. JSON-RPC `id` correlation preserved.
- **Lifecycle policies** — `shutdownBridge` or `waitForReconnection` on server close; opt-in client auto-reconnect.
- **Four lifecycle callbacks** — `onTransportError`, `onTransportClosed`, `onTransportReconnected`, `onServerReconnectRequested`.
- **JSON-configurable** — `McpBridgeConfig.fromJson` / `toJson`.
- **Pure Dart, no Flutter.** Hardware transports use Dart FFI bindings to system C libraries (libserialport, libusb, bluez).

## Built-In Transports — Platform Support

| Type-name | Linux | macOS | Windows | Status | Implementation |
|-----------|:-----:|:-----:|:-------:|:------:|----------------|
| `'stdio'` | ✓ | ✓ | ✓ | stable | mcp_client / mcp_server |
| `'sse'` | ✓ | ✓ | ✓ | stable | mcp_client / mcp_server |
| `'streamableHttp'` | ✓ | ✓ | ✓ | stable | mcp_client / mcp_server |
| `'websocket'` | ✓ | ✓ | ✓ | stable | `dart:io` |
| `'tcp'` | ✓ | ✓ | ✓ | stable | `dart:io` (newline-delimited JSON) |
| `'serial'` | ✓ | ✓ | ✓ | **insufficiently verified** | libserialport FFI (USB CDC included) |
| `'usb'` | ✓ | ✓ | ✓ | **insufficiently verified** | libusb FFI (raw bulk endpoints) |
| `'ble'` | ✓ | ✗ | ✗ | **insufficiently verified** | bluez D-Bus on Linux only — macOS/Windows throw `UnsupportedError` at `initialize()` |

> **"Insufficiently verified"** means the code compiles, the static surface is correct, and the unit tests for config validation pass — but the path through the underlying FFI / D-Bus library has not yet been exercised against representative real hardware. The transports are shipped so consumers with the relevant hardware can try them and report back; expect rough edges (library-path fallbacks, GATT discovery timing, USB context lifecycle) and prefer pinning a specific minor version until your environment is proven stable. Stable promotion targets a future release after broader hardware exposure.

Hardware transports (`'serial'`, `'usb'`, `'ble'`) require system C libraries — see Installation below.

## Installation

```bash
dart pub add mcp_bridge
```

### System dependencies for hardware transports

If you only use `stdio` / `sse` / `streamableHttp` / `websocket` / `tcp`, no extra setup is needed.

For the hardware transports:

| Transport | Linux | macOS | Windows |
|-----------|-------|-------|---------|
| `'serial'` | `apt install libserialport0` (Debian/Ubuntu) or build from source | `brew install libserialport` | install libserialport via vcpkg, or drop the DLL next to your executable |
| `'usb'` | `apt install libusb-1.0-0` + udev rule granting your user access to the device | `brew install libusb` | install libusb via vcpkg or drop `libusb-1.0.dll` next to your executable; bind WinUSB driver to the device with Zadig |
| `'ble'` | `bluez` (pre-installed on most distros); user must be in `bluetooth` group | not supported in 0.2.0 | not supported in 0.2.0 |

## Quick Start

```dart
import 'package:mcp_bridge/mcp_bridge.dart';

Future<void> main() async {
  final log = Logger.getLogger('app')..setLevel(LogLevel.info);

  final bridge = McpBridge(
    McpBridgeConfig(
      serverTransportType: 'stdio',
      clientTransportType: 'sse',
      serverConfig: const {},
      clientConfig: const {
        'serverUrl': 'http://localhost:8080/sse',
        'headers': {'Authorization': 'Bearer my_token'},
      },
      serverShutdownBehavior: ServerShutdownBehavior.shutdownBridge,
    ),
  );

  bridge.onTransportError = (source, error, stackTrace) {
    log.error('${source.name} transport error: $error');
  };
  bridge.onTransportClosed = (source) => log.info('${source.name} closed');

  bridge.setAutoReconnect(enabled: true);
  await bridge.initialize();
  // ... bridge runs until you call shutdown ...
}
```

Convenience constructors for the two common topologies:

```dart
final bridge = await McpBridge.createStdioToSseBridge(
  serverUrl: 'http://localhost:8080/sse',
);
await bridge.initialize();
```

## Per-Transport Config Keys

Each transport accepts a `Map<String, dynamic>` config under `serverConfig` / `clientConfig`. Keys below are passed verbatim to the underlying implementation.

### `'stdio'`

**Client-side** (spawn subprocess):

```dart
{ 'command': 'python', 'arguments': ['server.py'],
  'workingDirectory': '.', 'environment': {'FOO': 'bar'} }
```

**Server-side**: empty (binds host process stdin/stdout).

### `'sse'`

**Client-side**:

```dart
{ 'serverUrl': 'https://example.com/sse',
  'headers': {'Authorization': 'Bearer ...'} }
```

**Server-side**:

```dart
{ 'host': 'localhost', 'port': 8080,
  'endpoint': '/sse', 'messagesEndpoint': '/messages',
  'fallbackPorts': [8081, 8082], 'authToken': '...' }
```

### `'streamableHttp'`

**Client-side**:

```dart
{ 'baseUrl': 'https://example.com/mcp',
  'headers': {'Authorization': 'Bearer ...'},
  'timeoutMs': 5000, 'maxConcurrentRequests': 8, 'useHttp2': true }
```

**Server-side**:

```dart
{ 'host': 'localhost', 'port': 8080,
  'endpoint': '/mcp', 'messagesEndpoint': '/messages',
  'isJsonResponseEnabled': false }
```

### `'websocket'`

**Client-side**:

```dart
{ 'url': 'ws://example.com/mcp',
  'headers': {'Authorization': 'Bearer ...'},
  'protocols': ['mcp.v1'], 'pingInterval': 30000 }
```

**Server-side**:

```dart
{ 'host': 'localhost', 'port': 8080, 'path': '/',
  'authToken': '...' }
```

### `'tcp'`

**Client-side**:

```dart
{ 'host': '192.168.1.10', 'port': 9000, 'timeoutMs': 5000 }
```

**Server-side**:

```dart
{ 'host': 'localhost', 'port': 0 }  // 0 = OS picks free port
```

### `'serial'` (USB CDC ACM devices included)

Both directions accept the same keys:

```dart
{ 'port': '/dev/ttyACM0',          // Linux: /dev/ttyACM* or /dev/ttyUSB*
                                    // macOS: /dev/cu.usbmodem*
                                    // Windows: COM3 etc.
  'baudRate': 115200,
  'dataBits': 8,
  'parity': 'none',                 // 'none' | 'odd' | 'even' | 'mark' | 'space'
  'stopBits': 1,
  'flowControl': 'none',            // 'none' | 'rts_cts' | 'xon_xoff' | 'dsr_dtr'
  'pollIntervalMs': 10 }            // input-waiting poll cadence
```

### `'usb'`

Both directions accept:

```dart
{ 'vendorId': 0x1234,               // hex like 0x1234
  'productId': 0x5678,
  'interface': 0,                   // USB interface number
  'inEndpoint': 0x81,               // bulk-in (host reads from here)
  'outEndpoint': 0x01,              // bulk-out (host writes here)
  'readTimeoutMs': 10,              // per-poll bulk-in timeout
  'writeTimeoutMs': 1000,
  'readBufferSize': 4096,
  'pollIntervalMs': 10,
  'libusbPath': '/path/to/libusb-1.0.dylib' }  // optional override
```

### `'ble'` — Linux only in 0.2.0

```dart
{ 'deviceAddress': 'AA:BB:CC:DD:EE:FF',     // BLE peripheral
  'serviceUuid': '0000abcd-...',             // GATT service carrying MCP
  'notifyCharUuid': '0000abce-...',          // peripheral → host (notify)
  'writeCharUuid': '0000abcf-...' }          // host → peripheral (write)
```

The bridge connects as a BLE central. macOS / Windows throw `UnsupportedError` when `'ble'` is selected.

## JSON Configuration

```dart
final json = jsonDecode(await File('bridge.json').readAsString());
final config = McpBridgeConfig.fromJson(json);
final bridge = McpBridge(config);
await bridge.initialize();
```

```json
{
  "serverTransportType": "serial",
  "clientTransportType": "streamableHttp",
  "serverShutdownBehavior": "waitForReconnection",
  "serverConfig": { "port": "/dev/ttyUSB0", "baudRate": 115200 },
  "clientConfig": { "baseUrl": "http://localhost:8080/mcp" }
}
```

The four lifecycle callbacks cannot be carried in JSON — set them on the `McpBridge` instance after construction.

## Lifecycle and Reconnection

```dart
final config = McpBridgeConfig(
  // ...
  serverShutdownBehavior: ServerShutdownBehavior.waitForReconnection,
);
final bridge = McpBridge(config);

bridge.setServerReconnectionOptions(
  maxAttempts: 0,                              // 0 = unbounded
  checkInterval: const Duration(seconds: 5),
);

bridge.onServerReconnectRequested = () async {
  // false → decline, bridge shuts down. true → attempt reconnect now.
  return true;
};

final log = Logger.getLogger('app');
bridge.onTransportReconnected = (source) {
  log.info('${source.name} back online');
};

// Opt-in client-side auto-reconnect.
bridge.setAutoReconnect(
  enabled: true,
  maxAttempts: 3,
  delay: const Duration(seconds: 2),
);
```

## Adding a New Transport

mcp_bridge is the place to land new wires. The package isn't designed for third-party transport plugins — when you need a new transport, open a PR / issue and it goes into `lib/src/transport/`.

The pattern (used by every transport in this package):

1. Write `lib/src/transport/foo_server_transport.dart` — implements `mcp_server.ServerTransport`. Owns its own connect / disconnect / framing / error surface.
2. Write `lib/src/transport/foo_client_transport.dart` — implements `mcp_client.ClientTransport`. Same shape.
3. Add a `case 'foo':` branch to `_buildServerTransport` and `_buildClientTransport` in `lib/src/bridge.dart`. Append `'foo'` to `_supportedTransportTypes`.
4. Document the type-name + config keys in this README's platform support table.
5. Add tests — fake-driven unit + loopback integration where practical.
6. Bump mcp_bridge minor version (additive change).

Transports requiring Flutter (BLE on iOS / Android, USB on Android, etc.) belong in a sibling `flutter_mcp_bridge` package, not here.

## Logging

mcp_bridge re-exports [`package:logging`](https://pub.dev/packages/logging) — the workspace-standard logger used across mcp_client / mcp_server / mcp_llm / flutter_mcp. Records flow through `Logger.root.onRecord` as a Stream; your app subscribes and routes them to stderr / a file / a remote sink as needed.

```dart
import 'package:mcp_bridge/mcp_bridge.dart';
import 'dart:io';

void setupLogging() {
  hierarchicalLoggingEnabled = true;
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((rec) {
    stderr.writeln('[${rec.time}] [${rec.level.name}] [${rec.loggerName}] ${rec.message}');
  });
}

final log = Logger('mcp_bridge')..level = Level.FINE;
log.info('bridge starting');
log.severe('something failed');
```

For consumers migrating from 0.1.0, the extension shortcuts are still available: `log.debug(...)` → `fine`, `log.error(...)` → `severe`, `log.warn(...)` → `warning`, `log.trace(...)` → `finest`.

## Example

`example/mcp_bridge_example.dart` is a runnable CLI sample exercising every public surface (config, callbacks, auto-reconnect, JSON file loading, signal-based graceful shutdown). Run it directly:

```bash
dart run example/mcp_bridge_example.dart \
  --server-type=stdio --client-type=sse \
  --server-url=http://localhost:8080/sse
```

## Related Packages

- [`mcp_server`](https://pub.dev/packages/mcp_server) — build an MCP-compatible server
- [`mcp_client`](https://pub.dev/packages/mcp_client) — connect to an MCP-compatible server
- [`mcp_llm`](https://pub.dev/packages/mcp_llm) — LLM client integration
- [`flutter_mcp`](https://pub.dev/packages/flutter_mcp) — Flutter-specific MCP integration

## Issues and Feedback

File issues at the [issue tracker](https://github.com/app-appplayer/mcp_bridge/issues).

## License

MIT License. See [LICENSE](LICENSE) for details.
