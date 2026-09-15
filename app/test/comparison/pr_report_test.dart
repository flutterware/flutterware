import 'dart:io';
import 'dart:typed_data';

import 'package:flutterware/comparison_report.dart';
import 'package:flutterware_app/src/comparison/artifact.dart';
import 'package:flutterware_app/src/comparison/pr_report.dart';
import 'package:flutterware_app/src/comparison/runner.dart';
import 'package:flutterware_app/src/comparison/shot_cache.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late ShotCache cache;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fw_pr_report');
    cache = ShotCache(p.join(temp.path, 'shots'));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  void file(String key, int value, {int width = 6, int height = 6}) {
    cache.write(
      key,
      Uint8List(width * height * 4)..fillRange(0, width * height * 4, value),
      ShotRecord(
        format: 'raw',
        width: width,
        height: height,
        entryId: 'demo/card.dart#card',
      ),
    );
  }

  ComparisonResult previews(List<ComparedItem> items) => ComparisonResult(
    baseSha: 'abc',
    headRoot: '/w',
    elapsed: const Duration(milliseconds: 100),
    rendered: items.length,
    items: items,
  );

  // A caveat qualifies a clean verdict as much as a red one: "nothing changed"
  // over trees the base read another way is the one a reader most needs the
  // reason for.
  test('a caveat sits under the heading, whatever the heading says', () {
    var report = writePrReport(
      artifact: ComparisonArtifact(
        previews: previews(const []),
        caveats: const ['The base pins Flutter 3.47.0 and this branch 3.48.0.'],
      ),
      cache: cache,
      against: 'origin/master',
      directory: temp.path,
    );
    var comment = File(report.commentPath).readAsStringSync();

    var heading = comment.indexOf('### Comparison against');
    var caveat = comment.indexOf('> The base pins Flutter 3.47.0');
    var verdict = comment.indexOf('Nothing changed');
    expect(heading, isNonNegative);
    expect(caveat, greaterThan(heading));
    expect(verdict, greaterThan(caveat));
  });

  // A consumer's comparison on a saturated runner reported two base-side
  // flakes as the branch's change. A scenario with no result is named — never
  // a finding, never folded into "skipped" — and the verdict stays clean.
  test('a scenario with no result is named, and is not a finding', () {
    var report = writePrReport(
      artifact: ComparisonArtifact(
        previews: previews(const []),
        scenarios: ScenarioResults.of(
          items: const [
            ScenarioComparison.notCompared(
              scenario: 'test/save.dart#Save',
              inconclusive:
                  'The base failed once and passed when replayed again: '
                  'an error | dialog.',
            ),
            ScenarioComparison.notRun(
              scenario: 'test/cart.dart#Cart',
              state: ComparedState.skipped,
            ),
            ScenarioComparison(
              scenario: 'test/pay.dart#Pay',
              items: [],
              branches: [],
              state: ComparedState.same,
            ),
          ],
          ran: 2,
          skipped: 1,
          elapsed: Duration.zero,
        ),
      ),
      cache: cache,
      against: 'origin/master',
      directory: temp.path,
    );
    var comment = File(report.commentPath).readAsStringSync();

    expect(
      comment,
      contains('### Comparison against `origin/master` · 1 not compared'),
    );
    expect(
      comment,
      contains('Nothing changed — 3 entries compared · 1 skipped'),
    );
    expect(comment, contains('1 scenario not compared'));
    expect(
      comment,
      contains('| `test/save.dart#Save` | The base failed once and passed '),
    );
    expect(comment, contains(r'an error \| dialog.'));
    expect(report.mosaicPath, isNull);
  });

  // A half whose harness would not build leaves no rows, and until this the
  // comment printed that silence as a pass — the one thing a pull-request gate
  // must never do.
  group('a half that produced no verdict', () {
    test('says so instead of "nothing changed"', () {
      var report = writePrReport(
        artifact: ComparisonArtifact(
          previews: previews(const []),
          scenarios: ScenarioResults.of(
            items: const [],
            ran: 0,
            skipped: 0,
            elapsed: Duration.zero,
            note: 'notes: the harness does not compile',
          ),
        ),
        cache: cache,
        against: 'origin/master',
        directory: temp.path,
      );
      var comment = File(report.commentPath).readAsStringSync();

      expect(comment, contains('no verdict'));
      expect(comment, contains('the harness does not compile'));
      expect(comment, isNot(contains('Nothing changed')));
    });

    test('says so above the findings when there are some', () {
      var report = writePrReport(
        artifact: ComparisonArtifact(
          previews: ComparisonResult(
            baseSha: 'abc',
            headRoot: '/w',
            elapsed: Duration.zero,
            rendered: 1,
            items: const [
              ComparedItem(id: 'app/a#b', state: ComparedState.changed),
            ],
            packages: const ['app'],
            note: 'ops: the catalog does not compile',
          ),
        ),
        cache: cache,
        against: 'origin/master',
        directory: temp.path,
      );
      var comment = File(report.commentPath).readAsStringSync();

      expect(comment, contains('**No verdict**'));
      expect(
        comment.indexOf('No verdict'),
        lessThan(comment.indexOf('Open the full comparison')),
      );
    });
  });

  test('the receipt names how many packages were covered', () {
    var report = writePrReport(
      artifact: ComparisonArtifact(
        previews: ComparisonResult(
          baseSha: 'abc',
          headRoot: '/w',
          elapsed: Duration.zero,
          rendered: 0,
          items: const [ComparedItem(id: 'app/a#b', state: ComparedState.same)],
          packages: const ['app', 'packages/ops'],
        ),
      ),
      cache: cache,
      against: 'origin/master',
      directory: temp.path,
    );

    expect(
      File(report.commentPath).readAsStringSync(),
      contains('across 2 packages'),
    );
  });

  // A newline inside a markdown table cell ends the row, so a compiler error
  // dropped in whole breaks the table from there down — and a failing entry's
  // note is exactly where the compiler's diagnostics live.
  test('a multi-line note is one line in the table', () {
    var report = writePrReport(
      artifact: ComparisonArtifact(
        previews: previews(const [
          ComparedItem(
            id: 'a#b',
            state: ComparedState.failed,
            note: 'lib/a.dart:13:28: Error: not found\nWidget a() => B();\n   ^^^',
          ),
        ]),
      ),
      cache: cache,
      against: 'origin/master',
      directory: temp.path,
    );
    var comment = File(report.commentPath).readAsStringSync();
    var row = comment
        .split('\n')
        .firstWhere((line) => line.contains('a#b') && line.startsWith('|'));

    expect(row, contains('Error: not found …'));
    expect(row, isNot(contains('Widget a()')));
    expect(row.trim(), endsWith('|'));
  });

  // A run that took three times its usual length on a runner with no GPU was
  // indistinguishable, in its comment, from one on a quiet machine.
  test('the footer says what machine it ran on', () {
    var report = writePrReport(
      artifact: ComparisonArtifact(
        previews: previews(const []),
        host: const ComparisonHost(
          os: 'linux',
          cpus: 8,
          rasterizer: 'impeller-vulkan',
        ),
      ),
      cache: cache,
      against: 'master',
      directory: p.join(temp.path, 'host'),
    );

    expect(
      File(report.commentPath).readAsStringSync(),
      contains('on linux · 8 CPUs · impeller-vulkan —'),
    );
  });

  test('a clean comparison is a short comment and no mosaic', () {
    var report = writePrReport(
      artifact: ComparisonArtifact(
        previews: previews(const [
          ComparedItem(id: 'demo/a.dart#a', state: ComparedState.same),
          ComparedItem(id: 'demo/b.dart#b', state: ComparedState.skipped),
        ]),
      ),
      cache: cache,
      against: 'master',
      directory: p.join(temp.path, 'report'),
    );

    expect(report.mosaicPath, isNull);
    var comment = File(report.commentPath).readAsStringSync();
    expect(comment, contains('Nothing changed'));
    expect(comment, contains('2 entries compared'));
    expect(comment, isNot(contains(mosaicUrlPlaceholder)));
  });

  test('findings become a table, a mosaic and placeholder links', () {
    file('k-base', 40);
    file('k-head', 200);
    var report = writePrReport(
      artifact: ComparisonArtifact(
        previews: previews([
          ComparedItem(
            id: 'demo/card.dart#card',
            state: ComparedState.changed,
            pixels: PixelChannel(
              PixelDiff(
                width: 6,
                height: 6,
                changedPixels: 36,
                comparedPixels: 36,
                sizeChanged: false,
                clusters: const [
                  DiffRect(x: 0, y: 0, width: 6, height: 6, pixels: 36),
                ],
              ),
            ),
            shots: (base: 'k-base', head: 'k-head'),
          ),
        ]),
      ),
      cache: cache,
      against: 'master',
      head: 'abc123def4567890',
      directory: p.join(temp.path, 'report'),
    );

    var comment = File(report.commentPath).readAsStringSync();
    // The marker is how a workflow finds its own comment to update, and the
    // head sha is how a reader tells an updated comment from a stale one.
    expect(comment, startsWith('$commentMarker\n'));
    expect(comment, contains('`fw compare` @abc123d —'));
    expect(comment, contains('against `master` — **1 changed**'));
    // The entry cell is a door into the page, aimed by the viewer's own
    // fragment grammar — the id's `/` and `#` spelled as escapes so they
    // survive both the URL and the markdown.
    expect(
      comment,
      contains(
        '| [`demo/card.dart#card`]'
        '($viewerUrlPlaceholder#previews/demo%2Fcard.dart%23card) '
        '| changed |',
      ),
    );
    expect(comment, contains('100.00% · 1 region'));
    expect(comment, contains(mosaicUrlPlaceholder));
    expect(comment, contains(viewerUrlPlaceholder));

    // The comment is a teaser: the page link is the first line under the
    // heading, above the mosaic, and the table — the only part that grows per
    // finding — is folded shut.
    expect(
      comment.indexOf(viewerUrlPlaceholder),
      lessThan(comment.indexOf(mosaicUrlPlaceholder)),
    );
    // The image itself is a door to the page, not to the raw PNG.
    expect(
      comment,
      contains('[![comparison]($mosaicUrlPlaceholder)]($viewerUrlPlaceholder)'),
    );
    expect(comment, contains('<details><summary>1 finding</summary>'));
    expect(
      comment.indexOf('<details>'),
      lessThan(comment.indexOf('| entry |')),
    );
    expect(comment, contains('</details>'));

    var mosaic = img.decodePng(File(report.mosaicPath!).readAsBytesSync())!;
    expect(mosaic.width, greaterThan(0));
    expect(mosaic.height, greaterThan(0));
  });

  test('the folded summary says when the mosaic is a cap', () {
    var items = <ComparedItem>[];
    for (var index = 0; index < mosaicRowCap + 4; index++) {
      file('base$index', 40);
      file('head$index', 180);
      items.add(
        ComparedItem(
          id: 'demo/card$index.dart#card',
          state: ComparedState.changed,
          shots: (base: 'base$index', head: 'head$index'),
        ),
      );
    }
    var report = writePrReport(
      artifact: ComparisonArtifact(previews: previews(items)),
      cache: cache,
      against: 'master',
      directory: p.join(temp.path, 'report'),
    );

    var comment = File(report.commentPath).readAsStringSync();
    expect(
      comment,
      contains(
        '<summary>${mosaicRowCap + 4} findings '
        '(the picture shows $mosaicRowCap, those that moved on screen '
        'first)</summary>',
      ),
    );
    // Folded, but complete: every finding is a table row.
    expect('| changed |'.allMatches(comment).length, mosaicRowCap + 4);
  });

  test('the table stops at commentRowCap, so the comment always posts', () {
    var report = writePrReport(
      artifact: ComparisonArtifact(
        previews: previews([
          for (var index = 0; index < commentRowCap + 4; index++)
            ComparedItem(
              id: 'demo/entry$index.dart#entry',
              state: ComparedState.changed,
            ),
        ]),
      ),
      cache: cache,
      against: 'master',
      directory: p.join(temp.path, 'report'),
    );

    // No shots anywhere, so there is no mosaic to draw — the cap is about
    // the table alone.
    expect(report.mosaicPath, isNull);
    var comment = File(report.commentPath).readAsStringSync();
    expect('| changed |'.allMatches(comment).length, commentRowCap);
    expect(comment, contains('…and 4 more — the page has them all.'));
  });

  test('the mosaic leads with what moved on screen, whatever the cap', () {
    file('pixels-base', 40);
    file('pixels-head', 200);
    var report = writePrReport(
      artifact: ComparisonArtifact(
        previews: previews([
          // Ranked ahead by name, and not one of them changed a pixel — their
          // frames are not even in the cache, so a mosaic spent on them draws
          // nothing at all.
          for (var index = 0; index < mosaicRowCap; index++)
            ComparedItem(
              id: 'a/entry$index.dart#entry',
              state: ComparedState.changed,
              texts: const TextChannel(added: ['Pay'], removed: ['Buy']),
              shots: (base: 'gone-base$index', head: 'gone-head$index'),
            ),
          ComparedItem(
            id: 'z/card.dart#card',
            state: ComparedState.changed,
            pixels: PixelChannel(
              PixelDiff(
                width: 6,
                height: 6,
                changedPixels: 36,
                comparedPixels: 36,
                sizeChanged: false,
                clusters: const [],
              ),
            ),
            shots: (base: 'pixels-base', head: 'pixels-head'),
          ),
        ]),
      ),
      cache: cache,
      against: 'master',
      directory: p.join(temp.path, 'report'),
    );

    expect(report.mosaicPath, isNotNull);
  });

  test('a scenario is pictured at a step whose pixels moved', () {
    var framePath = p.join(temp.path, 'frame.raw');
    File(framePath)
        .writeAsBytesSync(Uint8List(4 * 4 * 4)..fillRange(0, 4 * 4 * 4, 120));
    var frame = FrameRef(path: framePath, width: 4, height: 4);
    var report = writePrReport(
      artifact: ComparisonArtifact(
        previews: previews(const []),
        scenarios: ScenarioResults.of(
          ran: 1,
          skipped: 0,
          elapsed: const Duration(seconds: 1),
          items: [
            ScenarioComparison(
              scenario: 'test/shop.dart#Checkout',
              state: ComparedState.changed,
              items: [
                const ComparedItem(
                  id: 'Cart',
                  state: ComparedState.changed,
                  texts: TextChannel(added: ['Pay'], removed: ['Buy']),
                ),
                ComparedItem(
                  id: 'Pay',
                  state: ComparedState.changed,
                  pixels: PixelChannel(
                    PixelDiff(
                      width: 4,
                      height: 4,
                      changedPixels: 16,
                      comparedPixels: 16,
                      sizeChanged: false,
                      clusters: const [],
                    ),
                  ),
                ),
              ],
              branches: const [],
              frames: {
                'Cart': (base: frame, head: frame),
                'Pay': (base: frame, head: frame),
              },
            ),
          ],
        ),
      ),
      cache: cache,
      against: 'develop',
      directory: p.join(temp.path, 'report'),
    );

    var comment = File(report.commentPath).readAsStringSync();
    expect(comment, contains('[step `Pay`]'));
    expect(comment, isNot(contains('[step `Cart`]')));
  });

  test("a scenario's face in the mosaic is its worst step with frames", () {
    var framePath = p.join(temp.path, 'pay.raw');
    File(framePath)
        .writeAsBytesSync(Uint8List(4 * 4 * 4)..fillRange(0, 4 * 4 * 4, 120));
    var report = writePrReport(
      artifact: ComparisonArtifact(
        previews: previews(const []),
        scenarios: ScenarioResults.of(
          ran: 1,
          skipped: 0,
          elapsed: const Duration(seconds: 1),
          items: [
            ScenarioComparison(
              scenario: 'test/shop.dart#Checkout',
              state: ComparedState.changed,
              items: const [
                ComparedItem(id: 'guest › Pay', state: ComparedState.changed),
              ],
              branches: const [],
              frames: {
                'guest › Pay': (
                  base: null,
                  head: FrameRef(path: framePath, width: 4, height: 4),
                ),
              },
            ),
          ],
        ),
      ),
      cache: cache,
      against: 'develop',
      directory: p.join(temp.path, 'report'),
    );

    var comment = File(report.commentPath).readAsStringSync();
    expect(
      comment,
      contains(
        '| [`test/shop.dart#Checkout`]'
        '($viewerUrlPlaceholder#scenarios/test%2Fshop.dart%23Checkout) '
        '| changed |',
      ),
    );
    // And the Δ cell opens the very step that moved.
    expect(
      comment,
      contains(
        '[step `guest › Pay`]'
        '($viewerUrlPlaceholder#scenarios/test%2Fshop.dart%23Checkout/'
        'guest%20%E2%80%BA%20Pay)',
      ),
    );
    expect(report.mosaicPath, isNotNull);
  });

  group('the mosaic lays its cells across before it lays them down', () {
    /// Phone-shaped, and [wideIndex] desktop-shaped — a mix is the case that
    /// decides the layout, not one shape repeated.
    img.Image mosaicOf(int findings, {int wideIndex = -1}) {
      var items = <ComparedItem>[];
      for (var index = 0; index < findings; index++) {
        var wide = index == wideIndex;
        var width = wide ? 1280 : 300;
        var height = wide ? 800 : 650;
        for (var key in ['base$index', 'head$index']) {
          file(key, 180, width: width, height: height);
        }
        items.add(
          ComparedItem(
            id: 'demo/card$index.dart#card',
            state: ComparedState.changed,
            shots: (base: 'base$index', head: 'head$index'),
          ),
        );
      }
      var report = writePrReport(
        artifact: ComparisonArtifact(previews: previews(items)),
        cache: cache,
        against: 'master',
        directory: p.join(temp.path, 'report$findings$wideIndex'),
      );
      return img.decodePng(File(report.mosaicPath!).readAsBytesSync())!;
    }

    test('so more findings make it wider, not taller', () {
      var one = mosaicOf(1);
      var fifteen = mosaicOf(15);

      // Stacked in one column, fifteen findings were fifteen times as tall as
      // one and no wider — a ribbon narrower than a comment's content column,
      // so no client scaled it and nobody read past the third row.
      expect(fifteen.width, greaterThan(one.width));
      expect(fifteen.height, lessThan(one.height * 15));
      // And it stops growing sideways rather than running off the other way.
      expect(fifteen.width, lessThanOrEqualTo(1400));
    });

    test('and one desktop entry does not collapse it back to a column', () {
      var fifteen = mosaicOf(15, wideIndex: 14);

      // A desktop pair is 1036px at full height, which leaves room for one
      // column — so everything shrinks together until two fit. Without that
      // this came back 1060 × 5412, which is the ribbon again.
      expect(fifteen.width, lessThanOrEqualTo(1400));
      // Wider than a single cell can be, so there is more than one column.
      expect(fifteen.width, greaterThan(700));
      expect(fifteen.height, lessThan(3000));
    });
  });

  group('a mosaic caption', () {
    test('is left alone when it fits its cell', () {
      expect(mosaicCaption('added', 'a.dart#b', 400), 'added  a.dart#b');
    });

    test('elides from the left, so the leaf survives', () {
      const id =
          'examples/src/assessment/list_card.dart#AssessmentListCardExample.new';
      var caption = mosaicCaption('changed', id, 332);

      expect(mosaicTextWidth(caption), lessThanOrEqualTo(332));
      // The state word says what happened and the tail says to what; it is
      // the middle of a path that identifies nothing.
      expect(caption, startsWith('changed  ...'));
      expect(caption, endsWith('CardExample.new'));
    });
  });
}
