import 'package:material_ui/material_ui.dart';
import 'package:flutterware_probes/main.dart';

import 'src/seed.dart';

/// A dev-only entry point that lives outside `lib/`, which is the whole point
/// of it.
///
/// It exists to hold the run guest to a non-`package:` entry point. The
/// wrapper the launch generates has to name three things three different ways:
/// this file by path, [Seed] beside it by path, and `MyHomePage` by the
/// `package:` URI it does have. Wrapping used to be refused here outright — no
/// knobs, no inspect, no act — on the grounds that a file outside `lib/` has no
/// `package:` URI for the wrapper to import. It does not need one.
///
/// `demo/` rather than a directory of its own because that is where this
/// package already keeps what is dev-only, and the previews plugin already
/// scans it — a config sending previews to `demo/` while its run plugin refused
/// `demo/` was one file disagreeing with itself.
void main({Seed seed = Seed.empty, String marker = '<none>'}) {
  runApp(_DevApp(seed: seed, marker: marker));
}

class _DevApp extends StatelessWidget {
  const _DevApp({required this.seed, required this.marker});

  final Seed seed;
  final String marker;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: Colors.white),
    home: Column(
      children: [
        // Both knobs on screen, because a knob you cannot read back from the
        // app is a knob whose value you are taking on trust.
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text('seed: ${seed.name} · marker: $marker'),
          ),
        ),
        const Expanded(child: MyHomePage(title: 'Dev entry point')),
      ],
    ),
  );
}
