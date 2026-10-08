/// How to write a scenario, in parts.
///
/// The panel's empty state used to be the only place this was said, which made
/// it the one thing about the feature an agent could not find: `list` and
/// `actions` describe how to *run* scenarios, and nothing described how to
/// write one.
///
/// It is **parts and not one string** because its two readers want different
/// shapes of the same answer: a terminal wants the paragraph
/// [scenarioAuthoringHint] composes, and the panel's help page wants the
/// snippet syntax-highlighted and the points as rows. One source either way, so
/// neither can drift into teaching an API the other does not.
///
/// [directory] is the package's configured scenario directory, because "where
/// does the file go" is the half of the answer that is per-project.
library;

import '../utils/source_code/escape_dart_string.dart';

String scenarioAuthoringIntro(String directory) =>
    'A scenario is an ordinary widget test that takes a screenshot at each '
    'step. `flutter test $directory` runs it, with no daemon and no GUI.';

/// The example, as Dart source — no indent, so the panel can highlight it and
/// the terminal can indent it itself.
String scenarioAuthoringExample(String directory) =>
    '''
// $directory/shop_test.dart
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('Around the shop', (s) async {
    await s.pumpWidget(const ShopApp());
    await s.tap('Get started', shot: Shot('Menu'));
    await s.enterText('Search', 'flat white');
    await s.screen('Results');
    expect(find.text('Flat white'), findsOneWidget);
  });
}''';

const scenarioAuthoringImportNote =
    'The import is `package:flutterware/flutter_test.dart`. It includes all '
    'of `package:flutter_test`, so an existing test compiles once you change '
    'its import.';

/// The API worth knowing, each as `(what it is, what it does)`. Backticks mark
/// code either reader renders as code.
const scenarioAuthoringPoints = <(String, String)>[
  (
    's.tap / s.enterText',
    'take a String (visible text), a Key, an IconData, a Type or a Finder. '
        'Each settles, then captures.',
  ),
  (
    "Shot('Name')",
    'names a capture; `Shot.skip` suppresses one; `s.screen(name)` captures '
        'without acting.',
  ),
  (
    'scenario(..., shots: Shots.manual)',
    'captures only where a Shot asks. For every scenario in a folder, pass '
        "`runScenarios(shots: ...)` in the folder's "
        '`flutter_test_config.dart`.',
  ),
  (
    "s.split({'pays': () async {…}, 'declines': () async {…}})",
    'forks the scenario: every branch runs, and the steps before the fork '
        'are captured once.',
  ),
  (
    's.tester',
    'is the real WidgetTester: all of flutter_test, with no captures.',
  ),
  (
    'recordAppEvent(AppEvent.request(…))',
    'reports what a fake did, shown between two steps: `.request`, '
        '`.query`, `.analytics`, `.log` or `.custom`. Import '
        '`package:flutterware/app_events.dart` in the fake itself. Outside a '
        'run it does nothing, and a mounted devbar shows the same report on '
        'its own tabs. Prints, logging records, platform channel messages and '
        'anything sent through a `DevbarHttpClient` are captured without any '
        'code.',
  ),
];

/// The command that writes a runnable scenario to edit.
String scenarioAuthoringCommand(String directory) =>
    'fw run scenarios new --file=$directory/shop_test.dart '
    '--name="Around the shop"';

/// The parts as one block of prose, for a terminal and for an agent.
///
/// Wrapped at 78 columns, the example indented under it: this lands in a
/// terminal that will not wrap it any more kindly than the width it was
/// written to.
String scenarioAuthoringHint(String directory) {
  // The command whole on its own line, however long: it is meant to be copied
  // into a terminal, and a wrap through `--name="..."` costs the reader the
  // paste.
  var closing = _wrap(
    "writes a runnable one to edit, as does the panel's New scenario button.",
  );
  return [
    _wrap(scenarioAuthoringIntro(directory)),
    scenarioAuthoringExample(directory)
        .split('\n')
        .map((line) => line.isEmpty ? '' : '  $line')
        .join('\n'),
    _wrap(scenarioAuthoringImportNote),
    [
      for (var (term, what) in scenarioAuthoringPoints)
        _wrap('- `$term` $what', hanging: '  '),
    ].join('\n'),
    '`${scenarioAuthoringCommand(directory)}`\n$closing',
  ].join('\n\n');
}

/// Greedy word wrap at 78 columns, continuation lines prefixed with [hanging].
String _wrap(String text, {String hanging = ''}) {
  var lines = <String>[];
  var line = StringBuffer();
  for (var word in text.split(' ')) {
    if (line.isEmpty) {
      line.write(word);
    } else if (line.length + 1 + word.length > 78) {
      lines.add('$line');
      line = StringBuffer('$hanging$word');
    } else {
      line.write(' $word');
    }
  }
  if (line.isNotEmpty) lines.add('$line');
  return lines.join('\n');
}

/// `Around the shop` → `around_the_shop_test.dart`.
///
/// Where `new` writes when the caller names no file. Public because the GUI's
/// dialog previews the path while you type: the action never overwrites, so
/// which file a name lands in is half of what pressing Create does.
///
/// Never a name the `file_names` lint refuses, which is any that starts with
/// a digit. A leading number is an order, so it is dropped: `01 Login` →
/// `login_test.dart`. The order belongs to the scenario's name, which is
/// what `shots` files its pictures by, and a numbered file was only ever a
/// way to sort the suite. A digit inside the first word is part of the name,
/// so it stays, behind a prefix: `2FA setup` → `scenario_2fa_setup_test.dart`.
String scenarioFileName(String name) {
  var slug = name
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '')
      .replaceFirst(RegExp(r'^(\d+_)+'), '');
  if (slug.startsWith(RegExp('[0-9]'))) slug = 'scenario_$slug';
  return '${slug.isEmpty ? 'scenario' : slug}_test.dart';
}

/// The file `new` writes: a stub app and a scenario that drives it.
///
/// It runs green as written, on purpose. `scenarios_new_test.dart` scaffolds
/// one and runs it, so the day `tap` or `Shot` changes shape this template
/// fails its own test instead of quietly teaching an API that no longer
/// exists — which is the failure mode a doc has and a scaffold does not.
String scenarioScaffold(String name) =>
    '''
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';

/// Replace `_Stub` with the app you want to walk through; the scenario below
/// is the shape. Every action takes a screenshot: `Shot('Name')` names one,
/// `Shot.skip` drops one, `s.screen('Name')` captures without acting.
void main() {
  scenario(${escapeDartString(name)}, (s) async {
    await s.pumpWidget(const _Stub());
    await s.tap('Continue', shot: Shot('Tapped continue'));
    expect(find.text('Tapped'), findsOneWidget);
  });
}

class _Stub extends StatefulWidget {
  const _Stub();

  @override
  State<_Stub> createState() => _StubState();
}

class _StubState extends State<_Stub> {
  var _tapped = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: _tapped
              ? const Text('Tapped')
              : TextButton(
                  onPressed: () => setState(() => _tapped = true),
                  child: const Text('Continue'),
                ),
        ),
      ),
    );
  }
}
''';
