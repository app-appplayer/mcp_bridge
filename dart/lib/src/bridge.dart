import 'dart:async';

import 'package:meta/meta.dart';
import 'package:mcp_client/mcp_client.dart' as client;
import 'package:mcp_server/mcp_server.dart' as server;

import '../logger.dart';
import 'config.dart';
import 'router.dart';
import 'transport/ble_client_transport.dart';
import 'transport/ble_server_transport.dart';
import 'transport/serial_client_transport.dart';
import 'transport/serial_server_transport.dart';
import 'transport/tcp_client_transport.dart';
import 'transport/tcp_server_transport.dart';
import 'transport/usb_client_transport.dart';
import 'transport/usb_server_transport.dart';
import 'transport/websocket_client_transport.dart';
import 'transport/websocket_server_transport.dart';

/// The set of transport-type names recognised by the bridge. Mirrors
/// what `mcp_client` / `mcp_server` 2.x expose. Adding a new transport
/// to those packages also requires a one-line case addition to
/// [_buildServerTransport] / [_buildClientTransport] and an entry here.
const List<String> _supportedTransportTypes = [
  'stdio',
  'sse',
  'streamableHttp',
  'websocket',
  'tcp',
  'serial',
  'usb',
  'ble',
];

/// Thrown by [McpBridge.initialize] when a transport-type name in
/// [McpBridgeConfig] is not recognised. Carries the offending name, the
/// side ('server' or 'client'), and the supported list so the message
/// can suggest alternatives.
class UnknownTransportTypeException implements Exception {
  final String name;
  final String side;
  final List<String> supported;
  const UnknownTransportTypeException(this.name, this.side, this.supported);
  @override
  String toString() =>
      'Unknown $side transport type: "$name". '
      'Supported: ${supported.join(", ")}';
}

/// Core MCP Bridge runtime. Spec: `docs/03_DDD/core-bridge.md`.
///
/// Constructed from [McpBridgeConfig], starts forwarding via
/// [initialize], tears down via [shutdown]. The bridge resolves the
/// configured transport-type names directly to `mcp_server` /
/// `mcp_client` 2.x transport factories — there is no transport
/// abstraction layer inside mcp_bridge.
class McpBridge {
  McpBridge(this._config);

  /// Test-only constructor that bypasses [_buildServerTransport] /
  /// [_buildClientTransport]. Pass already-constructed transports
  /// directly. Useful for driving lifecycle paths that are hard to
  /// provoke from real transports.
  @visibleForTesting
  McpBridge.testWithTransports(
    this._config, {
    required server.ServerTransport serverTransport,
    required client.ClientTransport clientTransport,
  })  : _testServerTransport = serverTransport,
        _testClientTransport = clientTransport;

  final McpBridgeConfig _config;
  final Logger _logger = Logger('mcp_bridge');

  // Test-only injected transports. When non-null, [initialize] uses
  // them instead of going through the type-name switch.
  server.ServerTransport? _testServerTransport;
  client.ClientTransport? _testClientTransport;

  // Test-only reconnect overrides. When non-null, the reconnect path
  // pulls these instead of calling [_buildServerTransport] /
  // [_buildClientTransport]. Each is consumed (set back to null) on
  // first use.
  server.ServerTransport? _testNextServerTransport;
  client.ClientTransport? _testNextClientTransport;

  /// Test-only — queue the next transport instances the bridge will
  /// pick up during a reconnect cycle. Consumed once each.
  @visibleForTesting
  void setTestNextTransports({
    server.ServerTransport? server,
    client.ClientTransport? client,
  }) {
    _testNextServerTransport = server;
    _testNextClientTransport = client;
  }

  server.ServerTransport? _serverTransport;
  client.ClientTransport? _clientTransport;
  MessageRouter? _router;

  bool _isInitialized = false;
  bool _isShuttingDown = false;
  bool _isServerActive = false;
  bool _isWaitingForServerReconnection = false;

