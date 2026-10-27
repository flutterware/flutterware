import 'package:flutterware/world.dart';

/// A world on a stack it does not host: it reads where its server is, and
/// says so before it seeds anything.
void main(List<String> args) => World.run(args, (w) async {
  w.progress('Seeding ${w.service('server').url}');
  w.person('Ana', email: 'ana.${w.id}@example.com');
});
