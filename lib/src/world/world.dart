import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:meta/meta.dart';

import '../devices.dart';
import 'protocol.dart';

/// A world while its script runs: what the script declares, and the helpers
/// that keep one opening from colliding with the next.
///
/// A world is **set up, never reset**. Every opening — the first and each
/// restart — runs the script from the top, with a new [id], so the emails,
/// phone numbers and names it makes are new each time and the server needs no
/// wiping between runs.
final class World {
  World._(this.id, this._knobValues, this._send);

  /// Runs a world script's [body] and serves whoever opened it, until they
  /// close the world.
  ///
  /// ```dart
  /// void main(List<String> args) => World.run(args, (w) async {
  ///   var server = await startServer(port: await w.freePort());
  ///   w.onClose(server.close);
  ///   w.person('Ana', app: Launch('Shop', knobs: {'server': '${server.url}'}));
  /// });
  /// ```
  ///
  /// Opened by flutterware, the script speaks to its owner and the people get
  /// their apps. Run on its own — `dart run worlds/pickup.dart` — it prints
  /// what it declares instead, which is how to debug the setup half without
  /// launching anything; `name=value` arguments are its knob values, and
  /// Ctrl-C closes it.
  static Future<void> run(
    List<String> args,
    FutureOr<void> Function(World w) body,
  ) async {
    var socketPath = Platform.environment[worldSocketVariable];
    if (socketPath == null) return _runAlone(args, body);
    var socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    var lines = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await serve(lines, (line) => socket.writeln(line), body);
    await socket.flush();
    await socket.close();
    // Whatever the script left running — a server's idle keep-alive, a
    // timer — is not a reason for the world to outlive its owner.
    exit(0);
  }

  /// [run], over [input] and [output] rather than the owner's socket —
  /// answers once the world has closed.
  @visibleForTesting
  static Future<void> serve(
    Stream<String> input,
    void Function(String line) output,
    FutureOr<void> Function(World w) body,
  ) async {
    void send(String type, [Map<String, Object?> fields = const {}]) =>
        output(encodeWorldMessage(type, fields));

    World? world;
    // Once, however many ways it is asked for: a `close` and the owner's
    // hanging up usually arrive together.
    Future<void>? closing;
    var asked = Completer<void>();
    Future<void> close() {
      if (!asked.isCompleted) asked.complete();
      return closing ??= () async {
        await world?._close();
        send(WorldMessage.closed);
      }();
    }

    var subscription = input.listen(
      (line) {
        var message = decodeWorldMessage(line);
        switch (message['type']) {
          case WorldMessage.open when world == null:
            var knobs = (message['knobs'] as Map? ?? const {})
                .cast<String, Object?>();
            var opened = world = World._(_newId(), knobs, send);
            send(WorldMessage.hello, {
              'protocol': worldProtocolVersion,
              'id': opened.id,
              'pid': pid,
            });
            unawaited(opened._setUp(body));
          case WorldMessage.ready:
            if (!(world?._ready.isCompleted ?? true)) world!._ready.complete();
          case WorldMessage.invoke:
            world?._invoke(
              message['action']! as String,
              message['run']! as int,
            );
          case WorldMessage.cancel:
            world?._runs[message['run']]?._cancel();
          case WorldMessage.close:
            unawaited(close());
        }
      },
      // The owner went away without closing: close anyway, so whatever the
      // script started is stopped rather than orphaned.
      onDone: () => unawaited(close()),
    );
    await asked.future;
    await closing;
    await subscription.cancel();
  }

  static Future<void> _runAlone(
    List<String> args,
    FutureOr<void> Function(World w) body,
  ) async {
    var knobs = {
      for (var arg in args)
        if (arg.contains('='))
          arg.substring(0, arg.indexOf('=')): arg.substring(
            arg.indexOf('=') + 1,
          ),
    };
    var done = Completer<void>();
    var interrupted = ProcessSignal.sigint.watch().listen((_) {
      if (!done.isCompleted) done.complete();
    });
    stdout.writeln(
      'Running on its own: nothing launches the apps. Open the world from '
      'flutterware for that. Ctrl-C closes it.',
    );
    var ended = serve(
      _AloneOwner(knobs, done.future).messages,
      _describe,
      body,
    );
    await ended;
    await interrupted.cancel();
    exit(0);
  }

  /// This opening's id: six characters, new every time the world opens or
  /// restarts. Everything [email], [phone] and [unique] make carries it.
  final String id;

  final Map<String, Object?> _knobValues;
  final void Function(String type, [Map<String, Object?> fields]) _send;

