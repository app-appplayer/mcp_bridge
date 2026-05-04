/// Server shutdown behavior options. Spec: SRS § FR4.1.
enum ServerShutdownBehavior {
  /// Completely shutdown the bridge when server is closed.
  shutdownBridge,

  /// Keep the bridge alive and wait for server reconnection.
  waitForReconnection,
}

/// Identifies which side of the bridge an event originated from.
enum TransportSource {
  server,
  client,
}

/// Transport error callback (FR4.2).
typedef TransportErrorCallback = void Function(
  TransportSource source,
  Object error,
  StackTrace? stackTrace,
);

/// Transport closed callback (FR4.3).
typedef TransportClosedCallback = void Function(TransportSource source);

/// Transport reconnected callback (FR4.4).
typedef TransportReconnectedCallback = void Function(TransportSource source);

/// Server reconnect requested callback (FR4.5). Returning `true` instructs
/// the bridge to attempt reconnection; `false` declines and the bridge
/// proceeds to shutdown.
typedef ServerReconnectRequestedCallback = Future<bool> Function();

/// Construction-time configuration for [McpBridge]. Spec:
/// `docs/03_DDD/core-config.md`.
class McpBridgeConfig {
  /// Registered server-side transport name (e.g. `"stdio"`, `"sse"`).
  /// Resolved against [BridgeTransportRegistry] at `initialize` time.
  final String serverTransportType;

  /// Registered client-side transport name.
  final String clientTransportType;

  /// Server-side transport configuration. Pass-through to the factory.
  final Map<String, dynamic> serverConfig;

  /// Client-side transport configuration. Pass-through to the factory.
  final Map<String, dynamic> clientConfig;

  /// Behavior when the server-side transport closes.
  final ServerShutdownBehavior serverShutdownBehavior;

  /// Optional lifecycle callbacks (since 0.2.0). All four are optional;
  /// absence MUST NOT crash the bridge.
  final TransportErrorCallback? onTransportError;
  final TransportClosedCallback? onTransportClosed;
  final TransportReconnectedCallback? onTransportReconnected;
  final ServerReconnectRequestedCallback? onServerReconnectRequested;

  const McpBridgeConfig({
    required this.serverTransportType,
    required this.clientTransportType,
    required this.serverConfig,
    required this.clientConfig,
    this.serverShutdownBehavior = ServerShutdownBehavior.shutdownBridge,
    this.onTransportError,
    this.onTransportClosed,
    this.onTransportReconnected,
    this.onServerReconnectRequested,
  });

  /// Create a config from a JSON map.
  factory McpBridgeConfig.fromJson(Map<String, dynamic> json) {
    var behavior = ServerShutdownBehavior.shutdownBridge;
    final raw = json['serverShutdownBehavior'];
    if (raw is String && raw.toLowerCase() == 'waitforreconnection') {
      behavior = ServerShutdownBehavior.waitForReconnection;
    }
    return McpBridgeConfig(
      serverTransportType: json['serverTransportType'] as String,
      clientTransportType: json['clientTransportType'] as String,
      serverConfig: (json['serverConfig'] as Map?)?.cast<String, dynamic>() ?? {},
      clientConfig: (json['clientConfig'] as Map?)?.cast<String, dynamic>() ?? {},
      serverShutdownBehavior: behavior,
    );
  }

  Map<String, dynamic> toJson() => {
        'serverTransportType': serverTransportType,
        'clientTransportType': clientTransportType,
        'serverConfig': serverConfig,
        'clientConfig': clientConfig,
        'serverShutdownBehavior':
            serverShutdownBehavior.toString().split('.').last,
      };
}
