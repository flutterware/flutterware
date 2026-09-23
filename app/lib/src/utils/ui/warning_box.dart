import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart';

import '../../ui/markdown_style.dart';

class WarningBox extends StatelessWidget {
  final String message;

  const WarningBox({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    const foreground = Color(0xff856404);
    var sheet = markdownStyleSheet(context);
    return Card(
      surfaceTintColor: Color(0xfffff3cd),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.all(15),
              child: Icon(Icons.warning_amber, color: foreground),
            ),
            Expanded(
              child: MarkdownBody(
                data: message,
                styleSheet: sheet.copyWith(
                  p: sheet.p!.copyWith(color: foreground),
                ),
                extensionSet: ExtensionSet.commonMark,
                inlineSyntaxes: [LineBreakSyntax()],
                onTapLink: (text, href, title) {},
              ),
            ),
          ],
        ),
      ),
    );
  }
}
