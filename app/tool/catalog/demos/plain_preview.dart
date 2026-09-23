import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';

/// Flutter's own annotation, and **nothing of ours anywhere in the file** — no
/// `package:flutterware` import, no shell, no wrapper.
///
/// A fixture before it is a demo. A project that already writes `@Preview` is
/// the one this tool most wants to be openable by, and the scanner accepted the
/// annotation the whole time — it was the generated wrapper, typing its getter
/// as `Demo`, that turned every such project into a compile error naming
/// generated code. Only an entry that renders proves otherwise, so this one
/// carries its own `MaterialApp` and stays deliberately unhelped.
@Preview(name: 'Plain preview')
Widget plainPreview() => const _PlainPreview();

class _PlainPreview extends StatelessWidget {
  const _PlainPreview();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: const Text('Plain preview')),
        body: const Center(child: Text('NO FLUTTERWARE IMPORT')),
      ),
    );
  }
}
