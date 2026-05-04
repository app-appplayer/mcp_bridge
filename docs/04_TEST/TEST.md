# mcp_bridge — TEST Strategy

> Status: Draft
> Last Updated: 2026-05-04
> Source: `01_SRS/SRS.md`, `03_DDD/*`

---

## 1. Test Pyramid

```
            ┌──────────────────┐
            │ E2E (real wire)  │  ← few, slow, expensive
            │  10–20 tests     │
            └──────────────────┘
        ┌─────────────────────────┐
        │ Integration             │  ← per-module + cross-module
        │  40–60 tests            │
        └─────────────────────────┘
   ┌────────────────────────────────┐
   │ Unit                           │  ← per-class, fast, many
   │  100+ tests                    │
   └────────────────────────────────┘
```

Coverage target: ≥ 80% line coverage on the **testable subset** of `lib/` (NFR5.2). The testable subset excludes hardware-FFI transport implementations (`_serial_base.dart`, `_usb_base.dart`, `_ble_base.dart` and their thin server / client wrappers) — these require real devices to exercise. They are verified manually before release using the example CLI against representative hardware.

Latest measured number lives in `50_CHANGELOG/CHANGELOG.md`'s release entry. Compute via:

```bash
dart test --coverage=coverage
dart pub global run coverage:format_coverage \
    --packages=.dart_tool/package_config.json --report-on=lib \
    --lcov -i coverage -o coverage/lcov.info
# Filter out hardware-FFI files from the gate.
lcov --remove coverage/lcov.info \
    '*_ble_base*' '*_serial_base*' '*_usb_base*' \
    '*ble_*_transport*' '*serial_*_transport*' '*usb_*_transport*' \
    -o coverage/lcov_testable.info
lcov --list coverage/lcov_testable.info
```

Hand-written core modules (config, bridge, router, logger) and the network/byte-stream transports (websocket, tcp, byte_stream_framing) all clear 80% individually.

---

## 2. Test Categories

### 2.1 Unit Tests

Test each module in isolation using fake `mcp_server.ServerTransport` / `mcp_client.ClientTransport` instances built directly in the test file — small classes with controllable `onMessage` (`StreamController.broadcast`), `send` (capture into list), and `onClose` (`Completer<void>`). See §3.

**Per-module coverage:**

All tests live in a single `test/mcp_bridge_test.dart` (the package is small enough that one file with named `group(...)` blocks reads cleaner than ten near-empty files). Group names map to module surface:

| Module / surface | Test group(s) |
|------------------|---------------|
| Transport selection (FR2) | `Transport selection` (cases per type-name + `UnknownTransportTypeException` cases) |
| `McpBridge` initialize / shutdown | `McpBridge initialize/shutdown` · `McpBridge edge cases` |
| `McpBridgeConfig` | `McpBridgeConfig` |
| `MessageRouter` (FR3 forwarding) | `Forwarding (FR3)` · `Router error routing` |
| Inline lifecycle (FR4) | `Lifecycle callbacks (FR4)` · `Reconnect (FR4.4 / FR4.5)` |
| Convenience constructors | `Convenience constructors` |
| Real-transport integration | `Built-in stdio adapter integration` · `Built-in sse adapter integration` · `Built-in streamableHttp adapter integration` |
| `UnknownTransportTypeException` | `UnknownTransportTypeException` |
| `Logger` | `Logger` |

### 2.2 Integration Tests

Wire fake transport pairs into a real `McpBridge` (via the `@visibleForTesting` seam) and exercise full forwarding flows. Verifies modules cooperate correctly without external dependencies.

| Test group | Verifies |
|------------|----------|
| `Forwarding (FR3)` | FR3.1 + FR3.2 + FR3.3-FR3.5 + FR3.6 — all four message kinds in both directions |
| `Lifecycle callbacks (FR4)` · `Reconnect (FR4.4 / FR4.5)` | FR4 — close events, reconnect with both ShutdownBehaviors |
| `Transport selection` | FR2 — type-name → factory call, `UnknownTransportTypeException` on miss |
| Protocol revisions | FR1.3 — all 4 protocol revisions handle correctly (frames flow through unchanged regardless of revision) |

### 2.3 End-to-End Tests

Real wire — actual STDIO subprocess, real HTTP server, real SSE stream. Slow, run in CI but skipped during dev.

| Test | Verifies |
|------|----------|
| Real STDIO bridged to real SSE | Bridge spawns subprocess on one side, listens on SSE on the other; framework client connects, frames round-trip |
| Real SSE bridged to real Streamable HTTP | One side hosts SSE, the other connects Streamable HTTP; both directions exchange MCP frames |
| Loopback streamableHttp client/server | Bridge wires `streamableHttp` server-side to `streamableHttp` client-side via loopback; identity round-trip |

E2E count is small (3–5) — they catch protocol-level regressions but are too slow for inner-loop. CI runs them on every release-prep PR.

### 2.4 Sample CLI

`example/mcp_bridge_example.dart` ships as a runnable CLI sample doubling as a manual end-to-end harness. It exercises the same public surface real callers use — `McpBridgeConfig`, the four lifecycle callbacks, `setAutoReconnect`, `setServerReconnectionOptions`, `shutdown` — across all combinations of `--server-type`/`--client-type` (`stdio` / `sse`). It is NOT part of `dart test`; it is invoked by hand or by the e2e harness.

