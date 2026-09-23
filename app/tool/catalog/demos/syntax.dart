import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/ui/syntax.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// Syntax highlighting, across the languages the app actually renders.
///
/// The colours are theme-dependent, and nothing had looked at them in the
/// dark build. `spansFor` resolves each token class against the palette, and
/// a class that resolved to near-black would be invisible on a dark ground with
/// no test anywhere that would notice.
///
/// Checked when these were written, and it holds: every class stays legible in
/// both builds. That is a fact with a shelf life rather than a conclusion — the
/// point of the paired entries is that the next palette change has somewhere to
/// be wrong in public.
///
/// Not a widget but a tokenizer — `syntax.dart` exposes `codeSpans`, and this
/// renders its output the way `help_page` and the diff view do.

const _dart = r'''
/// The tokenizer, exercised.
@Preview(name: 'Rows', group: 'Table')
Widget tableRows() => const _Table(rows: _rows);

class FwPanelHeader extends StatelessWidget {
  const FwPanelHeader(this.title, {super.key, this.badge});

  final String title;      // trailing comment
  final Widget? badge;

  static const _kinds = <String, int>{'direct': 1, 'dev': 2};

  @override
  Widget build(BuildContext context) {
    var n = 0x1F + 42 - 3.14;
    if (title.isEmpty) throw StateError("empty: '\$n'");
    return Text(title, style: context.type.pageTitle);
  }
}
''';

const _yaml = r'''
name: flutterware_app
publish_to: none          # never published
environment:
  sdk: ^3.13.0-0
  flutter: '>=3.21.0'
dependencies:
  flutter:
    sdk: flutter
  built_value: ^8.3.0
  path: ^1.8.0
flutter:
  assets:
    - assets/
''';

const _json = r'''
{
  "plugin": "flutterware.run",
  "result": {
    "status": "running",
    "waited": true,
    "ms": 315,
    "defines": {},
    "log": null
  }
}
''';

@Preview(name: 'Dart', group: 'Syntax', wrapper: wrapInAppTheme)
Widget syntaxDart() => const _Code(_dart, language: 'dart');

/// The reason this file exists. Every token class on a dark ground, where a
/// colour that was only ever checked against white shows up as unreadable.
@Preview(name: 'Dart · dark', group: 'Syntax', wrapper: wrapInDarkTheme)
Widget syntaxDartDark() => const _Code(_dart, language: 'dart');

@Preview(name: 'YAML', group: 'Syntax', wrapper: wrapInAppTheme)
Widget syntaxYaml() => const _Code(_yaml, language: 'yaml');

@Preview(name: 'YAML · dark', group: 'Syntax', wrapper: wrapInDarkTheme)
Widget syntaxYamlDark() => const _Code(_yaml, language: 'yaml');

@Preview(name: 'JSON', group: 'Syntax', wrapper: wrapInAppTheme)
Widget syntaxJson() => const _Code(_json, language: 'json');

/// An unknown language: the tokenizer has nothing to say and the text has to
/// come out plain rather than empty.
@Preview(name: 'Unknown language', group: 'Syntax', wrapper: wrapInAppTheme)
Widget syntaxUnknown() =>
    const _Code('SELECT * FROM ps_crud WHERE id > 3;', language: 'nonesuch');

class _Code extends StatelessWidget {
  const _Code(this.source, {required this.language});

  final String source;
  final String language;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return ColoredBox(
      color: colors.panel,
      child: Padding(
        padding: const EdgeInsets.all(FwSpacing.xxl),
        child: Align(
          alignment: Alignment.topLeft,
          child: Container(
            decoration: BoxDecoration(
              color: colors.bg,
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(context.radii.radius),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(FwSpacing.lg),
              child: SelectableText.rich(
                TextSpan(
                  children: codeSpans(context, source, language: language),
                ),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontFamilyFallback: ['Menlo', 'Consolas', 'Courier New'],
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
