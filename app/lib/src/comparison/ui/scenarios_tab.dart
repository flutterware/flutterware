import 'dart:async';

import 'package:flutterware/comparison_report.dart';
import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';

import '../../capture/settle.dart';
import '../../ui/empty_state.dart';
import '../../ui/tappable.dart';
import '../../ui/theme.dart';
import '../comparison_controller.dart';
import '../rules.dart';
import '../shot_store.dart';
import 'channel_signature.dart';
import 'compared_name.dart';
import 'index_filter.dart';
import 'merged_tree.dart';
import 'not_in_comparison.dart';
import 'step_page.dart';
import 'shot_image.dart';
import 'stage.dart';
import 'state_chip.dart';

const scenariosTabKey = Key('comparison.scenarios');

Key scenarioRowKey(String id) => ValueKey('comparison.scenario.$id');

/// The scenario half: every flow on the left, the picked flow's merged tree
/// beside it, and a picked *step* pushed over both.
///
/// A tree where the previews half has a list, because a preview is one
/// picture and a scenario is a tree of them: without it, picking a step means
/// reading a list of paths with `›` in them, which is the shape the tree exists
/// to replace.
///
/// And a pushed page where the previews half has a detail pane. A step's
/// two frames are portrait; a band under the tree is landscape and short, so
/// two of them side by side came out postage-stamp sized in the one place the
/// pictures are the point. The scenarios panel already pushes a step as a full
/// page with a back arrow, and this is the same move — the flow stays one tap
/// away, in the address as much as on screen.
class ScenariosTab extends StatefulWidget {
  const ScenariosTab({
    super.key,
    required this.half,
    required this.store,
    required this.settle,
    required this.selected,
    required this.onSelect,
    this.header,
    this.framesWithheld = _noneWithheld,
  });

  final ComparisonHalf half;
  final ShotStore store;
  final SettleRegistry settle;

  /// Whether a flow in this state has no pictures *here* — the twin of
  /// `PreviewsTab.framesWithheld`, asked of the flow rather than of the step,
  /// because an export keeps or drops a scenario whole.
  final bool Function(ComparedState state) framesWithheld;

  /// `<file>#<scenario>/<step path>` as the address names it, or null.
  final String? selected;
  final ValueChanged<String> onSelect;

  /// The half's verdict, drawn above the list — and **not** above a pushed
  /// page, which is about one step rather than about the half.
  final Widget? header;

  @override
  State<ScenariosTab> createState() => _ScenariosTabState();
}

bool _noneWithheld(ComparedState state) => false;

/// `<scenario id>` or `<scenario id>/<step path>`, split where one of
/// [scenarios] ends — or null when the address names none of them.
///
/// Where it splits cannot be worked out from the string: a scenario is named
/// by whoever wrote it, and `scenario('Contacts & collaboration / Create
/// group')` is a name with a separator in it. Splitting at the first `/` after
/// the `#` cut that name in half, and the half-a-name matched no scenario — so
/// the tab fell through to its own fallback, which happened to be the right
/// flow, and every step id parsed out of the tail matched nothing. The canvas
/// drew, the steps looked live, and tapping one selected an address that
/// resolved back to the same canvas: a whole page that did nothing.
///
/// So the boundary is matched against the ids there actually are rather than
/// guessed at a character, which also frees a step to carry a `/` in its name.
/// Longest wins: a file holding both `X` and `X/Y` would otherwise read the
/// second as the first with a step called `Y`.
(String scenario, String? step)? splitScenarioAddress(
  String address,
  Iterable<String> scenarios,
) {
  String? id;
  for (var candidate in scenarios) {
    if (address != candidate && !address.startsWith('$candidate/')) continue;
    if (id == null || candidate.length > id.length) id = candidate;
  }
  if (id == null) return null;
  return (
    id,
    address.length == id.length ? null : address.substring(id.length + 1),
  );
}

class _ScenariosTabState extends State<ScenariosTab> {
  late final _shots = ShotPair(widget.store);
  // The default answers both first questions at once: side by side shows what
  // each frame is, and its head half carries the diff's boxes for where to
  // look.
  var _mode = StageMode.sideBySide;
  var _filter = const IndexFilter();

