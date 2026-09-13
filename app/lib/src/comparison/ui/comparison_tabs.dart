import 'dart:async';

import 'package:flutterware/comparison_report.dart';
import 'package:flutter/material.dart';

import '../../capture/settle.dart';
import '../../shell/shell_controller.dart';
import '../../shell/worktree.dart';
import '../../ui/menu.dart';
import '../../ui/popover.dart';
import '../../ui/tappable.dart';
import '../../ui/theme.dart';
import '../comparison_controller.dart';
import '../session_environment.dart';
import '../shot_store_io.dart';
import 'previews_tab.dart';
import 'verdict.dart';
import 'scenarios_tab.dart';
import 'state_chip.dart';
import '../../ui/error_state.dart';

/// The tab strip's root, so a test can scope to it.
const comparisonTabsKey = Key('comparison-tabs');

Key comparisonTabKey(String id) => ValueKey('changes.tab.$id');

/// The Compare button of one half — pressed in tests and by people.
Key compareButtonKey(String id) => ValueKey('changes.compare.$id');

/// The Stop button of a half mid-run.
Key stopButtonKey(String id) => ValueKey('changes.stop.$id');

/// The tab ids, which are also their first address segment.
const filesTabId = 'files';

/// Every tab id, so a reader of the address can tell a tab from a file path.
const comparisonTabIds = {filesTabId, 'previews', 'scenarios'};

/// `fw:///worktrees/<worktree>/changes` — what this branch did.
///
/// Three renderings of one delta against one base: the files that changed,
/// what the previews look like on either side, and what the scenarios do.
/// This owns the strip and the two comparison halves; the file diff is handed
/// in as [files], because it is a screen of its own with its own master,
/// detail and index tabs.
///
/// Not its own space, and the reversal is the interesting part. The design
/// doc argued for one, from the premise that a comparison spans two plugins and
/// needs a session on both sides — which is a fact about the *runner*, and one
/// `fw compare` disproves by running with no session on the base at all. What a
/// comparison spans is not what a screen belongs to. The case that matters is
/// this work against its base, which is a fact about one worktree.
///
/// Files is free and the other two cost seconds, and that is why they are
/// tabs on one panel rather than a place of their own: behind a tab on the
/// screen you already open to read a diff, the expensive halves get discovered.
/// Somewhere else they would have to be remembered, and a feature that has to
/// be remembered is used twice.
///
/// Nothing runs on tab focus. Selecting a tab shows what the last run
/// concluded — kept on disk between sessions — and one explicit Compare press
/// per half is what starts the machinery. See [ComparisonController] for why
/// the auto-run was retired.
///
/// The file half renders without a session and these two cannot. It reads git;
/// they need the previews and scenarios cores, which need a resolved config. So
/// an unopened checkout gets the files tab and no others, rather than tabs that
/// could only explain why they are empty.
class ComparisonTabs extends StatefulWidget {
  const ComparisonTabs({
    super.key,
    required this.shell,
    required this.worktree,
    required this.files,
    this.unavailable,
  });

  final ShellController shell;
  final Worktree worktree;

  /// Why there is no comparison to offer, known before anything is asked —
  /// a recording, which has no checkout to build a base of. Null means to
  /// find out from the session and git, which is the normal case.
  final String? unavailable;

  /// The file diff, built only when its tab is showing.
  ///
  /// Told whether a strip was drawn above it, because that decides whether it
  /// has to name itself: with a strip it is a tab among three and writes no
  /// title, and without one it is the whole screen.
  final Widget Function(BuildContext context, bool withinTabs) files;

  @override
  State<ComparisonTabs> createState() => _ComparisonTabsState();
}

