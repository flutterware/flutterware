import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'chrome.dart';
import 'code.dart';
import 'content.dart';
import 'docs.dart';

/// The studio demo. Every link to it opens a tab of its own: it is an app,
/// and leaving the page for it loses the page.
const _demo = 'demo/';
const _sample = 'https://github.com/flutterware/flutterware_example';

/// What the page calls the two commands that add flutterware to a project,
/// wherever it shows them.
const _addIt = 'Add it to your project';

/// The part of its picture a small tile looks at, as percentages from the left
/// and from the top. A picture not listed here shows its top left corner.
const _focus = {
  'card-store': (0, 12),
  'card-run': (5, 80),
  'card-comparison': (100, 62),
  'card-changes': (70, 45),
  'card-server': (100, 30),
  'card-launcher-icon': (100, 40),
  'card-native-splash': (0, 62),
};

/// The home page.
///
/// What it says in the README's words comes from [content], by region name;
/// what is written here is the page's own.
class Home extends StatelessComponent {
  const Home(this.content, this.docs, {super.key});

  final Content content;
  final Docs docs;

  @override
  Component build(BuildContext context) => .fragment([
    pageHead(
      root: '',
      path: '',
      title: 'Flutterware: a studio for your Flutter project',
      description: '${content.text('tagline')} ${content.text('lede')}',
      image: content.picture('hero').url,
    ),
    pageTop(root: ''),
    main_([_hero(), _tools(), _config(), _scenarios(), _agents(), _tryIt()]),
    pageFooter(root: ''),
    script(src: 'copy.js', defer: true),
  ]);

  Component _hero() {
    var tagline = content.text('tagline');
    // The second clause takes the accent colour and its own line.
    var comma = tagline.indexOf(', ');
    var hero = content.picture('hero');
    return section(classes: 'hero', [
      div(classes: 'wrap', [
        div(classes: 'hero-grid', [
          div([
            span(classes: 'chip', [.text('Open source, MIT license')]),
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
              a(href: _sample, classes: 'button', [
                .text('Clone the sample app'),
              ]),
            ]),
            p(classes: 'note', [
              .text(
                'The demo is the studio itself, running in your browser on a '
                'small coffee-shop app. Nothing to install, and nothing in it '
                'can change.',
              ),
            ]),
          ]),
          div(classes: 'hero-side', [
            _code(content.snippet('add'), copy: true, title: _addIt),
            p([RawText(content.html('first-launch'))]),
          ]),
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
          _label(3, 'Scenarios'),
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
    span([
      a(href: docs.pageOf('$guide.md').path, [.text(name)]),
      .text(rest),
    ]),
  ]);

  Component _tools() {
    var tools = content.tools('tools');
    return section(id: 'tools', [
      div(classes: 'wrap', [
        _label(1, 'Tools'),
        h2([.text("What's in it")]),
        p(classes: 'sub', [
          .text(
            'Each tool has a guide, and you turn on only the ones you want.',
          ),
        ]),
        div(classes: 'tiles', [
          // The first two lead, at twice the width and with their whole
          // picture; the others show a part of theirs.
          for (var (i, tool) in tools.indexed) _tile(tool, big: i < 2),
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
  }

  Component _tile(Tool tool, {required bool big}) {
    var focus = _focus[tool.picture.name];
    return a(href: tool.guide, classes: big ? 'tile big' : 'tile', [
      div(
        classes: 'pic',
        attributes: {
          if (focus case (var x, var y)) 'style': '--fx:$x%;--fy:$y%',
        },
        [
          img(
            src: tool.picture.url,
            alt: tool.picture.alt,
            width: 1200,
            height: 900,
            loading: .lazy,
          ),
        ],
      ),
      h3([.text(tool.name)]),
      p([RawText(tool.description)]),
    ]);
  }

  Component _config() => section(id: 'config', classes: 'band', [
    div(classes: 'wrap', [
      div(classes: 'split code-wide', [
        div([
          _label(2, 'Configuration'),
          h2([.text('Pick your tools in one Dart file')]),
          p([
            .text('The first launch creates '),
            code([.text('tool/flutterware.dart')]),
            .text('. Each line turns a tool on for a package.'),
          ]),
          p([RawText(content.html('config-note'))]),
        ]),
        _code(content.snippet('config'), title: 'tool/flutterware.dart'),
      ]),
    ]),
  ]);

  Component _agents() {
    var run = content.picture('run');
    return section(id: 'agents', classes: 'band', [
      div(classes: 'wrap', [
        div(classes: 'split', [
          div([
            _label(4, 'Agents'),
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
          _way(
            'The studio',
            const Snippet(language: 'shell', code: 'dart run flutterware'),
            [.text('The desktop app, opened on your project.')],
          ),
          _way(
            'The command line',
            const Snippet(
              language: 'shell',
              code: 'fw run scenarios run\nfw run store export',
            ),
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
      _label(5, 'Get started'),
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
            h3([.text(_addIt)]),
            p([
              .text('The first launch creates '),
              code([.text('tool/flutterware.dart')]),
              .text(', where you pick your tools.'),
            ]),
          ]),
          _code(content.snippet('add'), copy: true),
        ]),
      ]),
      p(classes: 'fine', [
        RawText(
          '${content.html('first-launch')} ${content.html('requirements')}',
        ),
      ]),
    ]),
  ]);

  /// What a section is, above its title, numbered down the page.
  Component _label(int number, String name) => span(classes: 'label', [
    b([.text('$number'.padLeft(2, '0'))]),
    .text(name),
  ]);

  /// A code block: a terminal when it holds commands, with a [title] bar when
  /// it has a name, and a copy button when it is something to run.
  Component _code(Snippet snippet, {bool copy = false, String? title}) => div(
    classes: snippet.isShell ? 'code shell' : 'code',
    attributes: {if (copy) 'data-copy': ''},
    [
      if (title != null) span(classes: 'title', [.text(title)]),
      pre([
        code([RawText(_highlight(snippet))]),
      ]),
    ],
  );
}

/// The snippet in the page's colours, or, when it is commands, a line apart
/// for each so the stylesheet can draw its prompt.
String _highlight(Snippet snippet) {
  if (snippet.isShell) {
    return [
      for (var line in snippet.code.split('\n'))
        '<span class="ln">${escapeCode(line)}</span>',
    ].join('\n');
  }
  return highlightCode(snippet.code, language: snippet.language);
}
