import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_server/mcp_server.dart' as server;

/// Built-in 'websocket' server transport. Binds an HTTP server, upgrades
/// the first matching request to a WebSocket. One JSON-RPC frame per
/// text message. Single-client (the bridge is 1:1).
///
/// Config keys:
/// - `host` (string, default `'localhost'`)
/// - `port` (int, default `8080`)
/// - `path` (string, default `'/'`) — only requests matching this path
///   are upgraded
/// - `authToken` (string, optional) — if set, requires
///   `Authorization: Bearer <token>` header
class WebSocketServerTransport implements server.ServerTransport {
  WebSocketServerTransport(this._config);

  final Map<String, dynamic> _config;

  HttpServer? _httpServer;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  final _msgController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();

  /// Bind the listener and wait for the first incoming connection upgrade.
  Future<void> start() async {
    if (_httpServer != null) return;
    final host = _config['host'] as String? ?? 'localhost';
    final port = _config['port'] as int? ?? 8080;
    final path = _config['path'] as String? ?? '/';
    final authToken = _config['authToken'] as String?;

    _httpServer = await HttpServer.bind(host, port);
    _httpServer!.listen((request) async {
      if (request.uri.path != path) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      if (authToken != null) {
        final auth = request.headers.value(HttpHeaders.authorizationHeader);
        if (auth != 'Bearer $authToken') {
          request.response.statusCode = HttpStatus.unauthorized;
          await request.response.close();
          return;
        }
      }
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      if (_socket != null) {
        // Already have a client; reject further upgrades.
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(request);
      _attach(ws);
    });
  }

  void _attach(WebSocket ws) {
    _socket = ws;
    _socketSub = ws.listen(
      _onFrame,
      onError: _msgController.addError,
      onDone: _onClosed,
      cancelOnError: false,
    );
  }

  void _onFrame(dynamic frame) {
    if (frame is! String) {
      // Binary frames not used for MCP JSON-RPC.
      return;
    }
    try {
      _msgController.add(jsonDecode(frame));
    } catch (e, st) {
      _msgController.addError(e, st);
    }
  }

  void _onClosed() {
    if (!_closeCompleter.isCompleted) _closeCompleter.complete();
    if (!_msgController.isClosed) _msgController.close();
  }

  @override
  Stream<dynamic> get onMessage => _msgController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) {
    final ws = _socket;
    if (ws == null) {
      throw StateError('websocket server transport: no client connected yet');
    }
    ws.add(jsonEncode(message));
  }

  @override
  void close() {
    _socketSub?.cancel();
    _socket?.close();
    _socket = null;
    _httpServer?.close(force: true);
    _httpServer = null;
    _onClosed();
  }
}
