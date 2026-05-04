import 'dart:async';

import 'package:mcp_server/mcp_server.dart' as server;

import '_serial_base.dart';

/// Built-in 'serial' server transport. Opens a serial port (USB CDC ACM
/// devices included — they appear as /dev/ttyACMx · /dev/cu.usbmodem* ·
/// COMx). Newline-delimited JSON framing.
///
/// Config keys:
/// - `port` (string, required) — device path
/// - `baudRate` (int, default `115200`)
/// - `dataBits` (int, default `8`)
/// - `parity` (`'none' | 'odd' | 'even' | 'mark' | 'space'`, default `'none'`)
/// - `stopBits` (int, default `1`)
/// - `flowControl` (`'none' | 'rts_cts' | 'xon_xoff' | 'dsr_dtr'`,
///   default `'none'`)
/// - `pollIntervalMs` (int, default `10`) — input-waiting poll cadence
class SerialServerTransport implements server.ServerTransport {
  SerialServerTransport(Map<String, dynamic> config)
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