class _ComparisonTabsState extends State<ComparisonTabs>
    implements SettleSource {
  ComparisonController? _controller;

  /// Why there is no comparison at all — not a git repository, no base.
  String? _unavailable;

  var _loading = true;

  /// A base the human picked from the strip, overriding the project's answer
  /// for this panel. Null means the configured-or-inferred default.
  String? _baseOverride;

  @override
  void initState() {
    super.initState();
    // **Registered synchronously, before the first await.** Registering after
    // one leaves the registry empty for as long as that await takes, and a
    // capture only needs 250ms of quiet to decide the window is worth
    // photographing — which is how the first capture of this screen came back
    // `settled: true` over the words "Preparing the base checkout…".
    widget.shell.appContext.settle.add(this);
    // **A session arrives late, and this screen mounts before it.** The file
    // diff needs none, so the tabs are shown for a checkout that is still
    // opening — and deciding "no session, no comparison" on the first frame
    // pinned that answer forever, on the very worktree the window was
    // launched in.
    widget.shell.addListener(_onShell);
    if (widget.unavailable case var reason?) {
      _unavailable = reason;
      _loading = false;
      return;
    }
    unawaited(_open());
  }

  void _onShell() {
    if (!mounted || widget.unavailable != null) return;
    if (_controller != null) {
      // The address moves the tab — and nothing else: a pasted link, the back
      // button and a drive `navigate` land on a tab that shows its kept
      // results, exactly like a tap. Running is [compare]'s job alone.
      setState(() {});
      return;
    }
    if (widget.shell.sessionFor(widget.worktree) != null) {
      unawaited(_open());
    } else if (!widget.shell.isOpen(widget.worktree) && _unavailable == null) {
      // **Decided here, never on the first frame.** `ShellController.go`
      // deliberately does not open a tab for this screen — it renders for a
      // checkout nobody has opened — so at startup this mounts *before* the
      // window's own worktree has a session. Concluding "no comparison" in
      // that window latched the wrong answer, and told a window capture the
      // screen was finished when it had not begun.
      setState(() => _unavailable = 'Open this worktree to compare it.');
    }
  }

  /// What a capture must not photograph through.
  ///
  /// Answered from the same state the screen draws from, as [SettleSource]
  /// requires. An idle half is *not* busy — its kept results are the screen —
  /// so a capture waits only while a started half is preparing or running.
  @override
  String? get busyWith {
    if (_loading) return 'opening the comparison';
    // Undecided is busy. A capture that settled here would photograph the file
    // diff alone and report success; the alternative failure — a capture that
    // waits and then says `waitedOn: [opening the comparison]` — is one
    // somebody can act on.
    var controller = _controller;
    if (controller == null) {
      return _unavailable == null ? 'opening the comparison' : null;
    }
    var half = _tabs.firstWhere((tab) => tab.id == _tab).half;
    if (half == null) return null;
    return switch (half.stage) {
      HalfStage.preparing => 'preparing the base checkout',
      HalfStage.running => 'comparing ${half.kind.label}',
      _ => null,
    };
  }

  Future<void> _open() async {
    // **The addressed worktree's session, not the selected one.** This screen
    // renders for a checkout that has no tab, which is precisely a checkout
    // `selectedSession` knows nothing about.
    if (_controller != null) return;
    var session = widget.shell.sessionFor(widget.worktree);
    if (session == null) {
      // Not open, so there are no cores and no comparison — only the file
      // diff, which needs none. Said rather than waited on: leaving `_loading`
      // true made this the one screen a window capture could never settle.
      // Not concluded here — see [_onShell]. Left undecided, which is what
      // keeps the screen busy until the shell has actually answered.
      if (mounted) setState(() => _loading = false);
      return;
    }
    var environment = await SessionComparisonEnvironment.open(
      session: session,
      flutterSdk: widget.shell.flutterSdk,
      appToolDirectory: widget.shell.appContext.appToolDirectory.path,
      // **The project's own answer, not a second one** — unless the human
      // picked a base from the strip, which outranks both. The file diff
      // resolves its base as `fw.changes(base:)` first and inference after; a
      // comparison that only ever inferred would compare against `master` on
      // a screen whose other tab says `develop`, and the design's
      // one-definition rule exists precisely to stop that.
      baseRef:
          _baseOverride ??
          widget.shell.manifestFor(widget.worktree)?.changes?.base,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (environment == null) {
        _unavailable = _baseOverride == null
            ? 'This worktree is not in a git repository with a base to '
                  'compare against.'
            : 'Nothing called "$_baseOverride" here — git cannot resolve it '
                  'to a commit to compare against.';
        return;
      }
      _controller = ComparisonController(environment)..addListener(_onChange);
    });
  }

  /// Tears the comparison down and reopens it against [ref].
  ///
  /// The environment resolves its base once, on construction — one definition,
  /// no drift — so a different base is a different environment, and the kept
  /// results reload against it.
  void _rebase(String? ref) {
    if (ref == _baseOverride) return;
    _controller
      ?..removeListener(_onChange)
      ..dispose();
    setState(() {
      _controller = null;
      _unavailable = null;
      _loading = true;
      _baseOverride = ref;
    });
    unawaited(_open());
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// The tab named by the address's first segment.
  ///
  /// Anything that is not a tab id is a file path, which is what makes the
  /// grammar backwards compatible: `changes/app/lib/foo.dart` was a whole
  /// address before there were tabs, and it still means the file diff. New
  /// addresses spell it `changes/files/app/lib/foo.dart`, because a repository
  /// with a top-level `previews/` directory would otherwise be ambiguous
  /// exactly where it matters.
  String get _tab {
    var named = widget.shell.address.segments.firstOrNull;
    if (named != null && _tabs.any((tab) => tab.id == named)) return named;
    return filesTabId;
  }

  List<_Tab> get _tabs => [
    const _Tab(id: filesTabId, label: 'files'),
    for (var half in _controller?.declared ?? const <ComparisonHalf>[])
      _Tab(id: half.kind.name, label: half.kind.label, half: half),
  ];

  void _select(String id) => widget.shell.selectChangesTab(tab: id);

  @override
  Widget build(BuildContext context) {
    // No comparison to be had — the files tab still is one, and it is the one
    // that needs nothing from us. A base override that would not resolve is
    // the exception: it has to say so, or the picker looks broken.
    if (_unavailable != null && _baseOverride != null) {
      return _Refusal(_unavailable!, onRetry: () => _rebase(null));
    }
    if (_loading || _unavailable != null || _controller == null) {
      return Builder(builder: (context) => widget.files(context, false));
    }

    var controller = _controller!;
    var tabs = _tabs;
    var selected = tabs.firstWhere((tab) => tab.id == _tab);

    return Column(
      key: comparisonTabsKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TabStrip(
          tabs: tabs,
          selected: selected.id,
          onSelect: _select,
          controller: controller,
          overridden: _baseOverride != null,
          onRebase: _rebase,
        ),
        Expanded(
          child: selected.half == null
              ? Builder(builder: (context) => widget.files(context, true))
              : _HalfView(
                  controller: controller,
                  half: selected.half!,
                  settle: widget.shell.appContext.settle,
                  selected: widget.shell.address.segments.skip(1).isEmpty
                      ? null
                      : widget.shell.address.segments.skip(1).join('/'),
                  onSelect: (id) => widget.shell.selectChangesTab(
                    tab: selected.id,
                    segments: id.split('/'),
                  ),
                ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    widget.shell.removeListener(_onShell);
    widget.shell.appContext.settle.remove(this);
    _controller
      ?..removeListener(_onChange)
      ..dispose();
    super.dispose();
  }
}

class _Tab {
  const _Tab({required this.id, required this.label, this.half});

  final String id;
  final String label;

  /// Null for the file diff, which is not a comparison half — it needs no base
  /// checkout, costs nothing, and is built by the host.
  final ComparisonHalf? half;
}

/// `[ files ][ previews · 3 ][ scenarios ]      worktree ↔ origin/master ▾`
///
/// A tab carries its half's finding count once that half has an answer —
/// which, with the last run kept on disk, it usually has for free. What it
/// still does not carry is a *price*: pricing a click before it is made was
/// tried, cost about what the work costs, and was removed. See
/// [ComparisonController].
class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.tabs,
    required this.selected,
    required this.onSelect,
    required this.controller,
    required this.overridden,
    required this.onRebase,
  });

  final List<_Tab> tabs;
  final String selected;
  final void Function(String id) onSelect;
  final ComparisonController controller;

  /// Whether the base is a hand-picked one rather than the project's.
  final bool overridden;
  final ValueChanged<String?> onRebase;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      padding: const EdgeInsets.only(left: FwSpacing.xxxl, right: FwSpacing.xl),
      child: Row(
        children: [
          for (var tab in tabs)
            _TabButton(
              tab: tab,
              selected: tab.id == selected,
              onTap: () => onSelect(tab.id),
            ),
          const Spacer(),
          // **No title of its own.** The sidebar row says "Changes" and the
          // file diff writes its own header inside its tab; what is left is
          // the one thing the strip is the only place for: what every tab is
          // against — and, since the base is a choice now, the control that
          // changes it.
          _BaseControl(
            environment: controller.environment,
            overridden: overridden,
            onRebase: onRebase,
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final _Tab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var half = tab.half;
    var note = half?.isBusy == true ? 'running…' : null;
    var findings = half?.findingCount ?? 0;

    return Tappable(
      key: comparisonTabKey(tab.id),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.lg,
          vertical: FwSpacing.md,
        ),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? colors.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            Text(
              tab.label,
              style: context.type.body.copyWith(
                color: selected ? colors.ink : colors.mut,
              ),
            ),
            if (half?.stage == HalfStage.refused) ...[
              const Gap(FwSpacing.sm),
              Icon(Icons.error_outline, size: FwIconSize.xs, color: colors.red),
            ] else if (note != null) ...[
              const Gap(FwSpacing.sm),
              Text(
                '· $note',
                style: context.type.micro.copyWith(color: colors.mut),
              ),
            ] else if (findings > 0) ...[
              // The other tab's answer, readable without visiting it — the
              // kept run makes this free.
              const Gap(FwSpacing.sm),
              Text(
                '· $findings',
                style: context.type.micro.copyWith(color: colors.amber),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The contract, stated where every tab can see it: this worktree, against
/// which commit — and the commit is a control, not a caption.
class _BaseControl extends StatelessWidget {
  const _BaseControl({
    required this.environment,
    required this.overridden,
    required this.onRebase,
  });

  final ComparisonEnvironment environment;
  final bool overridden;
  final ValueChanged<String?> onRebase;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var sha = environment.baseSha;
    var sha7 = sha.length > 7 ? sha.substring(0, 7) : sha;

    return Menu(
      align: PopoverAlign.end,
      entries: [
        const MenuHeader('compare against'),
        MenuItem(
          overridden
              ? 'the project default'
              : '${environment.baseLabel} (default)',
          icon: overridden ? null : Icons.check,
          onSelected: overridden ? () => onRebase(null) : null,
        ),
        MenuItem(
          'HEAD~1 — the previous commit',
          icon: overridden && _isPrevious ? Icons.check : null,
          onSelected: () => onRebase('HEAD~1'),
        ),
        const MenuDivider(),
        MenuItem(
          'Another ref or commit…',
          onSelected: () => unawaited(_askForRef(context)),
        ),
      ],
      builder: (context, controller) => Tooltip(
        message:
            'This worktree as it sits on disk — uncommitted and untracked '
            'included — against the merge base with ${environment.baseLabel}.',
        child: Tappable(
          onTap: controller.toggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.sm,
              vertical: FwSpacing.sm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'this worktree',
                  style: context.type.micro.copyWith(color: colors.mut),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: FwSpacing.sm),
                  child: Icon(
                    Icons.sync_alt,
                    size: FwIconSize.xs,
                    color: colors.mut2,
                  ),
                ),
                Text(
                  '${environment.baseLabel} @$sha7',
                  style: context.type.micro.copyWith(
                    color: overridden ? colors.accent : colors.mut,
                  ),
                ),
                Icon(
                  Icons.arrow_drop_down,
                  size: FwIconSize.sm,
                  color: colors.mut,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool get _isPrevious => environment.baseLabel == 'HEAD~1';

  Future<void> _askForRef(BuildContext context) async {
    var ref = await showDialog<String>(
      context: context,
      builder: (context) => const _RefDialog(),
    );
    if (ref != null && ref.trim().isNotEmpty) onRebase(ref.trim());
  }
}

/// One text field: anything git can name — a branch, a tag, a sha, `HEAD~3`.
class _RefDialog extends StatefulWidget {
  const _RefDialog();

  @override
  State<_RefDialog> createState() => _RefDialogState();
}

class _RefDialogState extends State<_RefDialog> {
  final _ref = TextEditingController();

  @override
  void dispose() {
    _ref.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(_ref.text);
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Dialog(
      backgroundColor: colors.bg,
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(FwSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Compare against', style: context.type.bodyStrong),
            const Gap(FwSpacing.lg),
            TextField(
              controller: _ref,
              autofocus: true,
              style: context.type.body,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'any ref, tag or commit — origin/main, v2.1, HEAD~3',
                hintStyle: context.type.body.copyWith(color: colors.mut2),
                border: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.line),
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const Gap(FwSpacing.md),
            Text(
              'The comparison runs against the merge base of HEAD and what '
              'you name — the point where this branch left it.',
              style: context.type.caption.copyWith(color: colors.mut),
            ),
            const Gap(FwSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Tappable(
                  onTap: () => Navigator.of(context).pop(),
                  child: Padding(
                    padding: const EdgeInsets.all(FwSpacing.sm),
                    child: Text(
                      'Cancel',
                      style: context.type.body.copyWith(color: colors.mut),
                    ),
                  ),
                ),
                const Gap(FwSpacing.md),
                _CompareButton(label: 'Use it', onTap: _submit),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One half, in whatever state it is in.
///
/// Every state but [HalfStage.undeclared] draws a strip over the content: the
/// run's progress while it works, its receipt when it is done. **The strip is
/// a ribbon and the rows are the canvas** — the two answer different questions
/// ("is it working, can I stop it" against "what did it find") and the design
/// that failed here before was the one that merged them: a full-screen
/// "Comparing…" that became results all at once.
class _HalfView extends StatelessWidget {
  const _HalfView({
    required this.controller,
    required this.half,
    required this.settle,
    required this.selected,
    required this.onSelect,
  });

  final ComparisonController controller;
  final ComparisonHalf half;
  final SettleRegistry settle;

  /// What the address names below the tab, or null.
  final String? selected;
  final ValueChanged<String> onSelect;

  void _compare() => unawaited(controller.compare(half.kind));

  bool get _hasRows => half.rows.isNotEmpty || half.scenarios.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    switch (half.stage) {
      case HalfStage.undeclared:
        return const SizedBox.shrink();
      case HalfStage.refused:
        return _Refusal(
          half.refusal ?? 'Comparison refused',
          onRetry: _compare,
        );
      case HalfStage.preparing:
      case HalfStage.running:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _RunStrip(half: half, onStop: () => controller.stop(half.kind)),
            Expanded(
              child: _hasRows || half.pending.isNotEmpty
                  ? _rows(context)
                  : _Working(half.progress ?? 'Comparing…'),
            ),
          ],
        );
      case HalfStage.idle:
        if (!_hasRows) {
          return _ArmedView(
            half: half,
            environment: controller.environment,
            onCompare: _compare,
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ReceiptStrip(
              half: half,
              environment: controller.environment,
              onCompare: _compare,
            ),
            Expanded(child: _rows(context)),
          ],
        );
      case HalfStage.done:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ReceiptStrip(
              half: half,
              environment: controller.environment,
              onCompare: _compare,
            ),
            Expanded(
              child: _hasRows
                  ? _rows(context)
                  : const _Working('Nothing to compare on either side'),
            ),
          ],
        );
    }
  }

  /// What this half concluded, handed to the half to place.
  ///
  /// Drawn here it sat above *everything the tab renders*, which includes a
  /// pushed step page — so a header about eleven steps stayed on screen over a
  /// page about one of them. Only the half knows when it is showing a list.
  Widget _verdict() =>
      ComparisonVerdict.ofHalf(half, onToggle: half.toggleRule);

  Widget _rows(BuildContext context) => switch (half.kind) {
    ComparisonHalfKind.previews => PreviewsTab(
      half: half,
      store: CacheShotStore(controller.environment.shots),
      settle: settle,
      selected: selected,
      onSelect: onSelect,
      header: _verdict(),
    ),
    ComparisonHalfKind.scenarios => ScenariosTab(
      half: half,
      store: CacheShotStore(controller.environment.shots),
      settle: settle,
      selected: selected,
      onSelect: onSelect,
      header: _verdict(),
    ),
  };
}

/// The offer, before a first run: what would be compared, against what, and
/// what it will cost — from facts that are already free. No re-planning: the
/// four-minute estimate is the mistake this panel is built not to repeat.
class _ArmedView extends StatelessWidget {
  const _ArmedView({
    required this.half,
    required this.environment,
    required this.onCompare,
  });

  final ComparisonHalf half;
  final ComparisonEnvironment environment;
  final VoidCallback onCompare;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var sha = environment.baseSha;
    var sha7 = sha.length > 7 ? sha.substring(0, 7) : sha;
    var cost = environment.baseCheckoutReady
        ? 'base checkout ready · unchanged entries are skipped'
        : 'the first run checks out $sha7 and resolves its dependencies, '
              'which can take a minute';

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Compare ${half.kind.label} against ${environment.baseLabel}',
            style: context.type.bodyStrong,
          ),
          const Gap(FwSpacing.sm),
          Text(
            cost,
            style: context.type.caption.copyWith(color: colors.mut),
            textAlign: TextAlign.center,
          ),
          const Gap(FwSpacing.xl),
          _CompareButton(
            key: compareButtonKey(half.kind.name),
            label: 'Compare',
            onTap: onCompare,
          ),
          const Gap(FwSpacing.lg),
          Text(
            'No comparison yet on this worktree',
            style: context.type.micro.copyWith(color: colors.mut2),
          ),
        ],
      ),
    );
  }
}

/// The ribbon while a run works: what it is doing, how far along, for how
/// long, and the way out. The bar's denominator is exact — the plan knows
/// every entry before the first render — so its opening move is a leap to the
/// fraction the skip rule answered for free, which is the skip rule made
/// visible.
class _RunStrip extends StatefulWidget {
  const _RunStrip({required this.half, required this.onStop});

  final ComparisonHalf half;
  final VoidCallback onStop;

  @override
  State<_RunStrip> createState() => _RunStripState();
}

class _RunStripState extends State<_RunStrip> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The counter is the liveness signal: a phase with no denominator — `pub
    // get` on a cold cache — still visibly costs time rather than looking
    // hung.
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var half = widget.half;
    var total = half.planTotal;
    var answered = half.rows.length + half.scenarios.length;

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              half.progress ?? 'Comparing…',
              style: context.type.caption.copyWith(color: colors.mut),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (total != null && total > 0) ...[
            const Gap(FwSpacing.lg),
            SizedBox(
              width: 160,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: answered / total,
                  minHeight: 4,
                  backgroundColor: colors.line,
                  color: colors.accent,
                ),
              ),
            ),
            const Gap(FwSpacing.md),
            Text(
              '$answered of $total',
              style: context.type.micro.copyWith(color: colors.mut),
            ),
          ],
          const Gap(FwSpacing.lg),
          Text(
            _elapsed(half.startedAt),
            style: context.type.micro.copyWith(color: colors.mut2),
          ),
          const Gap(FwSpacing.lg),
          Tappable(
            key: stopButtonKey(half.kind.name),
            onTap: widget.onStop,
            borderRadius: BorderRadius.circular(context.radii.radius),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: FwSpacing.md,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                border: Border.all(color: colors.line),
                borderRadius: BorderRadius.circular(context.radii.radius),
              ),
              child: Text(
                'Stop',
                style: context.type.caption.copyWith(color: colors.ink),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _elapsed(DateTime? since) {
    if (since == null) return '';
    var seconds = DateTime.now().difference(since).inSeconds;
    if (seconds < 60) return '${seconds}s';
    return '${seconds ~/ 60}m ${(seconds % 60).toString().padLeft(2, '0')}s';
  }
}

/// The ribbon once a run is done — or was stopped, or came off disk: the
/// counts, the receipt, and the same button again. One control is the re-run,
/// the retry and the refresh, because they were always the same act.
class _ReceiptStrip extends StatelessWidget {
  const _ReceiptStrip({
    required this.half,
    required this.environment,
    required this.onCompare,
  });

  final ComparisonHalf half;
  final ComparisonEnvironment environment;
  final VoidCallback onCompare;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var counts = _counts;
    var quiet =
        half.rows.where((row) => !row.state.isFinding).length +
        half.scenarios.where((scenario) => !scenario.state.isFinding).length;

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.sm,
      ),
      child: Row(
        children: [
          for (var entry in counts.entries)
            Padding(
              padding: const EdgeInsets.only(right: FwSpacing.xs),
              child: StateChip(entry.key, count: entry.value),
            ),
          if (counts.isEmpty)
            Text(
              'No changes',
              style: context.type.caption.copyWith(color: colors.mut),
            )
          else if (quiet > 0)
            Text(
              '· $quiet unchanged',
              style: context.type.micro.copyWith(color: colors.mut),
            ),
          const Spacer(),
          Text(_receipt, style: context.type.micro.copyWith(color: colors.mut)),
          if (_movedSince) ...[
            const Gap(FwSpacing.sm),
            Tooltip(
              message:
                  'The worktree or its base has moved since this run — the '
                  'rows may no longer describe the code on disk.',
              child: Text(
                '· stale',
                style: context.type.micro.copyWith(color: colors.amber),
              ),
            ),
          ],
          const Gap(FwSpacing.lg),
          _CompareButton(
            key: compareButtonKey(half.kind.name),
            label: half.stopped ? 'Compare' : 'Compare again',
            onTap: onCompare,
            small: true,
          ),
        ],
      ),
    );
  }

  Map<ComparedState, int> get _counts {
    var counts = <ComparedState, int>{};
    for (var state in [
      for (var row in half.rows) row.state,
      for (var scenario in half.scenarios) scenario.state,
    ]) {
      if (state.isFinding) counts[state] = (counts[state] ?? 0) + 1;
    }
    return Map.fromEntries(
      counts.entries.toList()
        ..sort((a, b) => a.key.index.compareTo(b.key.index)),
    );
  }

  String get _receipt {
    if (half.stopped) {
      var started = half.startedAt;
      var lasted = started == null
          ? ''
          : ' after ${DateTime.now().difference(started).inSeconds}s';
      return 'stopped$lasted — partial';
    }
    var last = half.lastRun;
    if (last == null) return '';
    var took = last.elapsed.inMilliseconds >= 1000
        ? '${(last.elapsed.inMilliseconds / 1000).toStringAsFixed(last.elapsed.inSeconds >= 10 ? 0 : 1)}s'
        : '${last.elapsed.inMilliseconds}ms';
    return 'ran in $took · ${_ago(last.at)}';
  }

  bool get _movedSince {
    var last = half.lastRun;
    if (last == null) return false;
    if (last.baseSha != environment.baseSha) return true;
    var head = environment.headCommit;
    return last.headCommit != null && head != null && last.headCommit != head;
  }
}

String _ago(DateTime then) {
  var d = DateTime.now().difference(then);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// The one act this panel has, drawn the same wherever it appears.
class _CompareButton extends StatelessWidget {
  const _CompareButton({
    super.key,
    required this.label,
    required this.onTap,
    this.small = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool small;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.radii.radius),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: small ? FwSpacing.lg : FwSpacing.xxl,
          vertical: small ? 2 : FwSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: colors.accentSoft,
          border: Border.all(color: colors.accent),
          borderRadius: BorderRadius.circular(context.radii.radius),
        ),
        child: Text(
          label,
          style: (small ? context.type.caption : context.type.body).copyWith(
            color: colors.accent,
          ),
        ),
      ),
    );
  }
}

class _Refusal extends StatelessWidget {
  const _Refusal(this.message, {required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ErrorState(title: 'Not compared', message: message),
        const Gap(FwSpacing.lg),
        _CompareButton(label: 'Try again', onTap: onRetry),
      ],
    ),
  );
}

class _Working extends StatelessWidget {
  const _Working(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      message,
      style: context.type.body.copyWith(color: context.colors.mut),
    ),
  );
}
