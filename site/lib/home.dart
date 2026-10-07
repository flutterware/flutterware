import 'dart:convert';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'content.dart';

const _guides = '$repository/tree/master/doc';

/// The studio demo. Every link to it opens a tab of its own: it is an app,
/// and leaving the page for it loses the page.
const _demo = 'demo/';
const _sample = 'https://github.com/flutterware/flutterware_example';
const _pub = 'https://pub.dev/packages/flutterware';

/// The home page.
///
/// What it says in the README's words comes from [content], by region name;
/// what is written here is the page's own.
class Home extends StatelessComponent {
  const Home(this.content, {super.key});

  final Content content;

  @override
  Component build(BuildContext context) => .fragment([
    _top(),
    main_([_hero(), _tools(), _config(), _scenarios(), _agents(), _tryIt()]),
    _footer(),
    script(src: 'copy.js', defer: true),
  ]);

  Component _top() => header(classes: 'top', [
    div(classes: 'wrap', [
      a(href: './', classes: 'brand', [
        img(src: 'icon.svg', alt: '', width: 28, height: 28),
        .text('flutterware'),
      ]),
      nav(
        attributes: {'aria-label': 'Main'},
        [
          a(href: '#tools', classes: 'in-page', [.text('Tools')]),
          a(href: '#agents', classes: 'in-page', [.text('Agents')]),
          a(href: _guides, [.text('Docs')]),
          a(href: repository, [.text('GitHub')]),
          a(href: _pub, [.text('pub.dev')]),
        ],
      ),
    ]),
  ]);

  Component _hero() {
    var tagline = content.text('tagline');
    // The second clause takes the accent colour and its own line.
    var comma = tagline.indexOf(', ');
    var hero = content.picture('hero');
    return section(classes: 'hero', [
      div(classes: 'wrap', [
        p(classes: 'eyebrow', [.text('Open source, MIT license')]),
        h1([
          if (comma < 0)
            .text(tagline)
          else ...[
            .text(tagline.substring(0, comma + 1)),
            span([.text(tagline.substring(comma + 1))]),
          ],
        ]),
        p(classes: 'lede', [RawText(content.html('lede'))]),
        div(classes: 'actions', [
          a(href: _demo, target: .blank, classes: 'button primary', [
            .text('Open the web demo'),
          ]),
          a(href: _sample, classes: 'button', [.text('Clone the sample app')]),
        ]),
        p(classes: 'note', [
          .text(
            'The demo is the studio itself, running in your browser on a '
            'small coffee-shop app. Nothing to install, and nothing in it can '
            'change.',
          ),
        ]),
        a(href: _demo, target: .blank, classes: 'shot', [
          img(
            src: hero.url,
            alt: hero.alt,
            width: 2000,
            height: 1125,
            attributes: {'fetchpriority': 'high'},
          ),
        ]),
      ]),
    ]);
  }

  Component _scenarios() => section(id: 'scenarios', [
    div(classes: 'wrap', [
      div(classes: 'split', [
        div([
          h2([.text('Write the test once. Get the rest from it.')]),
          p([
            .text(
              'A scenario is a widget test that keeps a screenshot, the '
              'widget tree and the visible text of every step. ',
            ),
            code([.text('flutter test')]),
            .text(' runs it like any other test, and '),
            code([.text('s.split')]),
            .text(
              ' replays the body once per branch, so one scenario covers '
              'every path through a screen.',
            ),
          ]),
          ul(classes: 'outcomes', [
            _outcome(
              'scenarios',
              'The flow',
              ', drawn step by step in the studio',
            ),
            _outcome(
              'store_screenshots',
              'Store images',
              ' for both stores, in every language',
            ),
            _outcome(
              'translations',
              'Each translation',
              ', pictured where it appears',
            ),
            _outcome(
              'comparison',
              'What a branch changed',
              ' on screen, as a page for the pull request',
            ),
          ]),
        ]),
        _code(content.snippet('scenario')),
      ]),
    ]),
  ]);

  Component _outcome(String guide, String name, String rest) => li([
    a(href: '$repository/blob/master/doc/$guide.md', [.text(name)]),
    .text(rest),
  ]);

  Component _tools() => section(id: 'tools', [
    div(classes: 'wrap', [
      h2([.text("What's in it")]),
      p(classes: 'sub', [
        .text('Each tool has a guide, and you turn on only the ones you want.'),
      ]),
      div(classes: 'cards', [
        for (var tool in content.tools('tools'))
          a(href: tool.guide, classes: 'card', [
            img(
              src: tool.picture.url,
              alt: tool.picture.alt,
              width: 1200,
              height: 900,
              loading: .lazy,
            ),
            h3([.text(tool.name)]),
            p([RawText(tool.description)]),
          ]),
      ]),
      h3(classes: 'rest-title', [.text('And the rest')]),
      dl(classes: 'rest', [
        for (var row in content.rows('more-tools'))
          div([
            dt([RawText(row.name)]),
            dd([RawText(row.description)]),
          ]),
      ]),
    ]),
  ]);

