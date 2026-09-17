import 'package:flutterware/comparison_report.dart';
import 'package:flutterware_app/src/comparison/artifact.dart';
import 'package:flutterware_app/src/comparison/compare_command.dart';
import 'package:flutterware_app/src/comparison/runner.dart';
import 'package:test/test.dart';

/// A comparison that spans several packages, as one verdict.
///
/// A repository with previews in two packages and scenarios in two others used
/// to compare one of each — the first declared — and the scenario half did not
/// read `--package` at all, so narrowing to the second previews package
/// compared it against the *first* scenarios one. What is under test here is
/// the arithmetic that turns several halves into one, since none of it needs a
/// checkout, a compiler or a guest to be wrong.
void main() {
  ComparedItem entry(String id, ComparedState state, {String? note}) =>
      ComparedItem(id: id, state: state, note: note);

  ComparisonResult previews(
    List<ComparedItem> items, {
    String package = 'app',
    int rendered = 0,
    Map<String, int> because = const {},
  }) => ComparisonResult(
    items: items,
    baseSha: 'abc123',
    headRoot: '/head',
    elapsed: const Duration(seconds: 1),
    rendered: rendered,
    because: because,
    packages: [package],
  );

  group('addressing a row inside its package', () {
    test('a run of several packages puts the package in front of the id', () {
      var row = entry(
        'demo/card.dart#card',
        ComparedState.changed,
      ).inPackage('packages/gallery', qualify: true);

      expect(row.id, 'packages/gallery/demo/card.dart#card');
      expect(row.package, 'packages/gallery');
    });

    // Ids are in deep links, in the comment's table and in whatever a
    // consumer's script filters on. Renaming them all to buy a distinction a
    // single-package project cannot need is not a trade worth making.
    test(
      'a run of one package leaves the id alone and records the package',
      () {
        var row = entry(
          'demo/card.dart#card',
          ComparedState.changed,
        ).inPackage('app', qualify: false);

        expect(row.id, 'demo/card.dart#card');
        expect(row.package, 'app');
      },
    );

    test('a scenario is addressed the same way', () {
      var scenario = const ScenarioComparison.notRun(
        scenario: 'test/shop_test.dart#Checkout',
        state: ComparedState.added,
      ).inPackage('notes', qualify: true);

      expect(scenario.scenario, 'notes/test/shop_test.dart#Checkout');
      expect(scenario.package, 'notes');
    });

    test('both survive the round trip through the file', () {
      var row = ComparedItem.fromJson(
        entry(
          'a#b',
          ComparedState.same,
        ).inPackage('app', qualify: true).toJson(),
      );
      var scenario = ScenarioComparison.fromJson(
        const ScenarioComparison.notRun(
          scenario: 'a#b',
          state: ComparedState.same,
        ).inPackage('app', qualify: true).toJson(),
      );

      expect(row.package, 'app');
      expect(scenario.package, 'app');
    });
  });

  group('several halves as one', () {
    test('rows concatenate and re-rank worst first across packages', () {
      var merged = ComparisonResult.merged(
        [
          previews([entry('a', ComparedState.changed)], package: 'app'),
          previews([entry('b', ComparedState.broke)], package: 'ops'),
        ],
        baseSha: 'abc123',
        headRoot: '/head',
        elapsed: const Duration(seconds: 3),
      );

      expect(merged.items.map((item) => item.id), ['b', 'a']);
      expect(merged.packages, ['app', 'ops']);
    });

    test('the counters add and the causes fold together', () {
      var merged = ComparisonResult.merged(
        [
          previews(
            const [],
            package: 'app',
            rendered: 4,
            because: {'pubspec.lock differs': 3},
          ),
          previews(
            const [],
            package: 'ops',
            rendered: 2,
            because: {'pubspec.lock differs': 5, 'theme.dart differs': 1},
          ),
        ],
        baseSha: 'abc123',
        headRoot: '/head',
        elapsed: const Duration(seconds: 3),
      );

      expect(merged.rendered, 6);
      // Commonest first, and one line rather than one per package.
      expect(merged.because, {
        'pubspec.lock differs': 8,
        'theme.dart differs': 1,
      });
    });

    // Summing would report a number no clock ever showed.
    test('the elapsed time is the caller wall clock, not a sum', () {
      var merged = ComparisonResult.merged(
        [previews(const []), previews(const [], package: 'ops')],
        baseSha: 'abc123',
        headRoot: '/head',
        elapsed: const Duration(seconds: 3),
      );

      expect(merged.elapsed, const Duration(seconds: 3));
    });

    test('a package that would not compile is a note naming it', () {
      var merged = ComparisonResult.merged(
        [
          previews([entry('a', ComparedState.same)], package: 'app'),
        ],
        baseSha: 'abc123',
        headRoot: '/head',
        elapsed: const Duration(seconds: 3),
        refusals: {'ops': 'the base checkout does not compile'},
      );

      expect(merged.note, contains('ops'));
      expect(merged.note, contains('does not compile'));
      // The packages that did compare still report.
      expect(merged.items, hasLength(1));
    });

    test('scenario notes join with the package that produced each', () {
      var merged = ScenarioResults.merged([
        (
          package: 'app',
          results: ScenarioResults.of(
            items: const [],
            ran: 2,
            skipped: 1,
            elapsed: Duration.zero,
          ),
        ),
        (
          package: 'notes',
          results: ScenarioResults.of(
            items: const [],
            ran: 0,
            skipped: 0,
            elapsed: Duration.zero,
            note: 'the harness does not compile',
          ),
        ),
      ], elapsed: const Duration(seconds: 4));

      expect(merged.ran, 2);
      expect(merged.skipped, 1);
      expect(merged.packages, ['app', 'notes']);
      expect(merged.note, 'notes: the harness does not compile');
    });
  });

  group('which packages a run covers', () {
    test('naming none covers every package the half declares', () {
      expect(wantedPackages(const ['app', 'ops'], const []), ['app', 'ops']);
    });

    test('naming some intersects rather than looks up', () {
      expect(wantedPackages(const ['app', 'ops'], const ['ops']), ['ops']);
    });

    // `--package=notes` is a legitimate thing to say to a repository whose
    // previews live elsewhere: it narrows the scenario half and empties the
    // previews one, rather than refusing.
    test('a package this half does not declare empties it', () {
      expect(wantedPackages(const ['app'], const ['notes']), isEmpty);
    });
  });

  // A half whose harness would not build leaves no rows, and no rows read as
  // "nothing changed". The previews half could not say so at all until a
  // package's refusal stopped ending the whole comparison.
  test('a previews note is a verdict gap', () {
    expect(
      verdictGapOf(previewsNote: 'ops: the catalog does not compile'),
      contains('the previews half produced no verdict'),
    );
    expect(verdictGapOf(), isNull);
  });

  // One line a CI log can be read by: each phase summed over packages and
  // sides, and the scenarios that spent their whole settle budget.
  test('the time a comparison spent reads as one line', () {
    var line = describeTimings(
      const ComparisonTimings(
        phases: [
          ComparisonPhase(name: 'checkout', ms: 1800),
          ComparisonPhase(name: 'previews.compile', ms: 2000, side: 'base'),
          ComparisonPhase(name: 'previews.compile', ms: 1500, side: 'head'),
          ComparisonPhase(name: 'previews.render', ms: 9000, side: 'base'),
          ComparisonPhase(name: 'viewer', ms: 17800),
        ],
        unsettledSteps: {'test/a_test.dart#Spinning fox': 4},
        pooledOnlyDifferences: ['test/b_test.dart#Unread badge'],
        stillTicking: {
          'test/a_test.dart#Spinning fox': [
            'CircularProgressIndicator (lib/den.dart:12)',
          ],
        },
      ),
    );

    expect(
      line,
      'Time spent: checkout 1.8s · previews compile 3.5s, render 9.0s · '
      'viewer 17.8s\n'
      '1 scenario had steps that never settled, each running its whole '
      'settle budget: Spinning fox (4, still ticking: '
      'CircularProgressIndicator (lib/den.dart:12))\n'
      '1 scenario differed beside other replays and not alone, so replayed '
      'serially: Unread badge',
    );
  });
}
