import 'package:flutterware/world.dart';

import 'src/lab.dart';

/// A barista and a regular. Ana runs the counter, signed in, in a browser on
/// a desktop; Leo has a phone number and has never used the app, so signing
/// up with a code by SMS is the first thing he does — the code is in the
/// world's log.
///
/// The Leo knob starts him signed in instead. Mia has no app: the action Mia
/// orders a flat white puts her order on Ana's board.
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
    email: 'ana.${w.id}@example.com',
  );
  w.person(
    'Ana',
    email: 'ana.${w.id}@example.com',
    userId: ana.id,
    app: Launch(
      'Lab',
      knobs: {'server': '${server.url}', 'session': ana.token, 'person': 'Ana'},
    ),
    // The counter is a desktop: the same app, in a window, in a browser.
    on: const Studio(Devices.window),
  );

  var phone = newPhone();
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

  var miaPhone = newPhone();
  var mia = await createUser(server, 'Mia', phone: miaPhone);
  w.person('Mia', phone: miaPhone, userId: mia.id);

  // A service in the stack that is not Dart and sends its own mail stands
  // here as a few lines of SMTP to the world's inbox.
  var mail = await w.smtp('newsletter');
  w.action(
    'The newsletter goes out',
    (run) => sendNewsletter(port: mail.port, to: 'ana.${w.id}@example.com'),
    description: 'Ana gets the newsletter by email',
  );

  // A line that calls a function: an edit to it reaches the open world on
  // Reload, where an edit inside a closure would wait for a restart.
  w.action(
    'Mia orders a flat white',
    (run) => miaOrders(server, run, mia: mia),
    description: 'Mia orders through the API; the order shows on the counter',
  );
});
