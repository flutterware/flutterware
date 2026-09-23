import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';

import 'package:flutterware/previews.dart';

import 'shell.dart';

/// Declares its controls by reading them while it builds, which is how the
/// catalog learns they exist — there is no list of knobs anywhere, only the
/// calls a demo makes.
@Preview(name: 'Knobs', wrapper: wrapInApp)
Widget knobs() => const _Knobs();

class _Knobs extends StatelessWidget {
  const _Knobs();

  @override
  Widget build(BuildContext context) {
    var parameters = context.knobs;
    var label = parameters.string('label', 'Hello');
    var count = parameters.int('count', 2, min: 0, max: 9);
    var dense = parameters.bool('dense', false);
    return Scaffold(
      appBar: AppBar(title: const Text('Knobs')),
      body: Center(
        child: Text(
          'KNOB $label x$count ${dense ? 'dense' : 'roomy'}',
          style: TextStyle(fontSize: dense ? 12 : 20),
        ),
      ),
    );
  }
}
