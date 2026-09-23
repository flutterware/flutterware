import 'package:material_ui/material_ui.dart';

import '../service.dart';

Future<void> showFigmaSettingsDialog(
  BuildContext context,
  FigmaService service,
) async {
  await showDialog(
    context: context,
    builder: (context) => FigmaSettingDialog(service),
  );
}

class FigmaSettingDialog extends StatefulWidget {
  final FigmaService service;

  const FigmaSettingDialog(this.service, {super.key});

  @override
  State<FigmaSettingDialog> createState() => _FigmaSettingDialogState();
}

class _FigmaSettingDialogState extends State<FigmaSettingDialog> {
  final _personalTokenController = TextEditingController();

  @override
  void initState() {
    super.initState();

    _personalTokenController.text =
        widget.service.personalSettings.credentials?.token ?? '';
  }

  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      title: Text('Figma settings'),
      contentPadding: EdgeInsets.symmetric(horizontal: 20).copyWith(bottom: 20),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: ListTile(
            title: TextFormField(
              controller: _personalTokenController,
              decoration: InputDecoration(labelText: 'Personal token'),
            ),
          ),
        ),
        Row(
          children: [
            PopupMenuButton(
              child: Text('More options...'),
              itemBuilder: (context) => [
                PopupMenuItem(
                  child: Text('Force refresh all images from Figma'),
                  onTap: () {
                    widget.service.forceRefreshAllLinks();
                  },
                ),
              ],
            ),
            Expanded(child: const SizedBox()),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                var token = _personalTokenController.text;
                FigmaCredentials? credentials;
                if (token.isNotEmpty) {
                  credentials = FigmaCredentials(_personalTokenController.text);
                }
                widget.service.setFigmaToken(credentials);
                Navigator.pop(context);
              },
              child: Text('OK'),
            ),
          ],
        ),
      ],
    );
  }
}
