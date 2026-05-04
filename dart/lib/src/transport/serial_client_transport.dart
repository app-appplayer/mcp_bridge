import 'dart:async';

import 'package:mcp_client/mcp_client.dart' as client;

import '_serial_base.dart';

/// Built-in 'serial' client transport. Same wire as the server-side
/// adapter — the bridge can pair them in either direction. See
/// [SerialServerTransport] for config keys.
class SerialClientTransport implements client.ClientTransport {
  SerialClientTransport(Map<String, dynamic> config)
      : _adapter = SerialPortAdapter(config);

  final SerialPortAdapter _adapter;

  Future<void> start() => _adapter.start();

  @override
  Stream<dynamic> get onMessage => _adapter.msgController.stream;

  @override
  Future<void> get onClose => _adapter.closeCompleter.future;

  @override
  void send(dynamic message) => _adapter.send(message);

  @override
  void close() => _adapter.close();
}
