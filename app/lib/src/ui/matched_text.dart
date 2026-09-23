import 'package:material_ui/material_ui.dart';

import 'design/design.dart';

/// Text with the characters a filter matched lit up.
///
/// Yellow behind the glyph rather than a colour on it, which is what the
/// catalog's own search does (`lib/src/ui_catalog/search.dart`) and what a
/// reader recognises without being told. The indexes come from the same
/// [fuzzyMatch] that decided the row belongs here, so what is lit is literally
/// why it is on screen — a substring highlight would have to guess, and would
/// light nothing at all for a query the fuzzy matcher accepted.
class MatchedText extends StatelessWidget {
  const MatchedText(this.text, {super.key, required this.matched, this.style});

  final String text;
  final List<int> matched;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    if (matched.isEmpty) {
      return Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    var hot = matched.toSet();
    var lit = (style ?? const TextStyle()).copyWith(
      backgroundColor: context.colors.searchMark,
      color: context.colors.ink,
    );
    return Text.rich(
      TextSpan(
        children: [
          for (var i = 0; i < text.length; i++)
            TextSpan(text: text[i], style: hot.contains(i) ? lit : style),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
