import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/scenarios_core.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/scenarios/film_encode.dart';
import 'package:flutterware_app/src/scenarios/video_dialog.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';

/// The video dialog's two testable halves: the command it prints, and the
/// arithmetic behind the bar it draws. The dialog itself is looked at in the
/// catalog — `tool/catalog/demos/video_dialog.dart` has a preview per state.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('fw-video-dialog'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('the command the dialog shows', () {
    String command({
      String package = '.',
      bool nameThePackage = false,
      ScenarioVideoOptions options = const ScenarioVideoOptions(),
      String? device,
      Map<String, String> axes = const {},
    }) => scenarioVideoCommand(
      pluginId: 'flutterware.scenarios',
      package: package,
      file: 'test/scenarios/shop_test.dart',
      scenario: 'Order a cappuccino',
      nameThePackage: nameThePackage,
      options: options,
      device: device,
      axes: axes,
    );

    ScenariosCore core() {
      var worktree = Worktree(path: root.path);
      return ScenariosCore(
        PluginHost(
          id: 'flutterware.scenarios',
          label: 'Scenarios',
          worktree: worktree,
          workspace: Workspace(
            root: worktree.path,
            declared: [Pkg('.')],
            discovered: const ['.'],
            appContext: AppContext(logger: LogClient.print()),
            flutterSdk: FlutterSdkPath('/tmp/flutter'),
          ),
          config: const {
            'packages': [
              {'path': '.'},
            ],
          },
        ),
      );
    }

    test('names the plugin the way the CLI resolves it, and one scenario', () {
      // `fw` matches on the last dotted segment, not the full id — and a film
      // is one scenario, so both selectors are always on the line.
      expect(
        command(),
        'dart run flutterware run scenarios video '
        '--file=test/scenarios/shop_test.dart '
        "--scenario='Order a cappuccino'",
      );
    });

    test('leaves the defaults off and spells the rest', () {
      var line = command(
        options: const ScenarioVideoOptions(
          scale: 2,
          fps: 60,
          crf: 23,
          reel: true,
          branches: ['a cappuccino', 'large cup'],
          output: 'docs/reel.mp4',
        ),
        device: 'iphone-13',
      );
      expect(line, contains('--scale=2'));
      expect(line, contains('--fps=60'));
      expect(line, contains('--crf=23'));
      expect(line, contains('--reel=true'));
      expect(line, contains('--device=iphone-13'));
      expect(line, contains('--output=docs/reel.mp4'));
      // One flag per split, never a comma-separated list: a branch is a label
      // an author wrote in a sentence.
      expect(line, contains("--branch='a cappuccino'"));
      expect(line, contains("--branch='large cup'"));
    });

    test('names the app axes the page ran under, as the action reads them', () {
      expect(
        command(axes: {'contrast': 'high', 'brand': 'tea'}),
        contains('--axes=brand=tea,contrast=high'),
      );
      expect(command(), isNot(contains('--axes')));
    });

    test('a default is not worth printing', () {
      expect(command(), isNot(contains('--scale')));
      expect(command(), isNot(contains('--fps')));
      expect(command(), isNot(contains('--crf')));
      expect(command(), isNot(contains('--reel')));
    });

    test('every flag it prints is one the action declares', () {
      var action = core().report.actions.firstWhere(
        (a) => a.id == videoActionId,
      );
      var declared = {for (var parameter in action.parameters) parameter.id};
      var printed = command(
        package: 'packages/ui',
        nameThePackage: true,
        device: 'iphone-13',
        axes: {'brand': 'tea'},
        options: const ScenarioVideoOptions(
          scale: 2,
          fps: 60,
          crf: 23,
          reel: true,
          branches: ['left'],
          output: 'docs/reel.mp4',
        ),
      );
      var flags = RegExp(r'--([a-z-]+)=')
          .allMatches(printed)
          .map((m) => m.group(1)!)
          .toSet();

      expect(flags, isNotEmpty);
      // A flag renamed on the action and not here is a command that fails the
      // moment somebody copies it out of the dialog.
      expect(declared, containsAll(flags));
    });
  });

  group('the bar', () {
    test('has no fraction until the film knows how long it is', () {
      // The length of a film is what the scenario does, so there is nothing to
      // be a percentage of while it is still being drawn.
      expect(const ScenarioFilmProgress(frames: 87).fraction, isNull);
      expect(
        const ScenarioFilmProgress(frames: 296, total: 331).fraction,
        closeTo(0.894, 0.001),
      );
    });

    test('counts film rather than frames, for the reader', () {
      expect(
        const ScenarioFilmProgress(frames: 90, fps: 30).filmed,
        const Duration(seconds: 3),
      );
    });
  });
}