  // Reconnection settings (client-side auto-reconnect on transient failure).
  bool _autoReconnect = false;
  int _maxReconnectAttempts = 3;
  Duration _reconnectDelay = const Duration(seconds: 2);
  int _clientReconnectAttempts = 0;
  int _serverReconnectAttempts = 0;
  int _maxServerReconnectAttempts = 0;
  Duration _serverReconnectCheckInterval = const Duration(seconds: 5);

  // Direct callback fields preserved from 0.1.0 surface (G6). Config
  // also accepts them; either path works.
  TransportErrorCallback? onTransportError;
  TransportClosedCallback? onTransportClosed;
  TransportReconnectedCallback? onTransportReconnected;
  ServerReconnectRequestedCallback? onServerReconnectRequested;

  bool get isInitialized => _isInitialized;
  bool get isServerActive => _isServerActive;
  bool get isWaitingForServerReconnection => _isWaitingForServerReconnection;
  String get serverTransportType => _config.serverTransportType;
  String get clientTransportType => _config.clientTransportType;
  ServerShutdownBehavior get serverShutdownBehavior =>
      _config.serverShutdownBehavior;

  /// Configure auto-reconnect behavior for the client side.
  void setAutoReconnect({
    bool enabled = true,
    int maxAttempts = 3,
    Duration delay = const Duration(seconds: 2),
  }) {
    _autoReconnect = enabled;
    _maxReconnectAttempts = maxAttempts;
    _reconnectDelay = delay;
  }

  /// Configure server reconnection options. Only used when the
  /// configured behavior is `waitForReconnection`.
  void setServerReconnectionOptions({
    int maxAttempts = 0, // 0 = unbounded
    Duration checkInterval = const Duration(seconds: 5),
  }) {
    _maxServerReconnectAttempts = maxAttempts;
    _serverReconnectCheckInterval = checkInterval;
  }

  /// Initialize the bridge: build transports via mcp_server / mcp_client
  /// factories, start forwarding. Throws [UnknownTransportTypeException]
  /// if either transport type-name is not recognised; throws transport-
  /// specific exceptions on connection failure.
  Future<void> initialize() async {
    if (_isInitialized) {
      _logger.warning('Bridge already initialized');
      return;
    }
    _logger.info(
        'Initializing bridge: ${_config.serverTransportType} <=> ${_config.clientTransportType}');

    try {
      _clientTransport = _testClientTransport ??
          await _buildClientTransport(
              _config.clientTransportType, _config.clientConfig);
      _logger.info('Client transport ready');

      _serverTransport = _testServerTransport ??
          await _buildServerTransport(
              _config.serverTransportType, _config.serverConfig);
      _logger.info('Server transport ready');
      _isServerActive = true;

      _setupForwarding();
      _isInitialized = true;
      _logger.info('Bridge initialized');
    } catch (e, st) {
      _logger.severe('Bridge initialization failed: $e');
      // Best-effort dispatch of the error against whichever side failed.
      _dispatchError(
        _serverTransport == null
            ? TransportSource.server
            : TransportSource.client,
        e,
        st,
      );
      // Roll back any partial init.
      _serverTransport?.close();
      _clientTransport?.close();
      _serverTransport = null;
      _clientTransport = null;
      _isServerActive = false;
      _isInitialized = false;
      rethrow;
    }
  }

  void _setupForwarding() {
    _router = MessageRouter(
      serverTransport: _serverTransport!,
      clientTransport: _clientTransport!,
      logger: _logger,
      onError: _dispatchError,
    )..start();

    // Server-side close.
    _serverTransport!.onClose.then((_) {
      _logger.info('Server transport closed');
      _isServerActive = false;
      _dispatchClosed(TransportSource.server);
      if (_isShuttingDown) return;
      switch (_config.serverShutdownBehavior) {
        case ServerShutdownBehavior.shutdownBridge:
          shutdown();
          break;
        case ServerShutdownBehavior.waitForReconnection:
          _handleServerDisconnection();
          break;
      }
    });

    // Client-side close.
    _clientTransport!.onClose.then((_) {
      _logger.info('Client transport closed');
      _dispatchClosed(TransportSource.client);
      if (!_isShuttingDown && _isServerActive && _autoReconnect) {
        _attemptClientReconnect();
      }
    });
  }

