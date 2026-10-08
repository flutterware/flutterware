import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../logs.dart';

/// The platform's own log for one run — the half `flutter run` never shows.
///
/// This exists because forwarding more of the launcher's output could not
/// fix it. `flutter run` reads the device log itself and hands on a filtered
/// stream, and the filter is not about volume — it is structural. On an iOS
/// simulator the predicate it builds admits a line only if the sender is the
/// engine, `libswiftCore`, or the process's *own main executable*
/// (`processImageUUID == senderImageUUID`, `flutter_tools`
/// `ios/simulators.dart`). A plugin ships a framework, so it is a different
/// Mach-O image and can never satisfy that. On Android the mechanism differs
/// and the effect is the same: logcat is filtered against a tag allow-list
/// (`flutter*`, `DartVM`, `AndroidRuntime`, `System.err`, fatal), so a
/// plugin's `Log.d` — and the app's own — is dropped.
///
/// Measured on one simulator's log store, over a 12-hour window holding two
/// runs of an app whose push SDK ships as a framework: 1366 log events came
/// from the app's process, `flutter run`'s predicate admitted **7** of them,
/// and 105 of the 1359 it dropped were the SDK's own. That SDK's lines were
/// the entire evidence of whether the integration worked.
///
/// So the features whose behaviour is invisible in the widget tree — push,
/// purchases, deep links, maps, camera, Bluetooth, biometrics — are exactly
/// the features whose only instrument was unreadable from here.
///
/// Scoped to the process is necessary and not sufficient. The same window
/// unscoped is 385,000 events, and scoped to the app's process alone it is
/// still 1889 — `Network`, `UIKitCore`, `libxpc`, `CFNetwork` and the rest of
/// the OS talking on the app's behalf. One more clause, that the *sender* not
/// be an OS image, takes it to 141: the plugin frameworks, the engine, and the
/// app. That is the read this offers.
///
/// A question asked afterwards, not a stream. Like [readRunLog], and for
/// the same reason: the interesting lines are emitted in the first two seconds
/// of a launch, before any client could have attached. Both Apple platforms
/// answer from the log store with `log show --start`, so a run's whole life is
/// readable at any point in it — including after the app has died. Android's
/// buffer is the ring `logcat -d` dumps, which is the same shape with a
/// shorter memory.
abstract class NativeLogSource {
  /// Which platform's log this reads, for anything that has to say so.
  NativeLogPlatform get platform;

  /// Everything this run's process logged, newest last.
  ///
  /// [since] bounds the window — the run's start, normally, which is the only
  /// bound that means anything: a device log is machine-wide and permanent,
  /// and "this run" is the only slice of it worth reading.
  Future<NativeLogRead> read({DateTime? since, int? tail});
}

/// Which platform log, and what to call it out loud.
enum NativeLogPlatform {
  iosSimulator('the iOS simulator'),
  android('the device'),
  macos('macOS');

  const NativeLogPlatform(this.label);

  /// How a sentence about it reads: "… not in $label's own log".
  final String label;
}

/// One reading of a platform log.
class NativeLogRead {
  const NativeLogRead({
    required this.lines,
    required this.matched,
    required this.command,
    this.note,
  });

  /// An answer that found nothing to read, carrying why.
  const NativeLogRead.unread({required this.note, this.command})
    : lines = const [],
      matched = 0;

  final List<RunLogLine> lines;

  /// How many lines matched before [lines] was cut to the tail.
  final int matched;

  /// The command this came from, verbatim and runnable — null when no source
  /// was found, because there was then no command to run.
  ///
  /// Handed back rather than kept private, because the failure this feature
  /// exists to fix was a *silent* one: an empty answer that read as "nothing
  /// happened". An answer carrying the command it ran can be disagreed with.
  final String? command;

  /// Why the answer is empty or partial, when it is.
  final String? note;
}

/// Both Apple platforms: one `log show` against the unified log store.
///
/// The two differ only in how the bundle is found and who runs the command —
/// `xcrun simctl spawn <udid>` for a simulator, the host's own `log` for a
/// macOS app — so they are one class rather than two.
class AppleLogSource implements NativeLogSource {
  AppleLogSource._(this.platform, this._udid, this._bundle);

