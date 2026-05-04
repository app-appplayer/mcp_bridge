import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:mcp_bridge/mcp_bridge.dart';

final Logger _logger = Logger.getLogger('test_bridge');

late IOSink logSink;
late File detailedLogFile;

/// Main entry point for the MCP Bridge test application
void main(List<String> arguments) async {
  // Parse command-line arguments
  final parser = ArgParser()
    ..addOption('server-type',
        abbr: 's',
        help: 'Server transport type (stdio, sse)',
        defaultsTo: 'stdio')
    ..addOption('client-type',
        abbr: 'c',
        help: 'Client transport type (stdio, sse)',
        defaultsTo: 'sse')
    ..addOption('server-action',
        help: 'Server shutdown action (shutdown, waitreconnect)',
        defaultsTo: 'shutdown')
    ..addOption('server-url', help: 'SSE server URL (required for sse client)',
        defaultsTo: 'http://localhost:8999/sse')
    ..addOption('auth-token',
        help: 'Authentication token for SSE client/server connections',
        defaultsTo: 'test_token')
    ..addOption('command',
        help: 'Command to execute (required for stdio client)')
    ..addOption('arguments', help: 'Command arguments as comma-separated list')
    ..addOption('working-dir', help: 'Working directory for stdio client')
    ..addOption('port',
        help: 'HTTP server port for SSE server', defaultsTo: '8999')
    ..addOption('config-file', help: 'Configuration file path')
  // Add logging related options
    ..addOption('log-to-file',
        help: 'Enable or disable logging to file',
        defaultsTo: 'false') // Enable/disable file logging
    ..addOption('log-dir',
        help: 'Directory to store log files',
        defaultsTo: null) // Log file storage directory
    ..addFlag('verbose',
        abbr: 'v', help: 'Enable verbose logging', negatable: false)
    ..addFlag('help', abbr: 'h', help: 'Show help', negatable: false);

  ArgResults results;

  try {
    results = parser.parse(arguments);
  } catch (e) {
    logError('Argument parsing error: $e');
    _printUsage(parser);
    exit(1);
  }

  if (results['help'] as bool) {
    _printUsage(parser);
    exit(0);
  }
  Logger.getLogger('mcp_bridge').setLevel(LogLevel.trace);
  // Setup logging with command line options
  final logToFileStr = results['log-to-file'] as String;
  final logToFile = logToFileStr.toLowerCase() == 'true';
  final String? logDirectory = results['log-dir'] as String?;
  setupLogging(logToFile: logToFile, logDirectory: logDirectory);

  // Set log level
  if (results['verbose'] as bool) {
    Logger.getLogger('mcp_bridge').setLevel(LogLevel.trace);
  }

  try {
    // Load from configuration file or create from command-line arguments
    McpBridgeConfig config;
    if (results['config-file'] != null) {
      final configFilePath = results['config-file'] as String;
      config = await _loadConfigFromFile(configFilePath);
    } else {
      config = _createConfigFromArgs(results);
    }

    // Create and initialize bridge
    await runBridge(config);
  } catch (e, stackTrace) {
    logError('Error occurred: $e');
    logDebug(stackTrace.toString());
    exit(1);
  }
}

Future<McpBridgeConfig> _loadConfigFromFile(String path) async {
  final configFile = File(path);
  if (!await configFile.exists()) {
    throw FileSystemException('Configuration file not found: $path');
  }

  logInfo('Loading from configuration file: $path');
  final jsonStr = await configFile.readAsString();
  final json = jsonDecode(jsonStr);
  return McpBridgeConfig.fromJson(json);
}