  /// The merged tree's pan and zoom, owned here so that opening a step and
  /// coming back lands where the canvas was — the scenarios panel's flow keeps
  /// its place the same way.
  final _treeTransform = TransformationController();

  /// The flow the canvas above was panned over.
  String? _panned;

  @override
  void initState() {
    super.initState();
    _shots.addListener(_onShots);
    // Listened to rather than diffed: the half's list is mutated in place, so
    // a widget comparison can never see a row arrive.
    widget.half.addListener(_onRows);
    widget.settle.add(_shots);
    _load();
  }

  @override
  void didUpdateWidget(ScenariosTab old) {
    super.didUpdateWidget(old);
    if (!identical(old.half, widget.half)) {
      old.half.removeListener(_onRows);
      widget.half.addListener(_onRows);
    }
    if (old.selected != widget.selected) _load();
  }

  void _onShots() {
    if (mounted) setState(() {});
  }

  void _onRows() {
    if (mounted) _load();
  }

  (String? scenario, String? step) get _address {
    var selected = widget.selected;
    if (selected == null) return (null, null);
    return splitScenarioAddress(
          selected,
          widget.half.scenarios.map((s) => s.scenario),
        ) ??
        (selected, null);
  }

  /// What the address names that this half does not have — the whole
  /// selection, so it can be said back — or null when there is nothing
  /// missing.
  ///
  /// Only once the half has everything it will get. While a run is still
  /// landing rows, a flow the address names may simply not have arrived, and
  /// the tab keeps drawing the flow most worth reading in the meantime.
  String? get _missing {
    var selected = widget.selected;
    if (selected == null || widget.half.isBusy) return null;
    var (named, step) = _address;
    var scenario = widget.half.scenarios.firstWhereOrNull(
      (s) => s.scenario == named,
    );
    if (scenario == null) return selected;
    if (step != null && scenario.items.every((item) => item.id != step)) {
      return selected;
    }
    return null;
  }

  ScenarioComparison? get _scenario {
    var scenarios = widget.half.scenarios;
    if (scenarios.isEmpty) return null;
    var named = _address.$1;
    // A flow the address names and this half does not have is said, not
    // swapped for another — see [_missing].
    if (_missing != null && scenarios.every((s) => s.scenario != named)) {
      return null;
    }
    return scenarios.firstWhere(
      (s) => s.scenario == named,
      // Worst first, so this opens on the flow most likely to be a mistake.
      orElse: () => scenarios.firstWhere(
        (s) => s.state.isFinding,
        orElse: () => scenarios.first,
      ),
    );
  }

  /// The step the address names, and **only** that.
  ///
  /// No falling back to the first finding: a step is a *pushed page* here, so
  /// picking one for you would open it on arrival and hide the flow you came
  /// to read.
  ComparedItem? get _step {
    var named = _address.$2;
    if (named == null) return null;
    return _scenario?.items.firstWhereOrNull((item) => item.id == named);
  }

  void _load() {
    _resetTreeIfFlowChanged();
    var frames = _scenario?.frames[_step?.id];
    unawaited(_shots.loadFrames(base: frames?.base, head: frames?.head));
  }

  /// Another flow starts at the origin. The canvas is unconstrained and
  /// pans two thousand pixels past its own edges, so a place scrolled to in a
  /// long flow is, in the next one, blank canvas — the tree is drawn, off
  /// somewhere behind you.
  void _resetTreeIfFlowChanged() {
    var flow = _scenario?.scenario;
    if (flow == _panned) return;
    _panned = flow;
    _treeTransform.value = Matrix4.identity();
  }

