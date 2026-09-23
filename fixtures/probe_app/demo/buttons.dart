import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';

import 'shell.dart';

/// A single demo in its own file, so it gets no group and sits at the top
/// level of the catalog — the counterpart to `home_page.dart`.
@Preview(name: 'Buttons', wrapper: wrapInApp)
Widget buttons() => Scaffold(
  appBar: AppBar(title: const Text('Buttons')),
  body: Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 12,
      children: [
        for (var i = 0; i < 5; i++)
          ElevatedButton(onPressed: () {}, child: Text('Elevated $i')),
        FilledButton(onPressed: () {}, child: const Text('Filled')),
        OutlinedButton(onPressed: () {}, child: const Text('Outlined')),
        TextButton(onPressed: () {}, child: const Text('Text')),
        const ElevatedButton(onPressed: null, child: Text('Disabled')),
      ],
    ),
  ),
);