| Aspect | Detail |
|--------|--------|
| Entry point | `dart run example/mcp_bridge_example.dart [options]` |
| Config sources | CLI args (`--server-type`, `--client-type`, `--auth-token`, ...) OR `--config-file=path.json` (round-tripped through `McpBridgeConfig.fromJson`) |
| Lifecycle wiring | All four callbacks registered with logging output; `SIGINT` → graceful `bridge.shutdown()` |
| Verifies | Public surface stays runnable; readme examples are accurate; manual sanity check before release |

Quality gate: `dart analyze example/` MUST pass with 0 issues on every release. The sample's existence alone is the smoke test that the public surface compiles end-to-end.

---

## 3. Test Doubles

### 3.1 In-test fake transports

Tests construct small `mcp_server.ServerTransport` / `mcp_client.ClientTransport` fakes inline — same shape as the real ones, controllable from the test. Typically:

```dart
class _FakeServerTransport implements server.ServerTransport {
  final _msgController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  final List<dynamic> sent = [];
  bool _open = true;

  @override Stream<dynamic> get onMessage => _msgController.stream;
  @override Future<void> get onClose => _closeCompleter.future;
  @override void send(dynamic message) {
    if (!_open) throw StateError('transport closed');
    sent.add(message);
  }
  @override Future<void> close() async {
    _open = false;
    if (!_closeCompleter.isCompleted) _closeCompleter.complete();
    await _msgController.close();
  }

  /// Test helper — simulate inbound message arrival.
  void receive(dynamic message) => _msgController.add(message);

  /// Test helper — simulate transport-level error.
  void fail(Object error) => _msgController.addError(error);
}
```

`_FakeClientTransport` is identical against `client.ClientTransport`. Both are passed into `McpBridge` via the `@visibleForTesting` seam (`McpBridge.testWithTransports(...)`) instead of going through the type-name switch — that way tests don't have to spawn real subprocesses or bind sockets.

### 3.2 Real transport integration

Where a path needs the real underlying transport (e.g. verifying mcp_client / mcp_server 2.x factories actually return usable transports), the test calls `_buildXxxTransport` directly with a known type-name and a config that targets loopback / `cat` / a free port. The "Built-in stdio adapter integration" / "Built-in sse adapter integration" / "Built-in streamableHttp adapter integration" groups exercise these paths.

---

## 4. Track-Specific Test Coverage

(Tracks per `00_PLAN/PRD.md` §4 — release scheduling lives in `50_CHANGELOG/CHANGELOG.md`.)

### 4.1 Dependency Modernization

Focus: verify the dependency bump doesn't break the previously-published behavior.

- Port every existing test to 2.0-wave APIs (sampling reverse, roots reverse, etc.).
- Add new tests for 2.0 features the bridge now exposes (FR1.3 — protocol revisions, FR1.4 — `MCP-Protocol-Version` header).
- All FR1 SHALL have at least one test.

### 4.2 Transport Set Broadening

Focus: verify the transport-selection switch reaches every supported underlying factory.

- One test per recognised type-name (`'stdio'`, `'sse'`, `'streamableHttp'`) on each direction — confirm the switch calls the right `mcp_client` / `mcp_server` factory and that config-key pass-through works.
- `UnknownTransportTypeException` test — bad type-name on either side throws synchronously at `initialize()`, names the offending value and the supported list.
- For `streamableHttp`: at least one real-transport integration test (loopback bind + connect cycle) confirming the underlying factory is wired correctly.

### 4.3 Bidirectional Forwarding

Focus: lock the sampling / roots / elicitation forwarding behavior.

- `test/integration/bidirectional_test.dart` covers all three server-initiated request types.
- Add `test/integration/protocol_revisions_test.dart` — verify each protocol revision's specific bidirectional features work (e.g., 2025-06-18 added structured tool output, 2025-11-25 added new metadata fields).

### 4.4 Stability

No new tests required, but:
- Coverage SHALL meet NFR5.2.
- All flaky tests SHALL be deflaked or removed.
- E2E suite passes 100% on CI matrix.

---

## 5. CI Strategy

| Layer | When run | Duration target |
|-------|----------|-----------------|
| Unit | Every push | < 30 s |
| Integration | Every push | < 2 min |
| E2E | Pre-release / nightly | < 10 min |
| Coverage report | Pre-release | (via `dart test --coverage`) |

CI matrix:
- Dart SDK 3.7 (minimum) + 3.8 + stable
- Linux + macOS (Windows on best-effort — STDIO subprocess tests sometimes flake there due to process-spawning differences)

---

## 6. Test Quality Rules

- **No flaky tests.** A flaky test is a bug; either fix it or delete it.
- **No skipped tests in main.** If a test must be skipped, it carries a TODO with a tracking issue and an expiry date.
- **No test-only public API.** If something is `@visibleForTesting`, document it in DDD.
- **Coverage gate.** No release ships below NFR5.2 line coverage on touched files.

---

## 7. Out of Scope

- Performance benchmarks (NFR1) — track manually per release; not a test-suite concern. A benchmark harness MAY be added in `bench/` after stability is declared if needed.
- Browser tests — bridge core is pure Dart server-side; transports targeting browsers are sibling packages with their own test suites.
- Fuzz testing — could be valuable for the JSON-RPC parsing path but is deferred.