  void _select({String? scenario, String? step}) {
    var id = scenario ?? _scenario?.scenario;
    if (id == null) return;
    widget.onSelect(step == null ? id : '$id/$step');
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var scenario = _scenario;
    var step = _step;
    var missing = _missing;

    // **Pushed over the flow, not squeezed under it.** A phone frame is
    // portrait; a band along the bottom is landscape and short, so two of them
    // side by side came out postage-stamp sized in the one place the pictures
    // are the whole point. The scenarios panel already answers this — it pushes
    // a step as a full page with a back arrow — and the flow stays one tap
    // away, in the address as well as on screen.
    if (step != null && scenario != null) {
      var steps = scenario.items;
      var at = steps.indexOf(step);
      return StepPage(
        flow: scenario.scenario,
        position: (index: at, count: steps.length),
        onPrevious: at > 0 ? () => _select(step: steps[at - 1].id) : null,
        onNext: at < steps.length - 1
            ? () => _select(step: steps[at + 1].id)
            : null,
        item: step,
        shots: _shots,
        mode: _mode,
        onMode: (mode) => setState(() => _mode = mode),
        onBack: () => widget.onSelect(scenario.scenario),
        framesWithheld: widget.framesWithheld(scenario.state),
        onRule: widget.half.toggleRule,
      );
    }

    // A step the flow does not have: the page the link meant to push, saying
    // so, with the flow one tap away as it is from any step.
    if (missing != null && scenario != null) {
      return NotInComparison(
        address: missing,
        action: TextButton(
          onPressed: () => widget.onSelect(scenario.scenario),
          child: const Text('Back to the flow'),
        ),
      );
    }

    var body = Row(
      key: scenariosTabKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 280,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: colors.line)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                IndexFilterBar(
                  filter: _filter,
                  onFilter: (filter) => setState(() => _filter = filter),
                  changes: widget.half.scenarios
                      .where((s) => s.state.isFinding)
                      .length,
                  all:
                      widget.half.scenarios.length + widget.half.pending.length,
                ),
                Divider(height: 1, color: colors.line),
                Expanded(
                  child: _Index(
                    half: widget.half,
                    filter: _filter,
                    selected: scenario?.scenario,
                    onSelect: (id) => _select(scenario: id),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (scenario != null)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(scenario),
                Expanded(
                  // **A scenario with no steps is not an empty tree.** Three
                  // of the eight verdicts are reached without replaying
                  // anything, so `items` is empty by design — and the merged
                  // tree, given nothing to draw, drew nothing. Picking a
                  // `skipped` row from the index therefore selected it, filled
                  // the header, and left the rest of the pane blank, which
                  // reads as a row you cannot open rather than as one there is
                  // nothing behind.
                  child: scenario.items.isEmpty && scenario.branches.isEmpty
                      ? _NotReplayed(scenario)
                      : MergedTree(
                          scenario: scenario,
                          store: widget.store,
                          transform: _treeTransform,
                          selected: null,
                          onSelect: (id) => _select(step: id),
                        ),
                ),
              ],
            ),
          )
        else if (missing != null)
          Expanded(child: NotInComparison(address: missing)),
      ],
    );

    // Above the list, not above the tab: a pushed step page replaces this
    // whole subtree, and a header describing the half has no business over a
    // page describing one step.
    if (widget.header == null) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.header!,
        Divider(height: 1, color: colors.line),
        Expanded(child: body),
      ],
    );
  }

  @override
  void dispose() {
    widget.half.removeListener(_onRows);
    widget.settle.remove(_shots);
    _shots
      ..removeListener(_onShots)
      ..dispose();
    _treeTransform.dispose();
    super.dispose();
  }
}

class _Index extends StatelessWidget {
  const _Index({
    required this.half,
    required this.filter,
    required this.selected,
    required this.onSelect,
  });

  final ComparisonHalf half;
  final IndexFilter filter;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    var rules = RuleSet(half.rules);
    // A flow is hidden when every finding *step* inside it is, since a flow
    // has no channels of its own — its verdict is a roll-up of the steps.
    bool allHidden(ScenarioComparison s) {
      var any = false;
      for (var step in s.items) {
        if (!step.state.isFinding) continue;
        any = true;
        if (!rules.hidesAll(step)) return false;
      }
      return any;
    }

