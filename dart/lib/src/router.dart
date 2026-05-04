import 'dart:async';

import 'package:mcp_client/mcp_client.dart' as client;
import 'package:mcp_server/mcp_server.dart' as server;

import '../logger.dart';
import 'config.dart';

/// Forwards JSON-RPC messages between the bridge's two transports.
/// Verbatim pass-through — preserves JSON-RPC `id` correlation. Handles
/// all four message kinds (request · response · server-initiated request
/// · notification) in both directions.
///
/// Spec: `docs/03_DDD/core-router.md` · SRS FR3.
class MessageRouter {
  MessageRouter({
    required server.ServerTransport serverTransport,
    required client.ClientTransport clientTransport,
    required Logger logger,
    TransportErrorCallback? onError,
  })  : _serverTransport = serverTransport,
        _clientTransport = clientTransport,
        _logger = logger,
        _onError = onError;

  final server.ServerTransport _serverTransport;
  final client.ClientTransport _clientTransport;
  final Logger _logger;
  final TransportErrorCallback? _onError;

  StreamSubscription<dynamic>? _serverSub;
  StreamSubscription<dynamic>? _clientSub;
  bool _started = false;

  /// Subscribe to both transports' onMessage streams. Forwarding is
  /// active until [stop] is called.
  void start() {
    if (_started) return;
    _started = true;
    _serverSub = _serverTransport.onMessage.listen(
      _forwardServerToClient,
      onError: _onServerError,
    );
    _clientSub = _clientTransport.onMessage.listen(
      _forwardClientToServer,
      onError: _onClientError,
    );
  }

  /// Cancel subscriptions; stop forwarding. Idempotent.
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _serverSub?.cancel();
    await _clientSub?.cancel();
    _serverSub = null;
    _clientSub = null;
  }

  void _forwardServerToClient(dynamic message) {
    _logger.finest('server -> client');
    try {
      _clientTransport.send(message);
    } catch (e, st) {
      _logger.severe('failed to send to client: $e');
      _onError?.call(TransportSource.client, e, st);
    }
  }

  void _forwardClientToServer(dynamic message) {
    _logger.finest('client -> server');
    try {
      _serverTransport.send(message);
    } catch (e, st) {
      _logger.severe('failed to send to server: $e');
      _onError?.call(TransportSource.server, e, st);
    }
  }

  void _onServerError(Object error, StackTrace stack) {
    _logger.warning('server transport error: $error');
    _onError?.call(TransportSource.server, error, stack);
  }

  void _onClientError(Object error, StackTrace stack) {
    _logger.warning('client transport error: $error');
    _onError?.call(TransportSource.client, error, stack);
  }
}
