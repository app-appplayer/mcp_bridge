# mcp_bridge — SRS (Software Requirements Specification)

> Status: Draft
> Last Updated: 2026-05-04
> Source: `00_PLAN/PRD.md`

---

## 1. Introduction

### 1.1 Purpose

This document specifies the functional and non-functional requirements for the `mcp_bridge` package. Every requirement traces back to a PRD goal (G1–G6) and forward to a system design module (SDD).

### 1.2 Scope

`mcp_bridge` is a Dart package (pub.dev) that runs in a single Dart isolate and forwards Model Context Protocol (MCP) JSON-RPC messages between a server-side transport and a client-side transport. Both transports are obtained from `mcp_client` / `mcp_server` 2.x — mcp_bridge does NOT implement transports of its own.

### 1.3 Definitions

| Term | Definition |
|------|------------|
| **MCP** | Model Context Protocol (JSON-RPC over various transports per the MCP spec) |
| **Bridge** | The mcp_bridge runtime: one server-transport instance + one client-transport instance + forwarding logic |
| **Server transport** | The transport that receives MCP requests on behalf of the bridge (the "front door"), obtained from `mcp_server` 2.x |
| **Client transport** | The transport that the bridge uses to reach a backend MCP server (the "back door"), obtained from `mcp_client` 2.x |
| **Forwarding** | Reading a JSON-RPC message from one transport, writing it to the other |
| **Bidirectional forwarding** | Forwarding works in both directions — client request → backend AND server-initiated request (sampling / roots / elicitation) backend → originating client |

---

## 2. Functional Requirements

### 2.1 FR1 — 2.0-Wave Dependency Compatibility (← PRD G1)

| ID | Requirement |
|----|-------------|
| FR1.1 | mcp_bridge SHALL declare `mcp_client: ^2.0.0` in its pubspec. |
| FR1.2 | mcp_bridge SHALL declare `mcp_server: ^2.0.0` in its pubspec. |
| FR1.3 | mcp_bridge SHALL support every MCP protocol revision exposed by `mcp_client` / `mcp_server` 2.x: `2024-11-05`, `2025-03-26`, `2025-06-18`, `2025-11-25`. |
| FR1.4 | mcp_bridge SHALL forward the `MCP-Protocol-Version` HTTP header negotiation result transparently when both sides use HTTP-family transports. |
| FR1.5 | mcp_bridge SHALL absorb 2.0-wave breaking semantics — sampling direction reversal, roots direction reversal, `notifications/cancelled` replacing `cancelOperation`, JSON-RPC `auth/*` replaced by RFC 9728, JSON-RPC batching removal — without exposing them to bridge consumers. |

### 2.2 FR2 — Built-In Transport Set (← PRD G2, G4)

| ID | Requirement |
|----|-------------|
| FR2.1 | `McpBridgeConfig.serverTransportType` and `clientTransportType` SHALL accept transport-type names that resolve to a `mcp_server.ServerTransport` (server side) or `mcp_client.ClientTransport` (client side) inside the bridge. |
| FR2.2 | mcp_bridge SHALL ship eight built-in transports recognized for both directions: `'stdio'`, `'sse'`, `'streamableHttp'` (delegated to mcp_client / mcp_server factories), plus `'websocket'`, `'tcp'`, `'serial'`, `'usb'`, `'ble'` (implemented inside `lib/src/transport/`). |
| FR2.3 | `serverConfig` and `clientConfig` (`Map<String, dynamic>`) SHALL be passed verbatim to the resolved transport implementation. Per-transport key contracts are documented in README. |
| FR2.4 | An invalid transport-type name SHALL produce a clear error (`UnknownTransportTypeException`) at `initialize` time, naming the supplied value and the supported set. |
| FR2.5 | The five non-delegated transports SHALL implement `mcp_client.ClientTransport` / `mcp_server.ServerTransport` directly — no intermediate adapter / registry / plugin layer. |
| FR2.6 | A transport whose backend is not available on the current platform SHALL throw `UnsupportedError` synchronously at `initialize()` (e.g. `'ble'` on macOS / Windows). |
| FR2.7 | The consumer SHALL configure a hardware transport entirely through the `serverConfig` / `clientConfig` map. The consumer MUST NOT need to open ports, sockets, serial handles, or USB endpoints themselves. |

