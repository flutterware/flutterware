import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../plugins/native/dev_stack_core.dart';
import '../plugins/native/dev_stack_plugin.dart';
import '../plugins/native/dev_stack_results.dart';
import '../ui/action_button.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';

/// Which surface is drawing the stack.
///
/// Not a density flag: the two are different chrome around the same sentence.
/// A [strip] is a line on a screen about something else; a [band] is the header
/// of the screen about the stack.
enum DevStackForm {
  /// The worktree overview — one tinted line, and the line is the way in.
  strip,

  /// The plugin panel's header — the same answer at panel width, with the
  /// provenance the overview has no room for.
  band,
}

/// The stack's state, as one widget with two forms.
///
/// One widget, two homes. The worktree home mounts the [DevStackForm.strip]
/// so "is my stack up" costs no navigation, and the panel mounts the
/// [DevStackForm.band] above its services, commands and console. Sharing the
/// widget is what stops the two from disagreeing — a second rendering of a state
/// machine is a second set of six states to keep right — so the forms differ
/// only in chrome. Every word and every colour comes from the same methods.
///
/// It owns the subscription: mounting starts polling, unmounting stops it. That
/// is why [DevStackCore.watch] is reference-counted rather than a one-way
/// `track()` — this is a subprocess every ten seconds, and a worktree nobody is
/// looking at should not pay for one.
///
/// ## The layout, and what it is answering
///
/// See `docs/superpowers/specs/2026-08-11-dev-stack-ui-study.md` for the six
/// rules — one word one colour, answer before evidence, anatomical constancy,
/// the safe direction gets the weight — and
/// `2026-08-12-dev-stack-ui-study-2.md` for the pass that turned the card into
/// a strip. Two rules were added there:
///
/// - **The tint is the frame.** State was carried by a 3px rail against neutral
///   chrome, and the card existed mostly to give the rail an edge to be. A wash
///   of the state's own tone reads from across the desk and needs no card, so
///   142px of overview became 40.
/// - **A glance surface may only carry controls whose result is visible on it.**
///   The block used to promote the project's first argument-less command — in
///   practice `Logs` — to a link beside `Tear down`. Pressing it ran the command
///   and printed the output into the *panel*, a screen you were not on, so the
///   button read as doing nothing. Commands live in the panel now, next to the
///   console they write to.
class DevStackBlock extends StatefulWidget {
  const DevStackBlock(
    this.plugin, {
    super.key,
    this.form = DevStackForm.band,
    this.onOpenPanel,
  });

  final DevStackPlugin plugin;

  final DevStackForm form;

  /// Navigates to this plugin's panel. On a [DevStackForm.strip] the whole line
  /// is this, and the chevron says so; null for a caller with no shell, which
  /// then draws a line that is not a link rather than a link that does nothing.
  final VoidCallback? onOpenPanel;

  @override
  State<DevStackBlock> createState() => _DevStackBlockState();
}

/// How wide the strip is allowed to get.
///
/// A card has a reading width the same way a paragraph does. Left to fill a
/// maximised window it stretched to eleven hundred pixels, which put the
/// `Tear down` button most of a screen away from the `up` it belongs to — the
/// two halves of one statement, too far apart to be read as one.
const _maxWidth = 720.0;

/// The panel's content column, shared by every band of it.
///
/// One right edge for the whole page. The header's controls, a service's
/// state, a command's `Run` and the console's `Copy` are all trailing content,
/// and they were landing on three different edges because the sections capped
/// their width and the full-bleed bands did not. Whichever number is right, it
/// has to be the same number, so it is one widget rather than a constant three
/// files agree to remember.
class DevStackColumn extends StatelessWidget {
  const DevStackColumn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: ConstrainedBox(
      // Through an [Align], because a stretched column hands its children a
      // tight width and a bare [ConstrainedBox] would have that width enforced
      // right back over it.
      constraints: const BoxConstraints(maxWidth: 1040),
      child: child,
    ),
  );
}

