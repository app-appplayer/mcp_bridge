# mcp_bridge — Improvement PRD (Product Requirements Document)

> Status: Draft
> Last Updated: 2026-05-04

---

## 1. Vision and Background

### 1.1 Current State

`mcp_bridge` glues an MCP server-side transport to an MCP client-side transport in the same process — server transport receives a request, the bridge forwards it to a client transport, the client's response is returned back. Used for protocol gateway scenarios (e.g. an STDIO MCP server exposed as an SSE service for browser clients).

The currently-published baseline depends on the pre-2.0-wave `mcp_client` / `mcp_server` line and predates the workspace's MCP 2.0 wave (Apr 2026). The 2.0 wave introduced four protocol revisions (`2024-11-05` / `2025-03-26` / `2025-06-18` / `2025-11-25`) with major semantic changes — sampling direction reversed, roots direction reversed, `cancelOperation` → `notifications/cancelled`, JSON-RPC `auth/*` → RFC 9728 OAuth, JSON-RPC batching removed, `MCP-Protocol-Version` HTTP header negotiation, etc.

### 1.2 Pain Points

1. **Protocol stagnation.** The published bridge depends on the pre-2.0-wave mcp_client/server line. Any consumer using the modern 2.0+ ecosystem cannot use mcp_bridge in the same dependency graph — `pub get` fails or downgrades to incompatible versions.
2. **Transport set frozen.** The published bridge only knows STDIO + SSE. The bridge's whole reason to exist is to translate between *non-standard* transports (serial / USB / BLE / WebSocket / TCP / etc.) and *standard* MCP transports — which means mcp_bridge itself MUST own implementations for those non-standard transports. mcp_client / mcp_server only ship the standard set (stdio / sse / streamableHttp); without mcp_bridge filling the rest, embedded / IoT / vendor-specific devices have no path into MCP.
3. **One-way forwarding only.** The 2.0 wave introduced server-initiated requests (sampling / roots / elicitation). The published bridge does not forward these — server-to-client requests are silently dropped, breaking modern MCP server features in any bridged setup.
4. **API instability latent.** The published surface has been touched repeatedly without clear semantic versioning. Consumers don't have a stable surface to depend on.

### 1.3 Vision

**Modernize mcp_bridge into the workspace's canonical MCP-protocol gateway with a built-in transport zoo.** Bring it into 2.0-wave alignment, ship the non-standard transports the spec MCP packages don't (serial / USB / BLE / WebSocket / TCP), and complete the bidirectional forwarding semantics (sampling / roots / elicitation) so any 2.0 MCP feature works through the bridge identically to a direct connection.

The bridge owns its transport implementations. A consumer writes:

```dart
final bridge = McpBridge(McpBridgeConfig(
  serverTransportType: 'serial',
  serverConfig: {'port': '/dev/ttyUSB0', 'baudRate': 115200},
  clientTransportType: 'streamableHttp',
  clientConfig: {'baseUrl': 'https://example.com/mcp'},
));
await bridge.initialize();
```

— and the bridge handles the serial port, the framing, the HTTP connection, and the forwarding. The consumer never touches a socket or a port directly. That ergonomics is the whole product.

Implementations are pure Dart wherever possible — `dart:io` for WebSocket/TCP, FFI bindings to system C libraries (`libserialport`, `libusb`, `bluez`) for hardware transports. No Flutter dependency.

A mature mcp_bridge sits at the centre of every "MCP server visible behind a different transport" use case — embedded USB CDC devices accessed from a Flutter app over Streamable HTTP, browser clients reaching STDIO subprocess servers via WebSocket, BLE-paired sensor MCP servers tunnelled into desktop hosts.

---

## 2. Target Users (Personas)

### Persona A: Embedded Device MCP Server Author

