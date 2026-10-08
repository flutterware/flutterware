import 'package:logging/logging.dart';

/// Where `package:logging` records go.
///
/// What is left of `lib/src/logs/` — 2800 lines that were a copy of
/// `flutter_tools`' `Logger`, a websocket server, an ANSI terminal model and a
/// progress-spinner protocol, all of it built to carry the GUI's log lines back
/// to the terminal that ran `dart run flutterware`.
///
/// None of it was reachable. `RemoteLogServer.start` was never called, and
/// neither `REMOTE_LOGGER_URL` nor `FW_REMOTE_LOGGER_URL` was ever set, so the
/// "no server reachable" fallback had quietly become the only implementation
/// there is. The transport went when the process chain moved to inherited
/// stdio; this deletes the shape it left behind.
///
/// One method, because there is exactly one caller shape: a `Logger.root`
/// listener. The verbs that used to be here — `printBox`, `startProgress`,
/// `printStatus` — were terminal verbs on a process that has no terminal, and
/// the last of them is what put the GUI's welcome banner on screen as
/// `[$message - $title]`.
abstract class LogClient {
  /// Straight to stdout, which the CLI is reading and putting above its region.
  factory LogClient.print() => _LogClient(print);

  /// To [sink] instead — what a surface whose stdout belongs to something else
  /// needs.
  ///
  /// MCP speaks JSON-RPC on stdout, so a log line printed there is not a stray
  /// message a human can ignore; it is a malformed frame, and the client
  /// disconnects. Which sink a session logs to is therefore a property of the
  /// surface rather than a per-session default.
  factory LogClient.writeTo(StringSink sink) => _LogClient(sink.writeln);

  void printLogRecord(LogRecord record);
}

class _LogClient implements LogClient {
  _LogClient(this._write);

  final void Function(String line) _write;

  /// The level is named only when it is one worth acting on. Tagging
  /// every line `[STATUS]` is how the old client made ordinary logs look like
  /// diagnostics.
  @override
  void printLogRecord(LogRecord record) {
    var level = record.level >= Level.WARNING ? '${record.level.name}: ' : '';
    _write('$level${record.loggerName} - ${record.message}');
    if (record.error case var error?) _write('  $error');
    if (record.stackTrace case var stackTrace?) _write('  $stackTrace');
  }
}
