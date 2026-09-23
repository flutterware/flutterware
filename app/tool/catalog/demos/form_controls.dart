import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/ui/action_button.dart';
import 'package:flutterware_app/src/ui/picker.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// The form family: the house picker and the themed text field, in one column.
///
/// This page is the reference for "I need a dropdown" and "I need an input" —
/// the two requests that historically got answered with stock Material and
/// produced a form mixing two type ramps. Everything here is either [FwPicker]
/// or a plain `TextField` with **no** style or border overrides: the theme
/// dresses a bare field in the house border, padding and 13px body, which is
/// the point being demonstrated.

@Preview(name: 'Form controls', group: 'Controls', wrapper: wrapInAppTheme)
Widget formControls() => const _FormControls();

@Preview(
  name: 'Form controls · dark',
  group: 'Controls',
  wrapper: wrapInDarkTheme,
)
Widget formControlsDark() => const _FormControls();

class _FormControls extends StatefulWidget {
  const _FormControls();

  @override
  State<_FormControls> createState() => _FormControlsState();
}

class _FormControlsState extends State<_FormControls> {
  String? _device = 'iphone';
  String? _policy = 'embedFont';
  var _checked = true;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var cases = <(String, String, Widget)>[
      (
        'Picker, detailed rows',
        'A bold name, a muted line under it, a dot for liveness — the row '
            'shape that makes Kiosk and Onboarding tellable apart. A disabled '
            'row stays listed and says why it is not launchable.',
        FwPicker<String>(
          choices: [
            FwChoice(
              value: 'iphone',
              label: 'iPhone 16',
              detail: 'ios · iOS 26.5 · simulator',
              dotColor: colors.grn,
            ),
            FwChoice(
              value: 'pixel',
              label: 'Pixel 9',
              detail: 'android · API 36 · wireless',
              dotColor: colors.grn,
            ),
            FwChoice(
              value: 'asleep',
              label: 'Xavier’s phone',
              detail: 'ios · not connected',
              dotColor: colors.mut3,
              enabled: false,
            ),
          ],
          selected: _device,
          onChanged: (value) => setState(() => _device = value),
        ),
      ),
      (
        'Picker, one-word options',
        'An enum’s constants need no detail line. Cap the width — one word '
            'floating in a panel-wide box reads as a mistake.',
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: FwPicker<String>(
            choices: const [
              FwChoice(value: 'embedFont', label: 'embedFont'),
              FwChoice(value: 'outline', label: 'outline'),
              FwChoice(value: 'systemText', label: 'systemText'),
            ],
            selected: _policy,
            onChanged: (value) => setState(() => _policy = value),
          ),
        ),
      ),
      (
        'Text field, bare',
        'No style:, no border: — the theme supplies the house border, padding '
            'and body size. Overriding either is how a form ends up mixing '
            'two design systems.',
        const TextField(
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Around the shop',
          ),
        ),
      ),
      (
        'Text field, machine data',
        'Machine data wears context.type.mono; everything else stays bare.',
        Builder(
          builder: (context) => TextField(
            style: context.type.mono,
            decoration: const InputDecoration(
              isDense: true,
              hintText: '{"title": "…"}',
            ),
          ),
        ),
      ),
      (
        'Buttons, one height',
        'Material buttons are themed onto the form family: 33 tall, house '
            'corner, ramped label. FilledButton is the primary CTA; '
            'FwActionButton stays the async panel action with its own states.',
        Row(
          children: [
            FilledButton(onPressed: () {}, child: const Text('Create')),
            const Gap(FwSpacing.md),
            OutlinedButton(onPressed: () {}, child: const Text('Refresh')),
            const Gap(FwSpacing.md),
            TextButton(onPressed: () {}, child: const Text('Cancel')),
            const Gap(FwSpacing.md),
            FwActionButton(label: 'Reload', onPressed: () async {}),
          ],
        ),
      ),
      (
        'Checkbox, bare',
        'The theme dresses a bare Checkbox too — house corner, muted side, '
            'accent fill, no hover halo.',
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: _checked,
              visualDensity: VisualDensity.compact,
              onChanged: (value) => setState(() => _checked = value ?? false),
            ),
            const Gap(FwSpacing.sm),
            Text('Keep the branch', style: context.type.body),
          ],
        ),
      ),
    ];

    return ColoredBox(
      color: colors.panel,
      child: ListView(
        padding: const EdgeInsets.all(FwSpacing.xxl),
        children: [
          Text('Form controls', style: context.type.pageTitle),
          const Gap(FwSpacing.xl),
          for (var (heading, note, child) in cases)
            Padding(
              padding: const EdgeInsets.only(bottom: FwSpacing.xxxl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(heading, style: context.type.sectionLabel),
                  const Gap(FwSpacing.xxs),
                  Text(
                    note,
                    style: context.type.caption.copyWith(color: colors.mut2),
                  ),
                  const Gap(FwSpacing.md),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Align(alignment: Alignment.centerLeft, child: child),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
