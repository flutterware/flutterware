import 'dart:async';

import 'package:clock/clock.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../dev_stack/stack_block.dart';
import '../plugins/native/dev_stack_core.dart';
import '../plugins/native/dev_stack_plugin.dart';
import '../plugins/native/run_plugin.dart';
import '../plugins/worktree_session.dart';
import '../run/handle.dart';
import '../ui/panel_header.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import '../worktrees/facts.dart';
import 'worktree.dart';

/// What a worktree opens on, instead of whichever plugin happened to be first.
///
/// The page answers *where does this work stand* — the delta, the pull
/// request, what is running — from facts that are already paid for: the
/// explorer's shell-side probes ([WorktreeFacts]) and the run ledger on disk.
/// Composition rules, arrived at by mocking first (`tool/catalog/demos/
/// worktree_home.dart`):
///
/// - **No agent facts.** File-only readings of an agent session are fragile;
///   the page does not carry them.
/// - **Branch facts live on the branch chip.** Ahead/behind ride the chip in
///   the header — the branch is named once, at the top.
/// - **Each subject has its own shape.** The delta is a stat card whose
///   numbers are the headline and whose body is a button to the changes
///   screen; the pull request is a title with status pills; a run is a device
///   tile; and only the dev stack keeps its strip, which is
///   [DevStackForm.strip]'s established identity. A uniform stack of strips
///   was built first and read as one grey list.
/// - **One rail.** Everything below the header aligns to the same 720px
///   column — cards split it half and half at equal height.
///
/// The costs stay mount-scoped, like the stack strip's polling always was:
/// the facts refresh is the explorer's own coalesced sweep, triggered by this
/// screen appearing, and the run ledger is scanned and probed only while the
/// screen is on — and only when the project declares the run plugin, so the
/// session fixtures in tests never touch a run dir.
class WorktreeHome extends StatefulWidget {
  const WorktreeHome(
    this.worktree, {
    super.key,
    this.session,
    this.onOpenPlugin,
    this.facts = const WorktreeFacts(),
    this.onRefreshFacts,
    this.onOpenChanges,
  });

  final Worktree worktree;

  /// Navigates to a plugin's panel. Null for a caller with no shell — the
  /// blocks then draw without their way out, rather than with a link that
  /// does nothing.
  final void Function(String pluginId)? onOpenPlugin;

  /// The open session, when there is one. Null before the config resolves, and
  /// for any caller that has only the worktree — the screen degrades to what it
  /// always was rather than refusing to draw.
  final WorktreeSession? session;

  /// What the explorer knows about this checkout. The default is the empty
  /// reading, under which the page draws exactly what it drew before facts
  /// existed: the header.
  final WorktreeFacts facts;

  /// Asks the shell for a facts sweep. Called once on mount — the same
  /// "becoming visible" trigger the explorer uses, and coalesced by the same
  /// controller, so the two screens never race a second sweep.
  final VoidCallback? onRefreshFacts;

  /// Navigates to the changes screen — what the delta card is a button to.
  final VoidCallback? onOpenChanges;

  /// The stack panel for this worktree, or null when none is declared or the
  /// session has not landed. Read through the plugin rather than the core so
  /// the block subscribes to the same notifier the sidebar does.
  DevStackPlugin? get _stack {
    var plugin = session?.pluginById(devStackPluginId);
    return plugin is DevStackPlugin ? plugin : null;
  }

  /// The run core, when this project declares the run plugin. The gate for
  /// everything the LIVE section costs: no run plugin, no scan, no timer.
  RunCore? get _runCore {
    var plugin = session?.pluginById(runPluginId);
    return plugin is RunPlugin ? plugin.core : null;
  }

  @override
  State<WorktreeHome> createState() => _WorktreeHomeState();
}

class _WorktreeHomeState extends State<WorktreeHome> {
  var _runs = <RunReading>[];
  Timer? _timer;
  var _probing = false;

