import 'package:flutterware_site/content.dart';
import 'package:test/test.dart';

void main() {
  group('the README as it is', () {
    late Content content;
    setUpAll(() => content = Content.load());

    test('gives the page its words', () {
      expect(content.text('tagline'), isNot(contains('*')));
      expect(content.html('lede'), isNotEmpty);
      expect(content.snippet('scenario').language, 'dart');
      expect(content.snippet('config').code, contains('Flutterware.configure'));
      expect(content.html('config-note'), contains('$repository/blob/master/'));
      expect(content.snippet('sample').code, contains('git clone'));
      expect(content.snippet('add').isShell, isTrue);
      expect(content.html('first-launch'), isNotEmpty);
      expect(content.html('requirements'), isNotEmpty);
    });

    test('lists its tools the way the page reads them', () {
      var tools = content.tools('tools');
      expect(tools, isNotEmpty);
      for (var tool in tools) {
        expect(tool.guide, startsWith('$repository/blob/master/doc/'));
        expect(tool.picture.url, endsWith('.webp'));
        expect(tool.picture.alt, isNotEmpty);
        expect(tool.description, isNotEmpty);
      }
      expect(content.rows('more-tools'), isNotEmpty);
    });

    test('and its guides show the pictures the page shows', () {
      for (var name in ['hero', 'run']) {
        expect(content.picture(name).alt, isNotEmpty, reason: name);
      }
    });
  });

  test('a region is the text between its markers', () {
    var content = Content(
      readme: '''
# Title

<!-- site:lede -->
Some **bold** words,
on two lines.
<!-- /site -->

Not on the page.
''',
    );
    expect(content.text('lede'), 'Some bold words, on two lines.');
    expect(content.html('lede'), contains('<strong>bold</strong>'));
  });

  test('a missing region is named, with the ones there are', () {
    var content = Content(readme: '<!-- site:lede -->\nWords.\n<!-- /site -->');
    expect(
      () => content.html('tagline'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('site:tagline'), contains('lede')),
        ),
      ),
    );
  });

  test('a link written relative to the README goes to the repository', () {
    var content = Content(
      readme: '''
<!-- site:lede -->
See [the guide](doc/previews.md) and [pub](https://pub.dev).
<!-- /site -->
''',
    );
    expect(
      content.html('lede'),
      allOf(
        contains('href="$repository/blob/master/doc/previews.md"'),
        contains('href="https://pub.dev"'),
      ),
    );
  });

  test('tools are read three rows at a time, a tool per column', () {
    var content = Content(
      readme: '''
<!-- site:tools -->

| [One](doc/one.md) | [Two](doc/two.md) |
|:---|:---|
| [![First](https://example.com/one.webp)](doc/one.md) | [![Second](https://example.com/two.webp)](doc/two.md) |
| Does `one` thing. | Does another. |

<!-- /site -->
''',
    );
    var tools = content.tools('tools');
    expect(tools.map((t) => t.name), ['One', 'Two']);
    expect(tools.first.picture.alt, 'First');
    expect(tools.first.description, 'Does <code>one</code> thing.');
    expect(tools.last.guide, '$repository/blob/master/doc/two.md');
  });

  test('a tools table of another shape is refused', () {
    var content = Content(
      readme: '''
<!-- site:tools -->

| [One](doc/one.md) |
|:---|
| Does one thing. |

<!-- /site -->
''',
    );
    expect(() => content.tools('tools'), throwsStateError);
  });
}
