import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:material_ui/material_ui.dart';

/// The style sheet every `MarkdownBody` in the studio renders with.
///
/// `flutter_markdown_plus` is still written against
/// `package:flutter/material.dart`, and it always starts from a sheet of its
/// own built from *that* library's `Theme` — which the studio, on
/// `material_ui`, never provides, so what it finds is Material's fallback:
/// light, and off the ramp. A sheet passed in is merged over that one field by
/// field, and a text style property by property, so this one sets every field
/// the package's `MarkdownStyleSheet.fromTheme` does, the same way, from the
/// studio's own theme. Its text styles come from the theme's slots, which are
/// complete, so nothing of the fallback shows through them.
MarkdownStyleSheet markdownStyleSheet(BuildContext context) {
  var theme = Theme.of(context);
  var text = theme.textTheme;
  var body = text.bodyMedium!;
  return MarkdownStyleSheet(
    a: const TextStyle(color: Colors.blue),
    p: body,
    pPadding: EdgeInsets.zero,
    code: body.copyWith(
      backgroundColor: theme.cardTheme.color,
      fontFamily: 'monospace',
      fontSize: body.fontSize! * 0.85,
    ),
    h1: text.headlineSmall,
    h1Padding: EdgeInsets.zero,
    h2: text.titleLarge,
    h2Padding: EdgeInsets.zero,
    h3: text.titleMedium,
    h3Padding: EdgeInsets.zero,
    h4: text.bodyLarge,
    h4Padding: EdgeInsets.zero,
    h5: text.bodyLarge,
    h5Padding: EdgeInsets.zero,
    h6: text.bodyLarge,
    h6Padding: EdgeInsets.zero,
    em: const TextStyle(fontStyle: FontStyle.italic),
    strong: const TextStyle(fontWeight: FontWeight.bold),
    del: const TextStyle(decoration: TextDecoration.lineThrough),
    blockquote: body,
    img: body,
    checkbox: body.copyWith(color: theme.primaryColor),
    blockSpacing: 8,
    listIndent: 24,
    listBullet: body,
    listBulletPadding: const EdgeInsets.only(right: 4),
    tableHead: const TextStyle(fontWeight: FontWeight.w600),
    tableBody: body,
    tableHeadAlign: TextAlign.center,
    tablePadding: const EdgeInsets.only(bottom: 4),
    tableBorder: TableBorder.all(color: theme.dividerColor),
    tableColumnWidth: const FlexColumnWidth(),
    tableCellsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    tableCellsDecoration: const BoxDecoration(),
    blockquotePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    blockquoteDecoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(3),
      border: Border(
        left: BorderSide(color: theme.colorScheme.primary, width: 3),
      ),
    ),
    codeblockPadding: const EdgeInsets.all(8),
    codeblockDecoration: BoxDecoration(
      color: theme.cardTheme.color ?? theme.cardColor,
      borderRadius: BorderRadius.circular(2),
    ),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(width: 5, color: theme.dividerColor)),
    ),
  );
}
