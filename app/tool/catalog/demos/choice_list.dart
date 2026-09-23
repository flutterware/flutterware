import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/ui/choice_list.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// [FwChoiceList] — a choice out of a short list, all of it on screen.
///
/// The page to look at when deciding between this and [FwPicker]. A picker
/// hides its options behind a trigger, which is right when there are many of
/// them or when the choice is a detail of a form. A list spends the height to
/// show them, which is right when *seeing them together* is the explanation —
/// and it is the only one of the two that can hold a control belonging to one
/// row.
///
/// The scene's "where does this go" is the case it was built for: pick the
/// folder you already have, or the last row, which opens a field for a new one.

@Preview(name: 'Choice list', group: 'Controls', wrapper: wrapInAppTheme)
Widget choiceList() => const _ChoiceList();

@Preview(
  name: 'Choice list · dark',
  group: 'Controls',
  wrapper: wrapInDarkTheme,
)
Widget choiceListDark() => const _ChoiceList();

class _ChoiceList extends StatefulWidget {
  const _ChoiceList();

  @override
  State<_ChoiceList> createState() => _ChoiceListState();
}

class _ChoiceListState extends State<_ChoiceList> {
  String _where = 'demo';
  String _open = 'new';
  String _size = 'banner';
  final _folder = TextEditingController(text: 'lib/scenes');

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var cases = <(String, String, Widget)>[
      (
        'A list with a row that opens',
        'The last row is not a mode — it is the last option, and its field '
            'hangs under it only while it is chosen. An unselected row with a '
            'field in it is a second answer to a question that has one.',
        FwChoiceList<String>(
          choices: const [
            FwChoiceRow(
              value: 'demo',
              label: 'demo',
              detail: 'fixtures/probe_app/demo · 8 scenes',
            ),
            FwChoiceRow(
              value: 'marketing',
              label: 'marketing',
              detail: 'lib/marketing · 2 scenes',
            ),
            FwChoiceRow(value: 'new', label: 'A new folder…'),
          ],
          selected: _where,
          onChanged: (value) => setState(() => _where = value),
          below: (context, value) => value == 'new'
              ? TextField(
                  controller: _folder,
                  style: context.type.mono,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'lib/scenes',
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
      (
        'The same list, with that row chosen',
        'The field is indented to the row it belongs to, so it reads as part '
            'of the answer rather than as a field the form grew.',
        FwChoiceList<String>(
          choices: const [
            FwChoiceRow(
              value: 'demo',
              label: 'demo',
              detail: 'fixtures/probe_app/demo · 8 scenes',
            ),
            FwChoiceRow(value: 'new', label: 'A new folder…'),
          ],
          selected: _open,
          onChanged: (value) => setState(() => _open = value),
          below: (context, value) => value == 'new'
              ? TextField(
                  controller: _folder,
                  style: context.type.mono,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'lib/scenes',
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
      (
        'Plain rows, no captions',
        'Without a detail line the rows close up, and the control is a stack '
            'of radio buttons — which is all it should be.',
        FwChoiceList<String>(
          choices: const [
            FwChoiceRow(value: 'banner', label: 'Banner 1024 × 500'),
            FwChoiceRow(value: 'square', label: 'Square 1080 × 1080'),
            FwChoiceRow(value: 'phone', label: 'Phone 390 × 844'),
            FwChoiceRow(value: 'custom', label: 'Custom', enabled: false),
          ],
          selected: _size,
          onChanged: (value) => setState(() => _size = value),
        ),
      ),
    ];

    return ColoredBox(
      color: colors.panel,
      child: ListView(
        padding: const EdgeInsets.all(FwSpacing.xxl),
        children: [
          Text('Choice list', style: context.type.pageTitle),
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
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: child,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