  Future<void> _handleServerDisconnection() async {
    if (_isWaitingForServerReconnection) return;
    _isWaitingForServerReconnection = true;
    _serverReconnectAttempts = 0;

    _clientTransport?.close();
    _clientTransport = null;
    _logger.info('Waiting for server reconnection');

    while (_isWaitingForServerReconnection && !_isShuttingDown) {
      _serverReconnectAttempts++;
      if (_maxServerReconnectAttempts > 0 &&
          _serverReconnectAttempts > _maxServerReconnectAttempts) {
        _logger.severe('Max server reconnect attempts reached');
        await shutdown();
        return;
      }

      var shouldRetry = true;
      final cb = onServerReconnectRequested ??
          _config.onServerReconnectRequested;
      if (cb != null) {
        try {
          shouldRetry = await cb();
        } catch (e, st) {
          _logger.severe('Reconnect callback threw: $e');
          _dispatchError(TransportSource.server, e, st);
          shouldRetry = false;
        }
      }
      if (!shouldRetry) {
        await shutdown();
        return;
      }

      try {
        if (_testNextServerTransport != null) {
          _serverTransport = _testNextServerTransport;
          _testNextServerTransport = null;
        } else {
          _serverTransport = await _buildServerTransport(
              _config.serverTransportType, _config.serverConfig);
        }
        _isServerActive = true;
        _isWaitingForServerReconnection = false;

        if (_testNextClientTransport != null) {
          _clientTransport = _testNextClientTransport;
          _testNextClientTransport = null;
        } else {
          _clientTransport = await _buildClientTransport(
              _config.clientTransportType, _config.clientConfig);
        }

        _setupForwarding();
        _dispatchReconnected(TransportSource.server);
        return;
      } catch (e, st) {
        _logger.severe('Server reconnect failed: $e');
        _dispatchError(TransportSource.server, e, st);
      }

      await Future<void>.delayed(_serverReconnectCheckInterval);
    }
  }

  Future<void> _attemptClientReconnect() async {
    if (_isShuttingDown || !_isServerActive) return;
    _clientReconnectAttempts++;
    if (_clientReconnectAttempts > _maxReconnectAttempts) {
      _logger.severe('Max client reconnect attempts reached');
      return;
    }
    await Future<void>.delayed(_reconnectDelay);
    if (!_isServerActive) return;

    try {
      if (_testNextClientTransport != null) {
        _clientTransport = _testNextClientTransport;
        _testNextClientTransport = null;
      } else {
        _clientTransport = await _buildClientTransport(
            _config.clientTransportType, _config.clientConfig);
      }
      await _router?.stop();
      _setupForwarding();
      _clientReconnectAttempts = 0;
      _dispatchReconnected(TransportSource.client);
    } catch (e, st) {
      _logger.severe('Client reconnect failed: $e');
      _dispatchError(TransportSource.client, e, st);
      if (_isServerActive) _attemptClientReconnect();
    }
  }

  void _dispatchError(TransportSource side, Object e, StackTrace? st) {
    (onTransportError ?? _config.onTransportError)?.call(side, e, st);
  }

  void _dispatchClosed(TransportSource side) {
    (onTransportClosed ?? _config.onTransportClosed)?.call(side);
  }

  void _dispatchReconnected(TransportSource side) {
    (onTransportReconnected ?? _config.onTransportReconnected)?.call(side);
  }

  /// Tear down the bridge. Idempotent.
  Future<void> shutdown() async {
    if (!_isInitialized || _isShuttingDown) return;
    _isShuttingDown = true;
    _logger.info('Shutting down bridge');
    _isWaitingForServerReconnection = false;

    await _router?.stop();
    _router = null;

    _serverTransport?.close();
    _serverTransport = null;
    _isServerActive = false;

    _clientTransport?.close();
    _clientTransport = null;

    _isInitialized = false;
    _clientReconnectAttempts = 0;
    _serverReconnectAttempts = 0;
    _isShuttingDown = false;
    _logger.info('Bridge shutdown complete');
  }