    var findings = [
      for (var s in half.scenarios)
        if (s.state.isFinding && !allHidden(s) && filter.matches(s.scenario)) s,
    ];
    var hidden = [
      for (var s in half.scenarios)
        if (s.state.isFinding && allHidden(s) && filter.matches(s.scenario)) s,
    ];
    // Not findings, and not quiet either: listed whatever the scope, since
    // each is a scenario whose output depended on the machine that ran it.
    var unsure = [
      for (var s in half.scenarios)
        if (!s.compared && filter.matches(s.scenario)) s,
    ];
    var quiet = [
      for (var s in half.scenarios)
        if (filter.scope == IndexScope.all &&
            !s.state.isFinding &&
            s.compared &&
            filter.matches(s.scenario))
          s,
    ];
    var pending = [
      for (var id in half.pending)
        if (filter.matches(id)) id,
    ];

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: FwSpacing.sm),
      children: [
        for (var s in findings)
          _IndexRow(
            scenario: s,
            selected: s.scenario == selected,
            onTap: () => onSelect(s.scenario),
          ),
        if (findings.isEmpty && hidden.isEmpty && !half.isRunning)
          Padding(
            padding: const EdgeInsets.all(FwSpacing.xl),
            child: Text(
              filter.query.isEmpty ? 'No changes' : 'No matches',
              style: context.type.body.copyWith(color: context.colors.mut),
            ),
          ),
        // The flows still owed a verdict — the list draws its full shape from
        // the plan and only the answers arrive late.
        if (pending.isNotEmpty) ...[
          _SectionHeader('STILL REPLAYING', pending.length),
          for (var id in pending) _PendingRow(id),
        ],
        if (unsure.isNotEmpty) ...[
          _SectionHeader('NO RESULT', unsure.length),
          for (var s in unsure)
            _IndexRow(
              scenario: s,
              selected: s.scenario == selected,
              onTap: () => onSelect(s.scenario),
            ),
        ],
        if (hidden.isNotEmpty)
          HiddenRows(
            count: hidden.length,
            children: [
              for (var s in hidden)
                _IndexRow(
                  scenario: s,
                  selected: s.scenario == selected,
                  onTap: () => onSelect(s.scenario),
                ),
            ],
          ),
        if (quiet.isNotEmpty) ...[
          _SectionHeader('UNCHANGED', quiet.length),
          for (var s in quiet)
            _IndexRow(
              scenario: s,
              selected: s.scenario == selected,
              onTap: () => onSelect(s.scenario),
            ),
        ],
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label, this.count);

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      FwSpacing.xl,
      FwSpacing.lg,
      FwSpacing.xl,
      FwSpacing.sm,
    ),
    child: Text(
      '$label · $count',
      style: context.type.micro.copyWith(color: context.colors.mut),
    ),
  );
}

/// A flow whose verdict has not landed yet. Not tappable — there is nothing
/// behind it until its replay finishes, and then it becomes a real row.
class _PendingRow extends StatelessWidget {
  const _PendingRow(this.id);

  final String id;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var hash = id.indexOf('#');
    var name = hash < 0 ? id : id.substring(hash + 1);
    var file = hash < 0 ? '' : id.substring(0, hash);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: context.type.body.copyWith(color: colors.mut),
                  overflow: TextOverflow.ellipsis,
                ),
                if (file.isNotEmpty)
                  Text(
                    file,
                    style: context.type.micro.copyWith(color: colors.mut2),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const Gap(FwSpacing.sm),
          Text(
            'replaying…',
            style: context.type.micro.copyWith(color: colors.mut2),
          ),
        ],
      ),
    );
  }
}

class _IndexRow extends StatelessWidget {
  const _IndexRow({
    required this.scenario,
    required this.selected,
    required this.onTap,
  });

  final ScenarioComparison scenario;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var hash = scenario.scenario.indexOf('#');
    var name = hash < 0
        ? scenario.scenario
        : scenario.scenario.substring(hash + 1);
    var file = hash < 0 ? '' : scenario.scenario.substring(0, hash);

