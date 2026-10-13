// Reconnect-state-machine coverage for lib/src/bridge.dart —
// `_handleServerDisconnection` (server-side wait-for-reconnection loop)
// and `_attemptClientReconnect` (client-side auto-reconnect), plus the
// real (non-test-double) transport-factory delegation paths that
// `mcp_bridge_test.dart`'s fake-only scenarios never reach.
//
// Pattern: initial connect always uses `McpBridge.testWithTransports`
// (in-test fakes) so we don't need a live transport just to get the
// bridge into "initialized" state. The RECONNECT attempt then either:
//   - stays on fakes via `setTestNextTransports` (pure state-machine
//     branches: success / decline / callback-throws / max-attempts), or
//   - is deliberately left un-stubbed so the bridge falls through to
//     the REAL `_buildServerTransport` / `_buildClientTransport`
//     factory call — using either a synchronously-invalid config
//     (pure validation, no I/O touched) or a real TCP loopback (same
//     category already covered for the initial-connect path in
//     mcp_bridge_test.dart's "TCP loopback integration" group).
//
// No hardware transports (serial/usb/ble) are ever actually opened —
// only their synchronous config-validation `ArgumentError` is
// deliberately provoked, which throws before any device I/O.

import 'dart:async';
import 'dart:io';

import 'package:mcp_bridge/mcp_bridge.dart';
import 'package:mcp_client/mcp_client.dart' as client;
import 'package:mcp_server/mcp_server.dart' as server;
import 'package:test/test.dart';

class _FakeServerTransport implements server.ServerTransport {
  final _msgController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  final List<dynamic> sent = [];
  bool _open = true;

  @override
  Stream<dynamic> get onMessage => _msgController.stream;
  @override
  Future<void> get onClose => _closeCompleter.future;
  @override
  void send(dynamic message) {
    if (!_open) throw StateError('transport closed');
    sent.add(message);
  }

  @override
  void close() {
    if (!_open) return;
    _open = false;
    if (!_closeCompleter.isCompleted) _closeCompleter.complete();
    if (!_msgController.isClosed) _msgController.close();
  }

  void receive(dynamic message) => _msgController.add(message);
}

class _FakeClientTransport implements client.ClientTransport {
  final _msgController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  final List<dynamic> sent = [];
  bool _open = true;

  @override
  Stream<dynamic> get onMessage => _msgController.stream;
  @override
  Future<void> get onClose => _closeCompleter.future;
  @override
  void send(dynamic message) {
    if (!_open) throw StateError('transport closed');
    sent.add(message);
  }

  @override
  void close() {
    if (!_open) return;
    _open = false;
    if (!_closeCompleter.isCompleted) _closeCompleter.complete();
    if (!_msgController.isClosed) _msgController.close();
  }

  void receive(dynamic message) => _msgController.add(message);
}