McpBridgeConfig _createConfigFromArgs(ArgResults args) {
  final serverType = args['server-type'] as String;
  final clientType = args['client-type'] as String;
  final serverActionStr = args['server-action'] as String;
  final authToken =
  args['auth-token'] as String?; // Get authentication token value

  // Determine server action mode (existing code)
  ServerShutdownBehavior serverAction;
  if (serverType.toLowerCase() == 'stdio') {
    // STDIO server always uses shutdownBridge mode (because client controls it)
    serverAction = ServerShutdownBehavior.shutdownBridge;
    if (serverActionStr.toLowerCase() == 'waitreconnect') {
      logWarning(
          'STDIO server does not support wait for reconnection mode. Setting to shutdownBridge mode.');
    }
  } else {
    // SSE server determined by configuration
    serverAction = serverActionStr.toLowerCase() == 'waitreconnect'
        ? ServerShutdownBehavior.waitForReconnection
        : ServerShutdownBehavior.shutdownBridge;
  }

  // Server configuration
  final serverConfig = <String, dynamic>{};
  if (serverType.toLowerCase() == 'sse') {
    final port = int.tryParse(args['port'] as String) ?? 8080;
    serverConfig['port'] = port;
    serverConfig['endpoint'] = '/sse';
    serverConfig['messagesEndpoint'] =
    '/message'; // Changed '/messages' to '/message'

    // Add SSE server authentication token configuration
    if (authToken != null) {
      serverConfig['authToken'] = authToken;
      logInfo('Authentication token has been set for SSE server.');
    }
  }

  // Client configuration
  final clientConfig = <String, dynamic>{};
  if (clientType.toLowerCase() == 'stdio') {
    final command = args['command'] as String?;
    if (command == null) {
      throw ArgumentError('stdio client requires command argument');
    }
    clientConfig['command'] = command;

    // Process command arguments
    if (args['arguments'] != null) {
      final argsStr = args['arguments'] as String;
      final argsList = argsStr.split(',').map((e) => e.trim()).toList();
      clientConfig['arguments'] = argsList;
    }

    // Process working directory
    if (args['working-dir'] != null) {
      clientConfig['workingDirectory'] = args['working-dir'] as String;
    }
  } else if (clientType.toLowerCase() == 'sse') {
    final serverUrl = args['server-url'] as String?;
    if (serverUrl == null) {
      throw ArgumentError('sse client requires server-url argument');
    }
    clientConfig['serverUrl'] = serverUrl;

    // Add SSE client authentication header
    if (authToken != null) {
      clientConfig['headers'] = {'Authorization': 'Bearer $authToken'};
      logInfo('Authentication token header has been set for SSE client.');
    }
  }

  return McpBridgeConfig(
    serverTransportType: serverType,
    clientTransportType: clientType,
    serverConfig: serverConfig,
    clientConfig: clientConfig,
    serverShutdownBehavior: serverAction,
  );
}

Future<void> runBridge(McpBridgeConfig config) async {
  logInfo('Starting MCP Bridge');
  logInfo(
      'Server type: ${config.serverTransportType}, Client type: ${config.clientTransportType}');
  logInfo('Server shutdown behavior: ${config.serverShutdownBehavior}');

  // Check configuration
  if (config.clientTransportType.toLowerCase() == 'stdio') {
    logInfo('STDIO client command: ${config.clientConfig['command']}');
    if (config.clientConfig.containsKey('arguments')) {
      logInfo('STDIO client arguments: ${config.clientConfig['arguments']}');
    }
  } else if (config.clientTransportType.toLowerCase() == 'sse') {
    logInfo('SSE client server URL: ${config.clientConfig['serverUrl']}');
    // Log authentication header presence
    if (config.clientConfig.containsKey('headers')) {
      logInfo('SSE client authentication header has been set.');
    } else {
      logWarning('SSE client authentication header has not been set.');
    }
  }

  if (config.serverTransportType.toLowerCase() == 'sse') {
    logInfo('SSE server port: ${config.serverConfig['port']}');
    logInfo('SSE server endpoint: ${config.serverConfig['endpoint']}');
    logInfo(
        'SSE server message endpoint: ${config.serverConfig['messagesEndpoint']}');
    // Log authentication token presence
    if (config.serverConfig.containsKey('authToken')) {
      logInfo('SSE server authentication token has been set.');
    } else {
      logWarning('SSE server authentication token has not been set.');
    }
  }

  final bridge = McpBridge(config);

  // Configure client auto-reconnect
  bridge.setAutoReconnect(enabled: true);

  // Configure options for SSE server & wait for reconnection mode
  if (config.serverTransportType.toLowerCase() == 'sse' &&
      config.serverShutdownBehavior ==
          ServerShutdownBehavior.waitForReconnection) {
    bridge.setServerReconnectionOptions(
      maxAttempts: 0, // Unlimited retry
      checkInterval: Duration(seconds: 10),
    );

    // Server reconnection callback
    bridge.onServerReconnectRequested = () async {
      logInfo('Attempting server reconnection...');
      await Future.delayed(Duration(seconds: 3));
      return true;
    };
  }

  // Register event handlers
  bridge.onTransportError = (source, error, stackTrace) {
    logError('Error occurred in ${source.name}: $error');
  };

  bridge.onTransportClosed = (source) {
    logInfo('${source.name} connection closed');

    if (source == TransportSource.server) {
      if (config.serverTransportType.toLowerCase() == 'sse' &&
          config.serverShutdownBehavior ==
              ServerShutdownBehavior.waitForReconnection) {
        logInfo(
            'SSE server connection has been closed. Waiting for server reconnection.');
        // Handled internally (in McpBridge._handleServerDisconnection method)
      } else {
        logInfo('Server has terminated, so the bridge will also terminate.');
        // Shutdown is not necessary - handled automatically by internal logic
      }
    } else {
      logInfo(
          'Client connection has been lost. Will attempt reconnection while server is active.');
      // Client auto-reconnection is handled by internal logic
    }
  };

  bridge.onTransportReconnected = (source) {
    logInfo('${source.name} reconnection successful');
  };

  try {
    // Initialize bridge
    await bridge.initialize();
    logInfo('Bridge initialization complete');

    // Handle termination signals
    final completer = Completer<void>();

    ProcessSignal.sigint.watch().listen((_) async {
      logInfo('User termination signal received. Shutting down...');
      await bridge.shutdown();
      completer.complete();
    });

    logInfo('Bridge is running.');
    await completer.future;
  } catch (e) {
    logError('Failed to initialize bridge: $e');
    rethrow;
  } finally {
    if (bridge.isInitialized) {
      await bridge.shutdown();
    }
    logInfo('Bridge shutdown complete');
  }
}

