import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/world/web_snapshot.dart';

/// Renders a real page with macOS WebKit, through the helper compiled on
/// first use — so macOS only, and the Xcode command line tools.
void main() {
  test(
    'draws a page with each link where it is, and draws it once',
    () async {
      var directory = await Directory.systemTemp.createTemp('fw_pages');
      addTearDown(() => directory.delete(recursive: true));
      var snapshots = WebSnapshots(
        appRoot: Directory.current.path,
        directory: directory.path,
      );
      const html = '''
<!doctype html><html><body style="margin:0;font:16px -apple-system">
<div style="height:120px">A receipt</div>
<a href="worldlab://orders/o1" style="display:block;height:40px">Open the order</a>
<a href="https://flutterware.dev">The shop</a>
<script>document.body.innerHTML = 'scripts do not run';</script>
</body></html>''';
      var page = await snapshots.of(html, width: 320);
      expect(File(page.picture).existsSync(), isTrue);
      expect(page.width, 320);
      expect(page.height, greaterThan(160));
      expect(
        [for (var link in page.links) (link.href, link.text)],
        [
          ('worldlab://orders/o1', 'Open the order'),
          ('https://flutterware.dev/', 'The shop'),
        ],
      );
      expect(page.links.first.top, 120);
      expect(page.links.first.height, 40);
      expect(identical(await snapshots.of(html, width: 320), page), isTrue);
    },
    skip: !Platform.isMacOS,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'reads a page as UTF-8 though it names no charset, as a mail does',
    () async {
      var directory = await Directory.systemTemp.createTemp('fw_pages');
      addTearDown(() => directory.delete(recursive: true));
      var snapshots = WebSnapshots(
        appRoot: Directory.current.path,
        directory: directory.path,
      );
      var page = await snapshots.of(
        '<html><body><a href="https://example.test">It’s © 2026</a>'
        '</body></html>',
      );
      expect(page.links.single.text, 'It’s © 2026');
    },
    skip: !Platform.isMacOS,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
