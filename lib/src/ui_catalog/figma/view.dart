import 'package:material_ui/material_ui.dart';

import '../../utils/value_stream.dart';
import '../app.dart';
import 'link.dart';
import 'provider.dart';
import 'ui/clipboard_button.dart';
import 'ui/column.dart';
import 'ui/info_dialog.dart';
import 'ui/settings.dart';

class FigmaView extends StatelessWidget {
  final TreeEntry entry;
  final Widget child;
  final double Function() floatDefaultWidth;

  FigmaView({
    super.key,
    required this.child,
    required this.entry,
    required this.floatDefaultWidth,
  });

  @override
  Widget build(BuildContext context) {
    var figmaService = FigmaProvider.of(context).service;
    var path = entry.path;
    return ValueStreamBuilder<List<FigmaLink>>(
      stream: figmaService.linksForPath(path),
      builder: (context, snapshot) {
        return FigmaPreviewer(
          figmaService,
          key: ValueKey(entry),
          onOpenSettings: figmaService.canSaveFigmaToken
              ? () {
                  showFigmaSettingsDialog(context, figmaService);
                }
              : null,
          figmaLinks: snapshot,
          onAddLink: figmaService.canAddLink
              ? (v) {
                  figmaService.addLink(path, v);
                }
              : null,
          onLinkSettings: (link) {
            showFigmaLinkDialog(context, figmaService, entry, link);
          },
          clipboardButton: ClipboardButton(figmaService, entry),
          floatDefaultWidth: floatDefaultWidth,
          child: child,
        );
      },
    );
  }
}