### 2.3 FR3 — Bidirectional Message Forwarding (← PRD G3)

| ID | Requirement |
|----|-------------|
| FR3.1 | mcp_bridge SHALL forward client-to-server requests (`tools/call`, `resources/read`, `prompts/get`, etc.) from the server transport to the client transport. |
| FR3.2 | mcp_bridge SHALL forward server-to-client responses for those requests in the reverse direction. |
| FR3.3 | mcp_bridge SHALL forward server-initiated `requestClientSampling` from the backend MCP server through the bridge to the host LLM (or the originating client). |
| FR3.4 | mcp_bridge SHALL forward server-initiated `requestClientRoots` symmetrically. |
| FR3.5 | mcp_bridge SHALL forward server-initiated `requestClientElicitation` symmetrically. |
| FR3.6 | mcp_bridge SHALL forward notifications in both directions: list-changed (`notifications/{tools,resources,prompts}/list_changed`), `notifications/cancelled`, and progress notifications. |
| FR3.7 | Request / response correlation SHALL be preserved across the forwarding hop — the same JSON-RPC `id` returned to the originator. |

### 2.4 FR4 — Lifecycle and Error Handling

| ID | Requirement |
|----|-------------|
| FR4.1 | mcp_bridge SHALL expose `ServerShutdownBehavior.shutdownBridge` (close the bridge when the server-side transport closes) and `ServerShutdownBehavior.waitForReconnection` (keep the bridge alive awaiting server reconnection), preserved from the previously-published surface. |
| FR4.2 | mcp_bridge SHALL invoke `TransportErrorCallback` on transport-level errors with the originating side and error payload. |
| FR4.3 | mcp_bridge SHALL invoke `TransportClosedCallback` when either transport closes. |
| FR4.4 | mcp_bridge SHALL invoke `TransportReconnectedCallback` when a transport reconnects after a transient failure. |
| FR4.5 | mcp_bridge SHALL invoke `ServerReconnectRequestedCallback` and accept its `Future<bool>` return value to gate reconnection attempts. |
| FR4.6 | All four callbacks remain optional; absence MUST NOT crash the bridge. |

### 2.5 FR5 — Configuration

| ID | Requirement |
|----|-------------|
| FR5.1 | `McpBridgeConfig` SHALL accept `serverTransportType` (string), `clientTransportType` (string), `serverConfig` (Map), `clientConfig` (Map), and `serverShutdownBehavior` (enum) — the same shape as the previously-published surface for source-compat. |
| FR5.2 | `serverConfig` / `clientConfig` SHALL be passed through to the underlying mcp_server / mcp_client transport factory verbatim. |
| FR5.3 | An invalid transport name SHALL produce a clear error at `initialize` time, not at first message. |

---

## 3. Non-Functional Requirements

### 3.1 NFR1 — Performance

- NFR1.1: Bridge forwarding SHALL add no more than 5 ms overhead per message on a single-process loopback (target: 2 ms median, p95 ≤ 5 ms).
- NFR1.2: Bridge SHALL support sustained throughput of at least 1 000 messages/second on the host's loopback path (no transport-side limit).

### 3.2 NFR2 — Compatibility

- NFR2.1: Dart SDK `^3.7.2` minimum (matches the previously-published baseline).
- NFR2.2: Pure Dart — no Flutter dependency. Bridge MUST be usable from server-side / CLI Dart contexts. Hardware transports use Dart FFI bindings to system C libraries.
- NFR2.3: Cross-platform — Windows · macOS · Linux for 7 of 8 transports. `'ble'` is Linux-only in 0.2.0 (other OSes throw `UnsupportedError`). Browser is out of scope for the bridge.
- NFR2.4: System C libraries required for hardware transports MUST be documented in README install instructions (`libserialport`, `libusb`; bluez ships with most Linux distros).

### 3.3 NFR3 — Stability

- NFR3.1: Pre-stable cycles SHALL NOT promise API stability — pubspec users pin specific minor versions.
- NFR3.2: The stability declaration SHALL freeze the public API; further breaking changes require a major bump.
- NFR3.3: Internal symbols (prefixed `_` or under `src/`) SHALL NOT be considered API; consumers depending on them carry their own risk.

