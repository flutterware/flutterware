/// The example project's dev stack, as a CLI the project owns.
///
/// This file is not part of flutterware. It is the thing a `DevStack`
/// declaration points *at* — the `docker compose` wrapper, the `bin/dev`
/// script, the `make dev` a project already has. flutterware runs
/// `status --json` to find out what is going on and runs `up` / `down` when
/// told to; nothing here knows it is being called by a tool rather than by a
/// person in a terminal, and that is the whole arrangement. Run it by hand and
/// the panel reports the same thing.
///
/// ```sh
/// dart run tool/stack.dart up          # start the toy server in the background
/// dart run tool/stack.dart status      # what state is it in
/// dart run tool/stack.dart port        # which port it listens on
/// dart run tool/stack.dart logs        # what has it been saying
/// dart run tool/stack.dart hit /users  # send it a request
/// dart run tool/stack.dart down        # stop it
/// ```
///
/// The subject is `bin/example_server.dart` — the toy HTTP server this project
/// already ships for the server-inspection panel. That makes the pair worth
/// looking at together: bring the stack up here, and the Server panel fills
/// with the requests the `hit` command sends.
library;

import 'dart:convert';
import 'dart:io';

const _port = 8080;
const _base = 'http://localhost:$_port';

/// State and logs live under `.dart_tool/`, which is already ignored and
/// already the directory a Dart project throws away when it wants a clean one.
const _dir = '.dart_tool/flutterware_probes_stack';

final _stateFile = File('$_dir/state.json');
final _logFile = File('$_dir/server.log');

/// How long a launched-but-not-yet-answering server is called `starting`
/// before it is called `down`.
///
/// A clock rather than a liveness check, because there is no
/// platform-independent way to ask whether a pid is still alive — Dart can send
/// a signal but not the null signal, and `kill -0` is not a thing on Windows.
/// Being wrong here costs one wrong word for a few seconds; being wrong about
/// which platforms the script runs on costs the whole script.
const _startupGrace = Duration(seconds: 20);

Future<void> main(List<String> arguments) async {
  var verb = arguments.isEmpty ? 'status' : arguments.first;
  var rest = arguments.skip(1).toList();
  exitCode = switch (verb) {
    'up' => await _up(),
    'down' => await _down(),
    'status' => await _status(json: rest.contains('--json')),
    'logs' => _logs(),
    'port' => _port_(),
    'hit' => await _hit(rest.firstOrNull ?? '/users'),
    _ => _usage(verb),
  };
}

int _usage(String verb) {
  stderr.writeln('Unknown command `$verb`.');
  stderr.writeln(
    'Usage: dart run tool/stack.dart '
    '[up|down|status [--json]|port|logs|hit <path>]',
  );
  return 64;
}

// ── up ─────────────────────────────────────────────────────────────────────

