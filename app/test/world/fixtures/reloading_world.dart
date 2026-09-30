import 'dart:io';

import 'package:flutterware/server.dart';
import 'package:flutterware/world.dart';

/// A world whose actions say what its code says: the test edits the code and
/// reloads the world under it.
void main(List<String> args) => World.run(args, (w) async {
  w.person('Ana', email: 'ana.${w.id}@example.com');
  // A handler as a router makes it — a closure, made once per build —
  // served through `reloadable`, and the same handler without it.
  var reloaded = FlutterwareServer.reloadable(() => routes('reloadable'));
  var once = routes('built once');
  w.action('Greet', (run) => run.progress(greeting()));
  w.action('Route', (run) => run.progress(reloaded('/health')));
  w.action('Route once', (run) => run.progress(once('/health')));
  // Dies under a reload once the test says so, as a script does whose own
  // reloader collides with the world's.
  FlutterwareServer.onReassemble(() {
    if (!File('build/leave_on_reload').existsSync()) return;
    print('leaving on reload');
    exit(3);
  });
});

String greeting() => 'hello, v1';

String Function(String) routes(String how) =>
    (path) => '$path, $how, v1';
