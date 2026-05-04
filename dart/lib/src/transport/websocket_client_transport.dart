import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_client/mcp_client.dart' as client;

/// Built-in 'websocket' client transport. Connects via [WebSocket.connect].
/// One JSON-RPC frame per text message.
///
/// Config keys:
/// - `url` (string, required) — `ws://...` or `wss://...`
/// - `headers` (`Map<String, String>`, optional)
/// - `protocols` (`List<String>`, optional) — WebSocket subprotocols
/// - `pingInterval` (int milliseconds, optional)
class WebSocketClientTransport implements client.ClientTransport {
  WebSocketClientTransport(this._config);

  final Map<String, dynamic> _config;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  final _msgController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();

  /// Open the WebSocket connection.
  Future<void> start() async {
    if (_socket != null) return;
    final url = _config['url'];
    if (url is! String) {
      throw ArgumentError(
          'websocket client transport requires a `url` (String) config field');
    }
    final headers = (_config['headers'] is Map)
        ? Map<String, String>.from(_config['headers'] as Map)
        : null;
    final protocols = (_config['protocols'] is List)
        ? List<String>.from(_config['protocols'] as List)
        : null;

    final ws = await WebSocket.connect(url,
        headers: headers, protocols: protocols);
    final pingMs = _config['pingInterval'];
    if (pingMs is int && pingMs > 0) {
      ws.pingInterval = Duration(milliseconds: pingMs);
    }
    _socket = ws;
    _socketSub = ws.listen(
      _onFrame,
      onError: _msgController.addError,
      onDone: _onClosed,
      cancelOnError: false,
    );
  }

  void _onFrame(dynamic frame) {
    if (frame is! String) return;
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
    if (ws == null) throw StateError('websocket client transport not opened');
    ws.add(jsonEncode(message));
  }

  @override
  void close() {
    _socketSub?.cancel();
    _socket?.close();
    _socket = null;
    _onClosed();
  }
}
