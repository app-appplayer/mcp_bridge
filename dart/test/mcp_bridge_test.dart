import 'dart:async';
import 'package:test/test.dart';
import 'package:mcp_bridge/mcp_bridge.dart';
import 'package:mcp_client/mcp_client.dart' as client;
import 'package:mcp_server/mcp_server.dart' as server;
import 'dart:io';

// Mock classes to help with testing
class MockServerTransport extends server.ServerTransport {
  final StreamController<String> _messageController = StreamController<String>.broadcast();
  final Completer<void> _closeCompleter = Completer<void>();
  bool _isClosed = false;
  List<String> sentMessages = [];

  @override
  Stream<String> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) {
    if (_isClosed) throw Exception('Transport is closed');
    sentMessages.add(message.toString());
  }

  @override
  void close() {
    if (!_isClosed) {
      _isClosed = true;
      _closeCompleter.complete();
      _messageController.close();
    }
  }

  void simulateIncomingMessage(String message) {
    if (!_isClosed) {
      _messageController.add(message);
    }
  }

  void simulateError(dynamic error) {
    if (!_isClosed) {
      _messageController.addError(error);
    }
  }
}

class MockClientTransport extends client.ClientTransport {
  final StreamController<String> _messageController = StreamController<String>.broadcast();
  final Completer<void> _closeCompleter = Completer<void>();
  bool _isClosed = false;
  List<String> sentMessages = [];

  @override
  Stream<String> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) {
    if (_isClosed) throw Exception('Transport is closed');
    sentMessages.add(message.toString());
  }

  @override
  void close() {
    if (!_isClosed) {
      _isClosed = true;
      _closeCompleter.complete();
      _messageController.close();
    }
  }

  void simulateIncomingMessage(String message) {
    if (!_isClosed) {
      _messageController.add(message);
    }
  }

  void simulateError(dynamic error) {
    if (!_isClosed) {
      _messageController.addError(error);
    }
  }
}

// Helper to create mock transports for testing
class MockTransportFactory {
  static Future<server.ServerTransport> createMockServerTransport(
      String transportType, Map<String, dynamic> config) async {
    return MockServerTransport();
  }

  static Future<client.ClientTransport> createMockClientTransport(
      String transportType, Map<String, dynamic> config) async {
    return MockClientTransport();
  }
}

