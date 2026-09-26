import 'package:flutterware/world.dart';

/// A world with nobody's app in it, for the owner's tests: a real script in
/// a real process, and nothing to build.
void main(List<String> args) => World.run(args, (w) async {
  var mood = w.knob('mood', options: ['calm', 'busy'], initial: 'calm');
  w.progress('Mood is $mood');
  w.person('Ana', email: 'ana.${w.id}@example.com');
  if (mood == 'busy') w.person('Leo', phone: '+447700900001');
  w.action('Wave', (run) => run.progress('Ana waves'));
  w.onClose(() => print('closing ${w.id}'));
});