  @override
  void initState() {
    super.initState();
    widget.onRefreshFacts?.call();
    _watchRuns();
  }

  @override
  void didUpdateWidget(WorktreeHome old) {
    super.didUpdateWidget(old);
    // The call site keys this widget by worktree, so a session landing is the
    // only arrival worth reacting to — it is what brings the run core.
    if (old.session != widget.session) _watchRuns();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Scans the ledger now and keeps it fresh while the screen is on.
  ///
  /// Deliberately not [RunCore.track]: that is the panel's lease — a
  /// `flutter daemon` and a fast probe loop, paid for by whoever wants a live
  /// device list. This screen wants the ledger and liveness, at the stack
  /// strip's cadence, and stops paying when it unmounts.
  void _watchRuns() {
    _timer?.cancel();
    _timer = null;
    var core = widget._runCore;
    if (core == null) {
      _runs = const [];
      return;
    }
    unawaited(
      core.files.ready.then((_) {
        if (mounted) _scanRuns();
      }),
    );
    // Nothing under a recording moves, so it is read once.
    if (core.readOnly != null) return;
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _scanRuns());
  }

  void _scanRuns() {
    var core = widget._runCore;
    if (core == null) return;
    var handles = scanRunHandles(
      core.runDir,
      underRoot: widget.worktree.path,
      files: core.files,
    );
    // Keep what the last probe said about a handle that is still there, so a
    // rescan does not blink every tile back to "checking".
    var known = {
      for (var run in _runs)
        if (run.handle.handlePath != null) run.handle.handlePath!: run.probe,
    };
    setState(() {
      _runs = [
        for (var handle in handles)
          RunReading(handle, probe: known[handle.handlePath]),
      ];
    });
    unawaited(_probeRuns());
  }

  Future<void> _probeRuns() async {
    if (_probing) return;
    _probing = true;
    try {
      var core = widget._runCore;
      if (core == null) return;
      var probed = <String, RunProbe>{};
      for (var run in _runs) {
        if (run.handle.handlePath case var path?) {
          probed[path] = await core.sources.apps.probe(run.handle);
        }
      }
      if (!mounted) return;
      setState(() {
        _runs = [
          for (var run in _runs)
            RunReading(
              run.handle,
              probe: probed[run.handle.handlePath] ?? run.probe,
            ),
        ];
      });
    } finally {
      _probing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    var stack = widget._stack;
    return WorktreeHomeView(
      widget.worktree,
      facts: widget.facts,
      // A corpse is not a run. The probe decides, not the file.
      runs: [
        for (var run in _runs)
          if (!(run.probe?.isDead ?? false)) run,
      ],
      now: clock.now(),
      stackStrip: stack == null
          ? null
          : DevStackBlock(
              stack,
              form: DevStackForm.strip,
              onOpenPanel: widget.onOpenPlugin == null
                  ? null
                  : () => widget.onOpenPlugin!(devStackPluginId),
            ),
      onOpenChanges: widget.onOpenChanges,
      onOpenRun: widget.onOpenPlugin == null
          ? null
          : () => widget.onOpenPlugin!(runPluginId),
    );
  }
}

/// One run, as this screen reads it: the handle file, and what probing it
/// said — null until the first probe answers.
class RunReading {
  const RunReading(this.handle, {this.probe});

  final RunHandle handle;
  final RunProbe? probe;
}

/// The page itself: every value arrives as data and every action leaves as a
/// callback, which is what lets the catalog render it from fixtures.
class WorktreeHomeView extends StatelessWidget {
  const WorktreeHomeView(
    this.worktree, {
    super.key,
    this.facts = const WorktreeFacts(),
    this.runs = const [],
    required this.now,
    this.stackStrip,
    this.onOpenChanges,
    this.onOpenRun,
  });

  final Worktree worktree;
  final WorktreeFacts facts;
  final List<RunReading> runs;

