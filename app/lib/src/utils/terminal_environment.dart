import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

final _logger = Logger('terminal_environment');

Future<Map<String, String>>? _asked;
Map<String, String>? _pinned;

/// The environment a new terminal window would have.
///
/// Every process flutterware starts for the user — a service, the commands
/// that check and drive it, a script that works out a value — gets this, not
/// the environment flutterware happens to be running in. That one depends on
/// how flutterware was started: a studio opened from the Dock has launchd's
/// PATH, roughly `/usr/bin:/bin:/usr/sbin:/sbin`; the MCP server has whatever
/// the agent's client captured, with the SDK a version manager put in front;
/// a studio started from a terminal has that terminal's.
///
/// **Two things go wrong with "whatever we have".** A tool the user's shell
/// finds — `uv`, `docker`, anything Homebrew installed — is missing from the
/// Dock's PATH, so a service that starts from a terminal fails from the
/// studio. And Dart's build hooks keep a hash of the variables they read
/// (`PATH`, `ANDROID_HOME`, `HOME` and a few more) and rerun every hook when
/// one differs from the run before: about 50s on a consumer's server that
/// depends on webcrypto, paid again at every switch between a terminal and
/// the studio. One environment, the same however flutterware was started,
/// makes the second run a cache hit.
///
/// **Read from the variables a terminal starts with, not from ours.** A shell
/// started from this process would add its profile on top of whatever is
/// already here, and the answer would still depend on how we were started:
/// macOS's `path_helper` reorders a PATH it is handed, and a profile that
/// prepends does it twice. So the shell gets launchd's PATH and the handful
/// of variables that describe the user, and runs as a terminal runs it —
/// login and interactive, because `~/.zprofile` and `~/.zshrc` both edit
/// PATH, and a tool can be at a different place according to each.
///
/// Two exceptions keep this process's own environment. On Windows a desktop
/// app already has the user's. On CI (`CI` is set) there is no terminal to
/// copy, and the runner's environment, with whatever a setup step put on its
/// PATH, is the right one.
///
/// Asked once per process. A shell that cannot be read — it hung, it failed,
/// it printed nothing parseable — leaves this process's own environment,
/// which is what every spawn had before, and logs why.
Future<Map<String, String>> terminalEnvironment() {
  if (_pinned case var pinned?) return Future.value(pinned);
  return _asked ??= readTerminalEnvironment(
    Platform.environment,
    windows: Platform.isWindows,
  );
}

/// [terminalEnvironment], for running [executable] — see [environmentToRun].
Future<Map<String, String>> terminalEnvironmentToRun(String executable) async =>
    environmentToRun(
      executable,
      await terminalEnvironment(),
      separator: Platform.isWindows ? ';' : ':',
    );

/// [environment] for running [executable]: as it is, unless [executable] is
/// the `dart` or `flutter` of an SDK that fvm installed. That one runs with
/// its SDK's `bin` first on the PATH, as `fvm dart` runs it.
///
/// Dart's build hooks rerun whenever the PATH differs from the last run's
/// (see [terminalEnvironment]), and `fvm` puts the SDK's `bin` in front of
/// the PATH it is given. Without the same here, a terminal's `fvm dart run`
/// and flutterware's own `dart run` of the same SDK rebuild each other's
/// hooks, about 50s each time on a server that depends on webcrypto.
///
/// Nothing is added when the SDK's `bin` already comes first, which is the
/// case when [environment] is this process's own and fvm started it.
Map<String, String> environmentToRun(
  String executable,
  Map<String, String> environment, {
  String separator = ':',
}) {
  var bin = fvmSdkBin(executable);
  var path = environment['PATH'] ?? '';
  if (bin == null || path.split(separator).first == bin) return environment;
  return {...environment, 'PATH': path.isEmpty ? bin : '$bin$separator$path'};
}

/// The `bin` directory of the Flutter SDK [executable] belongs to, when fvm
/// installed that SDK; otherwise null.
///
/// fvm keeps every SDK it installs in a `versions` directory, by version:
/// `~/fvm/versions/3.38.0`, or under the cache path its config names. Both
/// the `dart` in the SDK's `bin` and the one under `bin/cache/dart-sdk` count.
@visibleForTesting
String? fvmSdkBin(String executable) {
  var name = p.basenameWithoutExtension(executable);
  if (name != 'dart' && name != 'flutter') return null;
  var bin = p.dirname(executable);
  if (p.basename(bin) != 'bin') return null;
  var sdk = p.dirname(bin);
  if (p.basename(sdk) == 'dart-sdk' &&
      p.basename(p.dirname(sdk)) == 'cache' &&
      p.basename(p.dirname(p.dirname(sdk))) == 'bin') {
    bin = p.dirname(p.dirname(sdk));
    sdk = p.dirname(bin);
  }
  if (p.basename(p.dirname(sdk)) != 'versions') return null;
  return bin;
}

/// Makes [terminalEnvironment] answer [environment] without asking a shell,
/// or ask again when null.
@visibleForTesting
set debugTerminalEnvironment(Map<String, String>? environment) {
  _pinned = environment;
  _asked = null;
}

