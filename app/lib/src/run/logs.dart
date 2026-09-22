import 'dart:convert';

import '../utils/daemon/events.dart';
import '../utils/daemon/protocol.dart';
import 'run_files.dart';

/// Who said it.
///
/// The split matters more than it looks. A launcher log interleaves the build
/// — Xcode noise, CocoaPods advice, progress lines — with what the app itself
/// printed, and they are answers to different questions. Debugging the app
/// wants [app] and nothing else; debugging a launch that never came up wants
/// [tool].
enum RunLogSource {
  /// The app's own output.
  ///
  /// Recognised by the `flutter: ` prefix, not by an event. This was
  /// written against `app.log` first, which was wrong: `flutter run --machine`
  /// sends that event only when a stop or a restart fails. Everything the app
  /// prints goes to plain stdout with the same `flutter: ` prefix a plain
  /// `flutter run` shows, *interleaved* with the machine protocol rather than
  /// carried by it. Measured, after reading the tool's source suggested
  /// otherwise — see the tests, which pin the real shape.
  app,

  /// `flutter run` talking about itself: `daemon.logMessage`, and every other
  /// plain line — the build, Xcode, the engine's own stderr.
  tool,

  /// The platform's own log, read by us rather than forwarded by the launcher.
  ///
  /// Not in the launcher's log file, and no amount of forwarding would put
  /// it there. `flutter run` reads the device log through a filter that keeps
  /// only the app's *main executable* and the engine, so every line a plugin's
  /// framework logs is dropped before it reaches anything we could read.
  /// `NativeLogSource` is what reads the platform log itself.
  native,
}

/// One line of a run's log.
class RunLogLine {
  const RunLogLine(this.source, this.text, {this.error = false});

  final RunLogSource source;
  final String text;

  /// The launcher marked it as an error — an errored `app.log`, a
  /// `daemon.logMessage` at error level, or the engine's own severity prefix
  /// (see [_engineSeverity]).
  ///
  /// Not inferred from prose. A line containing the word "error" is extremely
  /// often a line about not having one, and no amount of it makes a line an
  /// error report. A fixed *shape* written by one emitter is a different thing
  /// from prose, which is why [_saysFault]'s three are allowed here — an engine
  /// severity prefix, a front-end diagnostic's `path:line:col: Error:`, and
  /// xcodebuild's `** BUILD FAILED **`.
  final bool error;

  Map<String, Object?> toJson() => {
    'source': source.name,
    'text': text,
    if (error) 'error': true,
  };
}

/// Everything a run's launcher wrote, decoded.
///
/// The log is the source of truth, and it needs no VM service. It is
/// written by the detached `flutter run` from the moment it starts, so it
/// covers the build — before any app exists to connect to — and it survives the
/// app it describes. A crashed run is exactly the case where the logs matter
/// most and the app cannot be asked anything, which is why this reads a file
/// rather than subscribing to `Stdout`.
///
/// Tolerates everything, like [LaunchLog.read]: a log half-written, absent, or
/// carrying an event from a tool version this build does not know is a log that
/// says less than it will in a second, not an error.
List<RunLogLine> readRunLog(
  String path, {
  RunLogSource? only,
  bool errorsOnly = false,
  int? tail,
  RunFiles files = const DiskRunFiles(),
}) {
  var text = files.readString(path);
  if (text == null) return const [];
  var lines = const LineSplitter().convert(text);

  var result = <RunLogLine>[];
  for (var line in lines) {
    if (decodeRunLogLine(line) case var decoded?) {
      if (only != null && decoded.source != only) continue;
      if (errorsOnly && !decoded.error) continue;
      result.add(decoded);
    }
  }

  if (tail != null && result.length > tail) {
    return result.sublist(result.length - tail);
  }
  return result;
}

/// One line of a launcher log, as whatever it turns out to be — or null for a
/// line that is not scrollback at all.
///
/// Shared by the two readers rather than written twice. [readRunLog] answers a
/// whole file in one go, for a caller that wants a bounded answer and then
/// forgets; [RunLogTail] follows a file that is still being written. They must
/// agree about what a line *is*, and the tests that pin the shape only pin it
/// once.
RunLogLine? decodeRunLogLine(String line) {
  RunLogLine? made(RunLogSource source, String text, {bool error = false}) {
    if (text.trim().isEmpty) return null;
    return RunLogLine(source, text.trimRight(), error: error);
  }

  var object = DaemonProtocol.tryReadLine(line);
  if (object == null) {
    if (line.startsWith(_appPrefix)) {
      var text = line.substring(_appPrefix.length);
      return made(RunLogSource.app, text, error: _saysFault(text));
    }
    return made(RunLogSource.tool, line, error: _saysFault(line));
  }
  switch (DaemonProtocol.tryReadEvent(object)) {
    // Only ever a failed stop or restart, but it is about the app and the
    // tool has already marked it as an error.
    case DaemonLogEvent(:var log, :var error):
      return made(RunLogSource.app, log, error: error);
    case DaemonLogMessageEvent(:var level, :var message, :var stackTrace):
      // `trace` and `status` are the tool narrating its own progress and are
      // already covered by `app.progress`, which the panel shows as a
      // progress line rather than as scrollback.
      if (level == MessageLevel.trace || level == MessageLevel.status) {
        return null;
      }
      return made(
        RunLogSource.tool,
        stackTrace == null ? message : '$message\n$stackTrace',
        error: level == MessageLevel.error,
      );
    case AppStopEvent(error: var why?):
      return made(RunLogSource.tool, why, error: true);
    default:
      return null;
  }
}

