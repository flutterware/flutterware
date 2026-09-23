import 'package:material_ui/material_ui.dart';

import 'package:flutterware/previews.dart';

/// Stands in for a project's own catalog shell.
///
/// The axes are declared inside it, by asking for them, which is how the
/// catalog learns they exist — there is no list of axes anywhere, only the
/// calls the shell makes. That leaves `wrapInApp` an ordinary
/// `Widget Function(Widget)`: `@Preview(wrapper: wrapInApp)` takes it, Flutter's
/// own previewer calls it with one argument, and the real app calls it like any
/// other function. In all three the axes answer with their defaults.
enum Flavor { dev, staging, prod }

/// Small and grey: the probe is for reading, not for looking at.
const _probeStyle = TextStyle(fontSize: 10, color: Color(0x8a000000));

Widget wrapInApp(Widget child) => PreviewShell(
  'app',
  builder: (context, axes) {
    // Labels, not identifiers: only the labels cross the wire, so the top bar
    // shows what is written here rather than `Flavor.prod.name`.
    var flavor = axes.picker('flavor', {
      'Dev': Flavor.dev,
      'Staging': Flavor.staging,
      'Production': Flavor.prod,
    }, Flavor.dev);
    var compact = axes.flag('compact', false);
    return _Shell(flavor: flavor, compact: compact, child: child);
  },
);

class _Shell extends StatelessWidget {
  const _Shell({
    required this.flavor,
    required this.compact,
    required this.child,
  });

  final Flavor flavor;
  final bool compact;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: switch (flavor) {
          Flavor.dev => const Color(0xff3366ff),
          Flavor.staging => const Color(0xffff9900),
          Flavor.prod => const Color(0xff11aa55),
        },
        visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      ),
      // On screen so the headless check can read which way the axes are set
      // without a picture — the probe walks the tree for Text.
      home: Stack(
        children: [
          child,
          Positioned(
            right: 0,
            bottom: 0,
            // Styled, because a `Text` with no `Material` above it inherits the
            // style `MaterialApp` installs for exactly that mistake: 48px red
            // on a yellow double underline. A probe that paints like a crashed
            // demo is one you re-diagnose every time you see it.
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: DefaultTextStyle(
                style: _probeStyle,
                child: Text(
                  'SHELL ${flavor.name} ${compact ? 'compact' : 'roomy'}',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