/// [terminalEnvironment]'s work, given this process's environment [own].
@visibleForTesting
Future<Map<String, String>> readTerminalEnvironment(
  Map<String, String> own, {
  bool windows = false,
  Duration timeout = const Duration(seconds: 10),
}) async {
  if (windows || _onCi(own)) return own;
  var shell = own['SHELL'] ?? '/bin/sh';
  String? problem;
  try {
    var output = await _askShell(shell, _startingEnvironment(own), timeout);
    if (parseTerminalEnvironment(output) case var read?) return read;
    problem = output.isEmpty
        ? 'it printed nothing within ${timeout.inSeconds}s'
        : 'its output had no environment in it';
  } on Object catch (e) {
    problem = '$e';
  }
  _logger.warning(
    'Could not read the environment of a new terminal from $shell: $problem. '
    'Processes flutterware starts get its own environment instead.',
  );
  return own;
}

bool _onCi(Map<String, String> own) => switch (own['CI']) {
  null || '' || 'false' || '0' => false,
  _ => true,
};

/// The variables a terminal window starts its shell with, before any profile
/// runs: launchd's PATH, and the ones that say who the user is, where their
/// home and temporary directory are, their locale and their SSH agent. Those
/// are taken from ours, because they are the same however we were started.
Map<String, String> _startingEnvironment(Map<String, String> own) => {
  for (var MapEntry(:key, :value) in own.entries)
    if (_carried.contains(key) || key.startsWith('LC_')) key: value,
  'PATH': Platform.isMacOS
      ? '/usr/bin:/bin:/usr/sbin:/sbin'
      : '/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin',
};

const _carried = {
  'HOME',
  'USER',
  'LOGNAME',
  'SHELL',
  'TMPDIR',
  'LANG',
  'SSH_AUTH_SOCK',
  '__CF_USER_TEXT_ENCODING',
};

const _start = '__flutterware_environment__';
const _end = '__flutterware_environment_end__';

/// Everything [shell] printed, up to the end marker.
///
/// Not `Process.run`: an interactive profile can leave a background job
/// holding stdout open — a prompt's git-status daemon, an agent — and
/// `Process.run` would wait for it to close. The end marker says the answer
/// is complete, and the timeout bounds a profile that prompts or hangs.
Future<String> _askShell(
  String shell,
  Map<String, String> environment,
  Duration timeout,
) async {
  var process = await Process.start(
    shell,
    [
      '-l',
      '-i',
      '-c',
      "printf '\\n%s\\n' $_start; /usr/bin/env -0; printf '\\n%s\\n' $_end",
    ],
    environment: environment,
    includeParentEnvironment: false,
    workingDirectory: environment['HOME'],
  );
  unawaited(process.stdin.close());
  unawaited(process.stderr.drain<void>());
  var bytes = BytesBuilder(copy: false);
  var done = Completer<void>();
  var subscription = process.stdout.listen(
    (chunk) {
      bytes.add(chunk);
      if (utf8.decode(bytes.toBytes(), allowMalformed: true).contains(_end)) {
        if (!done.isCompleted) done.complete();
      }
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );
  var finished = await done.future
      .then((_) => true)
      .timeout(timeout, onTimeout: () => false);
  await subscription.cancel();
  if (!finished) process.kill(ProcessSignal.sigkill);
  return utf8.decode(bytes.takeBytes(), allowMalformed: true);
}

/// The environment between the markers of what [_askShell] printed, or null.
///
/// Records are NUL-separated, because a value can hold a newline. The
/// variables a shell sets about itself — where it is, how deep — are
/// dropped: they describe the shell that answered, not the terminal.
@visibleForTesting
Map<String, String>? parseTerminalEnvironment(String output) {
  var start = output.indexOf('\n$_start\n');
  var end = output.lastIndexOf('\n$_end\n');
  if (start < 0 || end < start) return null;
  var body = output.substring(start + _start.length + 2, end);
  var environment = <String, String>{};
  for (var record in body.split('\x00')) {
    var equals = record.indexOf('=');
    if (equals <= 0) continue;
    var key = record.substring(0, equals);
    if (_aboutTheShell.contains(key)) continue;
    environment[key] = record.substring(equals + 1);
  }
  return environment.containsKey('PATH') ? environment : null;
}

const _aboutTheShell = {'PWD', 'OLDPWD', 'SHLVL', '_'};

/// [name] on [path], as an absolute path, or null.
///
/// What a spawn with that PATH would run. Walked here rather than handed to a
/// shell, because a shell is a subprocess and this is a few `stat`s.
String? executableOnPath(String name, String path) {
  if (name.contains('/')) return null;
  for (var dir in path.split(':')) {
    if (dir.isEmpty) continue;
    var file = File(p.join(dir, name));
    try {
      // Any execute bit. A file on PATH that nobody may run is not the answer,
      // and reporting it would only move the failure to the spawn.
      var stat = file.statSync();
      if (stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0) {
        return file.path;
      }
    } on FileSystemException {
      // Not there, or a directory we cannot stat. Next.
    }
  }
  return null;
}
