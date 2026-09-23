import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'inspect_dock.dart';
import 'semantics_node.dart';
import 'transcript.dart';
import 'transcript_view.dart';

/// Which projection of the capture the Semantics tab is showing.
enum SemanticsLens {
  /// What gets said: the flat, audited reading — [TranscriptScript].
  script,

  /// What is there: the merged tree with every node, and a detail pane.
  tree,
}

/// The Semantics tab: one capture, two lenses. **Script** is the reading — the
/// utterances a screen reader would speak, in order, with the label audits'
/// findings pinned on. **Tree** is the structure — every node including the
/// silent ones, indent showing the merge shape, one node's full reading in the
/// detail pane. Same rows carry the same finding pills in both, so the lenses
/// never disagree about what is wrong.
///
/// Script leads because it is the summary; the tree is the drill-down for
/// *why* the reading says what it says. Each row lights its rect up on the
/// picture — a scenario step's screenshot, or the catalog's live preview; the
/// view neither knows nor cares which.
///
/// Selection is **local state, not the address**: a semantics node has no id
/// space of its own yet, and the picker stays bound to Elements (see
/// `2026-08-10-scenarios-semantics-tab.md`). What a selection leaves behind
/// is a lit row and a detail pane, never a rectangle on the picture — hover
/// draws, exactly as everywhere else.
class SemanticsView extends StatefulWidget {
  const SemanticsView({
    super.key,
    required this.root,
    required this.placeholder,
    required this.highlight,
    this.transcript,
    this.focusOrder,
    this.initialLens = SemanticsLens.script,
  });

  /// The tree, or null when this step has none — the [placeholder] says why.
  final SemanticsSnapshotNode? root;

  final String placeholder;

  /// The hovered node, drawn on the screenshot by the host's overlay.
  final ValueNotifier<SemanticsSnapshotNode?> highlight;

  /// The reading of [root]. Hosts that already derived one (for a tab badge)
  /// pass it; left null it is derived here, once per tree.
  final SemanticsTranscript? transcript;

  /// The host's switch for numbering the reading order on the picture — the
  /// discs are drawn by the host's overlay, this view only offers the toggle.
  /// Null when the host has no overlay to draw on, and the toggle is not
  /// shown.
  final ValueNotifier<bool>? focusOrder;

  final SemanticsLens initialLens;

  @override
  State<SemanticsView> createState() => _SemanticsViewState();
}

class _SemanticsViewState extends State<SemanticsView> {
  late var _lens = widget.initialLens;

  /// The list's share of the width in the tree lens — the same resting split
  /// as `ElementsView`, because the two panes stack in the same dock.
  double _split = 0.62;

  /// Local, and cleared when the tree is replaced: the selection is an
  /// object in *this* tree, and a fresh read means whatever it pointed at is
  /// gone — holding it would detail a node the list no longer shows.
  SemanticsSnapshotNode? _selected;

  /// Derived once per root when the host did not pass one, held by identity —
  /// the catalog re-reads its live tree often, and the walk is cheap but not
  /// free.
  SemanticsSnapshotNode? _derivedFor;
  SemanticsTranscript? _derived;

  SemanticsTranscript? get _transcript {
    if (widget.transcript case var it?) return it;
    var root = widget.root;
    if (root == null) return null;
    if (!identical(root, _derivedFor)) {
      _derivedFor = root;
      _derived = SemanticsTranscript.of(root);
    }
    return _derived;
  }

