import 'package:flutterware/world.dart';

import 'src/lab.dart';

/// A barista brings a colleague onto the counter. Ana runs it in a browser,
/// signed in. Ben has an address and a password and has never opened the
/// app.
///
/// Ana invites Ben by his address, and the invite reaches him by mail. Ben
/// signs in with his address and password. Neither of them types either: the
/// field that has focus offers what the world knows.
void main(List<String> args) => World.run(args, (w) async {
  var server = await startLabServer(w);

  var anaEmail = 'ana.${w.id}@example.com';
  var anaPassword = 'counter-${w.id}';
  var ana = await createUser(
    server,
    'Ana',
    role: 'staff',
    email: anaEmail,
    password: anaPassword,
  );
  w.person(
    'Ana',
    email: anaEmail,
    password: anaPassword,
    userId: ana.id,
    app: Launch(
      'Lab',
      knobs: {'server': '${server.url}', 'session': ana.token, 'person': 'Ana'},
    ),
    on: const Studio(Devices.window),
  );

  var benEmail = 'ben.${w.id}@example.com';
  var benPassword = 'espresso-${w.id}';
  var ben = await createUser(
    server,
    'Ben',
    email: benEmail,
    password: benPassword,
  );
  w.person(
    'Ben',
    email: benEmail,
    password: benPassword,
    userId: ben.id,
    app: Launch('Lab', knobs: {'server': '${server.url}', 'person': 'Ben'}),
  );
});
