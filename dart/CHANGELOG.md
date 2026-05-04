## 0.2.0-rc.1

Pre-release candidate. Hardware transports (`'serial'`, `'usb'`, `'ble'`)
have not yet been verified against representative real hardware — pin
to this exact version while you exercise them, and please file issues
with platform / device details so the next release can stabilize them.
Network and process transports (`'stdio'`, `'sse'`, `'streamableHttp'`,
`'websocket'`, `'tcp'`) are loopback-tested and considered ready.

Same content as the planned 0.2.0 (see below).

## 0.2.0 — planned (after rc validation)

* 2.0-wave modernization
    * Bumped `mcp_client` to `^2.0.0` and `mcp_server` to `^2.0.0`
    * Absorbed 2.0-wave breaking semantics: sampling/roots direction reversal, `notifications/cancelled` replacing `cancelOperation`, RFC 9728 OAuth replacing JSON-RPC `auth/*`, JSON-RPC batching removal, `MCP-Protocol-Version` HTTP header negotiation
    * Supports all four MCP protocol revisions exposed by 2.x: `2024-11-05`, `2025-03-26`, `2025-06-18`, `2025-11-25`
* **Built-in transport zoo (8 transports, selectable by type-name)**:
    * **Stable** (delegated to mcp_client / mcp_server): `'stdio'`, `'sse'`, `'streamableHttp'`
    * **Stable** (implemented inside mcp_bridge, loopback-tested):
        * `'websocket'` (`dart:io` `WebSocket` / `HttpServer`)
        * `'tcp'` (`dart:io` `Socket` / `ServerSocket`, newline-delimited JSON framing)
    * **Insufficiently verified** (implemented but awaiting broader real-hardware exposure):
        * `'serial'` (libserialport Dart FFI — USB CDC ACM devices included)
        * `'usb'` (libusb Dart FFI — raw bulk endpoints for vendor-specific protocols)
        * `'ble'` (bluez D-Bus on Linux only; macOS / Windows throw `UnsupportedError` at `initialize()`)
    * Consumer never opens a port / socket / device handle directly. Configure the transport via the `serverConfig` / `clientConfig` map; the bridge handles connect / framing / forwarding. See README for per-transport config keys.
* New deps: `libserialport`, `libusb`, `bluez` (all pure-Dart). System C libraries (libserialport, libusb) install instructions in README.
* `UnknownTransportTypeException` thrown at `initialize()` for unrecognised type-names; carries side + supported list.
* Verified forwarding for server-initiated MCP 2.0 requests (sampling / roots / elicitation)
* Bidirectional notification forwarding (list-changed / cancelled / progress)
* Public surface preserved from 0.1.0: `McpBridge`, `McpBridgeConfig`, `ServerShutdownBehavior`, `TransportSource`, four callback typedefs
* **Logger now uses `package:logging`** (workspace standard, matching mcp_client / mcp_server / mcp_llm / flutter_mcp). The previous custom `Logger` class is replaced by re-exporting `package:logging` plus extension methods (`debug` → `fine`, `error` → `severe`, `warn` → `warning`, `trace` → `finest`).
* Migration:
    * 0.1.0 → 0.2.0 is a hard dependency break. Consumers on `mcp_client ^0.1.x` / `mcp_server ^0.1.x` must update their dep pins to `^2.0.0`. The `McpBridge` / `McpBridgeConfig` public surface is source-compatible.
    * Logger callers using 0.1.0 patterns must update:
        * `Logger.getLogger('foo')` → `Logger('foo')`
        * `LogLevel.debug` → `Level.FINE` (and similar — see `package:logging`'s `Level` constants)
        * `logger.setLevel(LogLevel.X)` → `logger.level = Level.X`
        * `logger.configure(includeTimestamp:, useColor:, output:)` → set up a `Logger.root.onRecord.listen(...)` handler in your app's main and emit to stderr / file as you prefer.
        * `Logger.setAllLevels(LogLevel.X)` → `Logger.root.level = Level.X` (with `hierarchicalLoggingEnabled = true` if you want per-logger overrides).

## 0.1.0

* Initial release
    * Created bridge implementation for the Model Context Protocol (MCP)
    * Supports pluggable transport types (stdio, sse)
    * Provides bi-directional JSON-RPC message forwarding between MCP clients and servers
    * Command-line and config-file based configuration system
    * Auto-reconnection support for client and server transports
    * Token-based authentication support for SSE connections
    * Lifecycle coordination with graceful shutdown handling
    * Includes CLI test runner (test_bridge.dart) for integration testing
    * Compatible with mcp_server, mcp_client, and MCP Inspector