    return Tappable(
      key: scenarioRowKey(scenario.scenario),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.xl,
          vertical: FwSpacing.sm,
        ),
        color: selected ? colors.accent.withValues(alpha: 0.10) : null,
        // The name owns its line and the signature owns the next — trailing
        // both crushed a long name to `Coun…` in the one column where names
        // are how a reader recognises anything.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    name,
                    style: context.type.body,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Gap(FwSpacing.sm),
                StateChip.of(scenario),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: file.isEmpty
                      ? const SizedBox.shrink()
                      : Text(
                          file,
                          style: context.type.micro.copyWith(color: colors.mut),
                          overflow: TextOverflow.ellipsis,
                        ),
                ),
                // Which channels spoke — a flow has none of its own, so it
                // is the union of the steps inside it.
                if (scenario.state.isFinding && _channels.isNotEmpty) ...[
                  const Gap(FwSpacing.sm),
                  ChannelSignature(
                    channels: _channels,
                    pixelFraction: _worstPixelFraction,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<String> get _channels {
    var fired = <String>{};
    for (var step in scenario.items) {
      if (step.state.isFinding) fired.addAll(step.channelsFired);
    }
    return [
      for (var channel in const ['pixels', 'tree', 'texts', 'events'])
        if (fired.contains(channel)) channel,
    ];
  }

  /// The flow's worst step, because a flow-level fraction has no honest sum:
  /// three steps at 1% are not one step at 3%.
  double? get _worstPixelFraction {
    double? worst;
    for (var step in scenario.items) {
      if (!(step.pixels?.changed ?? false)) continue;
      var fraction = step.pixels?.diff.fraction;
      if (fraction != null && fraction > (worst ?? 0)) worst = fraction;
    }
    return worst;
  }
}

class _Header extends StatelessWidget {
  const _Header(this.scenario);

  final ScenarioComparison scenario;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      FwSpacing.xl,
      FwSpacing.lg,
      FwSpacing.xl,
      0,
    ),
    child: Row(
      children: [
        Expanded(child: ComparedTitle(scenario.scenario)),
        StateChip.of(scenario),
      ],
    ),
  );
}

/// Why a scenario has no tree: it was never replayed, or it was and produced
/// no result — and the reason differs.
///
/// The word in the chip, expanded. `skipped` beside an empty pane is a
/// verdict a reader has to already know how to trust — the thing worth saying
/// is *what was compared to reach it*, which is the closure hash, and that it
/// answers "no reason to run", not "could not run". A scenario with no result
/// is the other answer, and says what happened and what to do about it.
class _NotReplayed extends StatelessWidget {
  const _NotReplayed(this.scenario);

  final ScenarioComparison scenario;

  static const _notAboutTheBranch =
      'Not a finding about the branch: the scenario did not produce the same '
      'outcome twice here.';

  @override
  Widget build(BuildContext context) {
    if (scenario.inconclusive case var reason?) {
      return EmptyState(
        icon: Icons.help_outline,
        title: 'No result on this machine',
        message: [
          reason,
          for (var error in scenario.baseErrors)
            if (!reason.contains(error)) 'Base: $error',
          for (var error in scenario.headErrors)
            if (!reason.contains(error)) 'This branch: $error',
          _notAboutTheBranch,
        ].join('\n\n'),
      );
    }
    var state = scenario.state;
    return EmptyState(
      icon: switch (state) {
        ComparedState.added || ComparedState.removed => Icons.call_split,
        _ => Icons.done_all,
      },
      title: switch (state) {
        ComparedState.added => 'Only on this branch',
        ComparedState.removed => 'Only on the base',
        _ => 'Not replayed',
      },
      message: switch (state) {
        ComparedState.added =>
          'The base has no scenario by this name, so there is no run to '
              'compare this one against.',
        ComparedState.removed =>
          'This branch no longer declares it; the base still does.',
        _ =>
          'Nothing that decides its pixels changed between the two sides — '
              'not a file in its import closure, not an asset, not a lockfile '
              '— so both runs would have drawn the same frames and neither was '
              'run.',
      },
    );
  }
}

/// One step, over the flow: the two frames, and what the other channels found.
