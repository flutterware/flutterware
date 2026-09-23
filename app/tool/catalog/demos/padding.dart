import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';

import 'shell.dart';

/// Reports the padding a demo actually sees, which is the only way to tell a
/// notch that is drawn from one that is respected.
@Preview(name: 'Padding', wrapper: wrapInApp)
Widget paddingProbe() => const _PaddingProbe();

class _PaddingProbe extends StatelessWidget {
  const _PaddingProbe();

  @override
  Widget build(BuildContext context) {
    var padding = MediaQuery.paddingOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Padding')),
      body: Center(child: Text('PADDING ${padding.top},${padding.bottom}')),
    );
  }
}
