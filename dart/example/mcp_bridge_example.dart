import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:mcp_bridge/mcp_bridge.dart';

final Logger _logger = Logger('test_bridge');

late IOSink logSink;
late File detailedLogFile;

const _knownTypes = {
  'stdio',
  'sse',
  'streamableHttp',
  'websocket',
  'tcp',
  'serial',
  'usb',
  'ble',
};

/// Main entry point for the MCP Bridge test application.
///
/// Demonstrates wiring any of the 8 built-in transports on either side
/// of the bridge via command-line flags. See `_printUsage` for examples.
void main(List<String> arguments) async {
  final parser = _buildArgParser();

  ArgResults results;
  try {
    results = parser.parse(arguments);
  } catch (e) {
    stderr.writeln('Argument parsing error: $e');
    _printUsage(parser);
    exit(1);
  }

  if (results['help'] as bool) {
    _printUsage(parser);
    exit(0);
  }

  // Setup logging.
  final logToFile = (results['log-to-file'] as String).toLowerCase() == 'true';
  final logDirectory = results['log-dir'] as String?;
  setupLogging(logToFile: logToFile, logDirectory: logDirectory);
  if (results['verbose'] as bool) {
    Logger('mcp_bridge').level = Level.FINEST;
  }

  try {
    McpBridgeConfig config;
    if (results['config-file'] != null) {
      config = await _loadConfigFromFile(results['config-file'] as String);
    } else {
      config = _createConfigFromArgs(results);
    }
    await runBridge(config);
  } catch (e, stackTrace) {
    logError('Error occurred: $e');
    logDebug(stackTrace.toString());
    exit(1);
  }
}

ArgParser _buildArgParser() => ArgParser()
  ..addOption('server-type',
      abbr: 's',
      help: 'Server transport type: ${_knownTypes.join(", ")}',
      defaultsTo: 'stdio')
  ..addOption('client-type',
      abbr: 'c',
      help: 'Client transport type: ${_knownTypes.join(", ")}',
      defaultsTo: 'sse')
  ..addOption('server-action',
      help: 'Server shutdown behavior (shutdown | waitreconnect)',
      defaultsTo: 'shutdown')
  ..addOption('config-file', help: 'JSON configuration file path')

  // ---- HTTP-family transports (sse / streamableHttp / websocket) ----
  ..addOption('listen-host',
      help: 'Server-side bind host (sse / streamableHttp / websocket / tcp)',
      defaultsTo: 'localhost')
  ..addOption('listen-port',
      help: 'Server-side bind port (sse / streamableHttp / websocket / tcp)',
      defaultsTo: '8999')
  ..addOption('target-url',
      help: 'Client-side URL — sse: http://...; streamableHttp: http://...; '
          'websocket: ws://...')
  ..addOption('auth-token',
      help: 'Bearer token for sse / streamableHttp / websocket')
  ..addOption('ws-path',
      help: 'WebSocket server path (server-side only)', defaultsTo: '/')

  // ---- STDIO ----
  ..addOption('command',
      help: 'Subprocess to spawn (stdio client) — required if client-type=stdio')
  ..addOption('arguments',
      help: 'Comma-separated subprocess arguments')
  ..addOption('working-dir', help: 'Subprocess working directory')

  // ---- TCP ----
  ..addOption('tcp-host', help: 'TCP client target host')
  ..addOption('tcp-port', help: 'TCP client target port')

  // ---- Serial ----
  ..addOption('serial-port',
      help: 'Serial device path (e.g. /dev/ttyACM0, /dev/cu.usbmodem*, COM3)')
  ..addOption('serial-baud',
      help: 'Serial baud rate', defaultsTo: '115200')

  // ---- USB ----
  ..addOption('usb-vendor',
      help: 'USB vendor ID, hex with 0x prefix (e.g. 0x1234)')
  ..addOption('usb-product', help: 'USB product ID, hex with 0x prefix')
  ..addOption('usb-interface', help: 'USB interface number', defaultsTo: '0')
  ..addOption('usb-in-endpoint',
      help: 'USB bulk-in endpoint (e.g. 0x81)')
  ..addOption('usb-out-endpoint',
      help: 'USB bulk-out endpoint (e.g. 0x01)')

  // ---- BLE (Linux only) ----
  ..addOption('ble-address',
      help: 'BLE peripheral address (AA:BB:CC:DD:EE:FF)')
  ..addOption('ble-service-uuid',
      help: 'BLE GATT service UUID carrying MCP traffic')
  ..addOption('ble-notify-uuid',
      help: 'BLE GATT notify characteristic UUID (peripheral → host)')
  ..addOption('ble-write-uuid',
      help: 'BLE GATT write characteristic UUID (host → peripheral)')

  // ---- Logging / misc ----
  ..addOption('log-to-file',
      help: 'Log to file in addition to stderr (true | false)',
      defaultsTo: 'false')
  ..addOption('log-dir',
      help: 'Directory for log files (default: current directory)')
  ..addFlag('verbose',
      abbr: 'v', help: 'Enable verbose logging', negatable: false)
  ..addFlag('help', abbr: 'h', help: 'Show help', negatable: false);

