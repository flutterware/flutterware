import 'dart:io';

// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';

import 'capture/settle.dart';

class AppContext {
  final Directory appToolDirectory;
  final LogClient logger;

  /// Who the window is waiting on, for anything that needs to know when it has
  /// stopped moving. Here because it spans plugins — a panel registers into it
  /// and `fw capture` reads it, and neither knows about the other.
  final SettleRegistry settle;

  /// Whether this session answers one MCP tool call: opened for the call and
  /// disposed when it returns, in a process whose stdout is the protocol.
  /// Whatever a core holds in memory is gone with the call.
  final bool mcp;

  AppContext({
    required this.logger,
    Directory? appToolDirectory,
    SettleRegistry? settle,
    this.mcp = false,
  }) : settle = settle ?? SettleRegistry(),
       appToolDirectory = appToolDirectory ?? Directory.current;

  AppContext copyWith({LogClient? logger}) {
    return AppContext(
      logger: logger ?? this.logger,
      appToolDirectory: appToolDirectory,
      settle: settle,
      mcp: mcp,
    );
  }
}
