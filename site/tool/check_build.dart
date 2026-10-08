/// After `jaspr build`: every page of the site is in `build/jaspr`.
///
/// ```sh
/// cd site && fvm dart run tool/check_build.dart
/// ```
///
/// The build writes `/` and whatever the pages ask for while they render. An
/// ask the build tool did not hear leaves a page out, and nothing says so:
/// the build is green with the home page alone, which is how flutterware.dev
/// was deployed without its docs. This fails instead, and names the pages.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutterware_site/docs.dart';

void main() {
  var site = p.dirname(p.dirname(Platform.script.toFilePath()));
  var build = p.join(site, 'build', 'jaspr');
  var pages = ['', for (var page in Docs.load().pages) page.path];
  var missing = [
    for (var page in pages)
      if (!File(p.join(build, page, 'index.html')).existsSync()) '/$page',
  ];
  if (missing.isNotEmpty) {
    stderr.writeln(
      'build/jaspr has no page at: ${missing.join(', ')}. The build wrote '
      '${pages.length - missing.length} of ${pages.length} pages.',
    );
    exit(1);
  }
  stdout.writeln('build/jaspr holds all ${pages.length} pages.');
}
