import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';

import 'shell.dart';

/// Compiles, reloads, and is wrong — which is the gap the Problems tab exists
/// to close.
///
/// Deliberately broken and deliberately permanent, the same way
/// `does_not_compile.dart` is, and for a reason it does not cover: that one
/// fails the *compiler*, which every part of the loop already reports loudly.
/// This one passes every check that runs before a frame and then paints
/// Flutter's yellow-and-black stripes, so it is the only standing entry that
/// exercises the render-error path at all.
///
/// A `Row` of fixed-width boxes wider than any panel it is given. The overflow
/// is reported from `paint`, which means it fires **once per frame** — so this
/// is also the fixture that shows the count doing its job, rather than several
/// hundred identical rows.
@Preview(name: 'Overflows', wrapper: wrapInApp)
Widget overflows() => const _Overflows();

class _Overflows extends StatelessWidget {
  const _Overflows();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Overflows')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            for (var i = 0; i < 8; i++)
              Container(
                width: 160,
                height: 64,
                margin: const EdgeInsets.only(right: 8),
                color: Colors.blueGrey.shade100,
                alignment: Alignment.center,
                child: Text('box $i'),
              ),
          ],
        ),
      ),
    );
  }
}
