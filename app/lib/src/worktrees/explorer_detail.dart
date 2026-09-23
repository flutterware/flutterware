import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../ui/theme.dart';
import 'facts.dart';

/// What a row says when you ask it to say more.
///
/// Detail in place, not a destination. Everything here is already in the
/// facts, so expanding costs nothing and navigates nowhere — which is what lets
/// you interrogate a checkout you have not opened.
///
/// ## The layout, and the two it beat
///
/// Chosen by building all three and looking (2026-08-10):
///
/// - **A `Wrap` of label/value fields** — what shipped first. Fields reflow by
///   window width, so the same worktree looks different at different sizes and
///   two expanded rows never line up with each other. Worse, it gave
///   `UNCOMMITTED · 5 files` a full column for seven characters while squeezing
///   the change breakdown — the one thing here with real structure — into a
///   multi-line string in the narrowest slot left over.
/// - **Full-width stacked bands** — fixed the prose (a long prompt on one line,
///   a path that does not break mid-word) and read beautifully, but ran 87
///   pixels past a 250-pixel frame. An expanded row that tall pushes the rest of
///   the list off screen, and it spent 900 pixels on a bar whose number is
///   already written beside it.
///
/// So: **columns for the structured part, full width for the prose.** The change
/// table keeps aligned names, proportional bars and right-aligned digits; the
/// prompt and the path — the only two genuinely long strings — get a line each
/// underneath, where a sentence belongs.
class WorktreeDetail extends StatelessWidget {
  const WorktreeDetail({
    super.key,
    required this.facts,
    required this.now,
    this.path,
    this.branch,
    this.insetLeft = 0,
    this.insetRight = 0,
  });

  final WorktreeFacts facts;
  final DateTime now;
  final String? path;
  final String? branch;
  final double insetLeft;
  final double insetRight;

  @override
  Widget build(BuildContext context) {
    var agent = facts.agent.value;
    return Padding(
      padding: EdgeInsets.fromLTRB(insetLeft, 0, insetRight, FwSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The widest, because it is the only column with rows of its own.
              Expanded(flex: 5, child: _ChangeTable(facts: facts)),
              const Gap(FwSpacing.xxxl),
              Expanded(
                flex: 3,
                child: _AgentSummary(facts: facts, now: now),
              ),
              const Gap(FwSpacing.xxxl),
              Expanded(
                flex: 3,
                child: _BranchSummary(facts: facts, branch: branch),
              ),
            ],
          ),
          const Gap(FwSpacing.lg),
          if (agent?.lastPrompt case var it?) _Long('Last asked', '“$it”'),
          if (path case var it?) _Long('Path', it, selectable: true),
          if (facts.git.failure case var why?) _Long('Git said', why),
          // The one thing the 116px cell cannot hold. It says `can't tell`;
          // this is the sentence explaining why, without opening the checkout.
          if (facts.stack.value?.failure case var why?)
            _Long('Stack said', why),
        ],
      ),
    );
  }
}

/// The change breakdown as a **table**, not a paragraph.
///
/// One line per bucket, the numbers in their own right-aligned boxes so the
/// digits form columns, and a bar scaled against the busiest bucket in *this*
/// worktree — a different scale from the row's, which compares worktrees to each
/// other. Here the question is where this branch's work went.
class _ChangeTable extends StatelessWidget {
  const _ChangeTable({required this.facts});

  final WorktreeFacts facts;

  /// Beyond this the list stops being a summary. The tail is counted rather
  /// than dropped silently.
  static const _maxRows = 6;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var git = facts.git.value;
    var shape = git?.changes;

    if (shape == null || shape.isEmpty) {
      return _Block(
        label: 'Changed',
        children: [
          Text(
            git != null && git.dirty > 0
                ? '${git.dirty} uncommitted, nothing committed on this branch'
                : 'nothing to compare',
            style: context.type.bodySmall.copyWith(color: colors.mut2),
          ),
        ],
      );
    }

    var ranked = shape.ranked;
    var shown = ranked.take(_maxRows).toList();
    var hidden = ranked.length - shown.length;
    var biggest = ranked.first.lines;