  @override
  void didUpdateWidget(SemanticsView old) {
    super.didUpdateWidget(old);
    if (!identical(old.root, widget.root)) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var root = widget.root;
    if (root == null) {
      return Container(
        color: colors.panel,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(FwSpacing.lg),
        child: Text(
          widget.placeholder,
          textAlign: TextAlign.center,
          style: context.type.caption.copyWith(color: colors.mut),
        ),
      );
    }

    var transcript = _transcript!;

    // Flattened with depth, root's chrome included: unlike the widget tree
    // there is no folding — a semantics tree is already the summary, and
    // reading order top to bottom is the point of the listing.
    var rows = <(SemanticsSnapshotNode, int)>[];
    void walk(SemanticsSnapshotNode node, int depth) {
      rows.add((node, depth));
      for (var child in node.children) {
        walk(child, depth + 1);
      }
    }

    walk(root, 0);

    // The tree lens carries the same findings on the same nodes.
    var findingsByNode = {
      for (var utterance in transcript.utterances)
        if (utterance.findings.isNotEmpty) utterance.node: utterance.findings,
    };

    var flagged = transcript.findingCount;
    var utterances = transcript.utterances.length;
    var summary = _lens == SemanticsLens.script
        ? '$utterances ${utterances == 1 ? 'utterance' : 'utterances'}'
              '${flagged == 0 ? '' : ' · $flagged flagged'}'
        : '${rows.length} nodes'
              '${flagged == 0 ? '' : ' · $flagged flagged'}';

    return Material(
      type: MaterialType.transparency,
      child: Container(
        color: colors.panel,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FwSpacing.md,
                FwSpacing.sm,
                FwSpacing.sm,
                FwSpacing.sm,
              ),
              child: Row(
                children: [
                  _LensSwitch(
                    lens: _lens,
                    onChanged: (lens) => setState(() => _lens = lens),
                  ),
                  const Gap(FwSpacing.md),
                  Expanded(
                    child: Text(
                      summary,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.micro.copyWith(color: colors.mut2),
                    ),
                  ),
                  if (widget.focusOrder case var focusOrder?)
                    ValueListenableBuilder(
                      valueListenable: focusOrder,
                      builder: (context, on, _) => InspectStripButton(
                        icon: Icons.format_list_numbered,
                        tooltip: on
                            ? 'Hide the reading order'
                            : 'Number the reading order on the picture',
                        active: on,
                        onTap: () => focusOrder.value = !on,
                      ),
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.line),
            Expanded(
              child: _lens == SemanticsLens.script
                  ? TranscriptScript(
                      transcript: transcript,
                      highlight: widget.highlight,
                    )
                  : _tree(context, rows, findingsByNode),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tree(
    BuildContext context,
    List<(SemanticsSnapshotNode, int)> rows,
    Map<SemanticsSnapshotNode, List<TranscriptFinding>> findingsByNode,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        var listWidth = (constraints.maxWidth * _split)
            .clamp(200.0, math.max(200.0, constraints.maxWidth - 220))
            .toDouble();
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: listWidth,
              child: Container(
                color: context.colors.panel,
                child: MouseRegion(
                  onExit: (_) => widget.highlight.value = null,
                  child: ListView.builder(
                    primary: false,
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      var (node, depth) = rows[index];
                      return _SemanticsRow(
                        node: node,
                        indent: math.min(depth * 12.0, listWidth * 0.4),
                        highlight: widget.highlight,
                        selected: identical(node, _selected),
                        findings: findingsByNode[node] ?? const [],
                        onTap: () => setState(() => _selected = node),
                      );
                    },
                  ),
                ),
              ),
            ),
            InspectSplitGrip(
              axis: Axis.vertical,
              onDrag: (delta) => setState(() {
                _split = ((listWidth + delta) / constraints.maxWidth).clamp(
                  0.2,
                  0.85,
                );
              }),
            ),
            Expanded(child: _Detail(node: _selected)),
          ],
        );
      },
    );
  }
}

/// Script | Tree, as two pills — the summary lens and the drill-down.
class _LensSwitch extends StatelessWidget {
  const _LensSwitch({required this.lens, required this.onChanged});