  /// The clock the elapsed times are computed against, passed in so a
  /// screenshot of a fixture is the same picture tomorrow.
  final DateTime now;

  /// The dev-stack strip, handed in whole: the block owns its polling and its
  /// six states, and this page only decides where it sits.
  final Widget? stackStrip;

  final VoidCallback? onOpenChanges;
  final VoidCallback? onOpenRun;

  @override
  Widget build(BuildContext context) {
    var git = facts.git.value;
    var pr = facts.forge.value;
    var hasDelta = git != null && (!git.isInSync || git.dirty > 0);
    var hasLive = runs.isNotEmpty || stackStrip != null;

    return ListView(
      padding: const EdgeInsets.only(bottom: FwSpacing.xxxl),
      children: [
        FwPanelHeader(
          worktree.displayName,
          subtitle: [worktree.path],
          // A path is the thing most likely to be wanted in a terminal a moment
          // later.
          selectableSubtitle: true,
          below: Wrap(
            spacing: FwSpacing.md,
            runSpacing: FwSpacing.md,
            children: [
              _Chip(worktree.isMain ? 'main checkout' : 'linked worktree'),
              if (worktree.branch case var branch?)
                _Chip(
                  branch,
                  icon: Icons.call_split,
                  detail: git == null || (git.ahead == 0 && git.behind == 0)
                      ? null
                      : [
                          if (git.ahead > 0) '${git.ahead}↑',
                          if (git.behind > 0) '${git.behind}↓',
                        ].join(' '),
                )
              else if (worktree.head case var head?)
                _Chip('detached at ${_short(head)}'),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            panelGutter,
            FwSpacing.xl,
            panelGutter,
            0,
          ),
          // One rail: every block below the header aligns to the same 720px
          // column, so distinct shapes do not read as clutter.
          child: !hasDelta && pr == null && !hasLive
              ? (git != null && git.isInSync ? const _QuietLine() : null)
              : Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (hasDelta || pr != null)
                          IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (hasDelta)
                                  Expanded(
                                    child: _dimmed(
                                      facts.git,
                                      _ChangesCard(git, onOpen: onOpenChanges),
                                    ),
                                  ),
                                if (hasDelta && pr != null)
                                  const Gap(FwSpacing.lg),
                                if (pr != null)
                                  Expanded(
                                    child: _dimmed(facts.forge, _PrCard(pr)),
                                  ),
                              ],
                            ),
                          ),
                        if (hasLive) ...[
                          if (hasDelta || pr != null) const Gap(FwSpacing.xxl),
                          Text(
                            'LIVE',
                            style: context.type.micro.copyWith(
                              color: context.colors.mut3,
                            ),
                          ),
                          const Gap(FwSpacing.sm),
                          for (var pair in _pairs(runs)) ...[
                            IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: _RunTile(
                                      pair.$1,
                                      now: now,
                                      onOpen: onOpenRun,
                                    ),
                                  ),
                                  if (runs.length > 1) ...[
                                    const Gap(FwSpacing.lg),
                                    Expanded(
                                      child: pair.$2 == null
                                          ? const SizedBox.shrink()
                                          : _RunTile(
                                              pair.$2!,
                                              now: now,
                                              onOpen: onOpenRun,
                                            ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const Gap(FwSpacing.md),
                          ],
                          ?stackStrip,
                        ],
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// A stale fact is shown, dimmed — the explorer's rule, kept here so the two
  /// screens never disagree about what a dated reading looks like.
  Widget _dimmed(Fact<Object?> fact, Widget child) =>
      fact.isDim ? Opacity(opacity: 0.6, child: child) : child;

  /// Two tiles to a row, a single run getting the rail to itself.
  static List<(RunReading, RunReading?)> _pairs(List<RunReading> runs) => [
    for (var i = 0; i < runs.length; i += 2)
      (runs[i], i + 1 < runs.length ? runs[i + 1] : null),
  ];

  static String _short(String head) =>
      head.length <= 8 ? head : head.substring(0, 8);
}

/// Nothing to say, said once — not a field of empty labels.
class _QuietLine extends StatelessWidget {
  const _QuietLine();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: colors.grn, shape: BoxShape.circle),
        ),
        const Gap(FwSpacing.md),
        Text(
          'clean  ·  in sync  ·  nothing running',
          style: context.type.bodySmall.copyWith(color: colors.mut2),
        ),
      ],
    );
  }
}

