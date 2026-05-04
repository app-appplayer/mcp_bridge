// Re-export logging package to follow MCP standard pattern.
export 'package:logging/logging.dart';

import 'package:logging/logging.dart';

/// Extension methods for backward compatibility with existing MCP patterns.
extension LoggerExtensions on Logger {
  /// Debug log — maps to fine level.
  void debug(String message) => fine(message);

  /// Error log — maps to severe level.
  void error(String message) => severe(message);

  /// Warning log — maps to warning level (alias).
  void warn(String message) => warning(message);

  /// Trace log — maps to finest level.
  void trace(String message) => finest(message);
}