### 3.4 NFR4 — Documentation

- NFR4.1: Every public class, method, and field SHALL carry dartdoc comments.
- NFR4.2: README SHALL list the supported transport-type names and their config-key contracts (one row per transport, server-side and client-side).
- NFR4.3: README SHALL state the policy for adding new transports — namely that they belong in `mcp_client` / `mcp_server`, not in mcp_bridge.
- NFR4.4: CHANGELOG SHALL be updated per release with breaking-change migration notes.

### 3.5 NFR5 — Testability

- NFR5.1: All forwarding logic SHALL be testable without real network / serial / process — via in-memory fake transports that satisfy the `mcp_server.ServerTransport` / `mcp_client.ClientTransport` shape (typically a small test-only adapter constructed directly inside tests).
- NFR5.2: Coverage target: ≥ 80% line coverage on `lib/`.

---

## 4. External Interfaces

### 4.1 Public API (consumed by mcp_bridge users)

- `class McpBridge` — main runtime. `initialize()`, `shutdown()`, status getters, lifecycle callback fields, `setAutoReconnect`, `setServerReconnectionOptions`, convenience constructors `createStdioToSseBridge` / `createSseToStdioBridge`.
- `class McpBridgeConfig` — construction-time configuration.
- `enum ServerShutdownBehavior`, `enum TransportSource`.
- `typedef TransportErrorCallback`, `TransportClosedCallback`, `TransportReconnectedCallback`, `ServerReconnectRequestedCallback`.
- `class UnknownTransportTypeException` — thrown for invalid type names at initialize.
- `typedef MCPBridge = McpBridge` — compatibility alias.

### 4.2 Consumed APIs

- `mcp_client` 2.x — `ClientTransport` (abstract base implemented by built-in non-standard transports + delegated factories): `McpClient.createStdioTransport(...)`, `createSseTransport(...)`, `createStreamableHttpTransport(...)`.
- `mcp_server` 2.x — `ServerTransport` (abstract base implemented by built-in non-standard transports + delegated factory): `McpServer.createTransport(TransportConfig.{stdio,sse,streamableHttp}(...))`.
- `libserialport` (Dart pub.dev package, FFI to system libserialport) — used by `'serial'` transport.
- `libusb` (Dart pub.dev package, FFI to system libusb) — used by `'usb'` transport.
- `bluez` (Dart pub.dev package, D-Bus client) — used by `'ble'` transport on Linux.

### 4.3 Forbidden Dependencies

- `mcp_io_*` — explicit non-dependency. Layer separation per PRD §3.2 (NG2).
- `flutter` / `flutter_test` — pure Dart only (NFR2.2).

---

## 5. Constraints

- **C1.** mcp_bridge runs in a single Dart isolate. No multi-isolate parallelism in scope.
- **C2.** Both server and client transports operate in the same process. Network bridging across processes is the underlying transport's job, not the bridge's.
- **C3.** No persistent state — bridge is in-memory; restart loses all session state. Consumers needing persistence layer it on top.
- **C4.** Pre-stable SemVer applies: minor bumps may break. The stability declaration switches to strict SemVer.
- **C5.** Hardware transports (`'serial'`, `'usb'`, `'ble'`) require system C libraries to be installed by the host environment; mcp_bridge does not bundle them.
- **C6.** Pure Dart only — no Flutter dependency. Transports requiring Flutter platform channels (BLE on iOS/Android, USB on Android, etc.) belong in a sibling `flutter_mcp_bridge` package, not here.

---

## 6. Traceability

| PRD Goal | SRS FR / NFR |
|----------|--------------|
| G1 (deps modernize) | FR1 |
| G2 (8-transport built-in zoo) | FR2 |
| G3 (bidirectional forwarding) | FR3 |
| G4 (pure Dart, FFI-based hardware) | NFR2.2, FR2.5, FR2.6 |
| G5 (stability) | NFR3.2 |
| G6 (preserve published surface) | FR4, FR5 |

Every SRS FR will appear in `02_SDD/SDD.md` as a module / sub-module that implements it.