    return _Block(
      label: 'Changed',
      children: [
        Text(
          '${shape.files} file${shape.files == 1 ? '' : 's'} against '
          '${git!.base ?? 'the base'}'
          '${git.dirty > 0 ? '  ·  ${git.dirty} uncommitted' : ''}',
          style: context.type.bodySmall.copyWith(color: colors.mut),
        ),
        const Gap(FwSpacing.sm),
        for (var bucket in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 78,
                  child: Text(
                    bucket.name,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: context.type.bodySmall,
                  ),
                ),
                Expanded(
                  child: _MiniBar(
                    fraction: biggest == 0 ? 0 : bucket.lines / biggest,
                  ),
                ),
                const Gap(FwSpacing.md),
                SizedBox(
                  width: 52,
                  child: Text(
                    '+${bucket.added}',
                    textAlign: TextAlign.right,
                    style: context.type.micro.copyWith(color: colors.grn),
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(
                    '−${bucket.removed}',
                    textAlign: TextAlign.right,
                    style: context.type.micro.copyWith(color: colors.red),
                  ),
                ),
              ],
            ),
          ),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(top: FwSpacing.xs),
            child: Text(
              'and $hidden more',
              style: context.type.micro.copyWith(color: colors.mut3),
            ),
          ),
      ],
    );
  }
}

class _MiniBar extends StatelessWidget {
  const _MiniBar({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          height: 4,
          // A floor, so a bucket with two lines in it is still visible as a
          // bucket rather than as nothing.
          width: math.max(2, constraints.maxWidth * fraction.clamp(0, 1)),
          decoration: BoxDecoration(
            color: colors.mut2,
            borderRadius: BorderRadius.circular(context.radii.micro),
          ),
        ),
      ),
    );
  }
}

/// The agent, minus its prompt — that one is prose and has its own full-width
/// line below.
class _AgentSummary extends StatelessWidget {
  const _AgentSummary({required this.facts, required this.now});

  final WorktreeFacts facts;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var agent = facts.agent.value;
    return _Block(
      label: 'Agent',
      children: [
        if (agent == null || agent.state == AgentState.none)
          Text(
            'none',
            style: context.type.bodySmall.copyWith(color: colors.mut3),
          )
        else ...[
          Text(
            [agent.state.name, ?agent.model].join('  ·  '),
            style: context.type.bodySmall,
          ),
          if (agent.title case var it?) ...[
            const Gap(FwSpacing.sm),
            Text(it, style: context.type.bodySmall.copyWith(color: colors.mut)),
          ],
        ],
      ],
    );
  }
}

/// Branch facts and the pull request together — one subject. The `Wrap` had
/// them at opposite ends of two different runs.
class _BranchSummary extends StatelessWidget {
  const _BranchSummary({required this.facts, required this.branch});

  final WorktreeFacts facts;
  final String? branch;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var git = facts.git.value;
    var pr = facts.forge.value;
    return _Block(
      label: 'Branch',
      children: [
        Text(branch ?? 'detached', style: context.type.bodySmall),
        if (git != null) ...[
          const Gap(FwSpacing.sm),
          Text(
            '${git.ahead} ahead  ·  ${git.behind} behind'
            '${git.base == null ? '' : '  ·  ${git.base}'}',
            style: context.type.bodySmall.copyWith(color: colors.mut2),
          ),
        ],
        const Gap(FwSpacing.sm),
        Text(
          pr == null
              ? 'no pull request'
              : [
                  '#${pr.number}',
                  pr.state.name,
                  if (pr.failingChecks > 0) '${pr.failingChecks} failing',
                  if (pr.review != ReviewState.none) pr.review.label,
                ].join('  ·  '),
          style: context.type.bodySmall.copyWith(color: colors.mut2),
        ),
      ],
    );
  }
}

/// A label in the same gutter every time, then one full-width line. For the
/// strings that are prose rather than data.
class _Long extends StatelessWidget {
  const _Long(this.label, this.value, {this.selectable = false});

  final String label;
  final String value;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var style = context.type.bodySmall.copyWith(color: colors.mut);
    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _labelWidth,
            child: Text(
              label.toUpperCase(),
              style: context.type.micro.copyWith(color: colors.mut3),
            ),
          ),
          Expanded(
            child: selectable
                ? SelectableText(value, style: style)
                : Text(value, style: style),
          ),
        ],
      ),
    );
  }
}

const _labelWidth = 88.0;

class _Block extends StatelessWidget {
  const _Block({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label.toUpperCase(),
        style: context.type.micro.copyWith(color: context.colors.mut3),
      ),
      const Gap(FwSpacing.sm),
      ...children,
    ],
  );
}
