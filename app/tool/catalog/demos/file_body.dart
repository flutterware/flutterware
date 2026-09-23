import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/changes/diff_view.dart';
import 'package:flutterware_app/src/changes/file_body.dart';
import 'package:flutterware_app/src/ui/syntax.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// The changes screen's non-diff bodies, stacked: rendered markdown, an SVG
/// preview (and one with broken bytes, because the refusal is part of the
/// design), an untracked file's own lines, and the refusal notice.
///
/// The untracked body is the one to look at beside the diff: it draws the same
/// syntax colours, the same `+` in the margin, the same accent behind a picked
/// span, and puts a thread under the line it is about. What git can say about a
/// file is not what you can do with it.
///
/// The image differ is deliberately not here: its two sides come from a
/// worktree and a git revision, and a demo faking both would be a stage set —
/// it is reviewed live, on a real delta.

@Preview(name: 'File bodies', group: 'Changes', wrapper: wrapInAppTheme)
Widget fileBodies() => const _FileBodies();

@Preview(name: 'File bodies (dark)', group: 'Changes', wrapper: wrapInDarkTheme)
Widget fileBodiesDark() => const _FileBodies();

/// The untracked body on its own, because it is the one worth putting beside
/// the diff: same syntax colours, same `+` in the margin, same accent behind
/// the picked span, and a thread under the line it is about. Whether an agent
/// got as far as `git add` decides what git can tell us about a file, not what
/// you can do with it on your screen.
@Preview(name: 'Untracked file', group: 'Changes', wrapper: wrapInAppTheme)
Widget untrackedText() => const SizedBox(height: 320, child: _UntrackedText());

@Preview(
  name: 'Untracked file (dark)',
  group: 'Changes',
  wrapper: wrapInDarkTheme,
)
Widget untrackedTextDark() =>
    const SizedBox(height: 320, child: _UntrackedText());

class _FileBodies extends StatefulWidget {
  const _FileBodies();

  @override
  State<_FileBodies> createState() => _FileBodiesState();
}

class _FileBodiesState extends State<_FileBodies> {
  final _scrollX = DiffScrollX();

  @override
  void dispose() {
    _scrollX.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var label = context.type.sectionLabel;
    return ListView(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      children: [
        Text('MARKDOWN, RENDERED', style: label),
        const Gap(FwSpacing.sm),
        SizedBox(
          height: 300,
          child: MarkdownFileBody(
            content: _markdown,
            imageDirectory: '/nowhere/',
          ),
        ),
        const Gap(FwSpacing.xl),
        Text('SVG PREVIEW', style: label),
        const Gap(FwSpacing.sm),
        SizedBox(height: 220, child: SvgFileBody(bytes: utf8.encode(_svg))),
        const Gap(FwSpacing.xl),
        Text('SVG PREVIEW, BROKEN BYTES', style: label),
        const Gap(FwSpacing.sm),
        SizedBox(
          height: 120,
          child: SvgFileBody(bytes: utf8.encode('<not really svg')),
        ),
        const Gap(FwSpacing.xl),
        Text('UNTRACKED TEXT', style: label),
        const Gap(FwSpacing.sm),
        const SizedBox(height: 260, child: _UntrackedText()),
        const Gap(FwSpacing.xl),
        Text('REFUSAL', style: label),
        const Gap(FwSpacing.sm),
        const FileBodyNotice(
          'This file is 3.2 MB — past what the viewer reads. Open it in '
          'your editor.',
        ),
      ],
    );
  }
}

class _UntrackedText extends StatefulWidget {
  const _UntrackedText();

  @override
  State<_UntrackedText> createState() => _UntrackedTextState();
}

class _UntrackedTextState extends State<_UntrackedText> {
  final _scrollX = DiffScrollX();

  @override
  void dispose() {
    _scrollX.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var style = diffTextStyle(context);
    var painter = TextPainter(
      text: TextSpan(text: 'M' * 10, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    return TextFileBody(
      lines: _lines,
      tokens: LazyLineTokens(_lines, language: 'dart'),
      scrollX: _scrollX,
      charWidth: painter.width / 10,
      // A picked span and a thread under it, which is the state worth
      // photographing: an unmarked file is what the plain body already was.
      selected: const {3, 4},
      placed: {
        4: [
          Container(
            margin: const EdgeInsets.symmetric(
              horizontal: FwSpacing.xxl,
              vertical: FwSpacing.sm,
            ),
            padding: const EdgeInsets.all(FwSpacing.md),
            decoration: BoxDecoration(
              border: Border.all(color: context.colors.line),
              borderRadius: BorderRadius.circular(context.radii.radiusSmall),
            ),
            child: Text(
              'A thread sits here, under the line it is about — the same '
              'place the diff puts one.',
              style: context.type.bodySmall,
            ),
          ),
        ],
      },
      onComment: (_) {},
    );
  }
}

const _markdown = '''
# A new design note

This file is **new on the branch**, so its diff would be a wall of `+`
lines. Rendered, it reads like what it is: prose.

- one point
- a second point with `inline code`
- a [link](https://example.com) that opens in the browser

```dart
var code = 'blocks keep their monospace';
```

![missing asset](assets/not-there.png)
''';

const _svg = '''
<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80">
  <rect x="8" y="8" width="104" height="64" rx="10" fill="#1877f2"/>
  <circle cx="60" cy="40" r="18" fill="white" fill-opacity="0.9"/>
</svg>
''';

const _lines = [
  '// A source file an agent wrote thirty seconds ago and has not staged.',
  'class Migration {',
  "  static const name = 'add the missing index';",
  '  var applied = false;',
  '',
  '  // Numbered like a diff and tinted like nothing: "every line is new" is',
  "  // the header's claim, and repeating it in green for the length of the",
  '  // file would be noise. The colours are the tokeniser, which is a third',
  '  // channel and does not compete with it.',
  '  void run() => throw UnimplementedError("this line is deliberately long enough to give the shared horizontal scroll a reason to exist");',
  '}',
];
