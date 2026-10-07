import 'dart:convert';

import 'package:highlight/highlight_core.dart';
import 'package:highlight/languages/dart.dart' as dart_language;
import 'package:highlight/languages/json.dart' as json_language;
import 'package:highlight/languages/yaml.dart' as yaml_language;

/// The grammars for what the README and the guides fence their code in, under
/// the names they use.
final _grammars = {
  'dart': dart_language.dart,
  'json': json_language.json,
  'yaml': yaml_language.yaml,
};

/// [code] as HTML, its tokens in spans the stylesheet colours (`hljs-keyword`,
/// `hljs-string`…). Code in a language with no grammar here comes back escaped
/// and uncoloured.
String highlightCode(String code, {String language = ''}) {
  if (language == 'shell' || language == 'sh') return _commands(code);
  var grammar = _grammars[language];
  if (grammar == null) return escapeCode(code);
  highlight.registerLanguage(language, grammar);
  return highlight.parse(code, language: language).toHtml();
}

/// [code] as the text of an HTML element.
String escapeCode(String code) => const HtmlEscape(.element).convert(code);

/// Commands, with nothing marked but their comments. A grammar for shell
/// scripts marks the shell's own words wherever they turn up, and `test` in
/// `flutter test` or `export` in `--export` is not one of them.
String _commands(String code) => escapeCode(code).replaceAllMapped(
  _comment,
  (match) => '${match[1]}<span class="hljs-comment">${match[2]}</span>',
);

final _comment = RegExp(r'(^|\s)(#.*)$', multiLine: true);
