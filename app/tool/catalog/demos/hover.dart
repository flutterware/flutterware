import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';

import 'shell.dart';

/// Says out loud whether the guest is receiving hover, because nothing else
/// does. Hover has no lasting effect a probe can read — an ink highlight is a
/// colour, not a widget — so a demo that turns it into text is the only way the
/// headless check can tell forwarding from silence.
@Preview(name: 'Hover', wrapper: wrapInApp)
Widget hoverProbe() => const _HoverProbe();

class _HoverProbe extends StatefulWidget {
  const _HoverProbe();

  @override
  State<_HoverProbe> createState() => _HoverProbeState();
}

class _HoverProbeState extends State<_HoverProbe> {
  var _inside = false;
  Offset? _at;

  @override
  Widget build(BuildContext context) {
    // The `Scaffold` is for the `Material` it brings: without one, every line
    // below draws in the giant red style `MaterialApp` installs to flag exactly
    // that, and the probe reads as a crash.
    return Scaffold(
      body: MouseRegion(
        onEnter: (_) => setState(() => _inside = true),
        onHover: (e) => setState(() => _at = e.localPosition),
        onExit: (_) => setState(() {
          _inside = false;
          _at = null;
        }),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              Text(_inside ? 'POINTER IN' : 'POINTER OUT'),
              if (_at case var at?)
                Text('at ${at.dx.round()},${at.dy.round()}')
              else
                const Text('no hover yet'),
            ],
          ),
        ),
      ),
    );
  }
}
