import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/plugins.dart';

import '../plugins/worktree_session.dart';
import '../ui/theme.dart';
import 'plan.dart';
import 'remove_worktree.dart';
import 'runner.dart';

/// The "remove this worktree" checklist.
///
/// Two screens in one dialog, because they answer different questions and only
/// one of them is reversible: **the checklist**, where nothing has happened and
/// everything can be unticked, and **the run**, where rows are turning green
/// and the only remaining choice is what to do about a failure.
///
/// Returns true when the checkout was removed, so the caller can drop its tab —
/// and only then. A run that tore down a stack and then failed to remove the
/// directory has not removed the worktree, and a tab closing on it would be the
/// app disagreeing with the disk.
///
/// [prepare] runs with the dialog already on screen. Assembling a plan for an
/// unopened worktree costs a config subprocess, a facts refresh and a
/// warm-up of every plugin — seconds, during which the first version showed
/// nothing at all and the press looked ignored. Worse, the caller had to stay
/// mounted across that wait to show anything afterwards, and the thing it was
/// waiting on could unmount it. Opening first and preparing inside removes both:
/// the press is acknowledged immediately, and nothing outside this route can
/// take the dialog away.
Future<bool> showTeardownDialog(
  BuildContext context, {
  required Future<TeardownPreparation> Function() prepare,
  required String repositoryRoot,
  WorktreeRemover? remover,
}) async =>
    await showDialog<bool>(
      context: context,
      // The run cannot be interrupted by clicking away from it: half a teardown
      // is the one state nothing here knows how to describe.
      barrierDismissible: false,
      builder: (context) => _TeardownDialog(
        prepare: prepare,
        repositoryRoot: repositoryRoot,
        remover: remover,
      ),
    ) ??
    false;

/// What [showTeardownDialog] waits for: the plan, and the session its plugin
/// steps will be invoked through.
class TeardownPreparation {
  const TeardownPreparation(this.plan, this.session);

  final TeardownPlan plan;

  /// Null when the worktree could not be opened, in which case [plan] carries
  /// only what the shell knows on its own.
  final WorktreeSession? session;
}

class _TeardownDialog extends StatefulWidget {
  const _TeardownDialog({
    required this.prepare,
    required this.repositoryRoot,
    this.remover,
  });

  final Future<TeardownPreparation> Function() prepare;
  final String repositoryRoot;
  final WorktreeRemover? remover;

  @override
  State<_TeardownDialog> createState() => _TeardownDialogState();
}

class _TeardownDialogState extends State<_TeardownDialog> {
  final _ticked = <PlannedStep>{};
  var _deleteBranch = false;
  TeardownRunner? _runner;
  TeardownPreparation? _prepared;
  Object? _prepareError;

