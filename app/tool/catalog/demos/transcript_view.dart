import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/inspect/semantics_node.dart';
import 'package:flutterware_app/src/inspect/semantics_view.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// The Semantics tab — one capture, two lenses. **Script** is the reading a
/// screen reader would speak, with the label audits' findings pinned to their
/// rows; **Tree** is the structural half, same findings on the same nodes.
///
/// The trees below are the ones that exercise the audits, because those rows
/// are the script's whole reason to exist: a control with nothing to read, an
/// emoji label, two buttons announced identically, a label that says its own
/// role. The clean reading is first, so the flagged ones read against what
/// normal looks like.

/// A screen whose reading is fine: every control labeled, nothing repeated.
@Preview(name: 'Clean reading', group: 'Semantics tab', wrapper: wrapInAppTheme)
Widget semanticsClean() => _Frame(
  root: _screen([
    _node(label: 'Coffee menu', flags: ['isHeader']),
    _node(label: 'Search drinks', flags: ['isTextField'], actions: ['tap']),
    _node(label: 'Espresso, € 2,20', flags: ['isButton'], actions: ['tap']),
    _node(label: 'Flat white, € 3,80', flags: ['isButton'], actions: ['tap']),
    _node(label: '2-for-1 before 10:00'),
    _node(
      label: 'Pay € 7,50',
      hint: 'Double tap to check out',
      flags: ['isButton'],
      actions: ['tap'],
    ),
  ]),
);

/// One of each finding, on one screen — the script lens.
@Preview(name: 'Every finding', group: 'Semantics tab', wrapper: wrapInAppTheme)
Widget semanticsFindings() => _Frame(root: _findingsTree());

/// The same screen through the tree lens: structure nodes visible, findings
/// pinned to the same rows.
@Preview(name: 'Tree lens', group: 'Semantics tab', wrapper: wrapInAppTheme)
Widget semanticsTreeLens() =>
    _Frame(root: _findingsTree(), lens: SemanticsLens.tree);

/// A screen that says nothing at all.
@Preview(name: 'Silent screen', group: 'Semantics tab', wrapper: wrapInAppTheme)
Widget semanticsSilent() => _Frame(root: _screen([]));

/// No capture — the placeholder, worded by the host.
@Preview(name: 'Not captured', group: 'Semantics tab', wrapper: wrapInAppTheme)
Widget semanticsMissing() => const _Frame(root: null);

/// Words long enough to fight the row for space, next to a hint doing the
/// same — the ellipsis case.
@Preview(name: 'Long words', group: 'Semantics tab', wrapper: wrapInAppTheme)
Widget semanticsLong() => _Frame(
  root: _screen([
    _node(
      label:
          'Double-shot oat-milk flat white with an extra pump of house-made '
          'vanilla syrup and a dusting of ceremonial-grade matcha, large',
      value: 'selected, 2 of 12 in the seasonal specials carousel',
      hint: 'Double tap to add to the order, triple tap to customise',
      flags: ['isButton'],
      actions: ['tap', 'longPress'],
    ),
    _node(label: 'Pay € 7,50', flags: ['isButton'], actions: ['tap']),
  ]),
);

@Preview(
  name: 'Every finding · dark',
  group: 'Semantics tab',
  wrapper: wrapInDarkTheme,
)
Widget semanticsFindingsDark() => semanticsFindings();

SemanticsSnapshotNode _findingsTree() => _screen([
  _node(label: 'Kaffee', flags: ['isHeader']),
  // Unlabeled: an icon button that reaches the reader empty.
  _node(flags: ['isButton'], actions: ['tap']),
  // Symbol labels, twice — the second is also a duplicate.
  _node(label: '☕', flags: ['isButton'], actions: ['tap']),
  _node(label: '☕', flags: ['isButton'], actions: ['tap']),
  // The role said twice.
  _node(label: 'Pay button', flags: ['isButton'], actions: ['tap']),
  // Hidden: skipped by the script — the reading must not show 'secret' —
  // but present in the tree lens, which is the point of having both.
  _node(label: 'secret', flags: ['isHidden']),
  _node(label: '2-for-1 before 10:00'),
]);

/// A root the size of a phone, children stacked down the screen — enough
/// geometry for hover to have something to light up.
SemanticsSnapshotNode _screen(List<SemanticsSnapshotNode> children) =>
    SemanticsSnapshotNode(
      rect: const Rect.fromLTWH(0, 0, 390, 844),
      label: '',
      value: '',
      hint: '',
      tooltip: '',
      flags: const [],
      actions: const [],
      children: children,
    );

SemanticsSnapshotNode _node({
  String label = '',
  String value = '',
  String hint = '',
  List<String> flags = const [],
  List<String> actions = const [],
}) => SemanticsSnapshotNode(
  // Geometry is a formality here: no picture sits behind the demo for hover
  // to light up.
  rect: const Rect.fromLTWH(16, 56, 358, 48),
  label: label,
  value: value,
  hint: hint,
  tooltip: '',
  flags: flags,
  actions: actions,
  children: const [],
);

class _Frame extends StatelessWidget {
  const _Frame({required this.root, this.lens = SemanticsLens.script});

  final SemanticsSnapshotNode? root;
  final SemanticsLens lens;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.panel2,
    child: Padding(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          height: 340,
          width: 640,
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: SemanticsView(
              root: root,
              placeholder:
                  'No semantics captured for this step — the run predates '
                  'the capture, or the app disabled semantics.',
              highlight: ValueNotifier(null),
              focusOrder: ValueNotifier(false),
              initialLens: lens,
            ),
          ),
        ),
      ),
    ),
  );
}