- Publishes an MCP server running on an embedded device (USB CDC / UART / BLE)
- Wants the server to be reachable from any standard MCP client without forcing the client to speak the device's transport
- Needs: bridge that accepts the device's byte-stream transport on the server side and exposes a standard transport (STDIO / SSE / WebSocket / Streamable HTTP) on the client side
- Path to support: add the embedded transport to `mcp_server` (or a sibling package); mcp_bridge gains it automatically

### Persona B: Browser / Flutter Client Integrator

- Has a host running an MCP server as a STDIO subprocess
- Wants to expose it to a browser or Flutter Web app over SSE / WebSocket / Streamable HTTP
- Needs: bridge accepting STDIO server-side, exposing HTTP-based transport client-side

### Persona C: Cross-Process MCP Forwarding

- Runs an MCP server in a different process from the consuming client
- Wants a single transport-translation hop (e.g. a STDIO subprocess server bridged to an HTTP-accessible endpoint)
- Needs: bridge that forwards 1:1 between two transports across the process boundary

> **Multi-server / many-to-one routing** (one bridge fronting N backend MCP servers, picking per request) is OUT OF SCOPE — see §8. A future major redesign may expand the bridge to handle this; for now Persona C is served by running one bridge instance per backend server.

### Persona D: AppPlayer USB Secure Device (workspace-internal)

- AppPlayer's USB Secure Device pattern (memory `project_appplayer_usb_secure_device.md`) — USB device serving an MCP UI bundle
- AppPlayer is the universal client; the device is the MCP server speaking MCP-over-USB-CDC
- Needs: bridge that accepts USB CDC server-side, exposes the standard transport AppPlayer consumes
- Path to support: add USB CDC transport to `mcp_server`; mcp_bridge gains it via a `'usbCdc'` mapping

---

## 3. Goals and Non-Goals

### 3.1 Goals

- **G1.** Modernize dependencies to `mcp_client ^2.0` / `mcp_server ^2.0`, absorbing every 2.0 protocol revision (4 revisions through `2025-11-25`).
- **G2.** Ship a built-in transport set covering the **non-standard** wires (`websocket`, `tcp`, `serial`, `usb`, `ble`) on top of the standard set delegated to `mcp_client`/`mcp_server` (`stdio`, `sse`, `streamableHttp`). Consumers select a transport by type-name in `McpBridgeConfig` and never write transport code themselves — open the bridge, both sides connect.
- **G3.** Forward bidirectional MCP messages — server-initiated `requestClientSampling` / `requestClientRoots` / `requestClientElicitation` flow through the bridge identically to a direct connection.
- **G4.** Stay pure Dart. No Flutter dependency. Hardware transports use Dart FFI bindings to system C libraries (`libserialport`, `libusb`, `bluez`); platforms without a backend throw `UnsupportedError` at `initialize()` rather than silently failing.
- **G5.** Reach an API-stable release after sufficient pre-stable testing — no API churn within the stable major.
- **G6.** Preserve the published public surface across the dependency-bump work. `McpBridge` / `McpBridgeConfig` / `ServerShutdownBehavior` / `TransportSource` and the four lifecycle callback typedefs MUST remain source-compatible — only the underlying `mcp_client` / `mcp_server` 2.0 wave constitutes the breaking change.

### 3.2 Non-Goals

- **NG1.** Defining a public transport plugin interface. Transports are first-class citizens INSIDE mcp_bridge — selectable by type-name, configured by map. New transports go in `lib/src/transport/` and gain a switch case. The package isn't designed for third-party transport plugins; if a new transport is needed, file a PR / issue and it lands in mcp_bridge proper.
- **NG2.** Replacing or wrapping `mcp_io`. mcp_io is the industrial-protocol family (Modbus / OPC-UA / MQTT / CAN / SCPI). It operates at a different framing layer (application protocols on byte streams). mcp_bridge does not depend on or integrate mcp_io.
- **NG3.** Adding application-level features (auth, rate limiting, request logging beyond the existing Logger). Those belong in higher layers consuming mcp_bridge.
- **NG4.** Adding Flutter-specific transports (anything requiring a Flutter platform channel) to this pure-Dart package. If/when needed, they land in a sibling `flutter_mcp_bridge` package using the same selection-by-name pattern.