  final _people = <String>{};
  final _phones = <String>{};
  final _actions = <String, FutureOr<void> Function(ActionRun run)>{};
  final _runs = <int, ActionRun>{};
  final _closers = <FutureOr<void> Function()>[];
  final _ready = Completer<void>();

  /// An email address nobody has used: `ana.k3f9x2@example.com`.
  ///
  /// `example.com` is reserved for exactly this, so nothing a world sends
  /// reaches anyone; pass [domain] for a server that only accepts its own.
  String email(String name, {String domain = 'example.com'}) =>
      '${_slug(name)}.$id@$domain';

  /// A phone number from the range the UK reserves for fiction,
  /// `+447700900000` to `+447700900999`, and not one this world has handed
  /// out already.
  ///
  /// A thousand numbers is small: a server that keeps its users between
  /// worlds may already know one. A world that cannot afford that makes its
  /// own number.
  String phone() {
    if (_phones.length >= 1000) {
      throw StateError('This world has used every number in the range.');
    }
    String number;
    do {
      number = '+447700900${_random.nextInt(1000).toString().padLeft(3, '0')}';
    } while (!_phones.add(number));
    return number;
  }

  /// [name] made unique to this opening: `Canal Street k3f9x2`. For anything
  /// the server insists is unique — a shop's name, a team's.
  String unique(String name) => '$name $id';

  /// Declares someone using the system, and answers them.
  ///
  /// Any part of an identity is enough: a person who signs up while the world
  /// is open is declared by the phone number they will type. [app] is what
  /// they use, [on] is where it runs; a person with no [app] is headless — the
  /// script acts for them through the server.
  Person person(
    String name, {
    String? email,
    String? phone,
    String? userId,
    String? password,
    Launch? app,
    WorldDevice on = const Studio(),
  }) {
    if (!_people.add(name)) {
      throw ArgumentError.value(name, 'name', 'Two people have this name');
    }
    if (app != null) {
      for (var MapEntry(:key, :value) in app.knobs.entries) {
        try {
          jsonEncode(value);
        } on JsonUnsupportedObjectError {
          throw ArgumentError.value(
            value,
            'knobs',
            "$name's knob $key is not a value an app can be started with: "
                'a string, a number, a bool, or a list or map of them',
          );
        }
      }
    }
    var person = Person(
      name,
      email: email,
      phone: phone,
      userId: userId,
      password: password,
      app: app,
      on: on,
    );
    _send(WorldMessage.person, personToJson(person));
    return person;
  }

  /// Something anyone can do to the world while it is open — a human from
  /// the studio, the agent through `worlds invoke`. What it does is [body]'s;
  /// one that takes time says how far it is through [ActionRun.progress], and
  /// stops when it is cancelled.
  void action(
    String name,
    FutureOr<void> Function(ActionRun run) body, {
    String? description,
  }) {
    if (_actions.containsKey(name)) {
      throw ArgumentError.value(name, 'name', 'Two actions have this name');
    }
    _actions[name] = body;
    _send(WorldMessage.action, {'name': name, 'description': ?description});
  }

  /// A value the world is opened with, and answers it: what it was opened or
  /// restarted with, else [initial]. Changing one restarts the world.
  String knob(
    String name, {
    List<String> options = const [],
    String initial = '',
    String? description,
  }) {
    var value = '${_knobValues[name] ?? initial}';
    _send(WorldMessage.knob, {
      'name': name,
      'value': value,
      if (options.isNotEmpty) 'options': options,
      'description': ?description,
    });
    return value;
  }

  /// A line for whoever is watching the world open: *Starting the server*.
  void progress(String message) =>
      _send(WorldMessage.progress, {'message': message});

  /// Runs [close] when the world closes or restarts — the last registered
  /// first, as a stack unwinds. A failure is reported and the rest still run.
  void onClose(FutureOr<void> Function() close) => _closers.add(close);

  /// Completes once every person's app is up.
  Future<void> get ready => _ready.future;

  /// A port nothing on this machine is listening on — for a server the world
  /// hosts.
  Future<int> freePort() async {
    var socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var port = socket.port;
    await socket.close();
    return port;
  }

  Future<void> _setUp(FutureOr<void> Function(World w) body) async {
    try {
      await body(this);
      _send(WorldMessage.setUp);
    } on Object catch (error, stack) {
      _send(WorldMessage.failed, {'error': '$error', 'stack': '$stack'});
    }
  }

  void _invoke(String name, int run) {
    var body = _actions[name];
    if (body == null) {
      _send(WorldMessage.actionEnded, {
        'run': run,
        'error': 'This world has no action "$name".',
      });
      return;
    }
    var action = _runs[run] = ActionRun._(run, _send);
    unawaited(
      Future(() => body(action))
          .then(
            (_) => _send(WorldMessage.actionEnded, {'run': run}),
            onError: (Object error) => _send(WorldMessage.actionEnded, {
              'run': run,
              'error': '$error',
            }),
          )
          .whenComplete(() => _runs.remove(run)),
    );
  }

