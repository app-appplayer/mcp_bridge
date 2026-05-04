import 'dart:async';

import 'package:mcp_client/mcp_client.dart' as client;

import '_usb_base.dart';

/// Built-in 'usb' client transport. Same wire as the server-side
/// adapter — USB is symmetric. See [UsbServerTransport] for config keys.
class UsbClientTransport implements client.ClientTransport {
  UsbClientTransport(Map<String, dynamic> config)
      : _adapter = UsbDeviceAdapter(config);

  final UsbDeviceAdapter _adapter;

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