/// Starts the server detached and waits for it to answer.
///
/// Idempotent by contract, which is what makes "Bring up" safe to press when
/// you only want to be *sure*: a server already answering on the port is a
/// success, not a conflict.
Future<int> _up() async {
  var reading = await _read();
  if (reading.state == 'up') {
    stdout.writeln('Already up on $_base.');
    return 0;
  }
  if (reading.state == 'unavailable') {
    stderr.writeln(reading.detail);
    return 1;
  }

  Directory(_dir).createSync(recursive: true);
  // The log is truncated per launch. It is a dev server's scratch output, and a
  // file that only grows is one nobody ever reads the top of.
  _logFile.writeAsStringSync('');

  // Detached: it outlives this process, which is the entire point of a
  // background stack. A detached child has no stdio at all, so the log file is
  // passed by name and the server appends to it itself.
  var process = await Process.start(
    Platform.resolvedExecutable,
    ['bin/example_server.dart'],
    mode: ProcessStartMode.detached,
    environment: {'EXAMPLE_SERVER_LOG': _logFile.absolute.path},
  );
  _stateFile.writeAsStringSync(
    jsonEncode({
      'pid': process.pid,
      'port': _port,
      'startedAt': DateTime.now().toIso8601String(),
    }),
  );

  // `up` returns when the thing is usable, not when the process exists — the
  // same promise `docker compose up --wait` makes. Without it the button would
  // go green and the next probe would say `down`, which reads as a failure that
  // did not happen.
  var deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    if ((await _read()).state == 'up') {
      stdout.writeln('Example server up on $_base (pid ${process.pid}).');
      return 0;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  stderr.writeln('The server did not answer on $_base within 20s.');
  stderr.writeln(_tail(40));
  return 1;
}

// ── down ───────────────────────────────────────────────────────────────────

Future<int> _down() async {
  var reading = await _read();
  var state = _readState();
  if (reading.state == 'down') {
    _clearState();
    stdout.writeln('Already down.');
    return 0;
  }
  if (state == null) {
    // Somebody ran `dart run bin/example_server.dart` in a terminal. It is
    // genuinely up — the probe says so — but this script has no pid for it, and
    // guessing which process to kill by port is how a script kills the wrong
    // thing.
    stderr.writeln(
      'Something is serving $_base, but this script did not start it. Stop it '
      'where you started it.',
    );
    return 1;
  }

  Process.killPid(state.pid);
  // Waits on the *port*, not on [_read] — which would answer `starting` here,
  // since a state file plus a refused connection is exactly what a launch that
  // has not finished looks like. The two are indistinguishable from outside,
  // which is why the one that knows it just sent a signal has to ask the
  // narrower question.
  var deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if ((await _get('/health')).status == null) {
      _clearState();
      stdout.writeln('Example server stopped (pid ${state.pid}).');
      return 0;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  stderr.writeln('pid ${state.pid} was signalled but $_base still answers.');
  return 1;
}

// ── status ─────────────────────────────────────────────────────────────────

/// Prints the state, as one JSON object for `Probe.json` or as a line for a
/// person.
Future<int> _status({required bool json}) async {
  var reading = await _read();
  if (!json) {
    stdout.writeln('${reading.state} · ${reading.detail}');
    return reading.state == 'unavailable' ? 1 : 0;
  }
  stdout.writeln(
    jsonEncode({
      'state': reading.state,
      'detail': reading.detail,
      if (reading.state == 'up')
        'services': [
          {'name': 'http', 'port': _port, 'state': 'up'},
        ],
    }),
  );
  return 0;
}

/// The one place the state is decided. Everything else asks this.
///
/// The port is the authority, not the state file. A stack you started in a
/// terminal and a stack the button started have to read identically, and only
/// the port knows about both. The state file adds two things the port cannot
/// say: which pid to signal, and whether a refused connection means "not
/// running" or "running, not listening yet".
Future<({String state, String detail})> _read() async {
  var health = await _get('/health');
  if (health.status == 200 && health.body?.trim() == 'ok') {
    var state = _readState();
    // The address, and nothing else. A pid is a debugging fact and this line is
    // read on a dashboard — it goes to `logs` and to the state file, where it
    // is wanted about once a month.
    return (
      state: 'up',
      detail: state == null
          ? 'localhost:$_port · not started here'
          : 'localhost:$_port',
    );
  }
  if (health.status != null) {
    // It connected, and got something that is not this server. That is the
    // distinction `Probe.exitCode` cannot draw: reporting `down` here would
    // offer a Bring-up button that is guaranteed to fail on a taken port.
    return (
      state: 'unavailable',
      detail:
          'Something else is listening on :$_port — it answered /health with '
          '${health.status}.',
    );
  }
  var state = _readState();
  if (state != null &&
      DateTime.now().difference(state.startedAt) < _startupGrace) {
    return (state: 'starting', detail: 'launched, not answering yet');
  }
  // Past the grace window with nothing answering: whatever was launched is
  // gone, so the file it left behind is too.
  if (state != null) _clearState();
  return (state: 'down', detail: 'nothing listening on :$_port');
}

void _clearState() {
  if (_stateFile.existsSync()) _stateFile.deleteSync();
}

// ── logs, hit ──────────────────────────────────────────────────────────────

/// The port this server listens on, as a bare number.
///
/// The shape a value another tool reads has to take, and the one flutterware's
/// `ValueSource.script` asks for: one line, nothing else, and a non-zero exit
/// when the answer is not known. Here it is a constant; in a monorepo that
/// allocates a port per worktree it is a lookup, and that is the whole reason
/// the port is asked for rather than written into `tool/flutterware.dart`.
int _port_() {
  stdout.writeln(_port);
  return 0;
}

int _logs() {
  var tail = _tail(40);
  stdout.writeln(tail.isEmpty ? 'No log yet — the server has not run.' : tail);
  return 0;
}

/// Sends one request, so there is something to look at in the Server panel.
Future<int> _hit(String path) async {
  var response = await _get(path.startsWith('/') ? path : '/$path');
  if (response.status == null) {
    stderr.writeln('$_base$path: ${response.error}');
    return 1;
  }
  stdout.writeln('${response.status} $_base$path');
  var body = response.body ?? '';
  stdout.writeln(body.length > 2000 ? '${body.substring(0, 2000)}…' : body);
  return 0;
}

// ── plumbing ───────────────────────────────────────────────────────────────

Future<({int? status, String? body, Object? error})> _get(String path) async {
  var client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    var response = await (await client.getUrl(Uri.parse('$_base$path')))
        .close();
    return (
      status: response.statusCode,
      body: await response.transform(utf8.decoder).join(),
      error: null,
    );
  } on Object catch (e) {
    return (status: null, body: null, error: e);
  } finally {
    client.close(force: true);
  }
}

({int pid, DateTime startedAt})? _readState() {
  try {
    if (!_stateFile.existsSync()) return null;
    var json =
        jsonDecode(_stateFile.readAsStringSync()) as Map<String, Object?>;
    return (
      pid: json['pid']! as int,
      startedAt: DateTime.parse(json['startedAt']! as String),
    );
  } on Object {
    // A half-written or hand-edited state file is no state file.
    return null;
  }
}

String _tail(int lines) {
  if (!_logFile.existsSync()) return '';
  var all = const LineSplitter().convert(_logFile.readAsStringSync());
  return all.skip(all.length > lines ? all.length - lines : 0).join('\n');
}
