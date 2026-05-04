# mcp_bridge — Workspace Changelog

> Workspace-level changelog mirror. Source of truth for **published** versions: `dart/CHANGELOG.md` (the file pub.dev sees). This file additionally tracks **planned** versions per the improvement program (`00_PLAN/PRD.md`).

Release scheduling — which PRD §4 tracks ship together, in what order — is decided here, not in PRD/SRS/SDD/DDD/TEST/QA.

---

## Planned

### [0.2.0] — 2.0-Wave + Built-In Transport Zoo (combined release)

Status: planned · pending publish approval.

- Bump `mcp_client` `^0.1.6` → `^2.0.0`, `mcp_server` `^0.1.7` → `^2.0.0`.
- Absorb 2.0-wave breaking semantics (sampling reverse, roots reverse, `notifications/cancelled`, RFC 9728 OAuth, JSON-RPC batching removal, `MCP-Protocol-Version` HTTP negotiation).
- **8 built-in transports**, all selectable by type-name in `McpBridgeConfig`:
  - **Stable** (delegated to mcp_client / mcp_server): `'stdio'`, `'sse'`, `'streamableHttp'`.
  - **Stable** (implemented inside mcp_bridge, loopback-tested): `'websocket'` (dart:io), `'tcp'` (dart:io).
  - **Insufficiently verified** (implemented inside mcp_bridge, awaiting broader real-hardware exposure): `'serial'` (libserialport FFI; USB CDC included), `'usb'` (libusb FFI; raw bulk endpoints), `'ble'` (bluez D-Bus on Linux; macOS / Windows throw `UnsupportedError` at `initialize()`).
  - All implement `mcp_client.ClientTransport` / `mcp_server.ServerTransport` directly — no plugin / registry / adapter layer. Consumer never opens a port / socket / device handle directly: configure the transport via `serverConfig` / `clientConfig` map and the bridge handles connect / framing / forwarding.
- New deps: `libserialport`, `libusb`, `bluez` (all pure-Dart packages). System C libraries documented in README install instructions.
- `UnknownTransportTypeException` thrown at `initialize()` for unrecognised type-names; carries side + supported list.
- Verified forwarding for server-initiated MCP 2.0 requests (sampling / roots / elicitation).
- Bidirectional notification forwarding (list-changed / cancelled / progress).
- Previously-published public surface preserved — `McpBridge` / `McpBridgeConfig` / `ServerShutdownBehavior` / `TransportSource` / 4 callback typedefs.
- Pre-stable SemVer hard-break: 0.1.0 consumers must update their dep pin.

### [1.0.0] — Stability Declaration

Status: planned · after 0.2.0 incubation period.

- API freeze. Any future breaking change requires major bump.
- Migration guide: 0.x → 1.0 in dart/CHANGELOG.md migration block.
- All `@visibleForTesting` / `@experimental` APIs reviewed; promoted to stable or removed.

---

## Published

### [0.1.0] — 2025-04-02

Initial release. STDIO + SSE transport bridging. `mcp_client ^0.1.6` / `mcp_server ^0.1.7` deps. Single `McpBridge` class with `ServerShutdownBehavior` and 4 callback typedefs.

This release predates the workspace's MCP 2.0 wave (Apr 2026). It will be retained on pub.dev for users who can't migrate; 0.2.0+ is incompatible at the dependency layer.
