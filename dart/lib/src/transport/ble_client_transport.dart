import 'dart:async';

import 'package:mcp_client/mcp_client.dart' as client;

import '_ble_base.dart';

/// Built-in 'ble' client transport — Linux only in 0.2.0.
/// macOS / Windows throw [UnsupportedError] at construction.
///
/// Same wire as the server-side adapter. See [BleServerTransport] for
/// config keys.
class BleClientTransport implements client.ClientTransport {
  BleClientTransport(Map<String, dynamic> config)
      : _adapter = BleCentralAdapter(config);

  final BleCentralAdapter _adapter;

  Future<void> start() => _adapter.start();

  @override
  Stream<dynamic> get onMessage => _adapter.msgController.stream;

  @override
  Future<void> get onClose => _adapter.closeCompleter.future;

  @override
  void send(dynamic message) => _adapter.send(message);

  @override
  void close() {
    _adapter.close();
  }
}
