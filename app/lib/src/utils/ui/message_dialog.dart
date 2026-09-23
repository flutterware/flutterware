import 'package:material_ui/material_ui.dart';

Future<void> showMessageDialog(
  BuildContext context, {
  String? title,
  required String message,
}) {
  return showDialog(
    context: context,
    builder: (context) => MessageDialog(title: title, message: message),
  );
}

class MessageDialog extends StatelessWidget {
  final String? title;
  final String message;
  final VoidCallback? analyticsCallback;

  const MessageDialog({
    super.key,
    this.title,
    required this.message,
    this.analyticsCallback,
  });

  @override
  Widget build(BuildContext context) {
    var title = this.title;
    return AlertDialog(
      title: title != null ? Text(title) : null,
      content: Text(message),
      scrollable: true,
      actions: <Widget>[
        ElevatedButton(
          onPressed: () {
            analyticsCallback?.call();
            Navigator.pop(context);
          },
          child: Text('Ok'),
        ),
      ],
    );
  }
}
