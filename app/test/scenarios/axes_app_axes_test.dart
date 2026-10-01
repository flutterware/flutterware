import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/scenarios/axes.dart';

/// The app's own axes where the address, the wire and the artifact tree meet.
///
/// Values the host never interprets: it carries them to the harness in one
/// argument, writes them under `axis.` on an address, and appends them to a
/// directory name in the order the guest's own slug does.
void main() {
  const tea = ScenarioAxes(
    device: 'iphone-16',
    language: 'fr',
    appAxes: {'contrast': 'high', 'brand': 'tea'},
  );

  test('a slug ends with the values, by axis name', () {
    expect(axisSlug(tea), 'iphone-16-fr-tea-high');
    expect(axisSlug(const ScenarioAxes(appAxes: {'brand': 'tea'})), 'tea');
  });

  test('an address carries them under axis., apart from the built-ins', () {
    expect(tea.toParams(), {
      'device': 'iphone-16',
      'language': 'fr',
      'axis.brand': 'tea',
      'axis.contrast': 'high',
    });
  });

  test('the harness gets them whole, in one argument', () {
    var args = tea.harnessArgs();
    expect(jsonDecode(args['axes']!), {'brand': 'tea', 'contrast': 'high'});
    expect(
      const ScenarioAxes(device: 'iphone-16').harnessArgs(),
      isNot(contains('axes')),
    );
  });

  test('two assignments differing only there are two', () {
    expect(tea, isNot(tea.copyWith(appAxes: {'brand': 'coffee'})));
    expect(
      tea,
      tea.copyWith(appAxes: {'brand': 'tea', 'contrast': 'high'}),
      reason: 'equal by value, not by identity',
    );
    expect(const ScenarioAxes(appAxes: {'brand': 'tea'}).isEmpty, isFalse);
  });
}