  Component _config() => section(id: 'config', classes: 'band', [
    div(classes: 'wrap', [
      div(classes: 'split code-wide', [
        div([
          h2([.text('Pick your tools in one Dart file')]),
          p([
            .text('The first launch creates '),
            code([.text('tool/flutterware.dart')]),
            .text('. Each line turns a tool on for a package.'),
          ]),
          p([RawText(content.html('config-note'))]),
        ]),
        _code(content.snippet('config')),
      ]),
    ]),
  ]);

  Component _agents() {
    var run = content.picture('run');
    return section(id: 'agents', classes: 'band', [
      div(classes: 'wrap', [
        div(classes: 'split', [
          div([
            h2([.text('Your agent gets the same tools')]),
            p([RawText(content.html('agents'))]),
          ]),
          img(
            classes: 'framed',
            src: run.url,
            alt: run.alt,
            width: 1800,
            height: 1125,
            loading: .lazy,
          ),
        ]),
        div(classes: 'ways', [
          _way('The studio', const Snippet(code: 'dart run flutterware'), [
            .text('The desktop app, opened on your project.'),
          ]),
          _way(
            'The command line',
            const Snippet(code: 'fw run scenarios run\nfw run store export'),
            [
              .text('Every action, from a terminal. '),
              code([.text('fw')]),
              .text(' is an alias for '),
              code([.text('dart run flutterware')]),
              .text('.'),
            ],
          ),
          _way(
            'MCP',
            const Snippet(
              language: 'json',
              code:
                  'flutterware_act {\n'
                  '  "verb": "tap",\n'
                  '  "target": "Cold brew"\n'
                  '}',
            ),
            [
              .text(
                'The same actions as tools, and a running app an agent can '
                'drive.',
              ),
            ],
          ),
        ]),
        p(classes: 'same', [
          .text(
            'Three ways in, one set of tools. Every action and option is '
            'listed in the ',
          ),
          a(href: '$repository/blob/master/docs/capabilities.md', [
            .text('capabilities reference'),
          ]),
          .text('.'),
        ]),
      ]),
    ]);
  }

  Component _way(String name, Snippet snippet, List<Component> what) => div([
    h3([.text(name)]),
    _code(snippet),
    p(what),
  ]);

  Component _tryIt() => section(id: 'try', [
    div(classes: 'wrap', [
      h2([.text('Try it')]),
      ol(classes: 'steps', [
        li([
          div([
            h3([.text('Look around')]),
            p([
              .text(
                'The studio in your browser, opened on the demo app. The '
                'previews run live in the page, and every other tool shows '
                'what it found on a recorded run.',
              ),
            ]),
          ]),
          div([
            a(href: _demo, target: .blank, classes: 'button', [
              .text('Open the web demo'),
            ]),
          ]),
        ]),
        li([
          div([
            h3([.text('Run the sample')]),
            p([.text('The coffee-shop app, with every tool turned on.')]),
          ]),
          _code(content.snippet('sample'), copy: true),
        ]),
        li([
          div([
            h3([.text('Add it to your project')]),
            p([
              .text('The first launch creates '),
              code([.text('tool/flutterware.dart')]),
              .text(', where you pick your tools.'),
            ]),
          ]),
          _code(content.snippet('add'), copy: true),
        ]),
      ]),
      p(classes: 'fine', [RawText(content.html('requirements'))]),
    ]),
  ]);

  Component _footer() => footer([
    div(classes: 'wrap', [
      span([.text('MIT license')]),
      nav(
        attributes: {'aria-label': 'Footer'},
        [
          a(href: _guides, [.text('Docs')]),
          a(href: repository, [.text('GitHub')]),
          a(href: _pub, [.text('pub.dev')]),
          a(href: '$_pub/changelog', [.text('Changelog')]),
          a(href: '$repository/blob/master/CONTRIBUTING.md', [
            .text('Contributing'),
          ]),
        ],
      ),
    ]),
  ]);

  /// A code block, with a copy button when it is a command to run.
  Component _code(Snippet snippet, {bool copy = false}) => div(
    classes: 'code',
    attributes: {if (copy) 'data-copy': ''},
    [
      pre([
        code([RawText(_highlight(snippet))]),
      ]),
    ],
  );
}

/// Strings and a handful of keywords, which is all the page's snippets need.
String _highlight(Snippet snippet) {
  var escaped = const HtmlEscape(.element).convert(snippet.code);
  var token = switch (snippet.language) {
    'dart' => RegExp(r"('[^'\n]*')|\b(async|await|const|import|void)\b"),
    'json' => RegExp('("[^"\n]*")'),
    _ => null,
  };
  if (token == null) return escaped;
  return escaped.replaceAllMapped(
    token,
    (m) => m.group(1) != null
        ? '<span class="s">${m.group(1)}</span>'
        : '<span class="k">${m.group(2)}</span>',
  );
}