---

## 4. Capability Tracks

The improvement is structured as three capability tracks. Release scheduling (which tracks ship together, in what order) is recorded in `50_CHANGELOG/CHANGELOG.md`.

### 4.1 Dependency Modernization

**Goal:** Bring mcp_bridge into the 2.0-wave dependency tree without changing the public API surface.

- Bump `mcp_client` and `mcp_server` to `^2.0.0`.
- Absorb 2.0-wave breaking changes: sampling / roots direction reversal, `auth/*` → RFC 9728, batching removal, etc.
- Keep existing public API: `McpBridge` · `McpBridgeConfig` · `ServerShutdownBehavior` · `TransportSource` · the four callback typedefs.
- Test suite expanded to cover the 2.0 wave's negotiation paths (`MCP-Protocol-Version` HTTP header) and verify the bridge correctly forwards each protocol revision.

### 4.2 Built-In Transport Zoo

**Goal:** Ship the non-standard transports that consumers need to bridge embedded / IoT / vendor-specific devices into MCP, on top of the standard 3 delegated to mcp_client/mcp_server.

| Type-name | Backed by | Platforms |
|-----------|-----------|-----------|
| `'stdio'` | mcp_client / mcp_server (delegated) | Linux · macOS · Windows |
| `'sse'` | delegated | all |
| `'streamableHttp'` | delegated | all |
| `'websocket'` | `dart:io` `WebSocket` / `HttpServer` | all |
| `'tcp'` | `dart:io` `Socket` / `ServerSocket` | all |
| `'serial'` | `libserialport` Dart FFI (USB CDC included) | all (system libserialport required) |
| `'usb'` | `libusb` Dart FFI (raw bulk endpoints) | all (system libusb + udev/WinUSB driver) |
| `'ble'` | `bluez` D-Bus on Linux | Linux only — macOS/Windows throw `UnsupportedError` |

Each transport's `lib/src/transport/{name}_{server,client}_transport.dart` directly implements `mcp_client.ClientTransport` / `mcp_server.ServerTransport` — no intermediate adapter layer. Framing (where the wire doesn't already preserve frame boundaries) is newline-delimited JSON for byte-stream transports (TCP, serial, USB).

Adding the 9th transport later: write the implementation pair in `lib/src/transport/`, add the switch case in `bridge.dart`, document in README's platform matrix.

### 4.3 Bidirectional Forwarding

**Goal:** Make the bridge transparent to 2.0-wave server-initiated request features.

- Forward `Server.requestClientSampling` from server → bridge → client → host LLM (or back).
- Forward `Server.requestClientRoots` and `Server.requestClientElicitation` symmetrically.
- Notification routing: list-changed notifications, `notifications/cancelled`, progress notifications all flow through the bridge correctly.
- Verify with end-to-end tests against an actual 2.0 MCP server that exercises sampling / roots / elicitation.

### 4.4 Stability Declaration

**Goal:** Lock the API surface for production use.

- After pre-stable cycles validate the new transport-type set + bidirectional surfaces in real consumer integrations.
- API freeze: any breaking change after the stability declaration requires a major bump.
- Promote any remaining experimental surfaces to stable; mark or remove deprecated holdovers from the previously-published surface.
- Update `CHANGELOG.md` migration guide for pre-stable consumers.

---

## 5. Success Criteria