  /// A macOS run, whose bundle the caller already located.
  factory AppleLogSource.macos({required String bundle}) =>
      AppleLogSource._(NativeLogPlatform.macos, null, bundle);

  /// A simulator run, whose bundle is discovered on the first read.
  factory AppleLogSource.simulator({required String udid}) =>
      AppleLogSource._(NativeLogPlatform.iosSimulator, udid, null);

  @override
  final NativeLogPlatform platform;

  final String? _udid;

  /// The `.app` directory, once known. Everything the run's own code logs —
  /// its executable, the engine, every plugin framework — lives under it, and
  /// nothing else does.
  String? _bundle;

  @override
  Future<NativeLogRead> read({DateTime? since, int? tail}) async {
    var bundle = _bundle ??= await _findBundle(since);
    if (bundle == null) {
      return NativeLogRead.unread(
        command: _describe(_flutterSenderPredicate, since),
        note:
            'Nothing on this simulator has logged from a Flutter engine since '
            'the run started, so there is no app process to scope the log to. '
            'The log store may have rolled over, or the app never reached the '
            'engine.',
      );
    }
    var predicate = bundlePredicate(bundle);
    var output = await _show(predicate, since);
    if (output == null) {
      return NativeLogRead.unread(
        command: _describe(predicate, since),
        note: 'The platform log could not be read: `log show` failed.',
      );
    }
    var lines = parseAppleLog(output, bundle: bundle);
    return NativeLogRead(
      lines: _tail(lines, tail),
      matched: lines.length,
      command: _describe(predicate, since),
    );
  }

  /// The app bundle of whatever ran a Flutter engine in this window.
  ///
  /// Asked of the log rather than of the build directory, which is the
  /// difference between a fact and a guess. A product name has to be dug out
  /// of an Xcode configuration whose directory depends on the flavor, and the
  /// answer would still be a name rather than the container the simulator
  /// actually installed the app into. The engine, on the other hand, logs the
  /// backend it picked on every single launch, from inside the bundle — so one
  /// narrow query names the process, and its `.app` is the container.
  Future<String?> _findBundle(DateTime? since) async {
    var output = await _show(_flutterSenderPredicate, since);
    if (output == null) return null;
    String? newest;
    for (var record in _records(output)) {
      if (record['processImagePath'] case String path when path.contains('/')) {
        // Last wins: two apps on one simulator is possible, and the one this
        // run launched is the one that started most recently.
        newest = path;
      }
    }
    if (newest == null) return null;
    for (var dir = p.dirname(newest); dir.length > 1; dir = p.dirname(dir)) {
      if (dir.endsWith('.app')) return dir;
    }
    return null;
  }

  Future<String?> _show(String predicate, DateTime? since) async {
    try {
      var result = await Process.run(_command.first, [
        ..._command.skip(1),
        ..._arguments(predicate, since),
      ]);
      if (result.exitCode != 0) return null;
      return '${result.stdout}';
    } on ProcessException {
      return null;
    }
  }

  List<String> get _command => switch (_udid) {
    var udid? => ['xcrun', 'simctl', 'spawn', udid, 'log'],
    null => ['log'],
  };

  List<String> _arguments(String predicate, DateTime? since) => [
    'show',
    '--style',
    'ndjson',
    if (since != null) ...['--start', startArgument(since)],
    '--predicate',
    predicate,
  ];

  String _describe(String predicate, DateTime? since) => [
    ..._command,
    ..._arguments(predicate, since),
  ].map((word) => word.contains(' ') ? "'$word'" : word).join(' ');