  final SemanticsLens lens;
  final ValueChanged<SemanticsLens> onChanged;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colors.panel2,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var (value, label) in const [
            (SemanticsLens.script, 'Script'),
            (SemanticsLens.tree, 'Tree'),
          ])
            Tappable(
              onTap: () => onChanged(value),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: lens == value ? colors.accentSoft : null,
                  borderRadius: BorderRadius.circular(context.radii.micro),
                ),
                child: Text(
                  label,
                  style: context.type.micro.copyWith(
                    color: lens == value ? colors.accent : colors.mut,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SemanticsRow extends StatelessWidget {
  const _SemanticsRow({
    required this.node,
    required this.indent,
    required this.highlight,
    required this.selected,
    required this.findings,
    required this.onTap,
  });

  final SemanticsSnapshotNode node;
  final double indent;
  final ValueNotifier<SemanticsSnapshotNode?> highlight;
  final bool selected;
  final List<TranscriptFinding> findings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var hasWords =
        node.label.isNotEmpty ||
        node.value.isNotEmpty ||
        node.tooltip.isNotEmpty;
    return InkWell(
      onTap: onTap,
      onHover: (over) {
        if (over) {
          highlight.value = node;
        } else if (identical(highlight.value, node)) {
          highlight.value = null;
        }
      },
      child: ValueListenableBuilder(
        valueListenable: highlight,
        builder: (context, lit, child) => Container(
          // Selection outranks hover: one is where you are, the other is
          // where you were going.
          color: selected
              ? colors.accentSoft
              : identical(lit, node)
              ? colors.panel2
              : null,
          child: child,
        ),
        child: Padding(
          padding: EdgeInsets.only(
            left: FwSpacing.md + indent,
            right: FwSpacing.md,
            top: 3,
            bottom: 3,
          ),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        node.headline,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: context.type.caption.copyWith(
                          // Words bright, structure dim: the listing reads as
                          // the reader would speak it.
                          color: hasWords ? colors.ink : colors.mut2,
                        ),
                      ),
                    ),
                    if (node.role case var role? when hasWords) ...[
                      const SizedBox(width: FwSpacing.sm),
                      _Badge(role),
                    ],
                    if (node.hint.isNotEmpty) ...[
                      const SizedBox(width: FwSpacing.sm),
                      Flexible(
                        child: Text(
                          node.hint,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: context.type.caption.copyWith(
                            color: colors.mut2,
                          ),
                        ),
                      ),
                    ],
                    for (var finding in findings) ...[
                      const SizedBox(width: FwSpacing.sm),
                      TranscriptFindingPill(finding),
                    ],
                  ],
                ),
              ),
              if (node.actions.isNotEmpty)
                Text(
                  node.actions.join(' · '),
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: context.type.micro.copyWith(color: colors.mut3),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One node's full reading — what the row elides.
///
/// The row is tuned for scanning: the headline, one badge, the hint if it
/// fits. This is where the rest goes — every flag, every action, the rect —
/// so nothing about a node is only discoverable by making the panel wide.
class _Detail extends StatelessWidget {
  const _Detail({required this.node});

  final SemanticsSnapshotNode? node;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var it = node;
    if (it == null) {
      return Container(
        color: colors.panel2,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(FwSpacing.lg),
        child: Text(
          'Select a node',
          textAlign: TextAlign.center,
          style: context.type.caption.copyWith(color: colors.mut),
        ),
      );
    }

    return Container(
      color: colors.panel2,
      child: ListView(
        primary: false,
        padding: const EdgeInsets.all(FwSpacing.lg),
        children: [
          SelectableText(
            it.headline,
            style: context.type.bodyStrong.copyWith(color: colors.ink),
          ),
          const SizedBox(height: FwSpacing.md),
          if (it.label.isNotEmpty) _Pair(label: 'label', value: it.label),
          if (it.value.isNotEmpty) _Pair(label: 'value', value: it.value),
          if (it.hint.isNotEmpty) _Pair(label: 'hint', value: it.hint),
          if (it.tooltip.isNotEmpty) _Pair(label: 'tooltip', value: it.tooltip),
          if (it.identifier.isNotEmpty)
            _Pair(label: 'identifier', value: it.identifier),
          if (it.textDirection.isNotEmpty)
            _Pair(label: 'direction', value: it.textDirection),
          if (it.flags.isNotEmpty)
            _Pair(label: 'flags', value: it.flags.join(', ')),
          if (it.actions.isNotEmpty)
            _Pair(label: 'actions', value: it.actions.join(', ')),
          const SizedBox(height: FwSpacing.md),
          _Pair(
            label: 'rect',
            value:
                '${_n(it.rect.left)}, ${_n(it.rect.top)} — '
                '${_n(it.rect.width)} × ${_n(it.rect.height)}',
          ),
        ],
      ),
    );
  }

  /// Whole pixels without the `.0`, matching the elements detail pane.
  static String _n(double value) => value == value.roundToDouble()
      ? '${value.round()}'
      : value.toStringAsFixed(1);
}

class _Pair extends StatelessWidget {
  const _Pair({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: context.type.micro.copyWith(color: context.colors.mut3),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: context.type.caption.copyWith(color: context.colors.ink2),
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: colors.accentSoft,
        borderRadius: BorderRadius.circular(context.radii.micro),
      ),
      child: Text(
        text,
        style: context.type.micro.copyWith(color: colors.accent),
      ),
    );
  }
}