  Future<void> _close() async {
    for (var run in _runs.values) {
      run._cancel();
    }
    for (var close in _closers.reversed) {
      try {
        await close();
      } on Object catch (error) {
        progress('A close callback failed: $error');
      }
    }
  }

  static final _random = Random();

  static String _newId() {
    const alphabet = 'abcdefghijkmnpqrstuvwxyz23456789';
    return [
      for (var i = 0; i < 6; i++) alphabet[_random.nextInt(alphabet.length)],
    ].join();
  }

  static String _slug(String name) =>
      name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '.');
}

/// Someone using the system, as [World.person] declared them.
final class Person {
  const Person(
    this.name, {
    this.email,
    this.phone,
    this.userId,
    this.password,
    this.app,
    this.on = const Studio(),
  });

  final String name;
  final String? email;
  final String? phone;
  final String? userId;
  final String? password;

  /// What they use; null for a person the script acts for.
  final Launch? app;

  /// Where [app] runs.
  final WorldDevice on;
}

/// An app to start: one of the entry points the project declares for Run, by
/// its name, and the knobs its `main` is called with — by parameter name, as
/// Run calls it.
final class Launch {
  const Launch(this.entrypoint, {this.knobs = const {}});

  /// A Run entry point's name, as `tool/flutterware.dart` declares it.
  final String entrypoint;

  final Map<String, Object?> knobs;
}

/// Where a person's app runs.
sealed class WorldDevice {
  const WorldDevice();
}

/// In the studio's embedded guest, drawn as [device]: no native build, a
/// person's own storage without the app's help, and a platform the studio
/// answers — notifications, links, preferences — so the world sees and plays
/// it.
final class Studio extends WorldDevice {
  const Studio([this.device = Devices.iphone16]);

  final Device device;
}

/// An action while it runs.
final class ActionRun {
  ActionRun._(this._run, this._send);

  final int _run;
  final void Function(String type, [Map<String, Object?> fields]) _send;
  final _cancelled = Completer<void>();

  /// Says how far the action is: *Leo is 200 m from the shop*, and a
  /// [fraction] from 0 to 1 when it knows one.
  void progress(String message, {double? fraction}) => _send(
    WorldMessage.actionProgress,
    {'run': _run, 'message': message, 'fraction': ?fraction},
  );

  /// Whether someone asked the action to stop, or the world is closing. An
  /// action that takes time checks it, or awaits [whenCancelled].
  bool get cancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void _cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// The owner a script run on its own has: it opens the world with the knobs
/// from the command line, declares every app up at once, and closes on Ctrl-C.
class _AloneOwner {
  _AloneOwner(this.knobs, this.interrupted);

  final Map<String, Object?> knobs;
  final Future<void> interrupted;

  Stream<String> get messages async* {
    yield encodeWorldMessage(WorldMessage.open, {'knobs': knobs});
    yield encodeWorldMessage(WorldMessage.ready);
    await interrupted;
    yield encodeWorldMessage(WorldMessage.close);
  }
}

/// A script run on its own, in words.
void _describe(String line) {
  var message = decodeWorldMessage(line);
  var text = switch (message['type']) {
    WorldMessage.hello => 'World ${message['id']}',
    WorldMessage.progress => '  ${message['message']}',
    WorldMessage.person => _personLine(message),
    WorldMessage.action => '  Action: ${message['name']}',
    WorldMessage.knob => '  Knob: ${message['name']} = ${message['value']}',
    WorldMessage.setUp => 'Set up.',
    WorldMessage.failed => 'Failed: ${message['error']}\n${message['stack']}',
    WorldMessage.actionProgress => '  … ${message['message']}',
    WorldMessage.actionEnded => null,
    WorldMessage.closed => 'Closed.',
    _ => null,
  };
  if (text != null) stdout.writeln(text);
}

String _personLine(Map<String, Object?> message) {
  var person = personFromJson(message);
  var identity = [?person.email, ?person.phone, ?person.userId].join(', ');
  var app = person.app;
  var on = switch (person.on) {
    Studio(:var device) => "the studio's ${device.label}",
  };
  return [
    '  ${person.name}${identity.isEmpty ? '' : ' ($identity)'}',
    if (app == null)
      ' — no app'
    else ...[
      ' — ${app.entrypoint} on $on',
      for (var MapEntry(:key, :value) in app.knobs.entries)
        '\n      $key: ${jsonEncode(value)}',
    ],
  ].join();
}