  /// Every line the run's *own* code logged, and nothing the OS logged for it.
  ///
  /// The sender clause is the whole difference between 1889 lines and 141 —
  /// see the class comment. `libswiftCore` is the one OS image worth keeping:
  /// a Swift crash reports itself from there, and `flutter run` admits it for
  /// the same reason.
  ///
  /// The sender is excluded by what it is not, and that is not a style
  /// choice. Asking instead that the sender live under [bundle] — the
  /// obvious spelling, and the first one here — matched nothing at all, on a
  /// simulator where the process clause was matching 1889 lines. The log store
  /// resolves an image path by its Mach-O UUID and reports whichever path it
  /// first indexed for it, so after a reinstall a process running from one
  /// container logs frameworks that still name the *previous* one:
  ///
  ///     process: …/Application/ED3CF26A…/Runner.app/Runner
  ///     sender:  …/Application/8580A27E…/Runner.app/Frameworks/…
  ///
  /// The process clause is exact and stays exact. The sender clause only has
  /// to drop the OS talking on the app's behalf, and "not under `/System/` or
  /// `/usr/lib/`" does that without ever asking where the app was installed.
  @visibleForTesting
  static String bundlePredicate(String bundle) =>
      'eventType = logEvent '
      'AND processImagePath BEGINSWITH "$bundle/" '
      'AND ((NOT(senderImagePath BEGINSWITH "/System/") '
      'AND NOT(senderImagePath BEGINSWITH "/usr/lib/")) '
      'OR senderImagePath ENDSWITH "/libswiftCore.dylib")';

  /// What names a process that is running Flutter, and nothing else.
  static const _flutterSenderPredicate =
      'eventType = logEvent AND senderImagePath ENDSWITH "/Flutter"';

  /// `log show --start` takes a local wall clock, to the second.
  @visibleForTesting
  static String startArgument(DateTime at) {
    var local = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  /// `--style ndjson` output, as log lines.
  ///
  /// The sender's own name goes in front of the message, in the parentheses
  /// `log show --style compact` would have used, because "which framework said
  /// this" is the question the whole read exists to answer. The app's own
  /// executable is not labelled: it is the one sender that needs no telling
  /// apart.
  @visibleForTesting
  static List<RunLogLine> parseAppleLog(String output, {String? bundle}) {
    // By name, not by path: the sender's path may name a container the process
    // is not running from — see [bundlePredicate].
    var executable = bundle == null ? null : p.basenameWithoutExtension(bundle);
    var lines = <RunLogLine>[];
    for (var record in _records(output)) {
      var message = record['eventMessage'];
      if (message is! String || message.trim().isEmpty) continue;
      var sender = record['senderImagePath'];
      var name = sender is String && sender.isNotEmpty
          ? p.basename(sender)
          : null;
      if (name == executable) name = null;
      lines.add(
        RunLogLine(
          RunLogSource.native,
          name == null ? message : '($name) $message',
          // Apple's own words for it. `Default` and `Info` are not failures,
          // and a message containing the word "error" is very often about not
          // having one — the same rule the launcher's log follows.
          error:
              record['messageType'] == 'Error' ||
              record['messageType'] == 'Fault',
        ),
      );
    }
    return lines;
  }

  /// ndjson, tolerantly: `log show` prefixes a header and can emit a warning
  /// on the same stream, and a half-written record at the end is a record we
  /// do not have rather than a failure.
  static Iterable<Map<String, Object?>> _records(String output) sync* {
    for (var line in const LineSplitter().convert(output)) {
      if (!line.startsWith('{')) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (decoded is Map<String, Object?>) yield decoded;
    }
  }
}

/// Android: `logcat`, scoped to the app's process.
class AndroidLogSource implements NativeLogSource {
  AndroidLogSource({required this.serial, required this.adb});

  /// The device as `adb -s` takes it — the same string `flutter run -d` takes,
  /// so a run handle's device needs no translation.
  final String serial;

  /// Absolute path to `adb`.
  final String adb;

  @override
  NativeLogPlatform get platform => NativeLogPlatform.android;

