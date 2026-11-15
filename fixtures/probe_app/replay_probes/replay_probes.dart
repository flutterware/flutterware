import 'dart:io';

import 'package:flutterware/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Scenarios the scenario replay page is checked against, outside `test/` so
/// no suite runs them: two of them fail on purpose.
/// `app/integration_test/scenario_replay_test.dart` builds a page of them.
void main() {
  // Tapped by key: a draft changes the words, and a tap by words would miss.
  scenario('Greets', (s) async {
    var t = indexTranslations('probe');
    await s.pumpWidget(
      _app(Text(t('greeting', 'Hello'), key: const Key('greeting'))),
    );
    await s.tap(const Key('greeting'));
  });

  // Passes under `flutter test`, and cannot work in a browser.
  scenario('Reads the disk', (s) async {
    var name = File('pubspec.yaml').readAsLinesSync().first;
    await s.pumpWidget(_app(Text(name)));
  });

  // Every step passes. The failure comes once the body has returned.
  scenario('Fails after it ends', (s) async {
    addTearDown(() => throw StateError('The tear-down failed'));
    await s.pumpWidget(_app(const Text('Shown')));
  });

  // A build that throws on the first step, reported by the binding only
  // when the test ends: a replay stopped on the second step still has to say
  // it. Not an overflow: the page runs without asserts, and Flutter reports
  // an overflow only through one.
  scenario('Breaks a build, then goes on', (s) async {
    await s.pumpWidget(
      _app(Builder(builder: (_) => throw StateError('The build failed'))),
    );
    await s.pumpWidget(_app(const Text('Mended')));
  });
}

Widget _app(Widget body) => MaterialApp(home: Scaffold(body: body));
