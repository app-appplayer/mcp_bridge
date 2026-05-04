# MCP Bridge

A Dart plugin for bridging between different transport types using the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/). This package enables you to connect an MCP client and server even if they use different underlying communication protocols (e.g., STDIO, SSE).

## Features

- Acts as a bridge between MCP-compatible clients and servers
- Supports multiple transport types:
    - Standard I/O (STDIO)
    - Server-Sent Events (SSE)
- Enables full-duplex message forwarding between client and server
- Auto-reconnection support for client or server failure
- Server shutdown behavior configuration
- JSON-configurable bridge setup
- Designed for local and remote LLM use cases

## Use Cases

- Connect a local `mcp_server` running with STDIO to an external LLM frontend over SSE
- Embed `mcp_server` inside a Flutter app and expose it via HTTP to AutoGen/ChatGPT
- Bridge CLI-based tools and web-based LLM UIs

## Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  mcp_bridge: ^0.1.0
```

Or install via command line:

```bash
dart pub add mcp_bridge
```

## Basic Usage

```dart
import 'package:mcp_bridge/mcp_bridge.dart';

void main() async {
  final bridge = McpBridge(
    McpBridgeConfig(
      serverTransportType: 'stdio',
      clientTransportType: 'sse',
      serverConfig: {
        'command': 'dart',
        'arguments': ['my_server.dart'],
      },
      clientConfig: {
        'serverUrl': 'http://localhost:8080/sse',
        'headers': {'Authorization': 'Bearer test_token'},
      },
      serverShutdownBehavior: ServerShutdownBehavior.shutdownBridge,
    ),
  );

  bridge.setAutoReconnect(enabled: true);
  await bridge.initialize();

  print('Bridge is running...');
}
```

## Transport Modes

### Standard I/O (STDIO)

Useful for wrapping CLI-based MCP servers or clients:

```json
"serverTransportType": "stdio",
"serverConfig": {
  "command": "dart",
  "arguments": ["my_server.dart"]
}
```

### Server-Sent Events (SSE)

Enables HTTP-based communication between bridge and MCP endpoints:

```json
"clientTransportType": "sse",
"clientConfig": {
  "serverUrl": "http://localhost:8080/sse",
  "headers": {
    "Authorization": "Bearer my_token"
  }
}
```

## Configuration (JSON)

You can load bridge settings from a JSON file using `McpBridgeConfig.fromJson(...)`.

```json
{
  "serverTransportType": "stdio",
  "clientTransportType": "sse",
  "serverShutdownBehavior": "shutdownBridge",
  "serverConfig": {
    "command": "dart",
    "arguments": ["my_server.dart"]
  },
  "clientConfig": {
    "serverUrl": "http://localhost:8080/sse",
    "headers": {
      "Authorization": "Bearer test_token"
    }
  }
}
```

## Logging

You can configure logging behavior using your own logger, or forward logs from client/server for debugging.

```dart
final Logger _logger = Logger.getLogger('mcp_bridge');
_logger.setLevel(LogLevel.debug);
_logger.info('Bridge initialized');
```

## Examples

See the [example](https://github.com/app-appplayer/mcp_bridge/tree/main/example) folder for a full example including:

- Bridge setup using STDIO server and SSE client
- Argument parsing with `args` package
- CLI tool to launch test environments

## Future Plans

- [ ] WebSocket transport support
- [ ] Serial port support for embedded systems

## Related Packages

- [`mcp_server`](https://pub.dev/packages/mcp_server): Build and expose an MCP-compatible server
- [`mcp_client`](https://pub.dev/packages/mcp_client) (planned): Connect to any MCP-compliant server

## Issues and Feedback

Please file any issues, bugs, or feature requests in our [issue tracker](https://github.com/app-appplayer/mcp_client/issues).

## License

MIT License. See [LICENSE](LICENSE) for details.

