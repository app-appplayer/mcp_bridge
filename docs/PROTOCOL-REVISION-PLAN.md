# mcp_bridge — MCP Protocol Revision Adoption Plan

**Created**: 2026-07-18 · **Owner**: cherry (packages) · **Status**: 🔵 planned
**Note**: `docs/` is separate from `dart/` (published package) — internal, non-distributed.

## Role & scope (verified 2026-07-18)

`mcp_bridge` supplies **transport implementations** (tcp / serial / ble / usb / websocket, under
`lib/src/transport/`) that `mcp_client` / `mcp_server` plug into. It depends on `mcp_client ^2.0.0`
and `mcp_server ^2.0.0` (`dart/pubspec.yaml:15-16`). All MCP protocol logic — version negotiation,
`initialize`/session, JSON-RPC method dispatch — lives in client/server, **not** here.
`Bridge.initialize()` (`lib/src/bridge.dart:157`) is the bridge's own lifecycle, not the MCP
handshake. No `Mcp-Session-Id`, `protocolVersion`, or handshake code exists in this package.

**Consequence**: bridge is largely **transport-transparent** to revision changes. It carries
JSON-RPC frames opaquely; the request/response shape (handshake vs stateless) is client/server's
concern. This plan is therefore intentionally light — the correct finding is "little to do here,"
not invented work.

## Revision set

| Revision | Status | This package |
|---|---|---|
| 2024-11-05 / 2025-03-26 / 2025-06-18 | Final | transparent (keep) |
| 2025-11-25 | Current | transparent — dependency coordination only |
| 2026-07-28 | BREAKING (final 2026-07-28) | transport transparency verification |

---

## Part A — 2025-11-25

- [x] **A1. No protocol changes — verified transparent.** ✅ DONE 2026-07-18. Confirmed all
  transports encode/decode WHOLE messages via `jsonEncode`/`jsonDecode` (websocket transports;
  `ByteStreamFramer.encodeFrame`/`feedBytes` for tcp/serial/usb) — no selective field handling, so
  `_meta`/`icons`/`structuredContent`/unknown fields inherently survive. Regression test locks it:
  `test/frame_transparency_test.dart` (2 PASS — full field round-trip + split-chunk/multi-frame).
  Full suite 54 PASS·analyze 0.
- [ ] **A2. Dependency floors.** When `mcp_client` / `mcp_server` publish the 2025-11-25
  conformance work, bump bridge dep floors and re-run the transport interop suite. Coordinate
  with those packages' publish (internal deps → latest published).

## Part B — 2026-07-28 (stateless core)

Stateless core removes `Mcp-Session-Id` and the server-push SSE stream — both are **Streamable
HTTP** concerns living in `mcp_server`'s HTTP transport. Bridge's point-to-point transports
(tcp / serial / ble / usb) never carried an HTTP session id, so the removal is a non-event for them.

- [ ] **B1. Transport transparency verification.** Confirm each transport remains agnostic to the
  stateless request shape:
  - Requests now self-contained with client info/caps in `_meta` — verify no transport assumes a
    prior handshake established connection state it depends on.
  - `InputRequiredResult` multi-round-trip replaces server-push SSE — verify bidirectional
    transports (ws server/usb) relay server→client frames within an active request without
    relying on a long-lived server-initiated stream.
  - `MCP-Protocol-Version` as sole version signal — for non-HTTP transports the version travels in
    the JSON-RPC negotiation payload (client/server), not transport headers; confirm no transport
    strips it.
- [ ] **B2. `websocket_server_transport` / `usb_server_transport` review.** These are the only
  server-side transports here; ensure they don't hold session state that the stateless model
  invalidates. If any do, gate by negotiated version (coexist).
- [ ] **B3. Dependency floors.** Bump to the `mcp_client`/`mcp_server` releases that add the
  stateless path; re-run interop suite across a 2025-11-25 peer (handshake) and a 2026-07-28 peer
  (stateless) over each transport.

## Part B — tests
- [ ] Frame-transparency: `_meta` + unknown fields survive round-trip on every transport.
- [ ] Coexistence: same transport carries a handshake session (≤2025-11-25) and a stateless
  exchange (2026-07-28) without transport-level changes.

## Execution order
Bridge follows client/server: no independent protocol work. Do A1 transparency test now; A2/B3
dependency bumps track client/server releases; B1/B2 verification when the stateless path lands.

Cross-package: `mcp_client`, `mcp_server`, `mcp_gateway` plans + cherry track
`mcp-spec-2025-11-25-adoption-2026-07-18.md`.