  @override
  Future<NativeLogRead> read({DateTime? since, int? tail}) async {
    var pid = await _pid();
    if (pid == null) {
      return NativeLogRead.unread(
        command: _describe(_bootstrapArguments),
        note:
            'Nothing tagged `flutter` or `DartVM` is in the log buffer, so '
            "there is no pid to scope it to. Android's log is scoped to a "
            'live process: an app that has exited cannot be read back this '
            'way, and neither can one that reached logcat before the buffer '
            'rolled over.',
      );
    }
    var arguments = _readArguments(pid);
    var output = await _adb(arguments);
    if (output == null) {
      return NativeLogRead.unread(
        command: _describe(arguments),
        note: 'The platform log could not be read: `adb logcat` failed.',
      );
    }
    var lines = parseLogcat(output);
    return NativeLogRead(
      lines: _tail(lines, tail),
      matched: lines.length,
      command: _describe(arguments),
    );
  }

  /// The app's pid, from the engine's own logcat lines.
  ///
  /// Not from the applicationId, which is the obvious route and the wrong
  /// one: Gradle can rewrite it per flavor and per build type, which is why
  /// `flutter_tools` runs `aapt` over the built APK rather than reading the
  /// manifest. Bootstrapping from the log needs no build tools and no build
  /// directory — the engine's own tag is in the buffer whenever the app is,
  /// which is exactly when there is something to read.
  Future<int?> _pid() async {
    var output = await _adb(_bootstrapArguments);
    return output == null ? null : newestPid(output);
  }

  static const _bootstrapArguments = [
    'logcat',
    '-d',
    '-v',
    'brief',
    '-s',
    'flutter:V',
    'DartVM:V',
  ];

  static List<String> _readArguments(int pid) => [
    'logcat',
    '-d',
    '-v',
    'time',
    '--pid=$pid',
  ];

  Future<String?> _adb(List<String> arguments) async {
    try {
      var result = await Process.run(adb, ['-s', serial, ...arguments]);
      if (result.exitCode != 0) return null;
      return '${result.stdout}';
    } on ProcessException {
      return null;
    }
  }

  String _describe(List<String> arguments) =>
      [adb, '-s', serial, ...arguments].join(' ');

  /// The pid on the last `brief`-format line that has one.
  ///
  /// The last rather than the first: a device that has run this app twice has
  /// both pids in the buffer, and the live one is the later.
  @visibleForTesting
  static int? newestPid(String output) {
    int? pid;
    for (var line in const LineSplitter().convert(output)) {
      if (_brief.firstMatch(line) case var match?) {
        pid = int.tryParse(match.group(1)!) ?? pid;
      }
    }
    return pid;
  }

  /// `I/flutter ( 1234): message`
  static final _brief = RegExp(r'^[VDIWEF]/[^(]*\(\s*(\d+)\):');

  /// `-v time` output, as log lines.
  ///
  /// The tag is kept and the timestamp and pid are dropped: the tag says which
  /// SDK spoke, which is the point, and the rest is per-line noise on an
  /// answer that is already scoped to one process.
  @visibleForTesting
  static List<RunLogLine> parseLogcat(String output) {
    var lines = <RunLogLine>[];
    for (var line in const LineSplitter().convert(output)) {
      if (line.trim().isEmpty) continue;
      // `--------- beginning of main`: logcat's own buffer boundaries.
      if (line.startsWith('---------')) continue;
      var match = _timed.firstMatch(line);
      if (match == null) {
        // A continuation line of a multi-line message, or a format this build
        // does not know. Kept: an unparsed line still carries its words.
        lines.add(RunLogLine(RunLogSource.native, line.trimRight()));
        continue;
      }
      var level = match.group(1)!;
      var tag = match.group(2)!.trim();
      var message = match.group(3)!;
      lines.add(
        RunLogLine(
          RunLogSource.native,
          tag.isEmpty ? message : '($tag) $message',
          error: level == 'E' || level == 'F',
        ),
      );
    }
    return lines;
  }

  /// `08-17 14:20:38.069 I/flutter ( 1234): message`
  static final _timed = RegExp(
    r'^\d\d-\d\d \d\d:\d\d:\d\d\.\d+\s+([VDIWEF])/(.*?)\(\s*\d+\):\s?(.*)$',
  );
}

List<RunLogLine> _tail(List<RunLogLine> lines, int? tail) =>
    tail == null || lines.length <= tail
    ? lines
    : lines.sublist(lines.length - tail);
