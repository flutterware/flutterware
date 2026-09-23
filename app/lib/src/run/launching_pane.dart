import 'package:material_ui/material_ui.dart';

import '../plugins/native/run_core.dart';
import '../ui/design/design.dart';
import '../ui/theme.dart';
import 'handle.dart';
import 'logs_tab.dart';

/// What a run looks like before it is one.
///
/// This is the state the cockpit spends the most user-visible time in and was
/// designed least for. It used to be a spinner, one word, and the launcher
/// log's *path* printed as selectable text under a doc comment claiming the
/// logs were being offered — so a consumer's first real launch showed one word
/// for ninety seconds while the tool wrote a page of narration into a file the
/// panel would not open.
///
/// Three things instead, in the order somebody asks for them:
///
/// * **Where it is**, from [LaunchLog.stage] — the tool's own words while a
///   progress span is open, and the milestone the log has passed when none is.
/// * **How long that has taken, against how long it usually takes.** A cold
///   build is allowed to be slow; what nobody can tell from a spinner is
///   whether *this* one has stopped being slow and started being stuck.
/// * **The log**, live, in the same [LogsTab] the run gets once it is up — so
///   `app.started` changes which tabs are open to you and nothing else.
class LaunchingPane extends StatelessWidget {
  const LaunchingPane({
    super.key,
    required this.core,
    required this.handle,
    required this.stage,
    required this.elapsed,
    required this.platform,
    this.onStopAndEdit,
  });

  final RunCore core;
  final RunHandle handle;

  /// Where the launch is — `LaunchLog.stage`, or the page's own fallback for a
  /// run with no log yet.
  final String stage;

  /// Since [RunHandle.startedAt]. Moves with the panel, which the probe loop
  /// rebuilds every second for as long as anything is starting.
  ///
  /// **Null when the run has not been probed yet**, and the expectation line
  /// goes with it. Before a probe answers, a handle that exists and has not
  /// been asked is indistinguishable from a build in flight — it may equally
  /// be an app that has been up for hours — and the one thing this pane must
  /// not do in that window is convert an unknown into `3h 12m in, longer than
  /// a cold build usually takes`.
  final Duration? elapsed;

  /// What this run is building for — `RunCore.platformOf`, which answers null
  /// rather than falling back to the device id.
  ///
  /// Named in the sentence so the number beside it is attributable, and left
  /// out of it when unknown: *a cold ios build* is worth saying and *a cold
  /// 575104B7-6AB9-42BA-82B6-351FC0DA2921 build* is not.
  final String? platform;

  /// Stops the run and lands on the launch form, primed with what this run was
  /// launched with.
  ///
  /// The move somebody makes when the log has just told them the flavor was
  /// wrong. Stop alone is in the header, where it acts on the run whichever
  /// pane is open; this is the one thing that page could not do, so it is the
  /// only button here. Null for a run this worktree does not own.
  final VoidCallback? onStopAndEdit;

  Duration get _budget => coldBuildBudget(platform);

  bool get _late => elapsed != null && elapsed! > _budget;

  /// The second line, or null when there is nothing honest to put in it.
  String? get _note {
    if (elapsed case var since?) {
      return _late
          ? '${_since(since)} in — longer than $_aColdBuild usually takes. '
                'Whatever it is waiting on is in the log below.'
          : '${_since(since)} in — $_aColdBuild usually finishes within '
                '${_since(_budget)}.';
    }
    return null;
  }

  String get _aColdBuild =>
      platform == null ? 'a cold build' : 'a cold $platform build';

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.lg,
            vertical: FwSpacing.md,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _late ? colors.amber : colors.mut2,
                ),
              ),
              const Gap(FwSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(stage, style: context.type.bodyStrong),
                    if (_note case var note?) ...[
                      const Gap(2),
                      Text(
                        note,
                        style: context.type.caption.copyWith(
                          color: _late ? colors.amber : colors.mut2,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onStopAndEdit case var stopAndEdit?) ...[
                const Gap(FwSpacing.md),
                TextButton(
                  onPressed: stopAndEdit,
                  child: const Text('Stop and edit'),
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        // The same pane it will have once it is up. Nothing switches under the
        // reader at `app.started` except the other four tabs coming alive.
        Expanded(
          child: LogsTab(core: core, handle: handle),
        ),
      ],
    );
  }
}

/// How long a cold build for [platform] usually takes, past which a launch is
/// worth remarking on.
///
/// Not a timeout and not a promise. Nothing is cancelled when it passes, and a
/// genuinely cold pub cache or Gradle daemon will pass it honestly. It is the
/// threshold at which *saying nothing* stops being the right thing to do: past
/// it, the tool and the reader are waiting politely at each other, and only one
/// of them knows there is a log.
///
/// Generous round numbers rather than measurements, and deliberately not
/// per-project. The figure worth having is this project's own last successful
/// launch, and nothing records one yet — see the design note.
///
/// An unknown platform takes the generous branch along with the slow ones. The
/// two ways to be wrong here are not symmetric: crying late at two minutes on
/// a build that had four to run teaches the reader to ignore the line, and
/// staying quiet for two minutes longer costs nothing they cannot see in the
/// log that is already on screen.
Duration coldBuildBudget(String? platform) => switch (platform) {
  'macos' || 'linux' || 'windows' || 'web' => const Duration(minutes: 2),
  _ => const Duration(minutes: 4),
};

/// `45s`, `2m 30s`, `12m` — an elapsed time, not an age.
///
/// `describeAge` is the other one and says `ago`, which is wrong for a
/// stopwatch that is still running.
String _since(Duration d) {
  if (d.inSeconds < 90) return '${d.inSeconds}s';
  var seconds = d.inSeconds % 60;
  return seconds == 0 ? '${d.inMinutes}m' : '${d.inMinutes}m ${seconds}s';
}
