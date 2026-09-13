import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// What a visitor from the README sees before the studio has drawn anything,
/// and what a link to the page says about it.
void main() {
  late String html;
  setUpAll(() => html = File('web/index.html').readAsStringSync());

  // `build_web.dart` passes `--base-href`, and the browser test reads it back
  // off this tag to serve the page under the same path Pages does.
  test('keeps the base tag the build fills in', () {
    expect(html, contains(r'<base href="$FLUTTER_BASE_HREF">'));
  });

  // The template this replaced registered a service worker and waited for it
  // before loading the app — the deprecated template, over an empty worker.
  test("loads through Flutter's bootstrap, with no service worker", () {
    expect(html, contains('flutter_bootstrap.js'));
    expect(html, isNot(contains('serviceWorker')));
  });

  test('says something while the engine starts, and goes on first frame', () {
    expect(html, contains('id="loading"'));
    expect(html, contains('flutter-first-frame'));
  });

  // Flutter's template text, which is what a link preview showed.
  test('names the page, not a new Flutter project', () {
    for (var file in ['web/index.html', 'web/manifest.json']) {
      var text = File(file).readAsStringSync();
      expect(text, isNot(contains('A new Flutter project')), reason: file);
      expect(text, isNot(contains('"app"')), reason: file);
    }
    expect(html, contains('<title>flutterware</title>'));
  });
}
