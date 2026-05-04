import 'dart:async';

import 'package:mcp_server/mcp_server.dart' as server;

import '_ble_base.dart';

/// Built-in 'ble' server transport — Linux only in 0.2.0.
/// macOS / Windows throw [UnsupportedError] at construction.
///
/// Connects to a remote BLE peripheral (typically the embedded device
/// hosting the MCP server) as a central, subscribes to its notify
/// characteristic, writes to its write characteristic. Newline-
/// delimited JSON framing on characteristic values.
///
/// Config keys:
/// - `deviceAddress` (string, required) — `AA:BB:CC:DD:EE:FF`
/// - `serviceUuid` (string, required)
/// - `notifyCharUuid` (string, required) — server → bridge
/// - `writeCharUuid` (string, required) — bridge → server
class BleServerTransport implements server.ServerTransport {
  BleServerTransport(Map<String, dynamic> config)
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
