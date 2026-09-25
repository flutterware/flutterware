import 'package:flutterware/world.dart';

import 'src/lab.dart';

/// A barista and a regular. Ana runs the counter, signed in; Leo has a phone
/// number and has never used the app, so signing up with a code by SMS is the
/// first thing he does — the code is in the world's log.
///
/// The Leo knob starts him signed in instead, and the action Mia orders a
/// flat white puts an order on Ana's board from a customer with no app.
void main(List<String> args) => World.run(args, (w) async {
  var server = await startLabServer(w);
  var leoSignedIn = w.knob(
    'Leo',
    options: ['signed out', 'signed in'],
    initial: 'signed out',
    description: 'Whether Leo starts signed in, or signs up himself',
  );

  var ana = await createUser(
    server,
    'Ana',
    role: 'staff',
    email: w.email('ana'),
  );
  w.person(
    'Ana',
    email: w.email('ana'),
    userId: ana.id,
    app: Launch(
      'Lab',
      knobs: {'server': '${server.url}', 'session': ana.token, 'person': 'Ana'},
    ),
  );

  var phone = w.phone();
  var leo = leoSignedIn == 'signed in'
      ? await createUser(server, 'Leo', phone: phone)
      : null;
  w.person(
    'Leo',
    phone: phone,
    userId: leo?.id,
    app: Launch(
      'Lab',
      knobs: {
        'server': '${server.url}',
        'session': ?leo?.token,
        'person': 'Leo',
      },
    ),
  );

  w.action('Mia orders a flat white', (run) async {
    var mia = await createUser(server, 'Mia', phone: w.phone());
    run.progress('Mia is ${mia.id}');
    await call(server, 'POST', '/orders', {'item': 'Flat white'}, mia.token);
  }, description: 'A customer with no app puts an order on the board');
});
