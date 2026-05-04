import 'dart:async';
import 'dart:io';

import 'package:bluez/bluez.dart' as bz;

import '_byte_stream_framing.dart';

/// Linux-only BLE central-role transport. Connects to a remote
/// peripheral, subscribes to a notify GATT characteristic for inbound,
/// writes to a write GATT characteristic for outbound. Newline-
/// delimited JSON framing.
///
/// On non-Linux platforms this class throws [UnsupportedError] at
/// construction — the bridge's switch checks the platform before
/// instantiating.
class BleCentralAdapter {
  BleCentralAdapter(this._config) {
    if (!Platform.isLinux) {
      throw UnsupportedError(
          "'ble' transport is Linux-only in 0.2.0; running on "
          "${Platform.operatingSystem}");
    }
  }

  final Map<String, dynamic> _config;

  bz.BlueZClient? _bluez;
  bz.BlueZGattCharacteristic? _notifyChar;
  bz.BlueZGattCharacteristic? _writeChar;
  StreamSubscription<List<String>>? _propsSub;

  late final ByteStreamFramer _framer = ByteStreamFramer(
    onFrame: msgController.add,
    onError: msgController.addError,
  );
  final msgController = StreamController<dynamic>.broadcast();
  final closeCompleter = Completer<void>();

  Future<void> start() async {
    if (_bluez != null) return;
    final deviceAddress = _config['deviceAddress'];
    final serviceUuid = _config['serviceUuid'];
    final notifyUuid = _config['notifyCharUuid'];
    final writeUuid = _config['writeCharUuid'];
    if (deviceAddress is! String ||
        serviceUuid is! String ||
        notifyUuid is! String ||
        writeUuid is! String) {
      throw ArgumentError(
          'ble transport requires `deviceAddress`, `serviceUuid`, '
          '`notifyCharUuid`, `writeCharUuid` (all String)');
    }
    final discoveryTimeout = Duration(
        milliseconds: _config['discoveryTimeoutMs'] as int? ?? 15000);
    final scanIfMissing = _config['scanIfMissing'] as bool? ?? true;

    final client = bz.BlueZClient();
    await client.connect();
    _bluez = client;

    var device = _findDevice(client, deviceAddress);
    if (device == null && scanIfMissing) {
      // Trigger adapter discovery so the device shows up on
      // client.devices. We stop discovery as soon as the address
      // appears or the timeout elapses.
      final adapter = client.adapters.isNotEmpty ? client.adapters.first : null;
      if (adapter != null) {
        try {
          await adapter.startDiscovery();
        } catch (_) {/* already discovering is OK */}
        final deadline = DateTime.now().add(discoveryTimeout);
        while (DateTime.now().isBefore(deadline)) {
          device = _findDevice(client, deviceAddress);
          if (device != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        try {
          await adapter.stopDiscovery();
        } catch (_) {}
      }
    }
    if (device == null) {
      throw StateError(
          'ble device "$deviceAddress" not found '
          '(${client.devices.length} known)');
    }

    if (!device.connected) {
      await device.connect();
    }

    // Wait for GATT discovery to complete. bluez exposes a
    // `servicesResolved` property; without waiting, `gattServices` is
    // typically empty right after `connect()` returns.
    await _awaitServicesResolved(device, discoveryTimeout);

    final service = device.gattServices.firstWhere(
      (s) => s.uuid.toString().toLowerCase() == serviceUuid.toLowerCase(),
      orElse: () => throw StateError(
          'ble service "$serviceUuid" not found on device "$deviceAddress" '
          '(${device!.gattServices.length} services resolved)'),
    );

    final notifyChar = service.characteristics.firstWhere(
      (c) => c.uuid.toString().toLowerCase() == notifyUuid.toLowerCase(),
      orElse: () => throw StateError(
          'ble notify characteristic "$notifyUuid" not found'),
    );
    final writeChar = service.characteristics.firstWhere(
      (c) => c.uuid.toString().toLowerCase() == writeUuid.toLowerCase(),
      orElse: () => throw StateError(
          'ble write characteristic "$writeUuid" not found'),
    );

    _notifyChar = notifyChar;
    _writeChar = writeChar;

    _propsSub = notifyChar.propertiesChanged.listen((changed) {
      if (!changed.contains('Value')) return;
      final bytes = notifyChar.value;
      if (bytes.isEmpty) return;
      _framer.feedBytes(bytes);
    });
    await notifyChar.startNotify();
  }

  bz.BlueZDevice? _findDevice(bz.BlueZClient client, String address) {
    final lower = address.toLowerCase();
    for (final d in client.devices) {
      if (d.address.toLowerCase() == lower) return d;
    }
    return null;
  }

  Future<void> _awaitServicesResolved(
      bz.BlueZDevice device, Duration timeout) async {
    if (device.servicesResolved) return;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (device.servicesResolved) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    // Don't throw — proceed with whatever services we have. The
    // firstWhere below produces a clearer error if the target service
    // really isn't present.
  }

  void send(dynamic message) {
    final c = _writeChar;
    if (c == null) throw StateError('ble transport not opened');
    final bytes = ByteStreamFramer.encodeFrame(message);
    // Fire-and-forget the async write; failures surface via error
    // stream of msgController so the bridge's onTransportError fires.
    c.writeValue(bytes).catchError((Object e, StackTrace st) {
      msgController.addError(e, st);
    });
  }

  Future<void> close() async {
    await _propsSub?.cancel();
    _propsSub = null;
    final n = _notifyChar;
    if (n != null) {
      try {
        await n.stopNotify();
      } catch (_) {}
    }
    _notifyChar = null;
    _writeChar = null;
    final client = _bluez;
    if (client != null) {
      await client.close();
      _bluez = null;
    }
    if (!closeCompleter.isCompleted) closeCompleter.complete();
    if (!msgController.isClosed) await msgController.close();
  }
}
