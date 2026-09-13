import 'dart:io';

import 'package:flutterware/comparison_report.dart';
import 'package:flutterware_app/src/comparison/web_viewer.dart';
import 'package:test/test.dart';

/// What a reader arriving from a link sees before the page has drawn anything,
/// and what their browser calls it.
void main() {
  group('the page shell', () {
    late String html;
    setUpAll(() => html = File('web/index.html').readAsStringSync());

    // `setBaseHrefIn` rewrites exactly this tag; a page without it is mounted
    // at the wrong path on every host that is not a domain root.
    test('keeps the base tag the export rewrites', () {
      expect(html, contains(r'<base href="$FLUTTER_BASE_HREF">'));
    });

    test("loads through Flutter's bootstrap, with no service worker", () {
      expect(html, contains('flutter_bootstrap.js'));
      expect(html, isNot(contains('serviceWorker')));
    });

    test('says something while the engine starts, and goes on first frame', () {
      expect(html, contains('id="loading"'));
      expect(html, contains('flutter-first-frame'));
    });

    // It is what a chat shows under the link, and it was the web demo's.
    test('describes a report, not the studio demo', () {
      expect(html, isNot(contains('recorded project')));
      expect(
        File('web/manifest.json').readAsStringSync(),
        isNot(contains('recorded project')),
      );
    });
  });

  group('the tab title', () {
    ComparisonIndex index({
      List<ComparedItem> previews = const [],
      String? previewsNote,
      String? head = 'fe642dc0a9299e6a',
    }) => ComparisonIndex(
      base: 'ae89948f',
      against: 'origin/master',
      headCommit: head,
      previewItems: previews,
      scenarios: const [],
      previewsHalf: ComparedHalf(note: previewsNote),
    );

    test('leads with the verdict, then the commits', () {
      expect(
        comparisonPageTitle(
          index(
            previews: const [
              ComparedItem(id: 'a', state: ComparedState.changed),
              ComparedItem(id: 'b', state: ComparedState.broke),
              ComparedItem(id: 'c', state: ComparedState.changed),
              ComparedItem(id: 'd', state: ComparedState.same),
            ],
          ),
        ),
        '1 broke · 2 changed — fe642dc against origin/master',
      );
    });

    test('says when nothing changed, and when there was no verdict', () {
      expect(
        comparisonPageTitle(index(head: null)),
        'Nothing changed — against origin/master',
      );
      expect(
        comparisonPageTitle(index(previewsNote: 'the catalog did not compile')),
        startsWith('No verdict'),
      );
    });
  });
}
