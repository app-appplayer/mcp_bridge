/// MCP Bridge — forwards Model Context Protocol JSON-RPC messages
/// between two MCP transports. Aligned with the MCP 2.0 protocol wave
/// (revisions 2024-11-05 / 2025-03-26 / 2025-06-18 / 2025-11-25).
///
/// The bridge defines no transport interface of its own — it implements the
/// standard `mcp_client.ClientTransport` / `mcp_server.ServerTransport` — and
/// houses the **extension transports** (serial / usb / ble / tcp / WebSocket)
/// that carry MCP over non-standard wires. It is the opt-in home for their
/// FFI / platform dependencies, kept out of the mcp_client / mcp_server core
/// so general consumers of those packages are not burdened. The transport
/// classes are exported below so hosts can inject them directly (e.g.
/// brain_kernel's `McpClientKernelHost.connectWith`). See
/// `specs/platform/08-extension.md` §4.
///
/// See `docs/00_PLAN/PRD.md` for the design intent and
/// `docs/03_DDD/*` for module-level details.
library;

export 'logger.dart';
export 'src/config.dart';
export 'src/bridge.dart';

// Extension transports — `mcp_client.ClientTransport` /
// `mcp_server.ServerTransport` implementations, exposed for host injection.
export 'src/transport/tcp_client_transport.dart';
export 'src/transport/tcp_server_transport.dart';
export 'src/transport/websocket_client_transport.dart';
export 'src/transport/websocket_server_transport.dart';
export 'src/transport/serial_client_transport.dart';
export 'src/transport/serial_server_transport.dart';
export 'src/transport/usb_client_transport.dart';
export 'src/transport/usb_server_transport.dart';
export 'src/transport/ble_client_transport.dart';
export 'src/transport/ble_server_transport.dart';