/// The Flutter **engine**'s own severity prefix, as in
/// `[ERROR:flutter/runtime/dart_vm_initializer.cc(40)] Unhandled Exception: …`.
///
/// This is a format rather than a word. [RunLogLine.error] refuses to guess an
/// error from prose and should keep refusing; what is matched here is a fixed
/// shape one emitter writes — severity, source file, line — which no sentence
/// about not having an error produces by accident.
///
/// It is worth having because of what it is the only record of. An app whose
/// `main` throws before `runApp` never reaches a `FlutterError`, never sends an
/// `app.log`, and never produces a `daemon.logMessage`: the engine writes this
/// one line straight to the process's stderr and the app then sits there,
/// answering its VM service with nothing mounted. Without this, `errors: []`
/// was the correct reading of a log that plainly contained the reason.
final _engineSeverity = RegExp(r'^\[(ERROR|FATAL):[^\]]*\]');

/// The Dart front end's diagnostic shape, as in
/// `lib/main.dart:119:21: Error: Method not found: 'notAThing'.`
///
/// The same argument as [_engineSeverity], applied to the emitter that produces
/// the fault a broken build actually has. `Errors` matched **nothing at all**
/// on a real failed build until this existed: the launcher's structured error
/// is `Error: Build process failed`, which is true of every build failure and
/// names none, and the line that says which one — file, line, column, and the
/// caret under the token — carries no severity marker this could see. Measured
/// 2026-08-27 on a deliberately broken example app: 0 of 44 lines matched, on a
/// log whose whole point was the one it could not find.
///
/// A format, not a word, which is the test [RunLogLine.error] applies. Path,
/// colon, line, colon, column, colon, severity is a shape the front end writes
/// and prose does not produce by accident; matching a bare `Error:` anywhere in
/// a line would, and is exactly what that field refuses.
///
/// `Severe` is in here because the front end emits it too. Gradle's `e: ` and
/// the Kotlin compiler's shapes are not, because no log measured here has
/// carried one — add them when one does.
final _compilerDiagnostic = RegExp(r'^\S+:\d+:\d+: (Error|Severe): ');

/// `** BUILD FAILED **`, which xcodebuild writes and nothing else does.
///
/// A whole line, fixed, from one emitter. It is the last word of every failed
/// Apple build and it is worth having under `Errors` on its own account: the
/// diagnostic above says what is wrong, and this says the build is over.
final _buildFailed = RegExp(r'^\*\* BUILD FAILED \*\*');

/// Whether [line] carries one of the fixed fault shapes above.
bool _saysFault(String line) =>
    _engineSeverity.hasMatch(line) ||
    _compilerDiagnostic.hasMatch(line) ||
    _buildFailed.hasMatch(line);

/// What `flutter run` puts in front of a line the app printed.
///
/// The tool's own convention, the same one a plain `flutter run` shows in a
/// terminal, and the only signal separating app output from build output in a
/// `--machine` log.
const _appPrefix = 'flutter: ';

/// A launcher log followed rather than re-read.
///
/// The panel showing a log polls, and the log it polls is the biggest file the
/// tool writes: measured on a real run, 882 KB and 7,435 lines, parsed in
/// 4.2 ms warm and 18 ms cold. [readRunLog] pays that from byte zero every
/// time, on the UI isolate, every couple of seconds, for the whole life of a
/// run — a quarter of a frame thrown away on re-deciding facts that have not
/// changed, and the bill grows with the run rather than with what arrived.
///
/// This reads only what is new. It keeps its place in the file, its lines, and
/// the count of the ones it has had to let go, so the caller can say that the
/// scrollback has a beginning that is not the beginning. Same log, same poll,
/// five lines arriving: **4,637 µs against 93 µs**, and the second number is
/// the size of what arrived rather than the size of the file, so it stays
/// there while the first one climbs.
///
/// Three things it has to survive, all of which happen:
///
/// * **A line arriving in pieces.** A poll can land between the `[` and the
///   `]` of a machine event. Only whole lines are decoded; the rest waits.
/// * **A character arriving in pieces.** A read can split a multi-byte glyph,
///   which is why the remainder is kept as *bytes* and decoded once it is
///   complete — decoding each chunk with `allowMalformed` would leave a `�`
///   welded into the middle of a path.
/// * **A file that got shorter.** A relaunch reusing the path, or a truncation,
///   means the offset held here points past the end of a different file. The
///   answer is to start again rather than to read garbage.
class RunLogTail {
  RunLogTail(this.path, {this.keep = 10000, this.files = const DiskRunFiles()});