  TeardownPlan? get _plan => _prepared?.plan;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    TeardownPreparation prepared;
    try {
      prepared = await widget.prepare();
    } on Object catch (e) {
      if (mounted) setState(() => _prepareError = e);
      return;
    }
    if (!mounted) return;
    setState(() {
      _prepared = prepared;
      _ticked.addAll(prepared.plan.defaultSelection);
    });
  }

  Future<void> _start() async {
    var prepared = _prepared!;
    var runner = TeardownRunner(
      plan: prepared.plan,
      session: prepared.session,
      repositoryRoot: widget.repositoryRoot,
      selected: [
        for (var planned in prepared.plan.steps)
          if (_ticked.contains(planned)) planned,
      ],
      deleteBranch: _deleteBranch,
      remover: widget.remover,
      onFailure: _askAboutFailure,
    );
    setState(() => _runner = runner);
    runner.changes.listen((_) {
      if (mounted) setState(() {});
    });
    await runner.run();
    if (!mounted) return;
    setState(() {});
    // A clean run closes itself. One that failed or was aborted stays up: the
    // output is the only account of what happened, and dismissing it for the
    // user would throw that away.
    if (runner.removed && !runner.aborted) {
      Navigator.of(context).pop(true);
    }
  }

  Future<TeardownFailureChoice?> _askAboutFailure(
    TeardownProgress step,
  ) async => showDialog<TeardownFailureChoice>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text('${step.label} failed'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SelectableText(
          step.output.isEmpty ? 'It reported nothing.' : step.output,
          style: context.type.caption,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(TeardownFailureChoice.abort),
          child: const Text('Stop here'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(TeardownFailureChoice.skip),
          child: const Text('Skip and continue'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(TeardownFailureChoice.retry),
          child: const Text('Retry'),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _runner?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var plan = _plan;
    return AlertDialog(
      backgroundColor: colors.bg,
      title: Text(switch ((plan, _runner)) {
        (null, _) => 'Remove this worktree?',
        (var p?, null) => 'Remove “${p.worktree}”?',
        (var p?, _) => 'Removing “${p.worktree}”',
      }, style: context.type.heading),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: switch ((plan, _runner)) {
            _ when _prepareError != null => _Note(
              'Could not work out what this worktree is running: '
              '$_prepareError',
            ),
            (null, _) => const _Preparing(),
            (_, var runner?) => _run(context, runner),
            _ => _checklist(context, plan!),
          },
        ),
      ),
      actions: _actions(context),
    );
  }

  // ── the checklist ────────────────────────────────────────────────────────

  Widget _checklist(BuildContext context, TeardownPlan plan) {
    var type = context.type;
    var colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SelectableText(plan.path, style: type.caption),
        if (plan.branch case var branch?) ...[
          const Gap(FwSpacing.xs),
          Text(branch, style: type.caption),
        ],
        const Gap(FwSpacing.xl),

        for (var guard in plan.guards) ...[
          _GuardBanner(guard),
          const Gap(FwSpacing.md),
        ],

        if (!plan.sessionOpen) ...[
          _Note(
            'This worktree is not open, so nothing here knows what it is '
            'running. Open it first to see its stack and its apps.',
          ),
          const Gap(FwSpacing.md),
        ],

        if (!plan.isBlocked) ...[
          for (var phase in TeardownPhase.values)
            if (_stepsIn(phase) case var steps when steps.isNotEmpty) ...[
              const Gap(FwSpacing.md),
              Text(_phaseLabel(phase), style: type.fieldLabel),
              const Gap(FwSpacing.sm),
              for (var step in steps) _stepRow(context, step),
            ],

          const Gap(FwSpacing.xl),
          Text('FINALLY', style: type.fieldLabel),
          const Gap(FwSpacing.sm),
          // Locked: this is the thing the dialog is for, and a checklist whose
          // point can be unticked is a checklist that can be run for nothing.
          _Row(
            label: 'Remove the git worktree',
            // Says what it takes with it. The warning above is read once at the
            // top; this row is the one directly above the button, and it is
            // where "and my uncommitted files?" is actually asked.
            detail: plan.destroysUncommittedWork
                ? 'always last · deletes ${plan.uncommittedFiles} uncommitted '
                      '${plan.uncommittedFiles == 1 ? 'file' : 'files'} with it'
                : 'always last · cannot be unchecked',
            value: true,
            danger: plan.destroysUncommittedWork,
            onChanged: null,
          ),
          if (plan.branch case var branch?)
            _Row(
              label: 'Delete the branch $branch',
              detail: 'only if it is merged — git refuses otherwise',
              value: _deleteBranch,
              danger: true,
              onChanged: (value) =>
                  setState(() => _deleteBranch = value ?? false),
            ),
        ] else
          Text(
            'Nothing can be removed until the problems above are cleared.',
            style: type.body.copyWith(color: colors.mut),
          ),
      ],
    );
  }

  List<PlannedStep> _stepsIn(TeardownPhase phase) => [
    for (var planned in _plan!.steps)
      if (planned.step.phase == phase) planned,
  ];

  Widget _stepRow(BuildContext context, PlannedStep planned) => _Row(
    label: planned.step.label,
    detail: planned.step.detail,
    value: _ticked.contains(planned),
    danger: planned.step.danger,
    onChanged: planned.step.enabled
        ? (value) => setState(
            () =>
                value == true ? _ticked.add(planned) : _ticked.remove(planned),
          )
        : null,
  );

  static String _phaseLabel(TeardownPhase phase) => switch (phase) {
    TeardownPhase.apps => 'APPS',
    TeardownPhase.infra => 'INFRASTRUCTURE',
    TeardownPhase.cleanup => 'CLEANUP',
  };

  // ── the run ──────────────────────────────────────────────────────────────

  Widget _run(BuildContext context, TeardownRunner runner) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var step in runner.progress) ...[
          _ProgressRow(step),
          const Gap(FwSpacing.sm),
        ],
        if (runner.aborted) ...[
          const Gap(FwSpacing.md),
          _Note(
            runner.removed
                ? 'The worktree was removed, but not everything after it ran.'
                : 'Stopped before removing anything. The checkout is still '
                      'there.',
          ),
        ],
      ],
    );
  }

  // ── actions ──────────────────────────────────────────────────────────────

  List<Widget> _actions(BuildContext context) {
    var colors = context.colors;
    var runner = _runner;
    var plan = _plan;
    if (runner == null) {
      return [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: plan == null || plan.isBlocked ? null : _start,
          child: Text(
            _ticked.isEmpty ? 'Remove' : 'Tear down & remove',
            style: TextStyle(
              color: plan == null || plan.isBlocked ? colors.mut3 : colors.red,
            ),
          ),
        ),
      ];
    }
    var finished = runner.aborted || runner.removed;
    return [
      TextButton(
        onPressed: finished
            ? () => Navigator.of(context).pop(runner.removed)
            : null,
        child: const Text('Close'),
      ),
    ];
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.detail,
    required this.value,
    required this.danger,
    required this.onChanged,
  });

  final String label;
  final String? detail;
  final bool value;
  final bool danger;
  final ValueChanged<bool?>? onChanged;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var type = context.type;
    var enabled = onChanged != null;
    return InkWell(
      onTap: enabled ? () => onChanged!(!value) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: FwSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: value,
                onChanged: onChanged,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const Gap(FwSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: type.body.copyWith(
                      // Danger wins over locked. The removal row is both — it
                      // cannot be unticked *and* it is the destructive one —
                      // and drawing it muted made the point of the dialog look
                      // like the row you were least meant to read.
                      color: danger
                          ? colors.red
                          : !enabled
                          ? colors.mut
                          : colors.ink,
                    ),
                  ),
                  if (detail case var detail?)
                    Text(detail, style: type.caption),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressRow extends StatelessWidget {
  const _ProgressRow(this.step);

  final TeardownProgress step;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var type = context.type;
    var (glyph, color) = switch (step.outcome) {
      TeardownOutcome.pending => ('○', colors.mut3),
      TeardownOutcome.running => ('◐', colors.amber),
      TeardownOutcome.done => ('✓', colors.grn),
      TeardownOutcome.failed => ('✕', colors.red),
      TeardownOutcome.skipped => ('–', colors.mut3),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 20,
          child: Text(glyph, style: type.body.copyWith(color: color)),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                step.label,
                style: type.body.copyWith(
                  color: step.outcome == TeardownOutcome.skipped
                      ? colors.mut
                      : colors.ink,
                ),
              ),
              // The output only when it failed. A successful step's chatter is
              // noise between the reader and the one row that did not work.
              if (step.outcome == TeardownOutcome.failed &&
                  step.output.isNotEmpty)
                SelectableText(
                  step.output,
                  style: type.caption.copyWith(color: colors.red),
                )
              else if (step.detail case var detail?)
                Text(detail, style: type.caption),
            ],
          ),
        ),
      ],
    );
  }
}

