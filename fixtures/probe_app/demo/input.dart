import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/previews.dart';

import 'shell.dart';

/// Exercises what the preview forwards into the guest: typing needs the
/// guest's own text input (there is no platform IME on the other side), and
/// scrolling needs wheel and trackpad events on the wire.

/// A field per keyboard the platform can be asked for, and a knob for which
/// one is focused — so the fake keyboard can be photographed as each of them
/// rather than only as whichever field happened to autofocus.
///
/// **The entry to open when the fake keyboard changes.** Live, tapping between
/// the fields morphs one keyboard into another without it ever going down; from
/// a screenshot, `--knobs=focus=Email` is the same walk one frame at a time.
/// The digit pad is the one to look hardest at: on a phone it is a different
/// picture *and* a measurably shorter one, so the form above it moves.
@Preview(name: 'Keyboards', group: 'Input', wrapper: wrapInApp)
Widget keyboards() => Builder(
  builder: (context) => _Keyboards(
    focused: context.knobs.picker('focus', {
      for (var field in _KeyboardField.values) field.label: field,
    }, _KeyboardField.phone),
  ),
);

enum _KeyboardField {
  phone('Phone', 'a digit pad', TextInputType.phone),
  email('Email', 'an @ and a dot', TextInputType.emailAddress),
  url('URL', 'a slash and a .com', TextInputType.url),
  text('Text', 'the letters', null),
  none('None', 'brings its own pad', TextInputType.none);

  const _KeyboardField(this.label, this.gets, this.type);

  final String label;
  final String gets;
  final TextInputType? type;
}

class _Keyboards extends StatefulWidget {
  const _Keyboards({required this.focused});

  final _KeyboardField focused;

  @override
  State<_Keyboards> createState() => _KeyboardsState();
}

class _KeyboardsState extends State<_Keyboards> {
  final _nodes = {
    for (var field in _KeyboardField.values)
      field: FocusNode(debugLabel: field.label),
  };

  @override
  void didUpdateWidget(_Keyboards old) {
    super.didUpdateWidget(old);
    // Turning the knob moves the focus, which is what moves the keyboard — the
    // same path a tap takes, so a screenshot per option is a screenshot of the
    // thing the app really does rather than of a keyboard somebody forced up.
    //
    // The *first* focus is `autofocus:` below rather than a `requestFocus` from
    // here or from `initState`. Measured: asking a node that is not in the
    // focus tree yet colours the field's label as focused and opens no text
    // input connection at all — a screenshot with no caret and no keyboard,
    // which reads exactly like a keyboard that failed to arrive.
    if (widget.focused != old.focused) {
      _nodes[widget.focused]!.requestFocus();
    }
  }

  @override
  void dispose() {
    for (var node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Keyboards')),
    // **Not a `SingleChildScrollView`, which is what a real form would use.**
    // In the previews guest the entry builds once as this machine and again as
    // the staged device, and `MaterialScrollBehavior` wraps a viewport in a
    // `Scrollbar` on macOS and not on iOS — so the platform switch reparents
    // everything under a `Scrollable`, disposing these fields and closing the
    // input connection the autofocus had just opened. The keyboard then
    // correctly follows the app back down, and the entry photographs with no
    // keyboard on it at all. Unscrolled until the guest builds staged from the
    // first build rather than the first frame.
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        spacing: 16,
        children: [
          for (var field in _KeyboardField.values)
            TextField(
              autofocus: field == widget.focused,
              focusNode: _nodes[field],
              keyboardType: field.type,
              decoration: InputDecoration(
                labelText: '${field.label} — ${field.gets}',
              ),
            ),
        ],
      ),
    ),
  );
}

@Preview(name: 'Text fields', group: 'Input', wrapper: wrapInApp)
Widget textFields() => Scaffold(
  appBar: AppBar(title: const Text('Text fields')),
  body: Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      spacing: 16,
      children: [
        const _EchoField(),
        const TextField(
          maxLines: 4,
          decoration: InputDecoration(labelText: 'Multiline'),
        ),
        Builder(
          builder: (context) => TextField(
            decoration: const InputDecoration(labelText: 'Submit me'),
            onSubmitted: (value) =>
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('Submitted: $value'))),
          ),
        ),
      ],
    ),
  ),
);

/// A field beside a `Text` of what it holds.
///
/// The echo is not decoration: a field's content lives in `EditableText`'s
/// render object, where an inspecting tool cannot read it, while a `Text` is
/// right there in the widget tree. It is what lets a headless check assert
/// that typing landed — see `app/tool/embedder/input_probe.dart`.
class _EchoField extends StatefulWidget {
  const _EchoField();

  @override
  State<_EchoField> createState() => _EchoFieldState();
}

class _EchoFieldState extends State<_EchoField> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    // The controller, not `onChanged`: that one fires on text only, so a caret
    // that moved without typing would leave the readout showing where the
    // caret used to be — which reads exactly like an arrow key doing nothing.
    _controller.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 8,
    children: [
      TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Single line'),
      ),
      Text('echo: ${_controller.text}'),
      Text('sel: ${_controller.selection.start},${_controller.selection.end}'),
    ],
  );
}

@Preview(name: 'Scrolling', group: 'Input', wrapper: wrapInApp)
Widget scrolling() => Scaffold(
  appBar: AppBar(title: const Text('Scrolling')),
  body: ListView.builder(
    itemCount: 100,
    itemBuilder: (context, index) => ListTile(
      leading: CircleAvatar(child: Text('$index')),
      title: Text('Row $index'),
      subtitle: const Text('Wheel and trackpad should both move this'),
    ),
  ),
);