| Metric | Target |
|--------|--------|
| Dependency alignment | `mcp_client` / `mcp_server` ^2.0 throughout — no pre-2.0 deps |
| Transport count | 8 built-in (stdio · sse · streamableHttp · websocket · tcp · serial · usb · ble) — consumer-selectable by type-name |
| Platform support | Linux · macOS · Windows for 7 transports; BLE Linux-only with `UnsupportedError` elsewhere |
| Bidirectional feature coverage | sampling · roots · elicitation all forward end-to-end; one regression test per direction |
| Test stability | Test suite passes 100% across all 4 protocol revisions |
| Consumer ergonomics | Hardware transport setup is one `McpBridgeConfig` map; consumer never opens a port / socket / device handle directly |
| Pub.dev presence | Every release published with CHANGELOG entries linking the breaking changes |

---

## 6. Risks and Tradeoffs

### 6.1 Architecture Risks

- **R1: Over-abstracting transport handling.** A `BridgeTransport` plugin interface plus a registry sounds clean but adds a layer above the existing `mcp_client.ClientTransport` / `mcp_server.ServerTransport` interfaces for no win. Mitigation — built-in transports implement those interfaces directly. Selection is a switch in `bridge.dart`. No third-party plugin surface.
- **R2: Bidirectional forwarding subtlety.** Sampling / roots / elicitation forwarding correctness depends on session-state tracking that's transport-specific. Mitigation — model after `flutter_mcp` 2.0's `autoBridgeSampling` implementation, which already handled this for the host-LLM case.
- **R3: Hardware transport reliability across OSes.** libserialport / libusb / bluez behave differently across Linux / macOS / Windows. Mitigation — README documents the platform matrix and known limitations per transport; CI exercises at minimum loopback paths (websocket / tcp); hardware transports verified manually against real devices before release.

### 6.2 Release Risks

- **R4: Hard break for current consumers.** Consumers on the previously-published surface must rewrite their dep. Mitigation — pre-stable SemVer permits this; CHANGELOG carries the migration guide. The previously-published line stays available on pub.dev for users who can't migrate.
- **R5: Stability commitment.** Once stability is declared, breaking changes need a major bump. Mitigation — the pre-stable cycles provide the validation window.

### 6.3 Scope Drift Risks

- **R6: Pressure to add Flutter-only transports.** Some BLE / USB stacks are Flutter-only on certain platforms. Mitigation — pure-Dart-only inside mcp_bridge; if Flutter dep becomes necessary for a transport, it lands in a sibling `flutter_mcp_bridge` package (NG4).
- **R7: Confusion with mcp_io.** Both packages mention serial / WebSocket as adjacent concepts. Mitigation — README and CHANGELOG clearly state the layer separation (mcp_bridge = MCP wire forwarding, mcp_io = industrial application protocols); no inter-package dependency.

---

## 7. Dependencies and Sequencing

- **Blocker on `mcp_client` / `mcp_server` 2.x being available on pub.dev** — both at 2.0.0 (published 2026-04-30).
- **No dependency on `mcp_io`** — explicitly excluded per Non-Goals.
- **Coordinates with `flutter_mcp` 2.x** — same protocol-revision target set; mcp_bridge can reuse `flutter_mcp`'s 2.0-wave migration patterns without depending on `flutter_mcp`.

Track ordering is strict — Dependency Modernization → Transport Set Broadening → Bidirectional Forwarding → Stability Declaration. Skipping is not safe; each track validates surfaces that the next builds on. Whether they ship as one combined release or as sequential releases is a CHANGELOG decision.

---

## 8. Out of Scope (Future)

The following are intentionally deferred — they are real needs but not part of this improvement initiative:

- **Multi-server routing** (one bridge fronting multiple backend MCP servers) — needs route resolution + per-route transport pools; deserves its own design pass.
- **Transport-level metrics / observability hooks** — useful for production but not core to bridging.
- **Authentication / authorization at the bridge layer** — RFC 9728 OAuth lives in `mcp_server`; bridge could add per-route policies but that's a higher layer.
- **Streaming optimizations** (request batching, response coalescing) — real performance work after correctness is locked.
- **Flutter-only transports.** BLE on iOS / Android, USB on Android — anything requiring a Flutter platform channel. Belongs in a sibling `flutter_mcp_bridge` package, not here.
