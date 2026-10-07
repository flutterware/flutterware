import 'dart:io';

import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;

/// What the page takes from the repository's markdown, so that nothing on it
/// is written twice.
///
/// `README.md` says what it shares: the text between `<!-- site:name -->` and
/// `<!-- /site -->` is a region, and the page renders it by name. Reword the
/// README and the page follows on its next build; a region the page asks for
/// and the README no longer has fails that build, with the name.
///
/// Pictures are found the same way, by file name, in the README and the
/// guides — so the page shows the picture, and the alt text, they show.
///
/// The README writes its links for GitHub, relative to itself. [link] says
/// where each one goes from the page; left out, they all go to GitHub.
class Content {
  Content({
    required String readme,
    Iterable<String> guides = const [],
    String Function(String href) link = _absolute,
  }) : _resolve = link,
       _regions = {
         for (var m in _region.allMatches(readme))
           m.group(1)!: m.group(2)!.trim(),
       },
       _pictures = {
         for (var text in [readme, ...guides])
           for (var m in _image.allMatches(text))
             if (_pictureName.firstMatch(m.group(2)!) case var name?)
               name.group(1)!: Picture(m.group(2)!, _collapse(m.group(1)!)),
       };

  /// Reads the README and the guides of the repository this package sits in.
  factory Content.load({String Function(String href) link = _absolute}) {
    var root = _repositoryRoot();
    return Content(
      link: link,
      readme: File(p.join(root, 'README.md')).readAsStringSync(),
      guides: [
        for (var file in Directory(p.join(root, 'doc')).listSync())
          if (file is File && file.path.endsWith('.md'))
            file.readAsStringSync(),
      ],
    );
  }

  final String Function(String href) _resolve;
  final Map<String, String> _regions;
  final Map<String, Picture> _pictures;

  /// The words of a region, with no markup.
  String text(String region) =>
      _collapse(_inline(_markdown(region)).map((n) => n.textContent).join());

  /// A region as inline HTML: its emphasis, code and links, and no paragraph
  /// around them.
  String html(String region) => _html(_markdown(region));

  /// The fenced code block a region holds.
  Snippet snippet(String region) {
    var match = _fence.firstMatch(_markdown(region));
    if (match == null) throw _wrong(region, 'holds no fenced code block');
    return Snippet(language: match.group(1)!, code: match.group(2)!);
  }

  /// The tools of a region whose table gives each one three rows: its name
  /// linking to its guide, its picture, and what it does.
  List<Tool> tools(String region) {
    var rows = _rows(region);
    if (rows.length % 3 != 0 ||
        rows.any((row) => row.length != rows.first.length)) {
      throw _wrong(
        region,
        'is not rows of names, then pictures, then descriptions, each as '
        'wide as the others',
      );
    }
    return [
      for (var i = 0; i < rows.length; i += 3)
        for (var column = 0; column < rows[i].length; column++)
          _tool(
            region,
            name: rows[i][column],
            picture: rows[i + 1][column],
            description: rows[i + 2][column],
          ),
    ];
  }

  /// The rows of a region whose table has a name and a description per line.
  List<({String name, String description})> rows(String region) => [
    for (var row in _rows(region))
      if (row.length == 2)
        (name: _html(row[0].replaceAll('**', '')), description: _html(row[1]))
      else
        throw _wrong(region, 'has a row of ${row.length} cells, not two'),
  ];

  /// The picture the README or a guide shows under this file name.
  Picture picture(String name) =>
      _pictures[name] ??
      (throw StateError(
        'No picture named $name.webp is linked from README.md or doc/. The '
        'page shows only pictures they show.',
      ));

  Tool _tool(
    String region, {
    required String name,
    required String picture,
    required String description,
  }) {
    var link = _link.firstMatch(name);
    if (link == null) throw _wrong(region, 'has no link in "$name"');
    var image = _image.firstMatch(picture);
    if (image == null) throw _wrong(region, 'has no picture in "$picture"');
    return Tool(
      name: link.group(1)!,
      guide: _resolve(link.group(2)!),
      picture: Picture(image.group(2)!, _collapse(image.group(1)!)),
      description: _html(description),
    );
  }

  String _markdown(String region) =>
      _regions[region] ??
      (throw StateError(
        'README.md has no <!-- site:$region --> region, and the page renders '
        'one. Regions it has: ${_regions.keys.join(', ')}.',
      ));

  /// The cells of a region's table, without its alignment row or empty rows.
  List<List<String>> _rows(String region) {
    var rows = [
      for (var line in _markdown(region).split('\n'))
        if (line.trim() case var row
            when row.startsWith('|') && !_alignment.hasMatch(row))
          [
            for (var cell in row.substring(1, row.length - 1).split('|'))
              cell.trim(),
          ],
    ].where((row) => row.any((cell) => cell.isNotEmpty)).toList();
    if (rows.isEmpty) throw _wrong(region, 'holds no table');
    return rows;
  }

  String _html(String markdown) => md.renderToHtml(_inline(markdown));

  List<md.Node> _inline(String markdown) {
    var nodes = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored)
        .parseInline(markdown);
    for (var node in nodes) {
      node.accept(_Links(_resolve));
    }
    return nodes;
  }

  StateError _wrong(String region, String what) =>
      StateError('README.md: the site:$region region $what.');
}

/// A picture on the media branch, and the words that stand in for it.
class Picture {
  const Picture(this.url, this.alt);

  final String url;
  final String alt;

  /// The file name without its extension, which is how a picture is known.
  String get name => _pictureName.firstMatch(url)?.group(1) ?? '';
}

class Tool {
  const Tool({
    required this.name,
    required this.guide,
    required this.picture,
    required this.description,
  });

  final String name;
  final String guide;
  final Picture picture;

  /// Inline HTML.
  final String description;
}

class Snippet {
  const Snippet({this.language = '', required this.code});

  final String language;
  final String code;

  /// Whether these are commands for a terminal, one per line.
  bool get isShell => language == 'shell';
}

/// Where a file of the repository is read when the site has no page for it.
const repository = 'https://github.com/flutterware/flutterware';

String _absolute(String link) =>
    Uri.parse(link).hasScheme ? link : '$repository/blob/master/$link';

class _Links implements md.NodeVisitor {
  _Links(this.link);

  final String Function(String href) link;

  @override
  bool visitElementBefore(md.Element element) {
    if (element.tag == 'a') {
      element.attributes.update('href', link);
    }
    return true;
  }

  @override
  void visitElementAfter(md.Element element) {}

  @override
  void visitText(md.Text text) {}
}

String _collapse(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

String _repositoryRoot() {
  var dir = Directory.current;
  while (!File(p.join(dir.path, 'README.md')).existsSync() ||
      !Directory(p.join(dir.path, 'doc')).existsSync()) {
    if (dir.parent.path == dir.path) {
      throw StateError('No README.md with a doc/ beside it above the site.');
    }
    dir = dir.parent;
  }
  return dir.path;
}

final _region = RegExp(
  r'<!-- site:([\w-]+) -->(.*?)<!-- /site -->',
  dotAll: true,
);
final _image = RegExp(r'!\[([^\]]*)\]\(([^)\s]+)\)');
final _link = RegExp(r'(?<!!)\[([^\]\[]+)\]\(([^)\s]+)\)');
final _pictureName = RegExp(r'/([\w-]+)\.webp$');
final _fence = RegExp(r'^```(\w*)\n(.*?)\n```$', multiLine: true, dotAll: true);
final _alignment = RegExp(r'^\|[\s:|-]+\|$');
