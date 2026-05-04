import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:dart_libusb/dart_libusb.dart' as usb;
import 'package:ffi/ffi.dart' show calloc;

import '_byte_stream_framing.dart';

/// Default search paths for the system libusb-1.0 dynamic library.
/// Tries each candidate in turn; raises with the joined error list if
/// none load. The `libusbPath` config key overrides discovery entirely.
DynamicLibrary _loadLibusb(String? overridePath) {
  if (overridePath != null) {
    return DynamicLibrary.open(overridePath);
  }
  final candidates = <String>[
    if (Platform.isMacOS) ...[
      '/opt/homebrew/lib/libusb-1.0.0.dylib',  // Apple Silicon Homebrew
      '/usr/local/lib/libusb-1.0.0.dylib',     // Intel Homebrew
      '/opt/local/lib/libusb-1.0.0.dylib',     // MacPorts
      'libusb-1.0.0.dylib',
      'libusb-1.0.dylib',
    ],
    if (Platform.isLinux) ...[
      'libusb-1.0.so.0',
      'libusb-1.0.so',
      '/usr/lib/x86_64-linux-gnu/libusb-1.0.so.0',
      '/usr/lib/aarch64-linux-gnu/libusb-1.0.so.0',
      '/usr/lib64/libusb-1.0.so.0',
    ],
    if (Platform.isWindows) ...[
      'libusb-1.0.dll',
      'libusb.dll',
    ],
  ];
  if (candidates.isEmpty) {
    throw UnsupportedError(
        'libusb not supported on ${Platform.operatingSystem}');
  }
  final errors = <String>[];
  for (final path in candidates) {
    try {
      return DynamicLibrary.open(path);
    } catch (e) {
      errors.add('$path: $e');
    }
  }
  throw StateError(
      'libusb-1.0 not found. Install it via your OS package manager '
      '(Linux: apt install libusb-1.0-0 · macOS: brew install libusb · '
      'Windows: vcpkg or drop libusb-1.0.dll alongside the executable), '
      'or set `libusbPath` in the transport config to an explicit path. '
      'Tried:\n  ${errors.join("\n  ")}');
}

/// Shared USB plumbing — both server-side and client-side adapters use
/// this. Bulk-IN endpoint for receive, bulk-OUT for send. Newline-
/// delimited JSON framing.
class UsbDeviceAdapter {
  UsbDeviceAdapter(this._config);

  final Map<String, dynamic> _config;

  late final usb.Libusb _libusb;
  Pointer<usb.libusb_device_handle>? _handle;
  int _interface = 0;
  int _inEndpoint = 0;
  int _outEndpoint = 0;
  int _readTimeoutMs = 10;
  int _writeTimeoutMs = 1000;
  int _readBufferSize = 4096;

  Timer? _pollTimer;
  late final ByteStreamFramer _framer = ByteStreamFramer(
    onFrame: msgController.add,
    onError: msgController.addError,
  );
  final msgController = StreamController<dynamic>.broadcast();
  final closeCompleter = Completer<void>();

  Future<void> start() async {
    if (_handle != null) return;
    final vendorId = _config['vendorId'];
    final productId = _config['productId'];
    if (vendorId is! int || productId is! int) {
      throw ArgumentError(
          'usb transport requires `vendorId` (int) and `productId` (int)');
    }
    _interface = _config['interface'] as int? ?? 0;
    final inEp = _config['inEndpoint'];
    final outEp = _config['outEndpoint'];
    if (inEp is! int || outEp is! int) {
      throw ArgumentError(
          'usb transport requires `inEndpoint` (int) and `outEndpoint` (int)');
    }
    _inEndpoint = inEp;
    _outEndpoint = outEp;
    _readTimeoutMs = _config['readTimeoutMs'] as int? ?? 10;
    _writeTimeoutMs = _config['writeTimeoutMs'] as int? ?? 1000;
    _readBufferSize = _config['readBufferSize'] as int? ?? 4096;
    final libPath = _config['libusbPath'] as String?;

    _libusb = usb.Libusb(_loadLibusb(libPath));

    final initRc = _libusb.libusb_init(nullptr);
    if (initRc < 0) {
      throw StateError('libusb_init failed: rc=$initRc');
    }

    final handle = _libusb.libusb_open_device_with_vid_pid(
      nullptr,
      vendorId,
      productId,
    );
    if (handle == nullptr) {
      _libusb.libusb_exit(nullptr);
      throw StateError(
          'usb device not found: '
          'vendorId=0x${vendorId.toRadixString(16)} '
          'productId=0x${productId.toRadixString(16)}');
    }

    final claimRc = _libusb.libusb_claim_interface(handle, _interface);
    if (claimRc < 0) {
      _libusb.libusb_close(handle);
      _libusb.libusb_exit(nullptr);
      throw StateError(
          'libusb_claim_interface($_interface) failed: rc=$claimRc');
    }

    _handle = handle;
    _startPolling();
  }

  void _startPolling() {
    final interval = Duration(
        milliseconds: _config['pollIntervalMs'] as int? ?? 10);
    _pollTimer = Timer.periodic(interval, (_) => _pollOnce());
  }

  void _pollOnce() {
    final h = _handle;
    if (h == null) return;
    final buf = calloc<Uint8>(_readBufferSize);
    final transferred = calloc<Int>();
    try {
      final rc = _libusb.libusb_bulk_transfer(
        h,
        _inEndpoint,
        buf.cast(),
        _readBufferSize,
        transferred,
        _readTimeoutMs,
      );
      // 0 = success, -7 = LIBUSB_ERROR_TIMEOUT. Both fine for polling;
      // any other negative is a real error.
      if (rc == 0) {
        final n = transferred.value;
        if (n > 0) {
          final data = buf.asTypedList(n).toList();
          _framer.feedBytes(data);
        }
      } else if (rc != -7) {
        msgController.addError(
            StateError('libusb_bulk_transfer (read) failed: rc=$rc'),
            StackTrace.current);
      }
    } finally {
      calloc.free(buf);
      calloc.free(transferred);
    }
  }

  void send(dynamic message) {
    final h = _handle;
    if (h == null) throw StateError('usb transport not opened');
    final bytes = ByteStreamFramer.encodeFrame(message);
    final buf = calloc<Uint8>(bytes.length);
    buf.asTypedList(bytes.length).setAll(0, bytes);
    final transferred = calloc<Int>();
    try {
      final rc = _libusb.libusb_bulk_transfer(
        h,
        _outEndpoint,
        buf.cast(),
        bytes.length,
        transferred,
        _writeTimeoutMs,
      );
      if (rc < 0) {
        throw StateError('libusb_bulk_transfer (write) failed: rc=$rc');
      }
    } finally {
      calloc.free(buf);
      calloc.free(transferred);
    }
  }

  void close() {
    _pollTimer?.cancel();
    _pollTimer = null;
    final h = _handle;
    if (h != null) {
      try {
        _libusb.libusb_release_interface(h, _interface);
        _libusb.libusb_close(h);
        _libusb.libusb_exit(nullptr);
      } catch (_) {}
      _handle = null;
    }
    if (!closeCompleter.isCompleted) closeCompleter.complete();
    if (!msgController.isClosed) msgController.close();
  }
}
