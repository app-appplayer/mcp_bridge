// Direct unit tests for lib/src/router.dart (MessageRouter) — pure
// forwarding / lifecycle logic, isolated from the rest of McpBridge.
//
// Uses small local fakes (distinct from the ones in mcp_bridge_test.dart,
// which are library-private to that file) implementing the same
// mcp_server.ServerTransport / mcp_client.ClientTransport seams.

import 'dart:async';

import 'package:mcp_bridge/src/router.dart';
import 'package:mcp_bridge/src/config.dart' show TransportSource;
import 'package:mcp_bridge/logger.dart';
import 'package:mcp_client/mcp_client.dart' as client;
import 'package:mcp_server/mcp_server.dart' as server;
import 'package:test/test.dart';

class _FakeServer implements server.ServerTransport {
  final _msg = StreamController<dynamic>.broadcast();
  final List<dynamic> sent = [];
  bool throwOnSend = false;

  @override
  Stream<dynamic> get onMessage => _msg.stream;
  @override
  Future<void> get onClose => Completer<void>().future; // never closes
  @override
  void send(dynamic message) {
    if (throwOnSend) throw StateError('server send failed');
    sent.add(message);
  }

  @override
  void close() => _msg.close();

  void receive(dynamic m) => _msg.add(m);
  void fail(Object e) => _msg.addError(e, StackTrace.current);
}

class _FakeClient implements client.ClientTransport {
  final _msg = StreamController<dynamic>.broadcast();
  final List<dynamic> sent = [];
  bool throwOnSend = false;

  @override
  Stream<dynamic> get onMessage => _msg.stream;
  @override
  Future<void> get onClose => Completer<void>().future;
  @override
  void send(dynamic message) {
    if (throwOnSend) throw StateError('client send failed');
    sent.add(message);
  }

  @override
  void close() => _msg.close();

  void receive(dynamic m) => _msg.add(m);
  void fail(Object e) => _msg.addError(e, StackTrace.current);
}

void main() {
  group('MessageRouter', () {
    test('forwards server -> client', () async {
      final s = _FakeServer();
      final c = _FakeClient();
      final router = MessageRouter(
        serverTransport: s,
        clientTransport: c,
        logger: Logger('router_test'),
      )..start();
      s.receive({'jsonrpc': '2.0', 'method': 'ping'});
      await Future<void>.delayed(Duration.zero);
      expect(c.sent, hasLength(1));
      expect(c.sent.single, equals({'jsonrpc': '2.0', 'method': 'ping'}));
      await router.stop();
    });

    test('forwards client -> server', () async {
      final s = _FakeServer();
      final c = _FakeClient();
      final router = MessageRouter(
        serverTransport: s,
        clientTransport: c,
        logger: Logger('router_test'),
      )..start();
      c.receive({'jsonrpc': '2.0', 'id': 1, 'result': {}});
      await Future<void>.delayed(Duration.zero);
      expect(s.sent, hasLength(1));
      await router.stop();
    });

    test('start() is idempotent — second call does not double-subscribe',
        () async {
      final s = _FakeServer();
      final c = _FakeClient();
      final router = MessageRouter(
        serverTransport: s,
        clientTransport: c,
        logger: Logger('router_test'),
      );
      router.start();
      router.start(); // no-op per `if (_started) return;`
      s.receive({'a': 1});
      await Future<void>.delayed(Duration.zero);
      // If start() had double-subscribed, this message would have been
      // forwarded twice.
      expect(c.sent, hasLength(1));
      await router.stop();
    });

    test('stop() is idempotent and cancels both subscriptions', () async {
      final s = _FakeServer();
      final c = _FakeClient();
      final router = MessageRouter(
        serverTransport: s,
        clientTransport: c,
        logger: Logger('router_test'),
      )..start();
      await router.stop();
      await router.stop(); // no-op per `if (!_started) return;`

      // After stop(), forwarding must no longer happen.
      s.receive({'a': 1});
      await Future<void>.delayed(Duration.zero);
      expect(c.sent, isEmpty);
    });

    test('server transport stream error routes through onError as server',
        () async {
      final s = _FakeServer();
      final c = _FakeClient();
      TransportSource? side;
      Object? err;
      final router = MessageRouter(
        serverTransport: s,
        clientTransport: c,
        logger: Logger('router_test'),
        onError: (src, e, st) {
          side = src;
          err = e;
        },
      )..start();
      s.fail(StateError('server boom'));
      await Future<void>.delayed(Duration.zero);
      expect(side, equals(TransportSource.server));
      expect(err, isA<StateError>());
      await router.stop();
    });

    test('client transport stream error routes through onError as client',
        () async {
      final s = _FakeServer();
      final c = _FakeClient();
      TransportSource? side;
      Object? err;
      final router = MessageRouter(
        serverTransport: s,
        clientTransport: c,
        logger: Logger('router_test'),
        onError: (src, e, st) {
          side = src;
          err = e;
        },
      )..start();
      c.fail(StateError('client boom'));
      await Future<void>.delayed(Duration.zero);
      expect(side, equals(TransportSource.client));
      expect(err, isA<StateError>());
      await router.stop();
    });

    test('send-side exception forwarding server->client reports client side',
        () async {
      final s = _FakeServer();
      final c = _FakeClient()..throwOnSend = true;
      TransportSource? side;
      Object? err;
      final router = MessageRouter(
        serverTransport: s,
        clientTransport: c,
        logger: Logger('router_test'),
        onError: (src, e, st) {
          side = src;
          err = e;
        },
      )..start();
      s.receive({'a': 1});
      await Future<void>.delayed(Duration.zero);
      expect(side, equals(TransportSource.client));
      expect(err, isA<StateError>());
      await router.stop();
    });

    test('send-side exception forwarding client->server reports server side',
        () async {
      final s = _FakeServer()..throwOnSend = true;
      final c = _FakeClient();
      TransportSource? side;
      Object? err;
      final router = MessageRouter(
        serverTransport: s,
        clientTransport: c,
        logger: Logger('router_test'),
        onError: (src, e, st) {
          side = src;
          err = e;
        },
      )..start();
      c.receive({'a': 1});
      await Future<void>.delayed(Duration.zero);
      expect(side, equals(TransportSource.server));
      expect(err, isA<StateError>());
      await router.stop();
    });

    test('no onError callback set — errors are swallowed silently, not '
        'rethrown', () async {
      final s = _FakeServer();
      final c = _FakeClient();
      final router = MessageRouter(
        serverTransport: s,
        clientTransport: c,
        logger: Logger('router_test'),
        // onError intentionally omitted (nullable, optional per FR4.2).
      )..start();
      // Must not throw synchronously nor cause an uncaught async error.
      s.fail(StateError('unhandled but must not crash the test'));
      await Future<void>.delayed(Duration.zero);
      await router.stop();
    });
  });
}
