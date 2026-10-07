import 'dart:io';

import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;

import 'code.dart';
import 'content.dart' show repository;

/// The guides in `doc/`, as the docs pages of the site.
///
/// Nothing of them is copied here. `doc/README.md` is the first page and also
/// the menu: each of its tables is a group, named by the heading above it, and
/// each row a guide. So a guide the menu does not list, or a row with no guide
/// behind it, fails the build, and so does a link between guides that leads
/// nowhere, which is a link that is broken on GitHub too.
class Docs {
  Docs({required String index, required Map<String, String> guides})
    : groups = _menu(index) {
    var listed = [
      for (var group in groups)
        for (var entry in group.entries) entry.file,
    ];
    for (var file in listed) {
      if (!guides.containsKey(file)) {
        throw StateError(
          'doc/README.md lists $file, and there is no doc/$file.',
        );
      }
    }
    for (var file in guides.keys) {
      if (!listed.contains(file)) {
        throw StateError(
          'doc/$file is not in the tables of doc/README.md, which are the '
          'menu of the docs. Give it a row.',
        );
      }
    }
    _drafts['README.md'] = _Draft('README.md', index);
    for (var group in groups) {
      for (var entry in group.entries) {
        _drafts[entry.file] = _Draft(
          entry.file,
          guides[entry.file]!,
          group: group.title,
        );
      }
    }
    pages = [for (var draft in _drafts.values) draft.render(this)];
  }

  /// Reads the guides of the repository this package sits in.
  factory Docs.load() {
    var dir = Directory(p.join(_repositoryRoot(), 'doc'));
    var files = {
      for (var file in dir.listSync())
        if (file is File && file.path.endsWith('.md'))
          p.basename(file.path): file.readAsStringSync(),
    };
    var index = files.remove('README.md');
    if (index == null) throw StateError('There is no doc/README.md.');
    return Docs(index: index, guides: files);
  }

  /// The menu, as `doc/README.md` groups the guides.
  final List<DocGroup> groups;

  /// Every page, the index first and then the guides in the menu's order.
  late final List<DocPage> pages;

  final _drafts = <String, _Draft>{};

  /// The first page, which is `doc/README.md`.
  DocPage get index => pages.first;

  /// The page before [page] and the one after it, in the menu's order.
  (DocPage?, DocPage?) around(DocPage page) {
    var at = pages.indexOf(page);
    return (
      at > 0 ? pages[at - 1] : null,
      at < pages.length - 1 ? pages[at + 1] : null,
    );
  }

  /// The page of the site a guide's file is rendered as.
  DocPage pageOf(String file) =>
      pages.firstWhere((page) => page.source == 'doc/$file');

  /// Where a link goes on the site, when a file of the repository writes it.
  ///
  /// [from] is that file, as a path from the repository's root, and [root]
  /// leads the page showing the link back to the site's root. A link to a
  /// guide becomes a link to its page; a link to anything else in the
  /// repository goes to GitHub.
  String link(String href, {required String from, String root = ''}) {
    if (href.startsWith('#')) {
      if (_guide.firstMatch(from) case var own?) {
        _drafts[own.group(1)]?.expect(href.substring(1), by: from);
      }
      return href;
    }
    var uri = Uri.tryParse(href);
    if (uri == null || uri.hasScheme || uri.path.isEmpty) return href;

    var target = p.posix.normalize(
      p.posix.join(p.posix.dirname(from), uri.path),
    );
    var fragment = uri.hasFragment ? '#${uri.fragment}' : '';
    var match = _guide.firstMatch(target);
    if (match == null) return '$repository/blob/master/$target$fragment';

    var draft = _drafts[match.group(1)];
    if (draft == null) {
      throw StateError('$from links to $target, and there is no such guide.');
    }
    if (uri.hasFragment) draft.expect(uri.fragment, by: from);
    return '$root${draft.path}$fragment';
  }
}

/// A heading of the menu and the guides under it.
class DocGroup {
  const DocGroup(this.title, this.entries);

  final String title;
  final List<DocEntry> entries;
}

/// A guide as the menu names it.
class DocEntry {
  const DocEntry(this.name, this.file);

  final String name;

  /// The guide's file in `doc/`.
  final String file;
}

/// A guide, rendered.
class DocPage {
  const DocPage({
    required this.source,
    required this.path,
    required this.title,
    required this.description,
    required this.html,
    required this.headings,
    this.group,
  });

  /// The file this page renders, from the repository's root.
  final String source;

  /// Where the page is, from the site's root: `docs/previews/`.
  final String path;

  final String title;

  /// Its opening paragraph, for a search engine or a link preview.
  final String description;

  /// Everything under the title.
  final String html;

  /// Its sections, for the list beside the page.
  final List<DocHeading> headings;

  /// The group of the menu it is in, which the index is not.
  final String? group;

  /// How the page gets back to the site's root.
  String get root => _back(path);
}

class DocHeading {
  const DocHeading({required this.level, required this.id, required this.text});

  final int level;
  final String id;
  final String text;
}

