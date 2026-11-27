import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware/translations.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/translations_core.dart';
import 'package:flutterware_app/src/plugins/native/translations_results.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/scenarios/axes.dart';
import 'package:flutterware_app/src/scenarios/runner.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:path/path.dart' as p;

/// The export over a fake runner: the scenarios core around it is the real
/// one, so its run directories and the sweep that trims them are too.
void main() {
  late Directory root;

  TranslationsCore core(_FakeRunner runner) {
    var worktree = Worktree(path: root.path);
    return TranslationsCore(
      PluginHost(
        id: translationsPluginId,
        label: 'Translations',
        worktree: worktree,
        workspace: Workspace(
          root: worktree.path,
          declared: [Pkg('.')],
          discovered: const ['.'],
          appContext: AppContext(logger: LogClient.print()),
          flutterSdk: FlutterSdkPath('/tmp/flutter'),
        ),
        config: {
          'packages': [
            {
              'path': '.',
              'catalogs': [
                {'name': 'app', 'files': 'i18n/*.json', 'template': 'en'},
              ],
            },
          ],
        },
      ),
      scenarioRunner: (path, {required onLog}) => runner,
    );
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('fw_translations_export_test');
    File(p.join(root.path, 'i18n', 'en.json'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'save': 'Save'}));
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('measuring max lengths keeps the runs the export reads', () async {
    // Clean up to +30%, clipped from +40%: the export runs its own run, the
    // probe's baseline, four rungs and the clip's picture, more runs than the
    // sweep keeps.
    var runner = _FakeRunner(clipsAt: 40);
    var subject = core(runner);

    var result =
        (await subject.invoke('export', arguments: {'max-lengths': 'true'}))!
            as TranslationExportResult;

    expect(runner.runs, 7);
    expect(result.keysSeen, 1);
    expect(result.maxLengths, 1);
    var export = await TranslationExport.read(
      p.join(root.path, 'build', 'translations'),
    );
    var maxLength = export.keys.single.maxLength!;
    expect(maxLength.clipsChars, greaterThan(maxLength.chars));
    expect(maxLength.screen, isNotNull, reason: "the baseline's picture");
    expect(maxLength.clipped, isNotNull, reason: "the clip's picture");
    expect(export.keys.single.representative, isNotNull);
  });

  test('the probe runs leave no directory behind', () async {
    var subject = core(_FakeRunner(clipsAt: 40));
    await subject.invoke('export', arguments: {'max-lengths': 'true'});

    var runs = Directory(p.join(root.path, 'build', 'flutterware'));
    expect(runs.listSync().map((entity) => p.basename(entity.path)), [
      'scenario_runs',
    ]);
    expect(
      Directory(p.join(runs.path, 'scenario_runs')).listSync(),
      hasLength(1),
      reason: "the export's own run, as a run without max lengths leaves it",
    );
  });
}

/// One scenario with one step showing `save`, which overflows from
/// [clipsAt] percent of padding.
class _FakeRunner extends ScenarioRunner {
  _FakeRunner({required this.clipsAt})
    : super(packageRoot: '/none', directory: 'none', flutterSdkRoot: '/none');

  final int clipsAt;
  var runs = 0;

  @override
  String get logPath => '/none/scenarios.log';

  @override
  Future<Map<String, Object?>> run({
    required String outDir,
    String? file,
    String? scenario,
    String? tag,
    ScenarioAxes axes = const ScenarioAxes(),
    String? unspecifiedDevice,
    int? jobs,
    double? captureScale,
    bool captureRaw = false,
    ScenarioPixels pixels = ScenarioPixels.all,
    int? expandTranslations,
    bool narrowestDevice = false,
    bool captureNative = false,
    FilmSettings? film,
    bool filmReel = false,
    Duration? recordInterval,
    double? recordScale,
    int recordMaxFrames = 90,
    DateTime? clock,
    ScenarioNetwork? network,
    ScenarioNetwork? projectNetwork,
    String? networkStore,
  }) async {
    runs++;
    // A real run takes seconds. Two runs in one millisecond would share the
    // directory a run names after the time it started.
    await Future<void>.delayed(const Duration(milliseconds: 2));
    var base = p.join(outDir, '1-menu');
    File('$base.png')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(const [1, 2, 3]);
    File('$base.keys.json').writeAsStringSync(
      jsonEncode({
        'keys': [
          {
            'catalog': 'app',
            'key': 'save',
            'start': 0,
            'end': 4,
            'rect': '10,10 40×20',
            'overflowed': (expandTranslations ?? 0) >= clipsAt,
          },
        ],
      }),
    );
    return {
      'ms': 5,
      'scenarios': [
        {
          'file': 'test/scenarios/menu_test.dart',
          'name': 'Menu',
          'ok': true,
          'ms': 3,
          'translations': {
            'app': {'save': 'Save'},
          },
          'steps': [
            {
              'index': 1,
              'name': 'menu',
              'auto': false,
              'image': '$base.png',
              'format': 'png',
              'width': 390,
              'height': 844,
              'keys': '$base.keys.json',
              'texts': ['Save'],
            },
          ],
        },
      ],
    };
  }

  @override
  Future<List<ScenarioListing>> list() async => const [];

  @override
  Future<void> dispose() async {}
}