void main() {
  group('McpBridgeConfig Tests', () {
    test('fromJson creates correct config', () {
      final json = {
        'serverTransportType': 'stdio',
        'clientTransportType': 'sse',
        'serverConfig': {'key': 'value'},
        'clientConfig': {'url': 'http://localhost'},
        'serverShutdownBehavior': 'waitForReconnection',
      };

      final config = McpBridgeConfig.fromJson(json);

      expect(config.serverTransportType, 'stdio');
      expect(config.clientTransportType, 'sse');
      expect(config.serverConfig, {'key': 'value'});
      expect(config.clientConfig, {'url': 'http://localhost'});
      expect(config.serverShutdownBehavior, ServerShutdownBehavior.waitForReconnection);
    });

    test('toJson returns correct JSON', () {
      final config = McpBridgeConfig(
        serverTransportType: 'stdio',
        clientTransportType: 'sse',
        serverConfig: {'key': 'value'},
        clientConfig: {'url': 'http://localhost'},
        serverShutdownBehavior: ServerShutdownBehavior.waitForReconnection,
      );

      final json = config.toJson();

      expect(json['serverTransportType'], 'stdio');
      expect(json['clientTransportType'], 'sse');
      expect(json['serverConfig'], {'key': 'value'});
      expect(json['clientConfig'], {'url': 'http://localhost'});
      expect(json['serverShutdownBehavior'], 'waitForReconnection');
    });
  });

  group('McpBridge Basic Tests', () {
    late McpBridge bridge;
    late McpBridgeConfig config;

    setUp(() {
      config = McpBridgeConfig(
        serverTransportType: 'stdio',
        clientTransportType: 'sse',
        serverConfig: {},
        clientConfig: {'serverUrl': 'http://localhost:8080/sse'},
      );
      bridge = McpBridge(config);
    });

    test('Constructor initializes properties correctly', () {
      expect(bridge.isInitialized, false);
      expect(bridge.isServerActive, false);
      expect(bridge.serverTransportType, 'stdio');
      expect(bridge.clientTransportType, 'sse');
      expect(bridge.serverShutdownBehavior, ServerShutdownBehavior.shutdownBridge);
      expect(bridge.isWaitingForServerReconnection, false);
    });

    test('setAutoReconnect sets reconnection parameters', () {
      bridge.setAutoReconnect(
        enabled: true,
        maxAttempts: 5,
        delay: Duration(seconds: 3),
      );

      // This is testing private fields, which isn't ideal but necessary for this test
      // In real testing, you'd verify behavior rather than inspect fields
      final autoReconnect = (bridge as dynamic)._autoReconnect as bool;
      final maxReconnectAttempts = (bridge as dynamic)._maxReconnectAttempts as int;
      final reconnectDelay = (bridge as dynamic)._reconnectDelay as Duration;

      expect(autoReconnect, true);
      expect(maxReconnectAttempts, 5);
      expect(reconnectDelay, Duration(seconds: 3));
    });

    test('setServerReconnectionOptions sets server reconnection parameters', () {
      bridge.setServerReconnectionOptions(
        maxAttempts: 10,
        checkInterval: Duration(seconds: 7),
      );

      // This is testing private fields, which isn't ideal but necessary for this test
      final maxServerReconnectAttempts = (bridge as dynamic)._maxServerReconnectAttempts as int;
      final serverReconnectCheckInterval = (bridge as dynamic)._serverReconnectCheckInterval as Duration;

      expect(maxServerReconnectAttempts, 10);
      expect(serverReconnectCheckInterval, Duration(seconds: 7));
    });
  });

  group('McpBridge Integration Tests', () {
    // This test uses the MockTransportFactory to inject mock transports for testing
    late McpBridge bridge;
    late McpBridgeConfig config;
    late MockServerTransport mockServerTransport;
    late MockClientTransport mockClientTransport;

    // We need to patch the bridge to inject our mocks
    McpBridge patchedBridge(McpBridgeConfig config) {
      final bridge = McpBridge(config);

      // Override private methods to return our mocks
      (bridge as dynamic)._createServerTransport = (String transportType, Map<String, dynamic> config) async {
        mockServerTransport = MockServerTransport();
        return mockServerTransport;
      };

      (bridge as dynamic)._createClientTransport = (String transportType, Map<String, dynamic> config) async {
        mockClientTransport = MockClientTransport();
        return mockClientTransport;
      };

      return bridge;
    }

    setUp(() {
      config = McpBridgeConfig(
        serverTransportType: 'stdio',
        clientTransportType: 'sse',
        serverConfig: {},
        clientConfig: {'serverUrl': 'http://localhost:8080/sse'},
      );
      bridge = patchedBridge(config);
    });

    test('initialize creates transports and sets up message forwarding', () async {
      await bridge.initialize();

      expect(bridge.isInitialized, true);
      expect(bridge.isServerActive, true);
    });

    test('message forwarding from server to client works', () async {
      await bridge.initialize();

      mockServerTransport.simulateIncomingMessage('test message from server');

      // Give some time for the async processing
      await Future.delayed(Duration(milliseconds: 100));

      expect(mockClientTransport.sentMessages, contains('test message from server'));
    });

    test('message forwarding from client to server works', () async {
      await bridge.initialize();

      mockClientTransport.simulateIncomingMessage('test message from client');

      // Give some time for the async processing
      await Future.delayed(Duration(milliseconds: 100));

      expect(mockServerTransport.sentMessages, contains('test message from client'));
    });

    test('shutdown closes transports and cleans up resources', () async {
      await bridge.initialize();
      await bridge.shutdown();

      expect(bridge.isInitialized, false);
      expect(bridge.isServerActive, false);
    });

    test('transport error callbacks are triggered', () async {
      bool errorReceived = false;
      TransportSource? errorSource;

      bridge.onTransportError = (source, error, stackTrace) {
        errorReceived = true;
        errorSource = source;
      };

      await bridge.initialize();

      mockServerTransport.simulateError('Test error');

      // Give some time for the async processing
      await Future.delayed(Duration(milliseconds: 100));

      expect(errorReceived, true);
      expect(errorSource, TransportSource.server);
    });
  });

  group('McpBridge Factory Methods Tests', () {
    test('createStdioToSseBridge creates bridge with correct config', () async {
      final bridge = await McpBridge.createStdioToSseBridge(
        serverUrl: 'http://localhost:8080/sse',
        headers: {'Auth': 'token'},
        serverShutdownBehavior: ServerShutdownBehavior.waitForReconnection,
      );

      expect(bridge.serverTransportType, 'stdio');
      expect(bridge.clientTransportType, 'sse');
      expect(bridge.serverShutdownBehavior, ServerShutdownBehavior.waitForReconnection);
    });

    test('createSseToStdioBridge creates bridge with correct config', () async {
      final bridge = await McpBridge.createSseToStdioBridge(
        command: 'python',
        arguments: ['script.py'],
        port: 9000,
        endpoint: '/events',
        serverShutdownBehavior: ServerShutdownBehavior.waitForReconnection,
      );

      expect(bridge.serverTransportType, 'sse');
      expect(bridge.clientTransportType, 'stdio');
      expect(bridge.serverShutdownBehavior, ServerShutdownBehavior.waitForReconnection);
    });
  });

  group('ServerShutdownBehavior Tests', () {
    late McpBridge bridge;
    late MockServerTransport mockServerTransport;
    late MockClientTransport mockClientTransport;

    McpBridge patchedBridgeForReconnection(McpBridgeConfig config) {
      final bridge = McpBridge(config);

      (bridge as dynamic)._createServerTransport = (String transportType, Map<String, dynamic> config) async {
        mockServerTransport = MockServerTransport();
        return mockServerTransport;
      };

      (bridge as dynamic)._createClientTransport = (String transportType, Map<String, dynamic> config) async {
        mockClientTransport = MockClientTransport();
        return mockClientTransport;
      };

      return bridge;
    }

    test('waitForReconnection behavior activates when server closes', () async {
      final config = McpBridgeConfig(
        serverTransportType: 'stdio',
        clientTransportType: 'sse',
        serverConfig: {},
        clientConfig: {'serverUrl': 'http://localhost:8080/sse'},
        serverShutdownBehavior: ServerShutdownBehavior.waitForReconnection,
      );

      bridge = patchedBridgeForReconnection(config);
      bridge.setServerReconnectionOptions(maxAttempts: 1, checkInterval: Duration(milliseconds: 100));

      bool reconnectRequested = false;
      bridge.onServerReconnectRequested = () async {
        reconnectRequested = true;
        return true;
      };

      await bridge.initialize();

      // Simulate server closure
      mockServerTransport.close();

      // Give time for the reconnection logic to run
      await Future.delayed(Duration(milliseconds: 300));

      expect(reconnectRequested, true);
      expect(bridge.isWaitingForServerReconnection, false); // Should be false after reconnection attempt
    });
  });

  // Testing with real processes is challenging in unit tests, but here's a practical test for a real environment
  group('End-to-End Tests', () {
    test('STDIO to SSE bridge with echo server', () async {
      // Skip in CI environment where we can't start real processes
      if (Platform.environment.containsKey('CI')) {
        return;
      }

      // This test requires that an echo server is available
      // We'll use a simple Node.js express server as an example

      // Start echo server in a separate process
      final serverProcess = await Process.start('node', [
        '-e',
        '''
        const express = require('express');
        const bodyParser = require('body-parser');
        const app = express();
        app.use(bodyParser.json());
        app.get('/sse', (req, res) => {
          res.setHeader('Content-Type', 'text/event-stream');
          res.setHeader('Cache-Control', 'no-cache');
          res.setHeader('Connection', 'keep-alive');
          
          const interval = setInterval(() => {
            res.write('data: {"type":"ping"}\\n\\n');
          }, 1000);
          
          req.on('close', () => clearInterval(interval));
        });
        app.post('/messages', (req, res) => {
          console.log('Received:', req.body);
          res.json({status: 'ok'});
        });
        app.listen(8081, () => console.log('Echo server running on port 8081'));
        '''
      ]);

      // Wait for server to start
      await Future.delayed(Duration(seconds: 3));

      try {
        // Create STDIO to SSE bridge
        final bridge = await McpBridge.createStdioToSseBridge(
          serverUrl: 'http://localhost:8081/sse',
          headers: {'Content-Type': 'application/json'},
        );

        // Set up callbacks
        bridge.onTransportError = (source, error, stackTrace) {
          print('Transport error from $source: $error');
        };

        // Initialize bridge
        await bridge.initialize();

        // Keep bridge running for a few seconds
        await Future.delayed(Duration(seconds: 5));

        // Shutdown bridge
        await bridge.shutdown();

        // Verify bridge works correctly
        // This is a basic check - in a real test, we would verify message exchange
        expect(bridge.isInitialized, false);
      } finally {
        // Clean up server process
        serverProcess.kill();
      }
    }, timeout: Timeout(Duration(minutes: 1)));
  });
}