/// The delta as a stat: the numbers are the headline, and the card is the way
/// to the changes screen.
class _ChangesCard extends StatelessWidget {
  const _ChangesCard(this.git, {this.onOpen});

  final GitFacts git;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var shape = git.changes;
    var files = shape == null || shape.isEmpty
        ? null
        : '${shape.files} file${shape.files == 1 ? '' : 's'} against ${git.base ?? 'the base'}';
    return _Card(
      label: 'Changed',
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (shape != null && !shape.isEmpty)
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '+${shape.added}',
                    style: context.type.heading.copyWith(color: colors.grn),
                  ),
                  TextSpan(text: '  ', style: context.type.heading),
                  TextSpan(
                    text: '−${shape.removed}',
                    style: context.type.heading.copyWith(color: colors.red),
                  ),
                ],
              ),
            )
          else
            // No branch delta yet, so the dirty count *is* the stat — a
            // number in the number slot, not a label wearing its clothes.
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${git.dirty}', style: context.type.heading),
                  TextSpan(
                    text: '  uncommitted',
                    style: context.type.heading.copyWith(color: colors.mut2),
                  ),
                ],
              ),
            ),
          const Gap(FwSpacing.sm),
          Text(
            files == null
                ? (git.base == null
                      ? 'nothing committed on this branch yet'
                      : 'nothing committed against ${git.base} yet')
                : [
                    files,
                    if (git.dirty > 0) '${git.dirty} uncommitted',
                  ].join('  ·  '),
            style: context.type.caption.copyWith(color: colors.mut),
          ),
        ],
      ),
    );
  }
}

/// The pull request as a title with status pills — the pills carry the colour,
/// so red on this page always means "acts on you".
class _PrCard extends StatelessWidget {
  const _PrCard(this.pr);

  final ForgeFacts pr;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var url = pr.url;
    return _Card(
      label: 'Pull request',
      onTap: url == null ? null : () => unawaited(launchUrl(Uri.parse(url))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '#${pr.number}  ',
                  style: context.type.bodyStrong.copyWith(color: colors.mut2),
                ),
                TextSpan(text: pr.title, style: context.type.bodyStrong),
              ],
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const Gap(FwSpacing.md),
          Wrap(
            spacing: FwSpacing.sm,
            runSpacing: FwSpacing.sm,
            children: [
              switch (pr.checks) {
                ChecksState.failing => _Pill(
                  '${pr.failingChecks} check${pr.failingChecks == 1 ? '' : 's'}'
                  ' failing',
                  tone: colors.red,
                ),
                ChecksState.passing => _Pill(
                  'checks passing',
                  tone: colors.grn,
                ),
                ChecksState.pending => _Pill('checks running'),
                ChecksState.none => _Pill(pr.state.name),
              },
              if (pr.review != ReviewState.none)
                _Pill(
                  pr.review.label,
                  tone: switch (pr.review) {
                    ReviewState.changesRequested => colors.amber,
                    ReviewState.approved => colors.grn,
                    _ => null,
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.label, required this.child, this.onTap});

  final String label;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.radii.radius),
      child: Container(
        padding: const EdgeInsets.all(FwSpacing.lg),
        decoration: BoxDecoration(
          color: colors.panel,
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(context.radii.radius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label.toUpperCase(),
                    style: context.type.micro.copyWith(color: colors.mut3),
                  ),
                ),
                if (onTap != null)
                  Icon(
                    Icons.chevron_right,
                    size: FwIconSize.md,
                    color: colors.mut2,
                  ),
              ],
            ),
            const Gap(FwSpacing.md),
            child,
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, {this.tone});

  final String label;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.md,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: tone == null ? colors.panel2 : colors.statusFill(tone!),
        border: Border.all(
          color: tone == null ? colors.line : colors.statusBorder(tone!),
        ),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      child: Text(
        label,
        style: context.type.caption.copyWith(color: tone ?? colors.mut),
      ),
    );
  }
}

