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
});

String greeting() => 'hello, v1';

String Function(String) routes(String how) =>
    (path) => '$path, $how, v1';
