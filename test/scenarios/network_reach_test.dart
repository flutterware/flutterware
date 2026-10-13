import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/network.dart' show recordLaneNotice;

/// The one rung of the network ladder that used to lose silently.
///
/// `--network=record` is always a deliberate act at a command line, and a
/// scenario stating its own mode overrules it — correctly, since nearest wins.
/// A consumer ran a record against a scenario declaring `replay`, watched it
/// pass, and found the store empty. A record run now reaches `replay`; against
/// `off` and `live`, which it still cannot reach, it says so.
void main() {
  group('recordOverriddenMessage', () {
    test('names the scenario, its mode and the altitude that can record', () {
      for (var own in [ScenarioNetwork.off, ScenarioNetwork.live]) {
        var said = recordOverriddenMessage(
          'Store',
          own,
          ScenarioNetwork.record,
        );

        expect(said, isNotNull);
        expect(said, contains('"Store"'));
        expect(said, contains('network: ${own.name}'));
        expect(said, contains('runScenarios(network: ...)'));
        expect(said, contains('flutter_test_config.dart'));
      }
    });

    test('says nothing about replay, which a record run reaches', () {
      expect(
        recordOverriddenMessage(
          'Store',
          ScenarioNetwork.replay,
          ScenarioNetwork.record,
        ),
        isNull,
      );
    });

    test('says nothing when the run asked for anything else', () {
      for (var run in [
        ScenarioNetwork.off,
        ScenarioNetwork.live,
        ScenarioNetwork.replay,
        null,
      ]) {
        expect(
          recordOverriddenMessage('Store', ScenarioNetwork.live, run),
          isNull,
          reason: 'only a record run loses something it cannot get back',
        );
      }
    });

    test('says nothing when the scenario stated nothing', () {
      expect(
        recordOverriddenMessage('Store', null, ScenarioNetwork.record),
        isNull,
      );
    });

    test('says nothing when the scenario agrees', () {
      expect(
        recordOverriddenMessage(
          'Store',
          ScenarioNetwork.record,
          ScenarioNetwork.record,
        ),
        isNull,
      );
    });
  });

  group('notRecordedFailure', () {
    test('lists every miss, the store and the command', () {
      var said = notRecordedFailure('Store', [
        'GET https://cdn.example.com/a.jpg',
        'GET https://cdn.example.com/b.glb',
      ], 'test/scenarios/network');

      expect(said, contains('"Store"'));
      expect(said, contains('2 requests'));
      expect(said, contains('  GET https://cdn.example.com/a.jpg\n'));
      expect(said, contains('  GET https://cdn.example.com/b.glb\n'));
      expect(said, contains('test/scenarios/network'));
      expect(said, contains('--network=record'));
    });

    test('folds a long list', () {
      var said = notRecordedFailure('Store', [
        for (var i = 0; i < 14; i++) 'GET https://cdn.example.com/$i.jpg',
      ], 'store');
      expect(said, contains('… and 4 more'));
      expect(said, isNot(contains('/13.jpg')));
    });

    test('says nothing when nothing was missed', () {
      expect(notRecordedFailure('Store', const [], 'store'), isNull);
    });
  });

  group('recordLaneNotice', () {
    test('speaks only without Flutter GPU, in a package that uses it', () {
      expect(
        recordLaneNotice(flutterGpu: false, dependsOnFlutterGpu: true),
        allOf(contains('--enable-flutter-gpu'), contains('fw run scenarios')),
      );
      expect(
        recordLaneNotice(flutterGpu: true, dependsOnFlutterGpu: true),
        isNull,
      );
      expect(
        recordLaneNotice(flutterGpu: false, dependsOnFlutterGpu: false),
        isNull,
      );
    });
  });

  group('inertNetworkMessage', () {
    String? said(
      ScenarioNetwork reach, {
      bool stated = true,
      int requests = 0,
    }) =>
        inertNetworkMessage('Store', reach, stated: stated, requests: requests);

    test('names the mode and the layer that hides a request from it', () {
      var message = said(ScenarioNetwork.replay);

      expect(message, isNotNull);
      expect(message, contains('"Store"'));
      expect(message, contains('network: replay'));
      expect(message, contains('CachedNetworkImage'));
      expect(message, contains('getFileStream'));
    });

    test('says nothing once a single request was made', () {
      for (var reach in [
        ScenarioNetwork.replay,
        ScenarioNetwork.record,
        ScenarioNetwork.live,
      ]) {
        expect(said(reach, requests: 1), isNull);
      }
    });

    test('says nothing about off, which is what no requests looks like', () {
      expect(said(ScenarioNetwork.off), isNull);
    });

    test('holds only a scenario that stated the mode for itself', () {
      // A folder's `runScenarios(network: ...)` covers a whole suite, where
      // most scenarios legitimately fetch nothing.
      expect(said(ScenarioNetwork.replay, stated: false), isNull);
    });
  });
}
