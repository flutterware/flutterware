import 'package:material_ui/material_ui.dart';

import '../downloader_io.dart';
import '../link.dart';
import '../service.dart';
import 'settings.dart';

class FigmaImage extends StatelessWidget {
  final FigmaService figmaService;
  final FigmaLink link;

  const FigmaImage(this.figmaService, this.link, {super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ImageProvider>(
      future: figmaService.imageProviderFor(link),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(15),
              child: CircularProgressIndicator(),
            ),
          );
        } else if (snapshot.hasError) {
          return _ImageError(figmaService, snapshot.error!);
        } else {
          return Image(image: snapshot.requireData, fit: BoxFit.fitWidth);
        }
      },
    );
  }
}

class _ImageError extends StatelessWidget {
  final FigmaService service;
  final Object exception;

  const _ImageError(this.service, this.exception);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 400,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          //Expanded(child: ErrorWidget(exception)),
          TextButton(
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => _ErrorDialog(exception.toString()),
              );
            },
            child: Text('Show full error'),
          ),
          if (exception is FigmaCredentialsRequiredException)
            TextButton(
              onPressed: () {
                showFigmaSettingsDialog(context, service);
              },
              child: Text('Configure token'),
            ),
        ],
      ),
    );
  }
}

class _ErrorDialog extends StatelessWidget {
  final String error;

  const _ErrorDialog(this.error);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Text(error),
      actions: [
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
          },
          child: Text('OK'),
        ),
      ],
    );
  }
}