Future<McpBridgeConfig> _loadConfigFromFile(String path) async {
  final configFile = File(path);
  if (!await configFile.exists()) {
    throw FileSystemException('Configuration file not found: $path');
  }
  logInfo('Loading from configuration file: $path');
  final json = jsonDecode(await configFile.readAsString());
  return McpBridgeConfig.fromJson(json);
}

McpBridgeConfig _createConfigFromArgs(ArgResults args) {
  final serverType = args['server-type'] as String;
  final clientType = args['client-type'] as String;
  if (!_knownTypes.contains(serverType)) {
    throw ArgumentError(
        'Unknown --server-type "$serverType". Known: ${_knownTypes.join(", ")}');
  }
  if (!_knownTypes.contains(clientType)) {
    throw ArgumentError(
        'Unknown --client-type "$clientType". Known: ${_knownTypes.join(", ")}');
  }

  final serverConfig = _buildTransportConfig(args, serverType, side: 'server');
  final clientConfig = _buildTransportConfig(args, clientType, side: 'client');

  // Server shutdown behavior. STDIO server always uses shutdownBridge —
  // the spawning controller can't really keep the bridge alive past
  // the subprocess exit.
  ServerShutdownBehavior serverAction;
  final actionStr = (args['server-action'] as String).toLowerCase();
  if (serverType == 'stdio') {
    serverAction = ServerShutdownBehavior.shutdownBridge;
    if (actionStr == 'waitreconnect') {
      logWarning(
          'STDIO server cannot waitForReconnection — falling back to shutdownBridge.');
    }
  } else {
    serverAction = actionStr == 'waitreconnect'
        ? ServerShutdownBehavior.waitForReconnection
        : ServerShutdownBehavior.shutdownBridge;
  }

  return McpBridgeConfig(
    serverTransportType: serverType,
    clientTransportType: clientType,
    serverConfig: serverConfig,
    clientConfig: clientConfig,
    serverShutdownBehavior: serverAction,
  );
}

Map<String, dynamic> _buildTransportConfig(
    ArgResults args, String type, {required String side}) {
  final isServer = side == 'server';
  switch (type) {
    case 'stdio':
      if (isServer) return const {};
      final command = args['command'] as String?;
      if (command == null) {
        throw ArgumentError(
            'stdio client requires --command (path to subprocess)');
      }
      return {
        'command': command,
        if (args['arguments'] != null)
          'arguments': (args['arguments'] as String)
              .split(',')
              .map((e) => e.trim())
              .toList(),
        if (args['working-dir'] != null)
          'workingDirectory': args['working-dir'],
      };

    case 'sse':
      final auth = args['auth-token'] as String?;
      if (isServer) {
        return {
          'host': args['listen-host'],
          'port': int.parse(args['listen-port'] as String),
          'endpoint': '/sse',
          'messagesEndpoint': '/message',
          if (auth != null) 'authToken': auth,
        };
      }
      final url = args['target-url'] as String? ??
          'http://${args['listen-host']}:${args['listen-port']}/sse';
      return {
        'serverUrl': url,
        if (auth != null) 'headers': {'Authorization': 'Bearer $auth'},
      };

    case 'streamableHttp':
      final auth = args['auth-token'] as String?;
      if (isServer) {
        return {
          'host': args['listen-host'],
          'port': int.parse(args['listen-port'] as String),
          'endpoint': '/mcp',
          'messagesEndpoint': '/messages',
          if (auth != null) 'authToken': auth,
        };
      }
      final url = args['target-url'] as String? ??
          'http://${args['listen-host']}:${args['listen-port']}/mcp';
      return {
        'baseUrl': url,
        if (auth != null) 'headers': {'Authorization': 'Bearer $auth'},
      };

    case 'websocket':
      final auth = args['auth-token'] as String?;
      if (isServer) {
        return {
          'host': args['listen-host'],
          'port': int.parse(args['listen-port'] as String),
          'path': args['ws-path'],
          if (auth != null) 'authToken': auth,
        };
      }
      final url = args['target-url'] as String? ??
          'ws://${args['listen-host']}:${args['listen-port']}'
              '${args['ws-path']}';
      return {
        'url': url,
        if (auth != null) 'headers': {'Authorization': 'Bearer $auth'},
      };

    case 'tcp':
      if (isServer) {
        return {
          'host': args['listen-host'],
          'port': int.parse(args['listen-port'] as String),
        };
      }
      final host = args['tcp-host'] as String?;
      final portStr = args['tcp-port'] as String?;
      if (host == null || portStr == null) {
        throw ArgumentError('tcp client requires --tcp-host and --tcp-port');
      }
      return {'host': host, 'port': int.parse(portStr)};

    case 'serial':
      final port = args['serial-port'] as String?;
      if (port == null) {
        throw ArgumentError(
            'serial transport requires --serial-port (e.g. /dev/ttyACM0)');
      }
      return {
        'port': port,
        'baudRate': int.parse(args['serial-baud'] as String),
      };

    case 'usb':
      final vendor = args['usb-vendor'] as String?;
      final product = args['usb-product'] as String?;
      final inEp = args['usb-in-endpoint'] as String?;
      final outEp = args['usb-out-endpoint'] as String?;
      if (vendor == null || product == null || inEp == null || outEp == null) {
        throw ArgumentError(
            'usb transport requires --usb-vendor / --usb-product / '
            '--usb-in-endpoint / --usb-out-endpoint');
      }
      return {
        'vendorId': _parseHexOrInt(vendor),
        'productId': _parseHexOrInt(product),
        'interface': int.parse(args['usb-interface'] as String),
        'inEndpoint': _parseHexOrInt(inEp),
        'outEndpoint': _parseHexOrInt(outEp),
      };

    case 'ble':
      final addr = args['ble-address'] as String?;
      final svc = args['ble-service-uuid'] as String?;
      final notify = args['ble-notify-uuid'] as String?;
      final write = args['ble-write-uuid'] as String?;
      if (addr == null || svc == null || notify == null || write == null) {
        throw ArgumentError(
            'ble transport requires --ble-address / --ble-service-uuid / '
            '--ble-notify-uuid / --ble-write-uuid');
      }
      return {
        'deviceAddress': addr,
        'serviceUuid': svc,
        'notifyCharUuid': notify,
        'writeCharUuid': write,
      };

    default:
      throw ArgumentError('unsupported transport type: $type');
  }
}

