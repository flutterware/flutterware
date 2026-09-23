import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../link.dart';
import '../service.dart';

Future<void> showFigmaLinkDialog(
  BuildContext context,
  FigmaService service,
  TreeEntry entry,
  FigmaLink link,
) async {
  await showDialog(
    context: context,
    builder: (context) => FigmaLinkInfoDialog(service, entry, link),
  );
}

class FigmaLinkInfoDialog extends StatelessWidget {
  final FigmaService service;
  final TreeEntry entry;
  final FigmaLink link;

  const FigmaLinkInfoDialog(this.service, this.entry, this.link, {super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Figma'),
      content: Container(
        constraints: BoxConstraints(maxWidth: 500),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              onTap: () async {
                await Clipboard.setData(
                  ClipboardData(text: link.uri.toString()),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('URL copied to clipboard'),
                      backgroundColor: Colors.green,
                      duration: Duration(seconds: 1),
                    ),
                  );
                }
              },
              title: Text('URL'),
              subtitle: SelectableText(link.uri.toString()),
              leading: Icon(Icons.copy),
            ),
            if (service.canRefreshFromSource)
              ListTile(
                onTap: () {
                  service.forceRefreshLink(link);
                  Navigator.pop(context);
                },
                title: Text('Force refresh from Figma'),
                leading: Icon(Icons.refresh),
              ),
            if (service.canDeleteLink(link))
              ListTile(
                onTap: () {
                  service.deleteLink(entry.path, link);
                  Navigator.pop(context);
                },
                title: Text('Delete'),
                leading: Icon(Icons.delete),
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
          },
          child: Text('Close'),
        ),
      ],
    );
  }
}
