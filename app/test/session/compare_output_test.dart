import 'package:flutterware/comparison_report.dart';
import 'package:flutterware_app/src/comparison/artifact.dart';
import 'package:flutterware_app/src/comparison/compare_command.dart';
import 'package:flutterware_app/src/comparison/runner.dart';
import 'package:flutterware_app/src/session/cli.dart';
import 'package:test/test.dart';

/// What `fw compare` says when it did not do what its summary line implies.
///
/// Both halves print a line that reads the same whether the tool concluded or
/// gave up — `0 scenarios, 0 run, 0 skipped`, `90 entries, 90 rendered` — and
/// both facts that separate those cases were recorded in the artifact and
/// shown to nobody. A consumer wiring this into a pull-request check measured
/// each of them and had no way to learn why.
void main() {
  late StringBuffer out;
  late FwCli cli;

  setUp(() {
    out = StringBuffer();
    cli = FwCli(
      openSession: () => throw StateError('not opened'),
      out: out,
      err: StringBuffer(),
    );
  });

  ComparisonResult previews({
    int rendered = 0,
    Map<String, int> because = const {},
  }) => ComparisonResult(
    items: const [],
    baseSha: 'abc123',
    headRoot: '/head',
    elapsed: Duration.zero,
    rendered: rendered,
    because: because,
  );

  group('why the skip rule could not answer', () {
    // The consumer's case: an empty diff, everything rendered, and three
    // minutes spent proving that nothing changed. The number said the skip
    // rule did not earn its keep; only this line says which path the two
    // checkouts disagreed about.
    test('one shared cause is one line, naming the path', () {
      cli.printPreviews(
        previews(rendered: 90, because: {'pubspec.lock differs': 90}),
      );

      expect(
        out.toString(),
        contains('because pubspec.lock differs — 90 entries'),
      );
    });

    test('a single entry is counted in the singular', () {
      cli.printPreviews(
        previews(rendered: 1, because: {'lib/theme.dart differs': 1}),
      );

      expect(out.toString(), contains('— 1 entry'));
    });

    // Folded first, so the cap is reached only by a branch whose entries
    // genuinely moved for different reasons — where the summary would
    // otherwise be as long as the catalog.
    test('a branch with many reasons prints three and counts the rest', () {
      cli.printPreviews(
        previews(
          rendered: 5,
          because: {
            'a differs': 5,
            'b differs': 4,
            'c differs': 3,
            'd differs': 2,
            'e differs': 1,
          },
        ),
      );

      expect(out.toString(), contains('a differs'));
      expect(out.toString(), contains('c differs'));
      expect(out.toString(), isNot(contains('d differs')));
      expect(out.toString(), contains('… and 2 more reasons'));
    });

    test('a half that skipped everything explains nothing', () {
      cli.printPreviews(previews());

      expect(out.toString(), isNot(contains('because')));
    });

    test('the scenario half counts scenarios, not entries', () {
      cli.printScenarios(
        ScenarioResults.of(
          items: const [],
          ran: 16,
          skipped: 0,
          elapsed: Duration.zero,
          because: {'pubspec.lock differs': 16},
        ),
      );

      expect(out.toString(), contains('— 16 scenarios'));
    });

    // A consumer's split-branch timeouts appeared nowhere in their job log,
    // and a base failure printed as `removed step 26` with no message.
    test('a scenario with no result says why, and is counted', () {
      cli.printScenarios(
        ScenarioResults.of(
          items: const [
            ScenarioComparison.notCompared(
              scenario: 'test/save.dart#Save',
              inconclusive:
                  'The base failed once and passed when replayed again: '
                  'an error dialog was showing.',
            ),
            ScenarioComparison(
              scenario: 'test/boot.dart#Boot',
              items: [],
              branches: [],
              state: ComparedState.broke,
              headErrors: ['setUpAll threw'],
            ),
          ],
          ran: 2,
          skipped: 0,
          elapsed: Duration.zero,
        ),
      );

      var printed = out.toString();
      expect(printed, contains('no result  test/save.dart#Save'));
      expect(printed, contains('not compared — The base failed once'));
      expect(printed, contains('head failed — setUpAll threw'));
      expect(printed, contains('0 skipped, 1 not compared in 0ms'));
    });
  });

  group('a half that could not run', () {
    // The dangerous pair: a scenario harness that will not build leaves the
    // same empty list as a project with no scenarios, and the same summary
    // line. "The tool never ran" and "nothing changed" must not read alike.
    test('says so, above the summary that reads like a clean verdict', () {
      cli.printScenarios(
        ScenarioResults.of(
          items: const [],
          ran: 0,
          skipped: 0,
          elapsed: Duration.zero,
          note:
              'The scenarios harness does not compile:\n'
              "harness.dart:12:5: Error: Method not found: 'runScenarios'.",
        ),
      );

      var printed = out.toString();
      expect(printed, contains('scenarios: The scenarios harness'));
      // Whole, not the first line: a refusal naming neither the file nor the
      // symbol is one nobody can act on.
      expect(printed, contains("Method not found: 'runScenarios'"));
      expect(
        printed.indexOf('scenarios: '),
        lessThan(printed.indexOf('0 scenarios, 0 run')),
      );
    });

    test('a half with nothing to explain says nothing', () {
      cli.printScenarios(
        ScenarioResults.of(
          items: const [],
          ran: 0,
          skipped: 3,
          elapsed: Duration.zero,
        ),
      );

      expect(out.toString().trim(), '0 scenarios, 0 run, 3 skipped in 0ms');
    });

    // The printed warning was not enough: a CI job reads the exit code, and a
    // consumer gating a pull request on `fw compare` recorded a comparison
    // that could not run as a pass. The gap is the exit-code's reason, and
    // the artifact stays written either way — the record is whole, the
    // verdict is not.
    test('leaves a verdict gap, so the command can refuse to exit 0', () {
      var broken = ComparisonArtifact(
        previews: previews(),
        scenarios: ScenarioResults.of(
          items: const [],
          ran: 0,
          skipped: 0,
          elapsed: Duration.zero,
          note:
              'The scenarios harness does not compile:\n'
              "harness.dart:12:5: Error: Method not found: 'runScenarios'.",
        ),
      );

      expect(
        verdictGap(broken),
        'the scenario half produced no verdict — '
        'The scenarios harness does not compile:',
      );
    });

    test('a half that ran leaves no gap, and neither does a missing one', () {
      expect(
        verdictGap(
          ComparisonArtifact(
            previews: previews(),
            scenarios: ScenarioResults.of(
              items: const [],
              ran: 3,
              skipped: 0,
              elapsed: Duration.zero,
            ),
          ),
        ),
        isNull,
      );
      // No scenarios plugin at all is an absent half, not a silent one.
      expect(verdictGap(ComparisonArtifact(previews: previews())), isNull);
    });

    // A consumer's CI met this as a green check over a red comment: every
    // scenario hit the same missing native library on both sides, so the half
    // ran, recorded 51 `failed` rows, and exited 0. `failed` means neither
    // side rendered — a half made of nothing else answered no question about
    // the branch, which is the note case wearing a different record.
    test('a half of nothing but failures is a gap, not a verdict', () {
      ScenarioComparison failed(String name) => ScenarioComparison.notRun(
        scenario: 'test/scenarios/a_test.dart#$name',
        state: ComparedState.failed,
      );
      var allFailed = ComparisonArtifact(
        previews: previews(),
        scenarios: ScenarioResults.of(
          items: [failed('one'), failed('two')],
          ran: 2,
          skipped: 0,
          elapsed: Duration.zero,
        ),
      );

      expect(
        verdictGap(allFailed),
        'the scenario half produced no verdict — '
        'all 2 scenarios failed on both sides',
      );

      // *All*, not *any*: one pre-broken flow beside a compared one is a half
      // that did its job, and the failed row is already a finding.
      expect(
        verdictGap(
          ComparisonArtifact(
            previews: previews(),
            scenarios: ScenarioResults.of(
              items: [
                failed('one'),
                ScenarioComparison.notRun(
                  scenario: 'test/scenarios/a_test.dart#three',
                  state: ComparedState.same,
                ),
              ],
              ran: 2,
              skipped: 0,
              elapsed: Duration.zero,
            ),
          ),
        ),
        isNull,
      );
    });

    // "All of it failed" is evidence of environment only over the whole
    // suite. A run narrowed with --entry compares the rows somebody picked,
    // and picking the one pre-broken flow must stay an ordinary finding —
    // not a permanent exit 1 no change on the branch can lift. The artifact
    // carries the narrowing, so a reader of `index.json` applies the same
    // rule the exit code did.
    test('narrowing switches the all-failed rule off, and not the note', () {
      ScenarioResults oneFailed() => ScenarioResults.of(
        items: [
          ScenarioComparison.notRun(
            scenario: 'test/scenarios/a_test.dart#pre-broken',
            state: ComparedState.failed,
          ),
        ],
        ran: 1,
        skipped: 0,
        elapsed: Duration.zero,
      );
      expect(
        verdictGap(
          ComparisonArtifact(previews: previews(), scenarios: oneFailed()),
        ),
        isNotNull,
      );
      expect(
        verdictGap(
          ComparisonArtifact(
            previews: previews(),
            scenarios: oneFailed(),
            narrowed: true,
          ),
        ),
        isNull,
      );

      // A harness that would not build produced no verdict however the run
      // was narrowed; that rule stands.
      var broken = ComparisonArtifact(
        previews: previews(),
        scenarios: ScenarioResults.of(
          items: const [],
          ran: 0,
          skipped: 0,
          elapsed: Duration.zero,
          note: 'The scenarios harness does not compile:',
        ),
        narrowed: true,
      );
      expect(verdictGap(broken), isNotNull);
    });

    test('the previews half is held to the same rule', () {
      var allFailed = ComparisonArtifact(
        previews: ComparisonResult(
          items: const [
            ComparedItem(id: 'a', state: ComparedState.failed),
            ComparedItem(id: 'b', state: ComparedState.failed),
          ],
          baseSha: 'abc123',
          headRoot: '/head',
          elapsed: Duration.zero,
          rendered: 4,
        ),
      );

      expect(
        verdictGap(allFailed),
        'the previews half produced no verdict — '
        'all 2 entries failed on both sides',
      );
    });
  });

  // Two parsers disagreed: the CLI mapped `changed` itself, and the action
  // handed the string to `ExportedFrames.fromName`, which reads the *file's*
  // vocabulary and answered `all` for its own documented option.
  group('--frames', () {
    test('changed is the findings, on every surface', () {
      expect(exportedFramesFromFlag('changed'), ExportedFrames.findings);
    });

    test('all, empty and absent are everything', () {
      expect(exportedFramesFromFlag('all'), ExportedFrames.all);
      expect(exportedFramesFromFlag(''), ExportedFrames.all);
      expect(exportedFramesFromFlag(null), ExportedFrames.all);
    });

    // Refused rather than defaulted, which is what let the mismatch hide: an
    // unknown value quietly exporting everything looks exactly like success.
    test('anything else is refused', () {
      expect(exportedFramesFromFlag('findings'), isNull);
      expect(exportedFramesFromFlag('bogus'), isNull);
    });
  });
}