  /// Where [path] is read from.
  final RunFiles files;

  /// The launcher's log. Null is allowed and reads as empty — a run whose
  /// launcher has not said where it is writing yet is a normal early state,
  /// not an error.
  final String? path;

  /// How many lines to hold. Beyond it the oldest go, and [dropped] counts
  /// them: the alternative is a panel that grows without bound on a run that
  /// logs in a loop, and a log that logs in a loop is exactly the one somebody
  /// leaves open for an hour.
  final int keep;

  final _lines = <RunLogLine>[];

  /// Every line this holds, oldest first.
  List<RunLogLine> get lines => _lines;

  /// How many lines fell off the front. Zero means the scrollback starts where
  /// the log does.
  int get dropped => _dropped;
  var _dropped = 0;

  /// How far into the file everything above was read from.
  var _offset = 0;

  /// Bytes after the last newline — an unfinished line, or an unfinished
  /// character, or both.
  var _pending = <int>[];

  /// Whether the last line is [_pending] shown early.
  ///
  /// A log is usually read while something is writing it, and the writer is
  /// often mid-line. Holding that line back until its newline arrives is right
  /// for a live run and wrong for a dead one, where the half-written line may
  /// be the last thing the process managed to say — a process killed in the
  /// middle of printing why. So it is shown, and withdrawn on the next read
  /// before the bytes that complete it are decoded.
  var _provisional = false;

  void _reset() {
    _lines.clear();
    _pending = [];
    _offset = 0;
    _dropped = 0;
    _provisional = false;
  }

  /// Takes in whatever the file has gained since last time.
  ///
  /// Tolerates everything [readRunLog] tolerates, and for the same reason: a
  /// log that is half-written, absent, or carrying an event from a tool version
  /// this build does not know is a log that says less than it will in a second.
  void read() {
    var at = path;
    if (at == null) return;

    if (_provisional) {
      _lines.removeLast();
      _provisional = false;
    }

    var length = files.lengthOf(at);
    if (length == null) return;
    // Shorter than what was read from it: a different file under the same
    // name, or the same one truncated. Either way the offset is meaningless.
    if (length < _offset) _reset();

    if (length > _offset) {
      var read = files.readBytes(at, start: _offset);
      if (read == null) return;
      _pending = [..._pending, ...read];
      _offset += read.length;
    }

    var lastBreak = _lastBreakIn(_pending);
    if (lastBreak >= 0) {
      _take(_pending.sublist(0, lastBreak));
      _pending = _pending.sublist(lastBreak + 1);
      if (_lines.length > keep) {
        var over = _lines.length - keep;
        _lines.removeRange(0, over);
        _dropped += over;
      }
    }

    if (_pending.isNotEmpty) {
      var text = utf8.decode(_pending, allowMalformed: true);
      // Held back rather than guessed at. A machine event still arriving is
      // not a line of anything yet, and showing it would put half a JSON array
      // on the screen for one poll and then replace it with the message it
      // turned out to be. Plain text carries no such tell — and is exactly the
      // case this shows early — so it goes up.
      //
      // A *terminated* half-event is a different thing: it is garbage that is
      // really in the file, and [readRunLog] has always shown it as tool
      // output. This only defers a line that is still being written.
      if (!(text.startsWith('[{') && !text.endsWith('}]'))) {
        if (decodeRunLogLine(text) case var decoded?) {
          _lines.add(decoded);
          _provisional = true;
        }
      }
    }
  }

  /// Decodes complete lines out of [bytes] and keeps whatever they turn out to
  /// be.
  ///
  /// [LineSplitter], not `split('\n')`, because that is what [readRunLog] gets
  /// from `readAsLinesSync` and the two must not disagree about where a line
  /// ends. They did: a build tool redrawing its progress in place writes bare
  /// carriage returns, so `Building 10%\rBuilding 90%\r[{…}]` is three lines to
  /// one reader and one line to the other — and as one line it no longer starts
  /// with `[{`, so the machine event on the end of it is never decoded and the
  /// error it carried is never flagged.
  void _take(List<int> bytes) {
    if (bytes.isEmpty) return;
    var text = utf8.decode(bytes, allowMalformed: true);
    for (var line in const LineSplitter().convert(text)) {
      if (decodeRunLogLine(line) case var decoded?) _lines.add(decoded);
    }
  }

  /// The last byte that ends a line, or -1.
  ///
  /// Either terminator counts, and a `\r\n` cut down the middle by a poll is
  /// harmless: committing at the `\r` leaves the `\n` to open the next chunk,
  /// where it splits off an empty line that is dropped like any other.
  static int _lastBreakIn(List<int> bytes) {
    for (var i = bytes.length - 1; i >= 0; i--) {
      if (bytes[i] == _newline || bytes[i] == _return) return i;
    }
    return -1;
  }

  static const _newline = 0x0a;
  static const _return = 0x0d;
}
