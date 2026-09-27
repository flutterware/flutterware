import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../utils/run_dir.dart';
import '../utils/swift_helper.dart';

/// A page as a picture: what a mail looks like, drawn by the WebKit macOS
/// ships ([WebSnapshots]), with where each of its links is.
class WebSnapshot {
  const WebSnapshot({
    required this.picture,
    required this.width,
    required this.height,
    required this.links,
  });

  /// The PNG, at twice the page's size.
  final String picture;

  /// The page's size in points.
  final double width;
  final double height;
  final List<WebLink> links;
}

/// A link on a [WebSnapshot]: where it goes, what it says, and its box in
/// the page's points. Plain numbers rather than a `Rect`: the CLI and the
/// MCP server draw pages too, and they have no `dart:ui`.
class WebLink {
  const WebLink(
    this.href,
    this.text, {
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final String href;
  final String text;
  final double left;
  final double top;
  final double width;
  final double height;
}

/// Renders pages to pictures with the WebKit macOS ships, through a Swift
/// helper the studio compiles on first use ([SwiftHelper]): half a second a
/// page, nothing to download, and a picture the canvas zooms, screenshots
/// keep and an agent can read. Each page is rendered once, keyed by its HTML
/// and width, and kept under flutterware's own directory.
///
/// macOS only; elsewhere [of] throws an [UnsupportedError].
class WebSnapshots {
  WebSnapshots({this.appRoot, String? directory})
    : _directory = directory ?? p.join(flutterwareDir(), 'world', 'pages');

  /// The `flutterware_app` package root, where the helper's source is: a
  /// Flutter process cannot resolve its own package to find it.
  final String? appRoot;

  static const helper = SwiftHelper(
    'web_snapshot',
    'lib/src/world/web_snapshot.swift',
  );

  final String _directory;
  final _pages = <String, Future<WebSnapshot>>{};

  /// [html] drawn [width] points wide.
  Future<WebSnapshot> of(String html, {double width = 600}) {
    var key = sha1
        .convert(utf8.encode('$width\n$html'))
        .toString()
        .substring(0, 16);
    return _pages.putIfAbsent(key, () => _kept(key, html, width));
  }

  /// [_render], forgotten when it fails: whoever asks next tries again.
  Future<WebSnapshot> _kept(String key, String html, double width) async {
    try {
      return await _render(key, html, width);
    } on Object {
      // The future removed is this one; nothing waits on it here.
      _pages.remove(key)?.ignore();
      rethrow;
    }
  }

  Future<WebSnapshot> _render(String key, String html, double width) async {
    var binary = await helper.ensure(root: appRoot);
    if (binary == null) {
      throw UnsupportedError('Pages are drawn with macOS WebKit only.');
    }
    var directory = Directory(_directory)..createSync(recursive: true);
    var page = File(p.join(directory.path, '$key.html'))
      ..writeAsStringSync(html);
    var picture = p.join(directory.path, '$key.png');
    var result = await Process.run(binary, [
      page.path,
      picture,
      '$width',
    ]).timeout(const Duration(seconds: 30));
    if (result.exitCode != 0) {
      throw StateError('${result.stderr}'.trim());
    }
    var answer = jsonDecode(
      '${result.stdout}'.trim().split('\n').last,
    ) as Map<String, Object?>;
    return WebSnapshot(
      picture: picture,
      width: (answer['width']! as num).toDouble(),
      height: (answer['height']! as num).toDouble(),
      links: [
        for (var link in answer['links'] as List? ?? const [])
          if (link case {
            'href': String href,
            'x': num x,
            'y': num y,
            'w': num w,
            'h': num h,
          })
            WebLink(
              href,
              '${link['text'] ?? ''}',
              left: x.toDouble(),
              top: y.toDouble(),
              width: w.toDouble(),
              height: h.toDouble(),
            ),
      ],
    );
  }
}
