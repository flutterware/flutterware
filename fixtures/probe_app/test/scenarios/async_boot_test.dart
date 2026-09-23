import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutterware/flutter_test.dart';

/// An app that reads the asset bundle at boot — and the guard that the two
/// lanes agree about it.
///
/// This is the shape that used to be green under `flutter test` and red under
/// `fw run scenarios`: `flutter test` sets `UNIT_TEST_ASSETS`, which makes
/// `flutter_test` answer `flutter/assets` from a `readAsBytesSync` rather than
/// from the engine, so the read completes under FakeAsync. The directly
/// spawned tester did not, so the same code rendered blank here.
///
/// [Shot.skip] on the pump is load-bearing: a captured step runs inside
/// `tester.runAsync`, which gives the real event loop a turn and hides the
/// difference. A project that skips the capture — as a project with its own
/// `pumpApp` does — is the one that sees it.
void main() {
  scenario('Async boot', (s) async {
    await s.pumpWidget(const _AsyncBootApp(), shot: Shot.skip);
    expect(find.textContaining('loaded'), findsOneWidget);
    await s.screen('Booted');
  });
}

class _AsyncBootApp extends StatefulWidget {
  const _AsyncBootApp();

  @override
  State<_AsyncBootApp> createState() => _AsyncBootAppState();
}

class _AsyncBootAppState extends State<_AsyncBootApp> {
  String? _loaded;

  @override
  void initState() {
    super.initState();
    rootBundle.loadString('assets/icons/check.svg').then((value) {
      if (mounted) setState(() => _loaded = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: _loaded == null
              ? const SizedBox.shrink()
              : Text('loaded ${_loaded!.length} chars'),
        ),
      ),
    );
  }
}
