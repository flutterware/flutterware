import 'package:flutterware/world.dart';
import 'package:world_lab_server/world_lab_server.dart' show menu;

import 'src/lab.dart';

/// A busy shop: two baristas, three regulars with the app, and a kitchen
/// that brews every order through a job queue — each order a job that moves
/// it to preparing and to ready, stamps a loyalty card and, every fifth
/// stamp, gives away a coffee.
///
/// Rush hour brings a dozen walk-ins with no app, a few hundred milliseconds
/// apart, and the kitchen backs up the way a real one does. It is the world
/// to judge the Worlds screen on when there is a lot going on: many steps,
/// long ones, jobs, plumbing tables, pushes to people who did not tap.
///
/// The Regulars knob brings more of them, each with the app, for a world
/// with more phones than fit the screen.
void main(List<String> args) => World.run(args, (w) async {
  var server = await startLabServer(w, kitchen: true);
  var count = w.knob(
    'Regulars',
    options: ['3', '6', '10'],
    initial: '3',
    description: 'How many regulars have the app',
  );

  for (var name in ['Ana', 'Cleo']) {
    var email = '${name.toLowerCase()}.${w.id}@example.com';
    var staff = await createUser(server, name, role: 'staff', email: email);
    w.person(
      name,
      email: email,
      userId: staff.id,
      app: Launch(
        'Lab',
        knobs: {
          'server': '${server.url}',
          'session': staff.token,
          'person': name,
        },
      ),
    );
  }
  var regulars = <LabUser>[];
  for (var name in _regulars.take(int.parse(count))) {
    var phone = newPhone();
    var regular = await createUser(server, name, phone: phone);
    regulars.add(regular);
    w.person(
      name,
      phone: phone,
      userId: regular.id,
      app: Launch(
        'Lab',
        knobs: {
          'server': '${server.url}',
          'session': regular.token,
          'person': name,
        },
      ),
    );
  }

  w.action(
    'Rush hour',
    (run) => rushHour(server, run),
    description: 'A dozen walk-ins order, and the kitchen works the queue',
  );
  w.action(
    'The regulars order',
    (run) async {
      for (var (i, regular) in regulars.indexed) {
        await call(server, 'POST', '/orders', {
          'item': menu[i % menu.length],
        }, regular.token);
      }
    },
    description:
        'Each regular orders under their own session, and each is pushed '
        'when theirs is ready',
  );
});

const _regulars = [
  'Leo',
  'Mia',
  'Noor',
  'Omar',
  'Priya',
  'Sam',
  'Tess',
  'Ugo',
  'Vera',
  'Wen',
];
