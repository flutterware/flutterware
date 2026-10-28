import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';

import 'shell.dart';

/// What the view says about the screen it is on: its refresh rate, size and
/// pixel ratio. Lottie paces its animations by that refresh rate, and in a
/// debug build `View.display` fails an assertion when the embedder never
/// announced a display, so a guest that forgets to draws an error here
/// instead of the numbers.
@Preview(name: 'Display probe', wrapper: wrapInApp)
Widget displayProbe() => Builder(
  builder: (context) {
    var display = View.of(context).display;
    return Scaffold(
      body: Center(
        child: Text(
          '${display.refreshRate.round()} Hz · '
          '${display.size.width.round()}×${display.size.height.round()} · '
          '${display.devicePixelRatio}x',
        ),
      ),
    );
  },
);