  // --- Transport selection ------------------------------------------

  /// Map a transport-type name + config to the `mcp_server` 2.x
  /// `TransportConfig` variant. Pure mapping, no I/O — separated from
  /// the factory call so it can be unit-tested without real network /
  /// process. Throws [UnknownTransportTypeException] on unknown names.
  @visibleForTesting
  static server.TransportConfig serverTransportConfigFor(
      String type, Map<String, dynamic> cfg) {
    switch (type) {
      case 'stdio':
        return const server.TransportConfig.stdio();
      case 'sse':
        return server.TransportConfig.sse(
          endpoint: cfg['endpoint'] as String? ?? '/sse',
          messagesEndpoint: cfg['messagesEndpoint'] as String? ?? '/message',
          host: cfg['host'] as String? ?? 'localhost',
          port: cfg['port'] as int? ?? 8080,
          fallbackPorts:
              (cfg['fallbackPorts'] as List?)?.cast<int>() ?? const <int>[],
          authToken: cfg['authToken'] as String?,
        );
      case 'streamableHttp':
        return server.TransportConfig.streamableHttp(
          endpoint: cfg['endpoint'] as String? ?? '/mcp',
          messagesEndpoint:
              cfg['messagesEndpoint'] as String? ?? '/messages',
          host: cfg['host'] as String? ?? 'localhost',
          port: cfg['port'] as int? ?? 8080,
          fallbackPorts:
              (cfg['fallbackPorts'] as List?)?.cast<int>() ?? const <int>[],
          authToken: cfg['authToken'] as String?,
          isJsonResponseEnabled:
              cfg['isJsonResponseEnabled'] as bool? ?? false,
        );
      default:
        throw UnknownTransportTypeException(
            type, 'server', _supportedTransportTypes);
    }
  }

  /// Build a server-side transport from the configured type-name and
  /// config map. The first three cases (`stdio` / `sse` /
  /// `streamableHttp`) delegate to `mcp_server.McpServer.createTransport`;
  /// the remaining five are implemented inside `lib/src/transport/`.
  Future<server.ServerTransport> _buildServerTransport(
      String type, Map<String, dynamic> cfg) async {
    switch (type) {
      case 'stdio':
      case 'sse':
      case 'streamableHttp':
        final tc = serverTransportConfigFor(type, cfg);
        final result = server.McpServer.createTransport(tc);
        if (result.isFailure) throw result.failureOrNull!;
        return await result.successOrNull!;
      case 'websocket':
        final t = WebSocketServerTransport(cfg);
        await t.start();
        return t;
      case 'tcp':
        final t = TcpServerTransport(cfg);
        await t.start();
        return t;
      case 'serial':
        final t = SerialServerTransport(cfg);
        await t.start();
        return t;
      case 'usb':
        final t = UsbServerTransport(cfg);
        await t.start();
        return t;
      case 'ble':
        final t = BleServerTransport(cfg);
        await t.start();
        return t;
      default:
        throw UnknownTransportTypeException(
            type, 'server', _supportedTransportTypes);
    }
  }