class _GuardBanner extends StatelessWidget {
  const _GuardBanner(this.guard);

  final Guard guard;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var blocking = guard.level == GuardLevel.block;
    var tint = blocking ? colors.red : colors.amber;
    return Container(
      padding: const EdgeInsets.all(FwSpacing.lg),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.09),
        border: Border.all(color: tint.withValues(alpha: 0.28)),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            blocking ? Icons.block : Icons.warning_amber_rounded,
            size: FwIconSize.md,
            color: tint,
          ),
          const Gap(FwSpacing.md),
          Expanded(
            child: Text(
              guard.reason,
              style: context.type.caption.copyWith(
                color: blocking ? colors.red : colors.warningText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: context.type.caption.copyWith(color: context.colors.mut),
  );
}

/// While the plan is being worked out.
///
/// Says what is being waited on rather than spinning silently: opening a
/// worktree that was closed runs its config, and a checklist that appeared
/// instantly with nothing in it would be a lie about a checkout it had not
/// looked at yet.
class _Preparing extends StatelessWidget {
  const _Preparing();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const SizedBox.square(
        dimension: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      const Gap(FwSpacing.lg),
      Expanded(
        child: Text(
          'Reading what this checkout is running…',
          style: context.type.body.copyWith(color: context.colors.mut),
        ),
      ),
    ],
  );
}
