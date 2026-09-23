import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';

import 'package:flutterware/previews.dart';

/// A second shell, with axes of its own.
///
/// A project has as many as it needs, and an entry gets the axes of the one its
/// `wrapper:` builds — so the top bar changes as you move between them. Its
/// `flavor` is deliberately named like the other shell's and takes different
/// values: two shells sharing an axis name must not inherit each other's
/// selection, which is what filing selections under the shell's id is for.
enum Loudness { quiet, loud }

enum Flavour { plain, fancy }

Widget wrapInPlainApp(Widget child) => PreviewShell(
  'plain',
  builder: (context, axes) {
    var loudness = axes.picker('loudness', {
      'Quiet': Loudness.quiet,
      'Loud': Loudness.loud,
    }, Loudness.quiet);
    var flavor = axes.picker('flavor', {
      'Plain': Flavour.plain,
      'Fancy': Flavour.fancy,
    }, Flavour.plain);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Stack(
        children: [
          child,
          Positioned(
            right: 0,
            bottom: 0,
            // See `shell.dart`: unstyled text under a `MaterialApp` and outside
            // a `Material` draws in Flutter's giant red debug style.
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: DefaultTextStyle(
                style: const TextStyle(fontSize: 10, color: Color(0x8a000000)),
                child: Text('OTHER ${loudness.name} ${flavor.name}'),
              ),
            ),
          ),
        ],
      ),
    );
  },
);

/// A `Scaffold`, for the `Material` it brings: a bare `Center` leaves its text
/// with the style `MaterialApp` installs to flag a missing one.
@Preview(name: 'Elsewhere', wrapper: wrapInPlainApp)
Widget elsewhere() => const Scaffold(body: Center(child: Text('ELSEWHERE')));
