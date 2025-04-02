import 'dart:async';
import 'package:mcp_client/mcp_client.dart' as client;
import 'package:mcp_server/mcp_server.dart' as server;
import 'logger.dart';

export 'logger.dart';

/// Server shutdown behavior options
enum ServerShutdownBehavior {
  /// Completely shutdown the bridge when server is closed
  shutdownBridge,

  /// Keep the bridge alive and wait for server reconnection
  waitForReconnection,
}

/// Bridge configuration for connecting MCP transports
class McpBridgeConfig {
  /// Connection type for the server side
  final String serverTransportType;

  /// Connection type for the client side
  final String clientTransportType;

  /// Configuration options for server transport
  final Map<String, dynamic> serverConfig;

  /// Configuration options for client transport
  final Map<String, dynamic> clientConfig;

  /// Server shutdown behavior
  final ServerShutdownBehavior serverShutdownBehavior;

  McpBridgeConfig({
    required this.serverTransportType,
    required this.clientTransportType,
    required this.serverConfig,
    required this.clientConfig,
    this.serverShutdownBehavior = ServerShutdownBehavior.shutdownBridge,
  });

  /// Create a config from a JSON map
  factory McpBridgeConfig.fromJson(Map<String, dynamic> json) {
    ServerShutdownBehavior behavior = ServerShutdownBehavior.shutdownBridge;
    if (json['serverShutdownBehavior'] != null) {
      final behaviorStr = json['serverShutdownBehavior'].toString().toLowerCase();
      if (behaviorStr == 'waitforreconnection') {
        behavior = ServerShutdownBehavior.waitForReconnection;
      }
    }

    return McpBridgeConfig(
      serverTransportType: json['serverTransportType'],
      clientTransportType: json['clientTransportType'],
      serverConfig: json['serverConfig'] ?? {},
      clientConfig: json['clientConfig'] ?? {},
      serverShutdownBehavior: behavior,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'serverTransportType': serverTransportType,
      'clientTransportType': clientTransportType,
      'serverConfig': serverConfig,
      'clientConfig': clientConfig,
      'serverShutdownBehavior': serverShutdownBehavior.toString().split('.').last,
    };
  }
}

/// Transport source identification
enum TransportSource {
  server,
  client,
}

/// Transport error callback type
typedef TransportErrorCallback = void Function(
    TransportSource source, dynamic error, StackTrace? stackTrace);

/// Transport closed callback type
typedef TransportClosedCallback = void Function(TransportSource source);

/// Transport reconnected callback type
typedef TransportReconnectedCallback = void Function(TransportSource source);

/// Server reconnect requested callback type
typedef ServerReconnectRequestedCallback = Future<bool> Function();

typedef MCPBridge = McpBridge;

/// Core MCP Bridge class
class McpBridge {
  final McpBridgeConfig _config;
  final Logger _logger = Logger.getLogger('mcp_bridge');

  server.ServerTransport? _serverTransport;
  client.ClientTransport? _clientTransport;

  List<StreamSubscription> _subscriptions = [];
  bool _isInitialized = false;
  bool _isShuttingDown = false;
  bool _isServerActive = false;
  bool _isWaitingForServerReconnection = false;

  // Reconnection settings
  bool _autoReconnect = false;
  int _maxReconnectAttempts = 3;
  Duration _reconnectDelay = const Duration(seconds: 2);
  int _clientReconnectAttempts = 0;
  int _serverReconnectAttempts = 0;
  int _maxServerReconnectAttempts = 0;
  Duration _serverReconnectCheckInterval = const Duration(seconds: 5);

  // Callbacks
  TransportErrorCallback? onTransportError;
  TransportClosedCallback? onTransportClosed;
  TransportReconnectedCallback? onTransportReconnected;
  ServerReconnectRequestedCallback? onServerReconnectRequested;

  McpBridge(this._config);

  /// Check if the bridge is initialized
  bool get isInitialized => _isInitialized;

  /// Check if the server is active
  bool get isServerActive => _isServerActive;

  /// Get the server transport type
  String get serverTransportType => _config.serverTransportType;

  /// Get the client transport type
  String get clientTransportType => _config.clientTransportType;

  /// Get the current server shutdown behavior
  ServerShutdownBehavior get serverShutdownBehavior => _config.serverShutdownBehavior;

