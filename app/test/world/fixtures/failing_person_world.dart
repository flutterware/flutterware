import 'package:flutterware/world.dart';

/// A world one of whose people has an app that cannot start: it names an
/// entry point nobody declared. The world opens anyway.
void main(List<String> args) => World.run(args, (w) async {
  w.person('Ana', userId: 'u1');
  w.person('Leo', userId: 'u2', app: Launch('Nowhere'));
});