class _DevStackBlockState extends State<DevStackBlock> {
  DevStackCore get _core => widget.plugin.core;

  /// Redraws the elapsed seconds during a transition, and nothing else.
  ///
  /// Runs only while something is in flight: a stack sitting `up` has no
  /// second-by-second fact to report, and a timer that ticks anyway is a
  /// rebuild per second per open worktree forever.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _core.watch();
    widget.plugin.addListener(_syncTicker);
    _syncTicker();
  }

  @override
  void didUpdateWidget(DevStackBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.plugin != widget.plugin) {
      oldWidget.plugin
        ..core.unwatch()
        ..removeListener(_syncTicker);
      _core.watch();
      widget.plugin.addListener(_syncTicker);
      _syncTicker();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    widget.plugin.removeListener(_syncTicker);
    _core.unwatch();
    super.dispose();
  }

  void _syncTicker() {
    var wanted = _core.busy != null;
    if (wanted == (_tick != null)) return;
    _tick?.cancel();
    _tick = wanted
        ? Timer.periodic(const Duration(seconds: 1), (_) {
            if (mounted) setState(() {});
          })
        : null;
  }

  /// Asks first, and only for a stop the project marked as destructive.
  ///
  /// The dialog says what is lost rather than "are you sure", which adds
  /// nothing the reader did not already know.
  Future<void> _stop() async {
    if (!_core.stopIsDestructive) {
      await _core.stop();
      return;
    }
    var confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Tear down ${_core.label}?'),
        content: const Text(
          'This project marks its stop command as destroying data. Containers '
          'and their volumes go with it, and the next bring-up starts from '
          'empty.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Tear down',
              style: TextStyle(color: context.colors.red),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) await _core.stop();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.plugin,
    builder: (context, _) => switch (widget.form) {
      DevStackForm.strip => _strip(context, _shownState()),
      DevStackForm.band => _band(context, _shownState()),
    },
  );

  // ── the strip ────────────────────────────────────────────────────────────

  /// One line: the answer, the evidence that still fits, the one control that
  /// changes what the line says, and the way in.
  Widget _strip(BuildContext context, StackState state) {
    var colors = context.colors;
    var tone = _tone(colors, state);
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxWidth),
        child: Tappable(
          onTap: widget.onOpenPanel,
          borderRadius: BorderRadius.circular(context.radii.radius),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.lg,
              vertical: FwSpacing.md,
            ),
            decoration: BoxDecoration(
              color: tone == null ? colors.panel : colors.statusFill(tone),
              border: Border.all(
                color: tone == null ? colors.line : colors.statusBorder(tone),
              ),
              borderRadius: BorderRadius.circular(context.radii.radius),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _stripLine(context, state),
                // The one state that is allowed a second line. A failure
                // ellipsised at 200px is a failure nobody can act on, and the
                // height is spent on the day it buys something rather than
                // every day.
                if (_failure(state) case var failure?) ...[
                  const Gap(FwSpacing.xs),
                  Padding(
                    padding: const EdgeInsets.only(left: 8 + FwSpacing.md),
                    child: Text(
                      failure,
                      style: context.type.caption.copyWith(color: colors.red),
                    ),
                  ),
                ],
                if (state.isMoving) ...[
                  const Gap(FwSpacing.md),
                  _progress(context),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stripLine(BuildContext context, StackState state) {
    var colors = context.colors;
    var type = context.type;
    return Row(
      children: [
        _StateDot(state, muted: _isUnconfirmed),
        const Gap(FwSpacing.md),
        Text(
          _word(state),
          style: type.bodyStrong.copyWith(
            color: _isUnconfirmed ? colors.mut2 : _wordColor(colors, state),
          ),
        ),
        const Gap(FwSpacing.lg),
        // One run of text rather than three laid-out slots, so it truncates in
        // priority order — the services go before the detail, and the detail
        // before the name.
        Expanded(
          child: Text.rich(
            TextSpan(children: _summary(context, state)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const Gap(FwSpacing.lg),
        ..._controls(context, state),
        if (widget.onOpenPanel != null) ...[
          const Gap(FwSpacing.sm),
          Icon(Icons.chevron_right, size: FwIconSize.md, color: colors.mut2),
        ],
      ],
    );
  }

  /// The name, what makes the state actionable, and what is under it — in the
  /// order you would drop them.
  List<InlineSpan> _summary(BuildContext context, StackState state) {
    var colors = context.colors;
    var type = context.type;
    var detail = _detail(context, state);
    var services = _serviceLine();
    var parts = <InlineSpan>[
      if (_core.label != 'Dev stack')
        TextSpan(text: _core.label, style: type.body),
      // A failure has its own line; repeating it here would spend the whole
      // width saying the same thing twice.
      if (detail != null && _failure(state) == null)
        TextSpan(
          text: detail.$1,
          style: type.body.copyWith(color: detail.$2),
        ),
      if (services != null)
        TextSpan(
          text: services,
          style: type.caption.copyWith(color: colors.mut2),
        ),
    ];
    var separator = TextSpan(
      text: '  ·  ',
      style: type.caption.copyWith(color: colors.mut3),
    );
    return [
      for (var (i, part) in parts.indexed) ...[if (i > 0) separator, part],
    ];
  }

  /// `http :8080 · db :5432` — what is under the stack, at glance width.
  ///
  /// Deliberately one muted run with no per-service tone: the headline already
  /// says `up, 1 of 2` when they disagree, and colouring names here would put a
  /// second tone colour on a line whose whole design is that there is one. The
  /// per-service breakdown is a table on the panel.
  String? _serviceLine() {
    var services = _core.reading.services;
    if (services.isEmpty) return null;
    return [
      for (var service in services)
        service.port == null
            ? service.name
            : '${service.name} :${service.port}',
    ].join(' · ');
  }

  // ── the band ─────────────────────────────────────────────────────────────

  /// The panel's header: the same answer, at panel width.
  ///
  /// Shaped after the Run cockpit's header — name in ink, facts muted beneath,
  /// controls flush right — because they are the same kind of screen and were
  /// arriving at it differently.
  Widget _band(BuildContext context, StackState state) {
    var colors = context.colors;
    var type = context.type;
    var tone = _tone(colors, state);
    var detail = _detail(context, state);
    var failure = _failure(state);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xxxl,
        vertical: FwSpacing.xl,
      ),
      decoration: BoxDecoration(
        color: tone == null ? colors.panel : colors.statusFill(tone),
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: DevStackColumn(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              // Centred against the whole block, the way the Run cockpit's
              // header sets its controls: aligned to the *top* they hang off
              // the title line and leave the second line unbalanced beneath
              // them, and the link and the button — different heights — do not
              // even agree with each other.
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          _StateDot(state, muted: _isUnconfirmed),
                          const Gap(FwSpacing.md),
                          Flexible(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              // The name is 16px and the state word 13px, so
                              // they sit on one baseline rather than centred on
                              // each other's boxes. The dot stays out of this
                              // row — a circle has no baseline to sit on.
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                Flexible(
                                  child: Text(
                                    _core.label,
                                    style: type.heading,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const Gap(FwSpacing.md),
                                Text(
                                  _word(state),
                                  style: type.bodyStrong.copyWith(
                                    color: _isUnconfirmed
                                        ? colors.mut2
                                        : _wordColor(colors, state),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Gap(FwSpacing.xs),
                      Padding(
                        // Hangs under the name rather than under the dot, so
                        // the two lines read as one statement.
                        padding: const EdgeInsets.only(left: 8 + FwSpacing.md),
                        child: Text(
                          [
                            if (failure == null && detail != null) detail.$1,
                            ?_core.declaredDirectory,
                            // A stale reading has already said its age in the
                            // detail — `last seen 1m ago · checking now` — and
                            // repeating it as `checked 1m ago` reads as two
                            // different facts about the same probe.
                            if (!_isUnconfirmed) _freshness(),
                          ].join(' · '),
                          style: type.caption,
                        ),
                      ),
                      if (failure != null) ...[
                        const Gap(FwSpacing.xs),
                        Padding(
                          padding: const EdgeInsets.only(
                            left: 8 + FwSpacing.md,
                          ),
                          child: Text(
                            failure,
                            style: type.caption.copyWith(color: colors.red),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const Gap(FwSpacing.lg),
                ..._controls(context, state),
              ],
            ),
            if (state.isMoving) ...[
              const Gap(FwSpacing.lg),
              _progress(context),
            ],
          ],
        ),
      ),
    );
  }

  String _freshness() {
    var age = stackAge(_core.reading.at);
    if (age == null) return _core.isProbing ? 'checking…' : 'never checked';
    return 'checked $age, every ${_core.pollInterval.inSeconds}s';
  }

  // ── shared parts ─────────────────────────────────────────────────────────

  Widget _progress(BuildContext context) {
    var colors = context.colors;
    return ClipRRect(
      borderRadius: BorderRadius.circular(context.radii.micro),
      child: LinearProgressIndicator(
        minHeight: 3,
        backgroundColor: colors.statusBorder(colors.amber),
        color: colors.amber,
      ),
    );
  }

  /// `Check now`, then the control that changes the state. Never a project
  /// command — see the class comment.
  ///
  /// The strip offers the re-check only when the *reading* is the problem — the
  /// probe failed, or what we hold is history — because that is when re-reading
  /// is the next move, and a glance line has no room for a control that is
  /// rarely the answer. The panel offers it always: it is the screen you open
  /// when you doubt what the other one said.
  List<Widget> _controls(BuildContext context, StackState state) {
    var busy = _core.busy != null;
    var primary = _primary(state);
    return [
      if (widget.form == DevStackForm.band ||
          state == StackState.unavailable ||
          _isUnconfirmed) ...[
        _Link(
          'Check now',
          enabled: !busy,
          onTap: () => unawaited(_core.refresh()),
        ),
        if (primary != null) const Gap(FwSpacing.lg),
      ],
      ?primary,
    ];
  }

  /// The control that changes the state, or null when the project declared
  /// none — a stack this machine only observes gets a status and no buttons,
  /// which is a complete declaration rather than a degraded one.
  Widget? _primary(StackState state) {
    // A reading nobody has confirmed this session is history, and acting on
    // history is what the muted rendering is warning about. The probe lands in
    // a moment; until it does, both directions are off.
    var off = _core.busy != null || _isUnconfirmed;
    if (state.isMoving) {
      return FwActionButton(
        label: state == StackState.starting ? 'Bringing up' : 'Tearing down',
        onPressed: null,
      );
    }
    if (state == StackState.up) {
      if (!_core.canStop) return null;
      return FwActionButton(
        label: 'Tear down',
        tooltip: _core.stopIsDestructive
            ? 'Asks first — this destroys data'
            : null,
        onPressed: off ? null : _stop,
      );
    }
    if (!_core.canStart) return null;
    // Down, unknown and unavailable all offer the same control, deliberately:
    // after a failed probe the useful move is to try, and the command's own
    // error explains more than a disabled button does. Only `down` fills it —
    // when we cannot tell, an emphatic button would be promising an outcome
    // nothing has checked.
    return FwActionButton(
      label: 'Bring up',
      primary: state == StackState.down,
      onPressed: off ? null : () => _core.start(),
    );
  }

  /// What to show, which is not always what the last probe said — a transition
  /// in flight wins, because during those seconds the probe is the stale one.
  StackState _shownState() => switch (_core.busy) {
    'start' => StackState.starting,
    'stop' => StackState.stopping,
    _ => _core.reading.state,
  };

  /// True while what is on screen is history rather than a confirmed state: a
  /// cache read at startup, or nothing at all. Drawn muted, with controls off,
  /// for the half-second until the first probe of the session lands.
  bool get _isUnconfirmed =>
      _core.busy == null && (!_core.reading.isKnown || _core.isStale);

  /// The probe's own words about why it cannot be believed, or null.
  String? _failure(StackState state) => state == StackState.unavailable
      ? (_core.reading.failure ?? 'the check could not be run')
      : null;

  String _word(StackState state) {
    var reading = _core.reading;
    return switch (state) {
      StackState.unknown => _core.isProbing ? 'checking' : 'not checked',
      StackState.down => 'down',
      StackState.starting => 'bringing up',
      StackState.up when reading.isPartial =>
        'up, ${reading.serviceCount!.$1} of ${reading.serviceCount!.$2}',
      StackState.up => 'up',
      StackState.stopping => 'tearing down',
      StackState.unavailable => "can't tell",
    };
  }

  /// The one fact that makes the state actionable — the address when up, the
  /// reason when down, the clock during a transition.
  (String, Color)? _detail(BuildContext context, StackState state) {
    var colors = context.colors;
    var reading = _core.reading;
    if (state.isMoving) {
      var seconds = _core.busyFor?.inSeconds ?? 0;
      return ('${seconds}s elapsed', colors.mut);
    }
    if (state == StackState.unavailable) {
      return (reading.failure ?? 'the check could not be run', colors.red);
    }
    if (!reading.isKnown) {
      return (
        _core.isProbing ? 'running the first check…' : 'no reading yet',
        colors.mut,
      );
    }
    if (_core.isStale) {
      var age = stackAge(reading.at);
      return (
        [
          if (age != null) 'last seen $age',
          if (_core.isProbing) 'checking now',
        ].join(' · '),
        colors.mut,
      );
    }
    var detail = reading.detail?.trim();
    if (detail == null || detail.isEmpty) return null;
    return (detail, colors.mut);
  }

  Color _wordColor(FwPalette colors, StackState state) => switch (state) {
    StackState.up => colors.grn,
    StackState.starting || StackState.stopping => colors.amber,
    StackState.unavailable => colors.red,
    _ => colors.ink2,
  };

  /// The tone the surface is washed with, or null for a state that gets none.
  ///
  /// Down is not a fault and does not get a colour — a checkout you are not
  /// working in *should* have its stack down, and a tinted overview is a tinted
  /// overview whether or not anything is wrong.
  Color? _tone(FwPalette colors, StackState state) => switch (state) {
    StackState.up => _core.reading.isPartial ? colors.amber : colors.grn,
    StackState.starting || StackState.stopping => colors.amber,
    StackState.unavailable => colors.red,
    _ => null,
  };
}

class _StateDot extends StatelessWidget {
  const _StateDot(this.state, {this.muted = false});

  final StackState state;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var color = switch (state) {
      StackState.up => colors.grn,
      StackState.starting || StackState.stopping => colors.amber,
      StackState.unavailable => colors.red,
      StackState.down => colors.mut3,
      StackState.unknown => colors.mut3,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: muted ? colors.mut3 : color,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// A text control that admits to being one.
///
/// The first draft set these as plain ink at body size, which is the same
/// treatment as the sentence above them — you found out they were buttons by
/// hovering. The rule underneath is the second finding of the study: an
/// affordance you have to discover is not an affordance.
class _Link extends StatelessWidget {
  const _Link(this.label, {this.enabled = true, required this.onTap});

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: FwSpacing.xxs),
        child: Container(
          decoration: BoxDecoration(
            // [mut3], not a hairline: this link sits on a tinted band as often
            // as on white, and a line2 underline vanishes into the wash — an
            // affordance you have to hover for is not one.
            border: Border(
              bottom: BorderSide(color: enabled ? colors.mut3 : colors.line),
            ),
          ),
          child: Text(
            label,
            style: context.type.caption.copyWith(
              color: enabled ? colors.ink2 : colors.mut3,
            ),
          ),
        ),
      ),
    );
  }
}
