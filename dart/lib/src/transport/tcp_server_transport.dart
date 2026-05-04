import 'dart:async';
import 'dart:io';

import 'package:mcp_server/mcp_server.dart' as server;

import '_byte_stream_framing.dart';

/// Built-in 'tcp' server transport. Binds [ServerSocket], accepts the
/// first connection, attaches. Newline-delimited JSON framing.
///
/// Config keys:
/// - `host` (string, default `'localhost'`)
/// - `port` (int, default `0` — OS picks a free port)
class TcpServerTransport implements server.ServerTransport {
  TcpServerTransport(this._config);

  final Map<String, dynamic> _config;

  ServerSocket? _serverSocket;
  Socket? _clientSocket;
  StreamSubscription<List<int>>? _byteSub;
  late final ByteStreamFramer _framer = ByteStreamFramer(
    onFrame: _msgController.add,
    onError: _msgController.addError,
  );
  final _msgController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();

  Future<void> start() async {
    if (_serverSocket != null) return;
    final host = _config['host'] as String? ?? 'localhost';
    final port = _config['port'] as int? ?? 0;
    _serverSocket = await ServerSocket.bind(host, port);
    _serverSocket!.listen((socket) {
      if (_clientSocket != null) {
        // Already connected; reject further accepts.
        socket.destroy();
        return;
      }
      _attach(socket);
    });
  }

  void _attach(Socket socket) {
    _clientSocket = socket;
    _byteSub = socket.listen(
      _framer.feedBytes,
      onError: _msgController.addError,
      onDone: _onClosed,
      cancelOnError: false,
    );
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
    final s = _clientSocket;
    if (s == null) {
      throw StateError('tcp server transport: no client connected yet');
    }
    s.add(ByteStreamFramer.encodeFrame(message));
  }

  @override
  void close() {
    _byteSub?.cancel();
    _clientSocket?.destroy();
    _clientSocket = null;
    _serverSocket?.close();
    _serverSocket = null;
    _onClosed();
  }
}
