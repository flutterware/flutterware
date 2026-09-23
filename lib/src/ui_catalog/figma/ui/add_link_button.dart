import 'package:material_ui/material_ui.dart';

import '../../../utils/value_stream.dart';
import '../../toolbar.dart';
import 'colors.dart';

class AddLinkButton extends StatelessWidget {
  final void Function(String) onSubmit;
  final ValueStream<String?> clipboardWatcher;

  const AddLinkButton({
    super.key,
    required this.onSubmit,
    required this.clipboardWatcher,
  });

  @override
  Widget build(BuildContext context) {
    return ToolbarPanel(
      button: Icon(Icons.add),
      buttonBuilder: ({required button, required onPressed}) =>
          IconButton(onPressed: onPressed, icon: button),
      panel: _AddPanel(this),
      panelFollowerAnchor: Alignment(0.4, 1.0),
      panelTargetAnchor: Alignment.topCenter,
    );
  }
}

class _AddPanel extends StatefulWidget {
  final AddLinkButton button;

  const _AddPanel(this.button);

  @override
  State<_AddPanel> createState() => __AddPanelState();
}

class __AddPanelState extends State<_AddPanel> {
  final _formKey = GlobalKey<FormState>();
  final _textController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Container(
        width: 450,
        decoration: BoxDecoration(
          color: const Color(0xFFF5F5F5),
          border: Border.all(color: figmaBorderColor),
          borderRadius: BorderRadius.circular(5),
        ),
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Paste the component url'),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    autofocus: true,
                    controller: _textController,
                    validator: _validate,
                    decoration: InputDecoration(
                      hintText: 'https://www.figma.com/design/...',
                      hintStyle: const TextStyle(fontSize: 11),
                      border: OutlineInputBorder(),
                    ),
                    onFieldSubmitted: (v) {
                      _submit();
                    },
                  ),
                ),
                const SizedBox(width: 5),
                FilledButton(onPressed: _submit, child: Text('OK')),
              ],
            ),
            ValueStreamBuilder(
              stream: widget.button.clipboardWatcher,
              builder: (context, link) {
                if (link == null) {
                  return const SizedBox();
                } else {
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: OutlinedButton(
                        onPressed: () {
                          _textController.text = link;
                          _submit();
                        },
                        child: Text('Add from clipboard'),
                      ),
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  String? _validate(String? input) {
    if (input == null || input.isEmpty) {
      return 'Enter the component url';
    }
    return null;
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      widget.button.onSubmit(_textController.text);

      ToolbarPanel.of(context).hideMenu();
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }
}