  /// Check if the bridge is waiting for server reconnection
  bool get isWaitingForServerReconnection => _isWaitingForServerReconnection;

  /// Configure auto-reconnect settings for client
  void setAutoReconnect({
    bool enabled = true,
    int maxAttempts = 3,
    Duration delay = const Duration(seconds: 2),
  }) {
    _autoReconnect = enabled;
    _maxReconnectAttempts = maxAttempts;
    _reconnectDelay = delay;
    _logger.debug('Auto-reconnect ${enabled ? 'enabled' : 'disabled'}, max attempts: $maxAttempts, delay: ${delay.inMilliseconds}ms');
  }

  /// Configure server reconnection settings (only used when serverShutdownBehavior is waitForReconnection)
  void setServerReconnectionOptions({
    int maxAttempts = 0, // 0 = infinite attempts
    Duration checkInterval = const Duration(seconds: 5),
  }) {
    _maxServerReconnectAttempts = maxAttempts;
    _serverReconnectCheckInterval = checkInterval;
    _logger.debug('Server reconnection options set: maxAttempts=$maxAttempts, checkInterval=${checkInterval.inMilliseconds}ms');
  }

  /// Initialize the bridge and connect transports
  Future<void> initialize() async {
    if (_isInitialized) {
      _logger.warning('Bridge is already initialized');
      return;
    }

    _logger.info('Initializing MCP Bridge');
    _logger.info('Server transport: ${_config.serverTransportType}, Client transport: ${_config.clientTransportType}');
    _logger.info('Server shutdown behavior: ${_config.serverShutdownBehavior}');

    try {
      // Create client transport
      _clientTransport = await _createClientTransport(
        _config.clientTransportType,
        _config.clientConfig,
      );
      _logger.info('Client transport created successfully');

      // Create server transport
      _serverTransport = await _createServerTransport(
        _config.serverTransportType,
        _config.serverConfig,
      );
      _logger.info('Server transport created successfully');
      _isServerActive = true;

      // Set up message forwarding
      _setupMessageForwarding();

      _isInitialized = true;
      _logger.info('MCP Bridge initialized successfully');
    } catch (e, stackTrace) {
      _logger.error('Failed to initialize bridge: $e');
      _logger.debug(stackTrace.toString());

      // Notify about the error
      onTransportError?.call(
          _serverTransport == null ? TransportSource.server : TransportSource.client,
          e,
          stackTrace
      );

      await shutdown();
      rethrow;
    }
  }

  /// Create server transport based on type
  Future<server.ServerTransport> _createServerTransport(
      String transportType,
      Map<String, dynamic> config,
      ) async {
    switch (transportType.toLowerCase()) {
      case 'stdio':
        return server.McpServer.createStdioTransport();

      case 'sse':
        final endpoint = config['endpoint'] ?? '/sse';
        final port = config['port'] ?? 8080;
        final messagesEndpoint = config['messagesEndpoint'] ?? '/messages';

        List<int>? fallbackPorts;
        if (config['fallbackPorts'] is List) {
          fallbackPorts = List<int>.from(config['fallbackPorts']);
        }

        return server.McpServer.createSseTransport(
          endpoint: endpoint,
          port: port,
          messagesEndpoint: messagesEndpoint,
          fallbackPorts: fallbackPorts,
          authToken: config['authToken'],
        );

      default:
        throw UnsupportedError('Unsupported server transport type: $transportType');
    }
  }

  /// Create client transport based on type
  Future<client.ClientTransport> _createClientTransport(
      String transportType,
      Map<String, dynamic> config,
      ) async {
    switch (transportType.toLowerCase()) {
      case 'stdio':
        final command = config['command'];
        if (command == null) {
          throw ArgumentError('command is required for stdio client transport');
        }

        List<String> arguments = [];
        if (config['arguments'] is List) {
          arguments = List<String>.from(config['arguments']);
        }

        return await client.McpClient.createStdioTransport(
          command: command,
          arguments: arguments,
          workingDirectory: config['workingDirectory'],
          environment: config['environment'] != null
              ? Map<String, String>.from(config['environment'])
              : null,
        );

      case 'sse':
        final serverUrl = config['serverUrl'];
        if (serverUrl == null) {
          throw ArgumentError('serverUrl is required for SSE client transport');
        }

        Map<String, String>? headers;
        if (config['headers'] is Map) {
          headers = Map<String, String>.from(config['headers']);
        }

        return await client.McpClient.createSseTransport(
          serverUrl: serverUrl,
          headers: headers,
        );

      default:
        throw UnsupportedError('Unsupported client transport type: $transportType');
    }
  }

