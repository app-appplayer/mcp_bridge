## 0.1.0

* Initial release
    * Created bridge implementation for the Model Context Protocol (MCP)
    * Supports pluggable transport types (stdio, sse)
    * Provides bi-directional JSON-RPC message forwarding between MCP clients and servers
    * Command-line and config-file based configuration system
    * Auto-reconnection support for client and server transports
    * Token-based authentication support for SSE connections
    * Lifecycle coordination with graceful shutdown handling
    * Includes CLI test runner (test_bridge.dart) for integration testing
    * Compatible with mcp_server, mcp_client, and MCP Inspector