import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../plugins/native/scenarios_core.dart';
import '../plugins/native/scenarios_results.dart';
import '../ui/theme.dart';
import 'authoring.dart';

/// Asks for a name, calls the `new` action, and answers with what it wrote.
///
/// The GUI half of the authoring door. The panel's empty state ends by naming
/// the `fw run scenarios new …` command, which is the right answer for an agent
/// and the wrong one for somebody already looking at the panel that could do it.
///
/// Goes through [ScenariosCore.invoke] rather than around it: `new` validates
/// the name, derives the path, refuses to overwrite and rescans, and the dialog
/// wants every one of those. A failure is shown in place — "already exists" is
/// the one you actually hit, and it is answered by typing a different name into
/// the field that is still on screen.
Future<ScenarioNewResult?> showNewScenarioDialog(
  BuildContext context, {
  required ScenariosCore core,
  required String package,
}) => showDialog<ScenarioNewResult>(
  context: context,
  builder: (context) => _NewScenarioDialog(core: core, package: package),
);

class _NewScenarioDialog extends StatefulWidget {
  const _NewScenarioDialog({required this.core, required this.package});

  final ScenariosCore core;
  final String package;

  @override
  State<_NewScenarioDialog> createState() => _NewScenarioDialogState();
}

class _NewScenarioDialogState extends State<_NewScenarioDialog> {
  final _name = TextEditingController();

  var _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // The previewed path is derived from the name, so it has to be rebuilt as
    // the name is typed.
    _name.addListener(_onNameChanged);
  }

  void _onNameChanged() => setState(() {});

  @override
  void dispose() {
    _name
      ..removeListener(_onNameChanged)
      ..dispose();
    super.dispose();
  }

  String get _named => _name.text.trim();

  /// Where the file lands, spelled exactly as the action derives it.
  String get _target =>
      '${widget.core.newScenarioDirectoryFor(widget.package)}/'
      '${scenarioFileName(_named)}';

  Future<void> _create() async {
    if (_named.isEmpty || _creating) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      var result = await widget.core.invoke(
        'new',
        arguments: {'package': widget.package, 'name': _named},
      );
      if (mounted) Navigator.of(context).pop(result! as ScenarioNewResult);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _creating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return AlertDialog(
      title: const Text('New scenario'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Writes a scenario that already runs — a stub app and a walk '
              'through it. Replace the stub with the widget you meant.',
              style: context.type.caption.copyWith(color: colors.mut),
            ),
            const Gap(FwSpacing.xl),
            TextField(
              controller: _name,
              autofocus: true,
              enabled: !_creating,
              style: context.type.bodySmall,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Name',
                hintText: 'Around the shop',
              ),
              onSubmitted: (_) => unawaited(_create()),
            ),
            const Gap(FwSpacing.md),
            // A blank line rather than nothing, so the dialog does not jump a
            // row taller on the first keystroke.
            Text(
              _named.isEmpty ? ' ' : _target,
              style: context.type.micro.copyWith(
                fontFamily: 'monospace',
                color: colors.mut2,
              ),
            ),
            if (_error case var error?) ...[
              const Gap(FwSpacing.lg),
              SelectableText(
                error,
                style: context.type.bodySmall.copyWith(color: colors.red),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _creating ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _creating || _named.isEmpty
              ? null
              : () => unawaited(_create()),
          child: Text(_creating ? 'Creating…' : 'Create'),
        ),
      ],
    );
  }
}
