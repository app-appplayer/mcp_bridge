import 'dart:async';
import 'dart:io';

import 'package:mcp_client/mcp_client.dart' as client;

import '_byte_stream_framing.dart';

/// Built-in 'tcp' client transport. Connects via [Socket.connect].
/// Newline-delimited JSON framing.
///
/// Config keys:
/// - `host` (string, required)
/// - `port` (int, required)
/// - `timeoutMs` (int, optional)
class TcpClientTransport implements client.ClientTransport {
  TcpClientTransport(this._config);

  final Map<String, dynamic> _config;

  Socket? _socket;
  StreamSubscription<List<int>>? _byteSub;
  late final ByteStreamFramer _framer = ByteStreamFramer(
    onFrame: _msgController.add,
    onError: _msgController.addError,
  );
  final _msgController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();

  Future<void> start() async {
    if (_socket != null) return;
    final host = _config['host'];
    final port = _config['port'];
    if (host is! String || port is! int) {
      throw ArgumentError(
          'tcp client transport requires `host` (String) and `port` (int)');
    }
    Duration? timeout;
    final t = _config['timeoutMs'];
    if (t is int) timeout = Duration(milliseconds: t);

    _socket = await Socket.connect(host, port, timeout: timeout);
    _byteSub = _socket!.listen(
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
    final s = _socket;
    if (s == null) throw StateError('tcp client transport not opened');
    s.add(ByteStreamFramer.encodeFrame(message));
  }

  @override
  void close() {
    _byteSub?.cancel();
    _socket?.destroy();
    _socket = null;
    _onClosed();
  }
}
