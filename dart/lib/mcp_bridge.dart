/// MCP Bridge — forwards Model Context Protocol JSON-RPC messages
/// between two MCP transports. Aligned with the MCP 2.0 protocol wave
/// (revisions 2024-11-05 / 2025-03-26 / 2025-06-18 / 2025-11-25).
///
/// The bridge is intentionally thin: it does not define its own
/// transport interface. New transports (serial / WebSocket / BLE / …)
/// are added to `mcp_client` / `mcp_server`; mcp_bridge gains them via
/// a one-line type-name mapping update.
///
/// See `docs/00_PLAN/PRD.md` for the design intent and
/// `docs/03_DDD/*` for module-level details.
library;

export 'logger.dart';
export 'src/config.dart';
export 'src/bridge.dart';