void _printUsage(ArgParser parser) {
  logInfo('MCP Bridge Test Application');
  logInfo('');
  logInfo('Usage:');
  logInfo(
      '  dart mcp_test_app.dart --server-type=sse --client-type=stdio --command="python" --arguments="client.py,arg1,arg2" [options]');
  logInfo('  dart mcp_test_app.dart --config-file=config.json');
  logInfo('');
  logInfo('Options:');
  logInfo(parser.usage);
  logInfo('');
  logInfo('Logging Options:');
  logInfo('  --log-to-file=[true|false]   Enable or disable logging to file (default: false)');
  logInfo('  --log-dir=PATH               Directory to store log files (default: current directory)');
  logInfo('');
  logInfo('Examples:');
  logInfo(
      '  dart mcp_test_app.dart --server-type=stdio --client-type=sse --server-url="http://localhost:8080/sse"');
  logInfo(
      '  dart mcp_test_app.dart --server-type=sse --client-type=stdio --command="python" --arguments="mcp_client.py" --server-action=waitreconnect');
  logInfo(
      '  dart mcp_test_app.dart --server-type=sse --client-type=stdio --command="python" --arguments="mcp_client.py" --auth-token="test_token"');
  logInfo(
      '  dart mcp_test_app.dart --server-type=stdio --client-type=sse --server-url="http://localhost:8080/sse" --auth-token="test_token"');
  logInfo('  dart mcp_test_app.dart --config-file=config.json');
  logInfo('');
  logInfo('Logging Examples:');
  logInfo('  dart mcp_test_app.dart --log-to-file=false --server-type=stdio --client-type=sse --server-url="http://localhost:8080/sse"');
  logInfo('  dart mcp_test_app.dart --log-dir=/tmp --server-type=sse --client-type=stdio --command="python"');
}

// Logging setup function
void setupLogging({bool logToFile = true, String? logDirectory}) {
  Logger.getLogger('mcp_bridge').setLevel(LogLevel.debug);
  // Basic logging configuration
  _logger.configure(
      level: LogLevel.debug, includeTimestamp: true, useColor: true);

  // Skip log file creation if file logging is disabled
  if (!logToFile) {
    logInfo("File logging disabled");
    return;
  }

  // Set log directory - use default or specified directory
  final logDir = logDirectory ?? Directory.current.path;

  try {
    // Check if log directory exists and create if necessary
    final logDirObj = Directory(logDir);
    if (!logDirObj.existsSync()) {
      logDirObj.createSync(recursive: true);
    }

    // Create log file
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    detailedLogFile = File('$logDir/mcp_bridge_$timestamp.log');
    logSink = detailedLogFile.openWrite(mode: FileMode.append);

    logInfo("Log file created: ${detailedLogFile.path}");
  } catch (e) {
    _logger.error("Failed to create log file: $e. File logging disabled.");
    // Use only console logging if file logging fails
    logToFile = false;
  }
}

void logInfo(String message) {
  // Console logging
  _logger.info(message);

  try {
    final timestamp = DateTime.now().toIso8601String();
    logSink.writeln("$timestamp INFO: $message");
  } catch (e) {
    // Ignore log file write errors
  }
}

void logDebug(String message) {
  // Console logging
  _logger.debug(message);

  try {
    final timestamp = DateTime.now().toIso8601String();
    logSink.writeln("$timestamp DEBUG: $message");
  } catch (e) {
    // Ignore log file write errors
  }
}

void logWarning(String message) {
  // Console logging
  _logger.warning(message);

  try {
    final timestamp = DateTime.now().toIso8601String();
    logSink.writeln("$timestamp WARNING: $message");
  } catch (e) {
    // Ignore log file write errors
  }
}

void logError(String message, [Object? error, StackTrace? stackTrace]) {
  // Console logging
  _logger.error(message);

  try {
    final timestamp = DateTime.now().toIso8601String();
    logSink.writeln("$timestamp ERROR: $message");

    if (error != null) {
      logSink.writeln("$timestamp ERROR DETAIL: $error");
    }

    if (stackTrace != null) {
      logSink.writeln("$timestamp STACK TRACE: $stackTrace");
    }
  } catch (e) {
    // Ignore log file write errors
  }
}