  /// Build a client-side transport from the configured type-name and
  /// config map. Calls the matching `mcp_client.McpClient.createX(...)`
  /// factory directly.
  Future<client.ClientTransport> _buildClientTransport(
      String type, Map<String, dynamic> cfg) async {
    switch (type) {
      case 'stdio':
        final command = cfg['command'];
        if (command is! String) {
          throw ArgumentError(
              'stdio client transport requires a `command` (String) config field');
        }
        final r = await client.McpClient.createStdioTransport(
          command: command,
          arguments: (cfg['arguments'] as List?)?.cast<String>() ?? const [],
          workingDirectory: cfg['workingDirectory'] as String?,
          environment: (cfg['environment'] is Map)
              ? Map<String, String>.from(cfg['environment'] as Map)
              : null,
        );
        if (r.isFailure) throw r.failureOrNull!;
        return r.successOrNull!;
      case 'sse':
        final serverUrl = cfg['serverUrl'];
        if (serverUrl is! String) {
          throw ArgumentError(
              'sse client transport requires a `serverUrl` (String) config field');
        }
        final r = await client.McpClient.createSseTransport(
          serverUrl: serverUrl,
          headers: (cfg['headers'] is Map)
              ? Map<String, String>.from(cfg['headers'] as Map)
              : null,
        );
        if (r.isFailure) throw r.failureOrNull!;
        return r.successOrNull!;
      case 'streamableHttp':
        final baseUrl = cfg['baseUrl'];
        if (baseUrl is! String) {
          throw ArgumentError(
              'streamableHttp client transport requires a `baseUrl` (String) config field');
        }
        Duration? timeout;
        final t = cfg['timeoutMs'];
        if (t is int) timeout = Duration(milliseconds: t);
        final r = await client.McpClient.createStreamableHttpTransport(
          baseUrl: baseUrl,
          headers: (cfg['headers'] is Map)
              ? Map<String, String>.from(cfg['headers'] as Map)
              : null,
          timeout: timeout,
          maxConcurrentRequests: cfg['maxConcurrentRequests'] as int?,
          useHttp2: cfg['useHttp2'] as bool?,
        );
        if (r.isFailure) throw r.failureOrNull!;
        return r.successOrNull!;
      case 'websocket':
        final t = WebSocketClientTransport(cfg);
        await t.start();
        return t;
      case 'tcp':
        final t = TcpClientTransport(cfg);
        await t.start();
        return t;
      case 'serial':
        final t = SerialClientTransport(cfg);
        await t.start();
        return t;
      case 'usb':
        final t = UsbClientTransport(cfg);
        await t.start();
        return t;
      case 'ble':
        final t = BleClientTransport(cfg);
        await t.start();
        return t;
      default:
        throw UnknownTransportTypeException(
            type, 'client', _supportedTransportTypes);
    }
  }

  // --- Convenience constructors --------------------------------------

  /// STDIO (server side, e.g. running as subprocess) bridged to SSE
  /// client (consumes a remote SSE MCP server).
  static Future<McpBridge> createStdioToSseBridge({
    required String serverUrl,
    Map<String, String>? headers,
    ServerShutdownBehavior serverShutdownBehavior =
        ServerShutdownBehavior.shutdownBridge,
  }) async {
    final config = McpBridgeConfig(
      serverTransportType: 'stdio',
      clientTransportType: 'sse',
      serverConfig: const {},
      clientConfig: {
        'serverUrl': serverUrl,
        if (headers != null) 'headers': headers,
      },
      serverShutdownBehavior: serverShutdownBehavior,
    );
    return McpBridge(config);
  }

  /// SSE (server side, listens on a port) bridged to STDIO client (spawns
  /// a subprocess MCP server).
  static Future<McpBridge> createSseToStdioBridge({
    required String command,
    List<String> arguments = const [],
    String? workingDirectory,
    Map<String, String>? environment,
    int port = 8080,
    String endpoint = '/sse',
    String messagesEndpoint = '/messages',
    List<int>? fallbackPorts,
    String? authToken,
    ServerShutdownBehavior serverShutdownBehavior =
        ServerShutdownBehavior.shutdownBridge,
  }) async {
    final config = McpBridgeConfig(
      serverTransportType: 'sse',
      clientTransportType: 'stdio',
      serverConfig: {
        'port': port,
        'endpoint': endpoint,
        'messagesEndpoint': messagesEndpoint,
        if (fallbackPorts != null) 'fallbackPorts': fallbackPorts,
        if (authToken != null) 'authToken': authToken,
      },
      clientConfig: {
        'command': command,
        'arguments': arguments,
        if (workingDirectory != null) 'workingDirectory': workingDirectory,
        if (environment != null) 'environment': environment,
      },
      serverShutdownBehavior: serverShutdownBehavior,
    );
    return McpBridge(config);
  }
}

/// Compat alias retained from 0.1.0.
typedef MCPBridge = McpBridge;
