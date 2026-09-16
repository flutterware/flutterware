import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/app_events/events.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
    appEventBuffer = AppEventBuffer();
  });
  tearDown(() {
    scenarioRunListener = null;
    appEventBuffer = null;
  });

  group('setup is a step of its own', () {
    scenario('before the first picture, with what it returned in hand', (
      s,
    ) async {
      var token = await s.setup('fresh account', () async {
        // Real async, the kind a setup does: under the fake clock this only
        // completes because the beat gives it a real turn.
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return 'token-1';
      });
      expect(token, 'token-1');
      await s.pumpWidget(MaterialApp(home: Text(token)));
      await s.screen('home');
    });
    tearDown(() {
      expect(captures.first.kind, ScenarioCaptureKind.setup);
      expect(captures.first.name, 'fresh account');
      expect(captures.first.verb, 'setup');
      expect(captures.first.bytes, isNull, reason: 'nothing to look at');
      expect(captures.first.ms, isNotNull);
      expect(captures.first.ms!, greaterThanOrEqualTo(5));
      expect(captures.first.parent, isNull, reason: 'the flow starts here');
      expect(captures.last.name, 'home');
      expect(
        captures.last.parent,
        captures[captures.length - 2].index,
        reason: 'the picture after the beat chains onto the beat',
      );
    });
  });
}
