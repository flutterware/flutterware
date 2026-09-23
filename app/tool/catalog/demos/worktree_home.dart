import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/run/handle.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/shell/worktree_home.dart';
import 'package:flutterware_app/src/ui/tappable.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/worktrees/facts.dart';

import 'command_palette.dart' show wrapInAppTheme;

/// The worktree home — the real [WorktreeHomeView], rendered from fixtures.
///
/// This began as a mock and the mock's conclusions are now the view's doc
/// comment; what remains here is the variant gallery: busy (every subject
/// present, the PR wanting attention), and quiet (the main checkout with
/// nothing to say, which must degrade to the plain header rather than a
/// field of empty labels).
///
/// The dev-stack strip is a stand-in: the real [DevStackBlock] owns a core
/// and a subprocess, and has its own demos (`dev_stack.dart`). Here only its
/// place in the composition is being judged, and the view takes the strip as
/// a widget for exactly this reason.
///
/// No Figma behind this — it is flutterware's own chrome.

@Preview(name: 'Busy', group: 'Worktree home', wrapper: wrapInAppTheme)
Widget homeBusy() => _wrap(
  WorktreeHomeView(
    _worktree(
      'dashboard-page-content-711c6c',
      branch: 'claude/dashboard-page-content-711c6c',
    ),
    facts: _busyFacts,
    runs: _busyRuns,
    now: _now,
    stackStrip: const _StandInStackStrip(),
    onOpenChanges: _noop,
    onOpenRun: _noop,
  ),
);

@Preview(name: 'Quiet', group: 'Worktree home', wrapper: wrapInAppTheme)
Widget homeQuiet() => _wrap(
  WorktreeHomeView(
    _worktree('flutterware', branch: 'master', isMain: true),
    facts: WorktreeFacts(git: Fact.fresh(GitFacts())),
    now: _now,
  ),
);

/// Work that exists only in the working tree: the dirty count takes the stat
/// slot — a number in the number slot, not a label wearing its clothes — and
/// the caption explains what is absent.
@Preview(
  name: 'Uncommitted only',
  group: 'Worktree home',
  wrapper: wrapInAppTheme,
)
Widget homeUncommitted() => _wrap(
  WorktreeHomeView(
    _worktree(
      'dashboard-page-content-711c6c',
      branch: 'claude/dashboard-page-content-711c6c',
    ),
    facts: WorktreeFacts(git: Fact.fresh(GitFacts(dirty: 3, base: 'master'))),
    runs: [_run('macos', 'macOS', age: const Duration(minutes: 12))],
    now: _now,
    onOpenChanges: _noop,
    onOpenRun: _noop,
  ),
);

/// Stale facts draw dimmed — the reading is shown, not trusted.
@Preview(name: 'Stale facts', group: 'Worktree home', wrapper: wrapInAppTheme)
Widget homeStale() => _wrap(
  WorktreeHomeView(
    _worktree(
      'dashboard-page-content-711c6c',
      branch: 'claude/dashboard-page-content-711c6c',
    ),
    facts: WorktreeFacts(
      git: Fact.stale(_busyGit),
      forge: Fact.stale(_busyForge),
    ),
    now: _now,
  ),
);

void main() => runApp(wrapInAppTheme(homeBusy()));

Widget _wrap(Widget child) => Builder(
  builder: (context) => ColoredBox(color: context.colors.bg, child: child),
);

void _noop() {}

// ─── Fixtures ────────────────────────────────────────────────────────────────

/// Fixed, so a screenshot of this entry is the same picture tomorrow.
final _now = DateTime(2026, 8, 19, 11, 30);

Worktree _worktree(String dir, {String? branch, bool isMain = false}) =>
    Worktree(
      path: isMain
          ? '/Users/x/projects/flutterware'
          : '/Users/x/claude_worktrees/flutterware/$dir',
      gitName: isMain ? null : dir,
      branch: branch,
      isMain: isMain,
    );

final _busyGit = GitFacts(
  ahead: 3,
  behind: 1,
  dirty: 3,
  base: 'master',
  changes: ChangeShape(
    files: 23,
    buckets: [
      ChangeBucket('app', added: 1240, removed: 312),
      ChangeBucket('docs', added: 208, removed: 0),
      ChangeBucket('lib', added: 96, removed: 22),
      ChangeBucket('test', added: 84, removed: 9),
    ],
  ),
);

final _busyForge = ForgeFacts(
  number: 78,
  title: 'The worktree home says where the work stands',
  state: PrState.open,
  checks: ChecksState.failing,
  failingChecks: 2,
  review: ReviewState.changesRequested,
  url: 'https://example.invalid/pull/78',
);

final _busyFacts = WorktreeFacts(
  git: Fact.fresh(_busyGit),
  forge: Fact.fresh(_busyForge),
);

RunReading _run(
  String device,
  String deviceName, {
  required Duration age,
  bool building = false,
}) => RunReading(
  RunHandle(
    worktree: '/Users/x/claude_worktrees/flutterware/dashboard-page-content',
    worktreeName: 'dashboard-page-content',
    device: device,
    deviceName: deviceName,
    entrypoint: 'lib/main_dev.dart',
    entrypointName: 'Studio (dev)',
    launcherPid: 4242,
    startedAt: _now.subtract(age),
    vmService: building ? null : 'ws://127.0.0.1:50505/ws',
  ),
  probe: building
      ? const RunProbe(app: false, launcher: true)
      : const RunProbe(app: true, launcher: true),
);

final _busyRuns = [
  _run('macos', 'macOS', age: const Duration(minutes: 12)),
  _run(
    'ABCD-1234',
    'iPhone 16 sim',
    age: const Duration(minutes: 4),
    building: true,
  ),
];

/// One line standing where [DevStackBlock]'s strip form stands, so the
/// composition can be judged whole without wiring a core to a scripted
/// subprocess — `dev_stack.dart` does that for the block itself.
class _StandInStackStrip extends StatelessWidget {
  const _StandInStackStrip();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: () {},
      borderRadius: BorderRadius.circular(context.radii.radius),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.lg,
          vertical: FwSpacing.md,
        ),
        decoration: BoxDecoration(
          color: colors.panel,
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(context.radii.radius),
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: colors.grn,
                shape: BoxShape.circle,
              ),
            ),
            const Gap(FwSpacing.md),
            Text('up', style: context.type.bodyStrong),
            const Gap(FwSpacing.lg),
            Expanded(
              child: Text(
                'http :8080  ·  db :5432',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.type.body.copyWith(color: colors.mut),
              ),
            ),
            const Gap(FwSpacing.sm),
            Icon(Icons.chevron_right, size: FwIconSize.md, color: colors.mut2),
          ],
        ),
      ),
    );
  }
}
