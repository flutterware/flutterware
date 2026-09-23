import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../ui/design/design.dart';

/// A name edited where it is shown: the words become a field with the whole
/// name selected, Enter commits, Escape cancels, and a click anywhere else
/// commits too.
///
/// [onCommit] does the rename and answers with what went wrong — the
/// message shows under (or, [dense], beside) the field and the edit stays
/// open — or null when the name landed, after which the owner takes the
/// field down.
class InlineNameField extends StatefulWidget {
  const InlineNameField({
    super.key,
    required this.initial,
    required this.onCommit,
    required this.onCancel,
    this.style,
    this.dense = false,
  });

  final String initial;
  final String? Function(String name) onCommit;
  final VoidCallback onCancel;
  final TextStyle? style;

  /// One line high: the error goes beside the field, for a row whose height
  /// is fixed.
  final bool dense;

  @override
  State<InlineNameField> createState() => _InlineNameFieldState();
}

class _InlineNameFieldState extends State<InlineNameField> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );
  final _focus = FocusNode(debugLabel: 'inline name');
  String? _error;

  @override
  void initState() {
    super.initState();
    // The scope around is usually the focused thing when the field appears;
    // autofocus would lose to it. Ask after the frame that mounts the field.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    var error = widget.onCommit(_controller.text);
    if (error != null && mounted) setState(() => _error = error);
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    // Enter as a key, not only as the platform's submit action: on the
    // desktop the action does not always arrive, and Enter must commit.
    var field = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel,
        const SingleActivator(LogicalKeyboardKey.enter): _commit,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _commit,
      },
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        style: widget.style ?? context.type.body,
        decoration: const InputDecoration.collapsed(hintText: null),
        onSubmitted: (_) => _commit(),
        onTapOutside: (_) => _commit(),
      ),
    );
    var error = _error == null
        ? null
        : Text(
            _error!,
            style: context.type.caption.copyWith(color: colors.red),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          );
    if (widget.dense) {
      return Row(
        spacing: FwSpacing.sm,
        children: [
          Expanded(child: field),
          if (error != null) Flexible(child: error),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [field, ?error],
    );
  }
}