  /// Set up message forwarding between transports
  void _setupMessageForwarding() {
    // Clear existing subscriptions
    for (var sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();

    // Forward messages from server to client transport
    var serverSub = _serverTransport!.onMessage.listen(
            (message) {
          _logger.trace('Server -> Client: $message');
          // Add enhanced logging for server to client messages
          _logger.info('Server->Client message received. Length: ${message.length}');

          try {
            _clientTransport!.send(message);
            // Add confirmation log for successful forwarding
            _logger.info('Server->Client message forwarding completed successfully');
          } catch (e, stackTrace) {
            _logger.error('Error sending message to client: $e');
            onTransportError?.call(TransportSource.client, e, stackTrace);
          }
        },
        onError: (error, stackTrace) {
          _logger.error('Error in server transport: $error');
          onTransportError?.call(TransportSource.server, error, stackTrace);
        }
    );
    _subscriptions.add(serverSub);

    // Forward messages from client to server transport
    var clientSub = _clientTransport!.onMessage.listen(
            (message) {
          _logger.trace('Client -> Server: $message');
          // Add enhanced logging for client to server messages
          _logger.info('Client->Server message received. Length: ${message.length}');

          try {
            _serverTransport!.send(message);
            // Add confirmation log for successful forwarding
            _logger.info('Client->Server message forwarding completed successfully');
          } catch (e, stackTrace) {
            _logger.error('Error sending message to server: $e');
            onTransportError?.call(TransportSource.server, e, stackTrace);
          }
        },
        onError: (error, stackTrace) {
          _logger.error('Error in client transport: $error');
          onTransportError?.call(TransportSource.client, error, stackTrace);
        }
    );
    _subscriptions.add(clientSub);

    // Handle server transport closure
    _serverTransport!.onClose.then((_) {
      _logger.info('Server transport closed');
      _isServerActive = false;
      onTransportClosed?.call(TransportSource.server);

      // Handle server shutdown based on configuration
      if (!_isShuttingDown) {
        if (_config.serverShutdownBehavior == ServerShutdownBehavior.shutdownBridge) {
          _logger.info('Server transport closed, shutting down bridge');
          shutdown();
        } else if (_config.serverShutdownBehavior == ServerShutdownBehavior.waitForReconnection) {
          _logger.info('Server transport closed, entering wait for reconnection mode');
          _handleServerDisconnection();
        }
      }
    });

    // Handle client transport closure
    _clientTransport!.onClose.then((_) {
      _logger.info('Client transport closed');
      onTransportClosed?.call(TransportSource.client);

      // Attempt client reconnection only when server is active
      if (!_isShuttingDown && _isServerActive && _autoReconnect) {
        _attemptClientReconnect();
      }
    });
  }

  /// Handle server disconnection with waitForReconnection behavior
  void _handleServerDisconnection() async {
    if (_isWaitingForServerReconnection) return;

    _isWaitingForServerReconnection = true;
    _serverReconnectAttempts = 0;

    // 클라이언트 연결 종료
    if (_clientTransport != null) {
      _logger.info('Closing client transport while waiting for server reconnection');
      _clientTransport!.close();
      _clientTransport = null;
    }

    _logger.info('Waiting for server to reconnect...');

    while (_isWaitingForServerReconnection && !_isShuttingDown) {
      _serverReconnectAttempts++;

      // 최대 재시도 횟수 체크 (0인 경우 무한 재시도)
      if (_maxServerReconnectAttempts > 0 && _serverReconnectAttempts > _maxServerReconnectAttempts) {
        _logger.error('Max server reconnect attempts ($_serverReconnectAttempts) reached, shutting down bridge');
        await shutdown();
        return;
      }

      _logger.info('Checking for server reconnection (attempt $_serverReconnectAttempts${_maxServerReconnectAttempts > 0 ? '/$_maxServerReconnectAttempts' : ''})');

      // 애플리케이션에서 서버 재연결 확인 로직 호출
      bool shouldTryServerReconnect = true;
      if (onServerReconnectRequested != null) {
        try {
          shouldTryServerReconnect = await onServerReconnectRequested!();
        } catch (e) {
          _logger.error('Error in server reconnect callback: $e');
          shouldTryServerReconnect = false;
        }
      }

      if (!shouldTryServerReconnect) {
        _logger.info('Server reconnection cancelled by application');
        await shutdown();
        return;
      }

      // 서버 재연결 시도
      try {
        _serverTransport = await _createServerTransport(
          _config.serverTransportType,
          _config.serverConfig,
        );
        _logger.info('Server transport reconnected successfully');
        _isServerActive = true;
        _isWaitingForServerReconnection = false;

        // 클라이언트 재연결
        _clientTransport = await _createClientTransport(
          _config.clientTransportType,
          _config.clientConfig,
        );
        _logger.info('Client transport reconnected successfully');

        // 메시지 포워딩 재설정
        _setupMessageForwarding();

        // 재연결 성공 알림
        onTransportReconnected?.call(TransportSource.server);
        return;
      } catch (e, stackTrace) {
        _logger.error('Failed to reconnect server transport: $e');
        if (onTransportError != null) {
          onTransportError!(TransportSource.server, e, stackTrace);
        }
      }

      // 대기 후 재시도
      await Future.delayed(_serverReconnectCheckInterval);
    }
  }

  /// Attempt to reconnect client transport
  Future<void> _attemptClientReconnect() async {
    if (_isShuttingDown || !_isServerActive) return;

    _clientReconnectAttempts++;

    if (_clientReconnectAttempts > _maxReconnectAttempts) {
      _logger.error('Max client reconnect attempts ($_clientReconnectAttempts) reached');
      return;
    }

    _logger.info('Attempting to reconnect client transport (attempt $_clientReconnectAttempts/$_maxReconnectAttempts)');

    try {
      // Wait before reconnecting
      await Future.delayed(_reconnectDelay);

      // 서버가 여전히 살아있는지 확인
      if (!_isServerActive) {
        _logger.warning('Server transport is no longer active, skipping client reconnection');
        return;
      }

      // 클라이언트 트랜스포트 재생성
      _clientTransport = await _createClientTransport(
        _config.clientTransportType,
        _config.clientConfig,
      );
      _logger.info('Client transport reconnected successfully');

      // 메시지 포워딩 재설정
      _setupMessageForwarding();

      // 카운터 리셋
      _clientReconnectAttempts = 0;

      // 재연결 성공 알림
      onTransportReconnected?.call(TransportSource.client);
    } catch (e, stackTrace) {
      _logger.error('Failed to reconnect client transport: $e');
      onTransportError?.call(TransportSource.client, e, stackTrace);

      // 서버가 여전히 활성화되어 있으면 재시도
      if (_isServerActive) {
        _attemptClientReconnect();
      }
    }
  }

  /// Create a STDIO Server to SSE Client bridge
  static Future<McpBridge> createStdioToSseBridge({
    required String serverUrl,
    Map<String, String>? headers,
    ServerShutdownBehavior serverShutdownBehavior = ServerShutdownBehavior.shutdownBridge,
  }) async {
    final config = McpBridgeConfig(
      serverTransportType: 'stdio',
      clientTransportType: 'sse',
      serverConfig: {},
      clientConfig: {
        'serverUrl': serverUrl,
        if (headers != null) 'headers': headers,
      },
      serverShutdownBehavior: serverShutdownBehavior,
    );

    final bridge = McpBridge(config);
    return bridge;
  }

  /// Create an SSE Server to STDIO Client bridge
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
    ServerShutdownBehavior serverShutdownBehavior = ServerShutdownBehavior.shutdownBridge,
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

    final bridge = McpBridge(config);
    return bridge;
  }

  /// Shutdown the bridge
  Future<void> shutdown() async {
    if (!_isInitialized || _isShuttingDown) {
      return;
    }

    _isShuttingDown = true;
    _logger.info('Shutting down MCP Bridge...');

    _isWaitingForServerReconnection = false;

    for (var sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();

    // 서버 종료
    if (_serverTransport != null) {
      _serverTransport!.close();
      _serverTransport = null;
    }
    _isServerActive = false;

    // 클라이언트 종료
    if (_clientTransport != null) {
      _clientTransport!.close();
      _clientTransport = null;
    }

    _isInitialized = false;
    _clientReconnectAttempts = 0;
    _serverReconnectAttempts = 0;
    _isShuttingDown = false;
    _logger.info('MCP Bridge shutdown complete');
  }
}