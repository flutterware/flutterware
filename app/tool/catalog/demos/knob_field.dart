import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/plugins/native/run_results.dart';
import 'package:flutterware_app/src/run/knob_field.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'shell.dart';

/// A launch knob in each state it has to be told apart in.
///
/// One widget, two hosts — the New run page fills these in before a launch and
/// the running app's Knobs tab edits them afterwards — so what a state looks
/// like here is what it looks like in both.
///
/// The row worth checking is the third. A `required` knob with nothing set and
/// nothing computed is the one that stops the launch, and it has to be legible
/// as that from across the pane rather than only after reading the field: the
/// whole point of the flag is that forgetting one used to cost a build, an
/// install and a boot before anything said so.
@Preview(name: 'Knob field', wrapper: wrapInApp)
Widget knobField() => const _KnobFields();

class _KnobFields extends StatefulWidget {
  const _KnobFields();

  @override
  State<_KnobFields> createState() => _KnobFieldsState();
}

class _KnobFieldsState extends State<_KnobFields> {
  final _values = <String, String>{};

  static final _knobs = [
    RunKnobEntry(name: 'apiHost', kind: 'string', defaultValue: 'localhost'),
    RunKnobEntry(
      name: 'backend',
      kind: 'picker',
      defaultValue: 'dev',
      options: const ['dev', 'staging', 'prod'],
    ),
    // Nothing has answered for it: no value typed, and no default — a required
    // knob deliberately withholds the parameter's own, because that placeholder
    // is exactly what the flag says not to run against.
    RunKnobEntry(
      name: 'apiToken',
      kind: 'string',
      required: true,
      description: 'Issued per developer; there is no useful default',
    ),
    // The same flag, satisfied — by a source rather than by anybody typing,
    // which is the ordinary case and must not look like a warning.
    RunKnobEntry(
      name: 'flutterSdkRoot',
      label: 'Flutter SDK',
      kind: 'string',
      required: true,
      defaultValue: '/Users/dev/fvm/versions/3.47.0-0.1.pre',
      description: 'Supplied by whichever flutterware launched this one',
    ),
    // No parameter behind it at all, so no control — the line exists to carry
    // the reason.
    RunKnobEntry(
      name: 'serverPrt',
      problem:
          'main takes no `serverPrt` parameter. The control would appear and '
          'do nothing — check the spelling against the signature.',
    ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.colors.panel,
    body: Padding(
      padding: const EdgeInsets.all(FwSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var knob in _knobs) ...[
            KnobField(
              knob: knob,
              value: _values[knob.name],
              onChanged: (value) => setState(() {
                if (value == null) {
                  _values.remove(knob.name);
                } else {
                  _values[knob.name] = value;
                }
              }),
            ),
            const Gap(FwSpacing.md),
          ],
        ],
      ),
    ),
  );
}