void main() {
  group('Client-side auto-reconnect (_attemptClientReconnect)', () {
    test('successful reconnect swaps transport and re-wires forwarding',
        () async {
      final s = _FakeServerTransport();
      final c1 = _FakeClientTransport();
      final c2 = _FakeClientTransport();
      final bridge = McpBridge.testWithTransports(
        const McpBridgeConfig(
          serverTransportType: 'stdio',
          clientTransportType: 'stdio',
          serverConfig: {},
          clientConfig: {'command': 'cat'},
        ),
        serverTransport: s,
        clientTransport: c1,
      );
      bridge.setAutoReconnect(
          enabled: true,
          maxAttempts: 3,
          delay: const Duration(milliseconds: 5));
      final reconnected = <TransportSource>[];
      bridge.onTransportReconnected = (src) => reconnected.add(src);
      await bridge.initialize();

      bridge.setTestNextTransports(client: c2);
      c1.close();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(reconnected, contains(TransportSource.client));
      // Forwarding is now wired through c2, not the stale c1. (Map
      // literals don't override `==`, so reuse the same instance for
      // both the send and the assertion — matching the pattern already
      // used throughout mcp_bridge_test.dart.)
      const ping = {'jsonrpc': '2.0', 'method': 'ping'};
      s.receive(ping);
      await Future<void>.delayed(Duration.zero);
      expect(c2.sent, contains(ping));
      await bridge.shutdown();
    });

    test('maxAttempts=0 declines immediately — no reconnect attempted',
        () async {
      final s = _FakeServerTransport();
      final c1 = _FakeClientTransport();
      final bridge = McpBridge.testWithTransports(
        const McpBridgeConfig(
          serverTransportType: 'stdio',
          clientTransportType: 'stdio',
          serverConfig: {},
          clientConfig: {'command': 'cat'},
        ),
        serverTransport: s,
        clientTransport: c1,
      );
      bridge.setAutoReconnect(enabled: true, maxAttempts: 0);
      final reconnected = <TransportSource>[];
      bridge.onTransportReconnected = (src) => reconnected.add(src);
      await bridge.initialize();

      c1.close();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(reconnected, isEmpty);
      await bridge.shutdown();
    });

    test('build failure retries recursively then gives up at maxAttempts',
        () async {
      final s = _FakeServerTransport();
      final c1 = _FakeClientTransport();
      // clientConfig deliberately missing `command` — every real
      // `_buildClientTransport('stdio', ...)` retry throws
      // synchronously (pure validation, no process spawned).
      final bridge = McpBridge.testWithTransports(
        const McpBridgeConfig(
          serverTransportType: 'stdio',
          clientTransportType: 'stdio',
          serverConfig: {},
          clientConfig: {},
        ),
        serverTransport: s,
        clientTransport: c1,
      );
      bridge.setAutoReconnect(
          enabled: true,
          maxAttempts: 2,
          delay: const Duration(milliseconds: 5));
      final errors = <TransportSource>[];
      bridge.onTransportError = (src, e, st) => errors.add(src);
      await bridge.initialize();

      c1.close();
      // Attempt 1 fails -> recurse -> attempt 2 fails -> attempt 3
      // exceeds maxAttempts(2) -> gives up silently.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(errors, everyElement(equals(TransportSource.client)));
      expect(errors.length, greaterThanOrEqualTo(2));
      await bridge.shutdown();
    });
  });

  group('Server-side wait-for-reconnection (_handleServerDisconnection)',
      () {
    test('onServerReconnectRequested set only via config (not the field) '
        'is still consulted', () async {
      final s = _FakeServerTransport();
      final c = _FakeClientTransport();
      var configCallbackInvoked = false;
      final bridge = McpBridge.testWithTransports(
        McpBridgeConfig(
          serverTransportType: 'stdio',
          clientTransportType: 'stdio',
          serverConfig: const {},
          clientConfig: const {'command': 'cat'},
          serverShutdownBehavior: ServerShutdownBehavior.waitForReconnection,
          onServerReconnectRequested: () async {
            configCallbackInvoked = true;
            return false; // decline -> shutdown
          },
        ),
        serverTransport: s,
        clientTransport: c,
      );
      // Deliberately do NOT set bridge.onServerReconnectRequested (the
      // direct field) — forces the `?? _config.onServerReconnectRequested`
      // fallback to be evaluated.
      await bridge.initialize();
      s.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(configCallbackInvoked, isTrue);
      expect(bridge.isInitialized, isFalse);
    });

    test('reconnect callback throwing is treated as decline and reported',
        () async {
      final s = _FakeServerTransport();
      final c = _FakeClientTransport();
      final bridge = McpBridge.testWithTransports(
        const McpBridgeConfig(
          serverTransportType: 'stdio',
          clientTransportType: 'stdio',
          serverConfig: {},
          clientConfig: {'command': 'cat'},
          serverShutdownBehavior: ServerShutdownBehavior.waitForReconnection,
        ),
        serverTransport: s,
        clientTransport: c,
      );
      bridge.onServerReconnectRequested = () async {
        throw StateError('callback exploded');
      };
      Object? caughtError;
      TransportSource? caughtSide;
      bridge.onTransportError = (src, e, st) {
        caughtError = e;
        caughtSide = src;
      };
      await bridge.initialize();
      s.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(caughtError, isA<StateError>());
      expect(caughtSide, equals(TransportSource.server));
      // shouldRetry forced to false after the throw -> bridge shuts down.
      expect(bridge.isInitialized, isFalse);
    });

    test(
        'max server reconnect attempts reached (real build repeatedly '
        'fails validation) triggers shutdown', () async {
      final s = _FakeServerTransport();
      final c = _FakeClientTransport();
      // Real reconnect build target: 'serial' with no `port` — throws
      // ArgumentError synchronously (validated in SerialPortAdapter.start()
      // before any device is touched). Initial connect below bypasses
      // this via the injected fakes.
      final bridge = McpBridge.testWithTransports(
        const McpBridgeConfig(
          serverTransportType: 'serial',
          clientTransportType: 'stdio',
          serverConfig: {}, // missing `port`
          clientConfig: {'command': 'cat'},
          serverShutdownBehavior: ServerShutdownBehavior.waitForReconnection,
        ),
        serverTransport: s,
        clientTransport: c,
      );
      bridge.setServerReconnectionOptions(
        maxAttempts: 1,
        checkInterval: const Duration(milliseconds: 5),
      );
      var callbackCalls = 0;
      bridge.onServerReconnectRequested = () async {
        callbackCalls++;
        return true; // always agree to retry; the real build keeps failing
      };
      final serverErrors = <Object>[];
      bridge.onTransportError = (src, e, st) {
        if (src == TransportSource.server) serverErrors.add(e);
      };
      await bridge.initialize();
      s.close();
      // attempt 1: build throws ArgumentError -> logged, loop continues.
      // attempt 2: exceeds maxAttempts(1) -> "max attempts reached" -> shutdown.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(callbackCalls, greaterThanOrEqualTo(1));
      expect(serverErrors, isNotEmpty);
      expect(serverErrors.first, isA<ArgumentError>());
      expect(bridge.isInitialized, isFalse);
      expect(bridge.isWaitingForServerReconnection, isFalse);
    });

    test(
        'real (non-test-double) transport reconnect succeeds via genuine '
        'TCP loopback build', () async {
      // Stub TCP listener the bridge's reconnect CLIENT transport will
      // connect to (analogous to the existing "TCP loopback integration"
      // group's topology — real sockets, no external device).
      final stub = await ServerSocket.bind('127.0.0.1', 0);
      stub.listen((sock) => sock.listen((_) {}));

      final s = _FakeServerTransport();
      final c = _FakeClientTransport();
      final bridge = McpBridge.testWithTransports(
        McpBridgeConfig(
          serverTransportType: 'tcp',
          clientTransportType: 'tcp',
          serverConfig: const {'host': '127.0.0.1', 'port': 0},
          clientConfig: {'host': '127.0.0.1', 'port': stub.port},
          serverShutdownBehavior: ServerShutdownBehavior.waitForReconnection,
        ),
        serverTransport: s,
        clientTransport: c,
      );
      // No setTestNextTransports() call -> reconnect falls through to
      // the REAL _buildServerTransport / _buildClientTransport factory
      // calls (lines otherwise unreachable by the fake-only tests).
      bridge.onServerReconnectRequested = () async => true;
      final reconnected = <TransportSource>[];
      bridge.onTransportReconnected = (src) => reconnected.add(src);
      await bridge.initialize();

      s.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(reconnected, contains(TransportSource.server));
      expect(bridge.isInitialized, isTrue);

      await bridge.shutdown();
      await stub.close();
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('Real stdio client-transport factory delegation', () {
    test('_buildClientTransport(stdio) spawns a real subprocess (cat)',
        () async {
      // Server side: real TCP (safe, already an established pattern in
      // this suite). Client side: real stdio spawning `cat` — exercises
      // the actual `client.McpClient.createStdioTransport(...)` call
      // that every other test in the suite bypasses via
      // `testWithTransports`. `cat` is a trivial, always-available
      // subprocess that terminates cleanly on transport close.
      final stub = await ServerSocket.bind('127.0.0.1', 0);
      stub.listen((sock) => sock.listen((_) {}));

      final bridge = McpBridge(McpBridgeConfig(
        serverTransportType: 'tcp',
        clientTransportType: 'stdio',
        serverConfig: const {'host': '127.0.0.1', 'port': 0},
        // `environment` deliberately included — exercises the
        // Map<String,String>.from(...) conversion branch that a bare
        // `{'command': 'cat'}` config never reaches.
        clientConfig: const {
          'command': 'cat',
          'environment': {'MCP_BRIDGE_TEST': '1'},
        },
      ));
      try {
        await bridge.initialize().timeout(const Duration(seconds: 5));
        expect(bridge.isInitialized, isTrue);
        await bridge.shutdown();
      } finally {
        await stub.close();
      }
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