int _parseHexOrInt(String v) {
  final s = v.toLowerCase();
  if (s.startsWith('0x')) return int.parse(s.substring(2), radix: 16);
  return int.parse(s);
}

Future<void> runBridge(McpBridgeConfig config) async {
  logInfo('Starting MCP Bridge: '
      '${config.serverTransportType} <=> ${config.clientTransportType} '
      '(${config.serverShutdownBehavior.name})');

  final bridge = McpBridge(config);
  bridge.setAutoReconnect(enabled: true);

  if (config.serverShutdownBehavior ==
      ServerShutdownBehavior.waitForReconnection) {
    bridge.setServerReconnectionOptions(
      maxAttempts: 0,
      checkInterval: Duration(seconds: 10),
    );
    bridge.onServerReconnectRequested = () async {
      logInfo('Attempting server reconnection...');
      await Future.delayed(Duration(seconds: 3));
      return true;
    };
  }

  bridge.onTransportError = (source, error, stackTrace) {
    logError('Error in ${source.name}: $error');
  };
  bridge.onTransportClosed = (source) {
    logInfo('${source.name} closed');
  };
  bridge.onTransportReconnected = (source) {
    logInfo('${source.name} reconnected');
  };

  try {
    await bridge.initialize();
    logInfo('Bridge initialized');

    final completer = Completer<void>();
    ProcessSignal.sigint.watch().listen((_) async {
      logInfo('SIGINT received — shutting down');
      await bridge.shutdown();
      completer.complete();
    });

    logInfo('Bridge is running. Ctrl-C to exit.');
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
  // Tool-level help goes to stdout (user-facing), not the log stream.
  final out = StringBuffer()
    ..writeln('MCP Bridge Test Application')
    ..writeln('')
    ..writeln('Usage:')
    ..writeln('  dart example/mcp_bridge_example.dart \\')
    ..writeln('       --server-type=<type> --client-type=<type> [transport options]')
    ..writeln('  dart example/mcp_bridge_example.dart --config-file=path.json')
    ..writeln('')
    ..writeln('Transport types: ${_knownTypes.join(", ")}')
    ..writeln('')
    ..writeln('Options:')
    ..writeln(parser.usage)
    ..writeln('')
    ..writeln('Examples:')
    ..writeln('')
    ..writeln('  # STDIO subprocess server <-> SSE client')
    ..writeln('  dart example/mcp_bridge_example.dart \\')
    ..writeln('       --server-type=stdio --client-type=sse \\')
    ..writeln('       --target-url="http://localhost:8080/sse"')
    ..writeln('')
    ..writeln('  # SSE listener server <-> STDIO subprocess client')
    ..writeln('  dart example/mcp_bridge_example.dart \\')
    ..writeln('       --server-type=sse --client-type=stdio \\')
    ..writeln('       --listen-port=8999 --command=python --arguments=mcp_server.py')
    ..writeln('')
    ..writeln('  # WebSocket listener <-> Streamable HTTP client')
    ..writeln('  dart example/mcp_bridge_example.dart \\')
    ..writeln('       --server-type=websocket --client-type=streamableHttp \\')
    ..writeln('       --listen-port=9000 --target-url=https://example.com/mcp')
    ..writeln('')
    ..writeln('  # TCP listener <-> TCP target')
    ..writeln('  dart example/mcp_bridge_example.dart \\')
    ..writeln('       --server-type=tcp --client-type=tcp \\')
    ..writeln('       --listen-port=9001 --tcp-host=10.0.0.5 --tcp-port=9100')
    ..writeln('')
    ..writeln('  # Serial-port-attached MCP device <-> Streamable HTTP exposure')
    ..writeln('  dart example/mcp_bridge_example.dart \\')
    ..writeln('       --server-type=streamableHttp --client-type=serial \\')
    ..writeln('       --listen-port=8080 --serial-port=/dev/ttyUSB0 --serial-baud=115200')
    ..writeln('')
    ..writeln('  # USB-attached vendor device <-> WebSocket exposure')
    ..writeln('  dart example/mcp_bridge_example.dart \\')
    ..writeln('       --server-type=websocket --client-type=usb \\')
    ..writeln('       --listen-port=9000 \\')
    ..writeln('       --usb-vendor=0x1234 --usb-product=0x5678 \\')
    ..writeln('       --usb-in-endpoint=0x81 --usb-out-endpoint=0x01')
    ..writeln('')
    ..writeln('  # BLE peripheral (Linux only) <-> Streamable HTTP exposure')
    ..writeln('  dart example/mcp_bridge_example.dart \\')
    ..writeln('       --server-type=streamableHttp --client-type=ble \\')
    ..writeln('       --listen-port=8080 \\')
    ..writeln('       --ble-address=AA:BB:CC:DD:EE:FF \\')
    ..writeln('       --ble-service-uuid=0000abcd-... \\')
    ..writeln('       --ble-notify-uuid=0000abce-... \\')
    ..writeln('       --ble-write-uuid=0000abcf-...')
    ..writeln('')
    ..writeln('  # Load from JSON config')
    ..writeln('  dart example/mcp_bridge_example.dart --config-file=bridge.json');
  stdout.write(out.toString());
}

// Logging setup. Wires `package:logging`'s root onRecord stream to
// stderr (and optionally to a file) since `package:logging` is just a
// record stream — output is the consumer's job.
StreamSubscription<LogRecord>? _stderrSub;

void setupLogging({bool logToFile = true, String? logDirectory}) {
  hierarchicalLoggingEnabled = true;
  Logger.root.level = Level.FINE;
  Logger('mcp_bridge').level = Level.FINE;

  _stderrSub?.cancel();
  _stderrSub = Logger.root.onRecord.listen((rec) {
    stderr.writeln(
        '[${rec.time}] [${rec.level.name}] [${rec.loggerName}] ${rec.message}');
  });

  if (!logToFile) {
    logInfo('File logging disabled');
    return;
  }

  final logDir = logDirectory ?? Directory.current.path;
  try {
    final logDirObj = Directory(logDir);
    if (!logDirObj.existsSync()) logDirObj.createSync(recursive: true);
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    detailedLogFile = File('$logDir/mcp_bridge_$timestamp.log');
    logSink = detailedLogFile.openWrite(mode: FileMode.append);
    logInfo('Log file created: ${detailedLogFile.path}');
  } catch (e) {
    _logger.severe('Failed to create log file: $e. File logging disabled.');
    logToFile = false;
  }
}

void logInfo(String message) {
  _logger.info(message);
  _writeFile('INFO', message);
}

void logDebug(String message) {
  _logger.fine(message);
  _writeFile('DEBUG', message);
}

void logWarning(String message) {
  _logger.warning(message);
  _writeFile('WARNING', message);
}

void logError(String message, [Object? error, StackTrace? stackTrace]) {
  _logger.severe(message);
  _writeFile('ERROR', message);
  if (error != null) _writeFile('ERROR DETAIL', '$error');
  if (stackTrace != null) _writeFile('STACK TRACE', '$stackTrace');
}

void _writeFile(String level, String message) {
  try {
    final timestamp = DateTime.now().toIso8601String();
    logSink.writeln('$timestamp $level: $message');
  } catch (_) {
    // File logging not initialized or write failed — ignore.
  }
}
