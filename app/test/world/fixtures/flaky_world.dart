import 'dart:io';

import 'package:flutterware/world.dart';

/// A world whose first start dies the way a script does when the resident
/// compiler it found was going away — on the compiler's socket, before it
/// connects — and whose second start is fine.
void main(List<String> args) {
  var marker = File('build/flaky_world.marker');
  if (!marker.existsSync()) {
    marker
      ..createSync(recursive: true)
      ..writeAsStringSync('died once');
    print('Unhandled exception:');
    print(
      'SocketException: Connection reset by peer (OS Error: Connection '
      'reset by peer, errno = 54), address = 127.0.0.1, port = 55686',
    );
    exit(255);
  }
  World.run(args, (w) async {
    w.person('Ana', email: 'ana.${w.id}@example.com');
  });
}