/// A guide that is parsed and knows its headings, which every guide has to be
/// before any of them is rendered: a link is checked against the headings of
/// the guide it leads to.
class _Draft {
  _Draft(this.file, String markdown, {this.group})
    : nodes = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored)
          .parse(markdown) {
    var first = nodes.whereType<md.Element>().firstOrNull;
    if (first == null || first.tag != 'h1') {
      throw StateError('doc/$file does not open with a "# Title".');
    }
    title = _words(first);
    nodes.remove(first);

    var taken = <String, int>{};
    for (var node in nodes.whereType<md.Element>()) {
      if (node.tag != 'h2' && node.tag != 'h3') continue;
      var text = _words(node);
      var id = _anchor(text, taken);
      node.attributes['id'] = id;
      headings.add(
        DocHeading(level: int.parse(node.tag.substring(1)), id: id, text: text),
      );
    }
  }

  final String file;
  final String? group;
  final List<md.Node> nodes;
  late final String title;
  final headings = <DocHeading>[];

  String get source => 'doc/$file';

  String get path => file == 'README.md'
      ? 'docs/'
      : 'docs/${p.withoutExtension(file).replaceAll('_', '-')}/';

  /// Fails when this guide has no heading a link's fragment can land on.
  void expect(String fragment, {required String by}) {
    if (headings.any((heading) => heading.id == fragment)) return;
    throw StateError(
      '$by links to $source#$fragment, and that guide has no such heading. '
      'It has: ${headings.map((heading) => heading.id).join(', ')}.',
    );
  }

  DocPage render(Docs docs) => DocPage(
    source: source,
    path: path,
    title: title,
    description: _description(),
    html: md.renderToHtml(_Rewrite(docs, source, _back(path)).all(nodes)),
    headings: headings,
    group: group,
  );

  String _description() {
    var opening = nodes
        .whereType<md.Element>()
        .where((node) => node.tag == 'p')
        .firstOrNull;
    if (opening == null) return title;
    var words = _words(opening);
    if (words.length <= 200) return words;
    var cut = words.lastIndexOf(' ', 200);
    return '${words.substring(0, cut)}…';
  }
}

/// Turns what the markdown says into what the page shows: links that lead to
/// the site's own pages, code in the page's colours, a heading you can link
/// to, a table that scrolls by itself on a phone.
class _Rewrite {
  _Rewrite(this.docs, this.source, this.root);

  final Docs docs;
  final String source;
  final String root;

  List<md.Node> all(List<md.Node> nodes) => [
    for (var node in nodes) node is md.Element ? _element(node) : node,
  ];

  md.Node _element(md.Element source) {
    if (source.tag == 'pre') return _code(source);

    // A copy, because the parser's own lists of children are not all lists
    // that take any node.
    var children = source.children;
    var element = md.Element(
      source.tag,
      children == null ? null : all(children),
    )..attributes.addAll(source.attributes);
    switch (element.tag) {
      case 'a':
        element.attributes.update(
          'href',
          (href) => docs.link(href, from: this.source, root: root),
        );
      case 'img':
        element.attributes['loading'] = 'lazy';
      case 'h2' || 'h3':
        var id = element.attributes['id'];
        if (id != null) {
          element.children?.add(
            md.Element('a', [md.Text('#')])
              ..attributes['class'] = 'anchor'
              ..attributes['href'] = '#$id'
              ..attributes['aria-label'] = 'Link to this section',
          );
        }
      case 'table':
        return md.Element('div', [element])..attributes['class'] = 'table';
    }
    return element;
  }

  md.Node _code(md.Element pre) {
    var code = pre.children?.whereType<md.Element>().firstOrNull;
    var language = (code?.attributes['class'] ?? '').replaceFirst(
      'language-',
      '',
    );
    var source = _unescape((code ?? pre).textContent).trimRight();
    // Its line breaks are written as character references: the page is
    // indented as it is written out, and inside a `<pre>` an indent shows.
    var html = highlightCode(
      source,
      language: language,
    ).replaceAll('\n', '&#10;');
    return md.Text(
      '<div class="code" data-copy><pre><code>$html</code></pre></div>',
    );
  }
}

/// The groups of `doc/README.md`: each table whose rows link to a guide, under
/// the heading above it.
List<DocGroup> _menu(String index) {
  var groups = <DocGroup>[];
  String? heading;
  for (var line in index.split('\n')) {
    if (_heading.firstMatch(line) case var match?) {
      heading = match.group(1)!.trim();
    } else if (_row.firstMatch(line.trim()) case var match?) {
      if (heading == null) {
        throw StateError(
          'doc/README.md has a table of guides with no "## Heading" above it '
          'to name its group.',
        );
      }
      if (groups.isEmpty || groups.last.title != heading) {
        groups.add(DocGroup(heading, []));
      }
      groups.last.entries.add(DocEntry(match.group(1)!, match.group(2)!));
    }
  }
  if (groups.isEmpty) {
    throw StateError('doc/README.md has no table of guides.');
  }
  return groups;
}

/// From a page at [path] back to the site's root, as the start of a relative
/// link: `../../` from `docs/previews/`.
String _back(String path) => '../' * (path.split('/').length - 1);

/// The words of an element, with no markup.
String _words(md.Element element) =>
    _unescape(element.textContent).replaceAll(RegExp(r'\s+'), ' ').trim();

/// The anchor GitHub gives a heading, so a link written for GitHub lands on
/// the page too.
String _anchor(String heading, Map<String, int> taken) {
  var anchor = heading
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}\p{M}_ -]', unicode: true), '')
      .replaceAll(' ', '-');
  var count = taken.update(anchor, (count) => count + 1, ifAbsent: () => 0);
  return count == 0 ? anchor : '$anchor-$count';
}

/// What the markdown parser escaped, back as it was written.
String _unescape(String text) => text
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&');

String _repositoryRoot() {
  var dir = Directory.current;
  while (!File(p.join(dir.path, 'doc', 'README.md')).existsSync()) {
    if (dir.parent.path == dir.path) {
      throw StateError('No doc/README.md above the site.');
    }
    dir = dir.parent;
  }
  return dir.path;
}

final _guide = RegExp(r'^doc/([\w-]+\.md)$');
final _heading = RegExp(r'^## +(.+)$');
final _row = RegExp(r'^\|\s*\[([^\]]+)\]\(([\w-]+\.md)\)\s*\|.*\|$');
