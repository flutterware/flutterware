import 'package:flutterware_site/content.dart';
import 'package:flutterware_site/docs.dart';
import 'package:test/test.dart';

const _index = '''
# The docs

Every guide.

## Screens

| Tool | What it does |
|:---|:---|
| [Previews](previews.md) | Widgets on a device. |
| [Store screenshots](store_screenshots.md) | Images for the stores. |

## The same tools, three ways

Words with no table are a section of the first page and no group.
''';

const _previews = '''
# Previews

What a preview is, and [how it is tested](store_screenshots.md#turn-it-on).

## Turn it on

```dart
fw.use(Previews());
```

## Turn it on

A second section of the same name, [read from here](#turn-it-on-1).
''';

const _store = '''
# Store screenshots

Images, from [the capabilities](../docs/capabilities.md#store) and
[a frame](../examples/brewline/lib/store_frame.dart).

## Turn it on

| Flag | What it does |
|---|---|
| `--all` | Everything. |
''';

Docs _docs({String? previews, Map<String, String> more = const {}}) => Docs(
  index: _index,
  guides: {
    'previews.md': previews ?? _previews,
    'store_screenshots.md': _store,
    ...more,
  },
);

void main() {
  group('the guides as they are', () {
    late Docs docs;
    setUpAll(() => docs = Docs.load());

    test('are all in the menu, with every link between them landing', () {
      expect(docs.groups, isNotEmpty);
      expect(docs.index.path, 'docs/');
      for (var page in docs.pages) {
        expect(page.title, isNotEmpty, reason: page.source);
        expect(page.description, isNotEmpty, reason: page.source);
        expect(page.html, isNotEmpty, reason: page.source);
      }
    });

    test('are where the README sends its readers', () {
      var content = Content.load(
        link: (href) => docs.link(href, from: 'README.md'),
      );
      var paths = {for (var page in docs.pages) page.path};
      for (var tool in content.tools('tools')) {
        expect(paths, contains(tool.guide), reason: tool.name);
      }
    });
  });

  test('the menu is the tables of the first page', () {
    var docs = _docs();
    expect(docs.groups.map((group) => group.title), ['Screens']);
    expect(docs.groups.single.entries.map((entry) => entry.name), [
      'Previews',
      'Store screenshots',
    ]);
    expect(docs.pages.map((page) => page.path), [
      'docs/',
      'docs/previews/',
      'docs/store-screenshots/',
    ]);
    expect(docs.pageOf('previews.md').group, 'Screens');
    expect(docs.index.group, isNull);
  });

  test('a page is its guide under the title', () {
    var page = _docs().pageOf('previews.md');
    expect(page.title, 'Previews');
    expect(page.description, startsWith('What a preview is'));
    expect(page.html, isNot(contains('<h1')));
    expect(page.root, '../../');
    expect(_docs().index.root, '../');
  });

  test('a heading takes the anchor GitHub gives it', () {
    var page = _docs().pageOf('previews.md');
    expect(page.headings.map((heading) => heading.id), [
      'turn-it-on',
      'turn-it-on-1',
    ]);
    expect(page.html, contains('<h2 id="turn-it-on">'));
    expect(page.html, contains('href="#turn-it-on-1"'));
  });

  test('a link to a guide leads to its page, from wherever it is read', () {
    var docs = _docs();
    expect(
      docs.pageOf('previews.md').html,
      contains('href="../../docs/store-screenshots/#turn-it-on"'),
    );
    expect(docs.index.html, contains('href="../docs/previews/"'));
    expect(
      docs.link('doc/previews.md#turn-it-on', from: 'README.md'),
      'docs/previews/#turn-it-on',
    );
    expect(docs.link('doc/README.md', from: 'README.md'), 'docs/');
  });

  test('a link to anything else in the repository leads to GitHub', () {
    var html = _docs().pageOf('store_screenshots.md').html;
    expect(
      html,
      contains('href="$repository/blob/master/docs/capabilities.md#store"'),
    );
    expect(
      html,
      contains(
        'href="$repository/blob/master/examples/brewline/lib/store_frame.dart"',
      ),
    );
    expect(
      _docs().link('https://pub.dev', from: 'doc/previews.md'),
      'https://pub.dev',
    );
  });

  test(
    'code is coloured, and keeps its lines however the page is indented',
    () {
      var html = _docs(
        previews: '# Previews\n\n```dart\nvar a = 1;\nvar b = 2;\n```\n',
      ).pageOf('previews.md').html;
      expect(html, contains('<span class="hljs-keyword">var</span>'));
      expect(html, contains('&#10;'));
      expect(html, contains('data-copy'));
    },
  );

  test('a table scrolls on its own', () {
    expect(
      _docs().pageOf('store_screenshots.md').html,
      matches(RegExp(r'<div class="table">\s*<table>')),
    );
  });

  group('refuses', () {
    Matcher saying(String words) => throwsA(
      isA<StateError>().having((e) => e.message, 'message', contains(words)),
    );

    test('a guide the menu does not list', () {
      expect(
        () => _docs(more: {'lints.md': '# Lints'}),
        saying('doc/lints.md is not in the tables of doc/README.md'),
      );
    });

    test('a row with no guide behind it', () {
      expect(
        () => Docs(index: _index, guides: {'previews.md': _previews}),
        saying('lists store_screenshots.md'),
      );
    });

    test(
      'a link to a heading the guide does not have, naming those it has',
      () {
        expect(
          () => _docs(previews: '# Previews\n\n[x](store_screenshots.md#nope)'),
          saying('no such heading. It has: turn-it-on'),
        );
        expect(
          () => _docs(previews: '# Previews\n\n[x](#nope)\n\n## Here'),
          saying('doc/previews.md#nope'),
        );
      },
    );

    test('a link to a guide there is not', () {
      expect(
        () => _docs(previews: '# Previews\n\n[x](gone.md)'),
        saying('there is no such guide'),
      );
    });

    test('a guide with no title', () {
      expect(
        () => _docs(previews: 'Words first.\n\n# Previews'),
        saying('does not open with a "# Title"'),
      );
    });
  });
}