/// A run as a device tile: the device glyph gives it its identity, so two
/// running devices read as two machines rather than two more grey lines.
class _RunTile extends StatelessWidget {
  const _RunTile(this.run, {required this.now, this.onOpen});

  final RunReading run;
  final DateTime now;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var handle = run.handle;
    var probe = run.probe;
    var (word, dot) = switch (probe) {
      null => ('checking', colors.mut2),
      RunProbe(app: true) => ('running', colors.grn),
      RunProbe(launcher: true) => ('building', colors.amber),
      // Both halves dead is [RunProbe.isDead], and the screen filters those
      // out before this widget — but a fixture can hand one in.
      _ => ('stopped', colors.mut2),
    };
    var elapsed = now.difference(handle.startedAt);
    return Tappable(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(context.radii.radius),
      child: Container(
        padding: const EdgeInsets.all(FwSpacing.md),
        decoration: BoxDecoration(
          color: colors.panel,
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(context.radii.radius),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: colors.panel2,
                borderRadius: BorderRadius.circular(context.radii.radiusSmall),
              ),
              child: Icon(
                _deviceIcon(handle),
                size: FwIconSize.lg,
                color: colors.mut,
              ),
            ),
            const Gap(FwSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    handle.deviceName ?? handle.device,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.bodyStrong,
                  ),
                  const Gap(2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: dot,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const Gap(FwSpacing.xs),
                      Flexible(
                        child: Text(
                          [
                            word,
                            handle.entrypointName ?? handle.entrypoint,
                            ?handle.flavor,
                            _elapsed(elapsed),
                          ].join('  ·  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.type.caption.copyWith(
                            color: colors.mut,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Gap(FwSpacing.md),
            Icon(Icons.chevron_right, size: FwIconSize.md, color: colors.mut2),
          ],
        ),
      ),
    );
  }

  /// `40s`, `12m`, `3h` — one unit, because a tile is a glance.
  static String _elapsed(Duration d) {
    if (d.inMinutes < 1) return '${d.inSeconds}s';
    if (d.inHours < 1) return '${d.inMinutes}m';
    return '${d.inHours}h';
  }

  static IconData _deviceIcon(RunHandle handle) {
    var haystack = '${handle.device} ${handle.deviceName ?? ''}'.toLowerCase();
    bool has(String needle) => haystack.contains(needle);
    if (has('mac')) return Icons.laptop_mac;
    if (has('ipad')) return Icons.tablet_mac;
    if (has('iphone') || has('ios')) return Icons.phone_iphone;
    if (has('chrome') || has('web') || has('edge')) return Icons.language;
    if (has('windows')) return Icons.desktop_windows;
    if (has('linux')) return Icons.computer;
    return Icons.smartphone;
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, {this.icon, this.detail});

  final String label;
  final IconData? icon;

  /// A muted suffix on the same chip — `3↑ 1↓` beside the branch name, so the
  /// branch is named once and its state rides along.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.md,
        vertical: FwSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      // Capped: a Wrap hands its children unbounded width, so a chip carrying
      // a long branch name would run off the panel rather than wrap.
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: FwIconSize.xs, color: colors.mut),
              const Gap(FwSpacing.xs),
            ],
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: context.type.caption,
              ),
            ),
            if (detail case var it?) ...[
              const Gap(FwSpacing.sm),
              Text(
                it,
                style: context.type.caption.copyWith(color: colors.mut2),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
