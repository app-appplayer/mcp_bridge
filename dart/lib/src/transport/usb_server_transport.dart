import 'dart:async';

import 'package:mcp_server/mcp_server.dart' as server;

import '_usb_base.dart';

/// Built-in 'usb' server transport. Direct USB endpoint access via
/// libusb FFI — for vendor-specific protocols not exposed as CDC.
/// Newline-delimited JSON framing on bulk endpoints.
///
/// Config keys:
/// - `vendorId` (int, required) — e.g. `0x1234`
/// - `productId` (int, required)
/// - `interface` (int, default `0`)
/// - `inEndpoint` (int, required) — typically `0x81` for bulk in
/// - `outEndpoint` (int, required) — typically `0x01` for bulk out
/// - `readTimeoutMs` (int, default `10`)
/// - `writeTimeoutMs` (int, default `1000`)
/// - `readBufferSize` (int, default `4096`)
/// - `pollIntervalMs` (int, default `10`)
/// - `libusbPath` (string, optional) — override default libusb path
///
/// System deps: `libusb-1.0` installed; udev / WinUSB driver setup
/// per device. See README.
class UsbServerTransport implements server.ServerTransport {
  UsbServerTransport(Map<String, dynamic> config)
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
