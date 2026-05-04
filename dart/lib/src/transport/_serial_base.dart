import 'dart:async';

import 'package:clib_serialport_dart/clib_serialport_dart.dart' as csp;

import '_byte_stream_framing.dart';

/// Shared serial-port plumbing used by both [SerialServerTransport] and
/// [SerialClientTransport]. Serial is symmetric — same code works on
/// both sides.
class SerialPortAdapter {
  SerialPortAdapter(this._config);

  final Map<String, dynamic> _config;

  csp.SerialPort? _port;
  Timer? _pollTimer;
  late final ByteStreamFramer _framer = ByteStreamFramer(
    onFrame: msgController.add,
    onError: msgController.addError,
  );
  final msgController = StreamController<dynamic>.broadcast();
  final closeCompleter = Completer<void>();

  /// Open and configure the serial port.
  Future<void> start() async {
    if (_port != null) return;
    final portName = _config['port'];
    if (portName is! String) {
      throw ArgumentError(
          'serial transport requires a `port` (String) config field — '
          'e.g. /dev/ttyUSB0, /dev/cu.usbmodem*, COM3');
    }
    final p = csp.SerialPort(portName);
    if (!p.open()) {
      throw StateError('failed to open serial port "$portName"');
    }
    final cfg = csp.SerialPortConfig(
      baudRate: _config['baudRate'] as int? ?? 115200,
      dataBits: _config['dataBits'] as int? ?? 8,
      parity: _parseParity(_config['parity']),
      stopBits: _config['stopBits'] as int? ?? 1,
      flowControl: _parseFlowControl(_config['flowControl']),
    );
    if (!p.configure(cfg)) {
      p.close();
      throw StateError(
          'failed to configure serial port "$portName" with $cfg');
    }
    _port = p;
    _startPolling();
  }

  csp.SPParity _parseParity(dynamic v) {
    switch (v) {
      case 'odd':
        return csp.SPParity.odd;
      case 'even':
        return csp.SPParity.even;
      case 'mark':
        return csp.SPParity.mark;
      case 'space':
        return csp.SPParity.space;
      case null:
      case 'none':
        return csp.SPParity.none;
      default:
        throw ArgumentError('unknown parity: $v');
    }
  }

  csp.SPFlowControl _parseFlowControl(dynamic v) {
    switch (v) {
      case 'rts_cts':
      case 'rtscts':
        return csp.SPFlowControl.rtscts;
      case 'xon_xoff':
      case 'xonxoff':
        return csp.SPFlowControl.xonxoff;
      case 'dsr_dtr':
      case 'dsrdtr':
        return csp.SPFlowControl.dsrdtr;
      case null:
      case 'none':
        return csp.SPFlowControl.none;
      default:
        throw ArgumentError('unknown flowControl: $v');
    }
  }

  void _startPolling() {
    final interval = Duration(
        milliseconds: _config['pollIntervalMs'] as int? ?? 10);
    _pollTimer = Timer.periodic(interval, (_) {
      final p = _port;
      if (p == null) return;
      try {
        final available = p.inputWaiting();
        if (available > 0) {
          final data = p.read(available, timeoutMs: 0);
          if (data.isNotEmpty) _framer.feedBytes(data);
        }
      } catch (e, st) {
        msgController.addError(e, st);
      }
    });
  }

  void send(dynamic message) {
    final p = _port;
    if (p == null) throw StateError('serial transport not opened');
    final bytes = ByteStreamFramer.encodeFrame(message);
    p.write(bytes, timeoutMs: 1000);
  }

  void close() {
    _pollTimer?.cancel();
    _pollTimer = null;
    final p = _port;
    if (p != null) {
      try {
        p.close();
      } catch (_) {}
      _port = null;
    }
    if (!closeCompleter.isCompleted) closeCompleter.complete();
    if (!msgController.isClosed) msgController.close();
  }
}
