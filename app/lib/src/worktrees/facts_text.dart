/// The explorer, rendered as text.
///
/// The third renderer of one model — the GUI's row, this, and `--json` — and
/// none of the three is privileged over the others. It lives here rather than
/// in `cli.dart` so it can be tested without a CLI, and so the columns stay
/// next to the facts they render.
library;

import 'package:flutterware/plugins.dart';

import '../shell/worktree.dart';
import '../plugins/native/dev_stack_results.dart';
import 'facts.dart';

/// One column of the table.
class _Column {
  const _Column(this.render);

  final String Function(WorktreeFacts facts, DateTime now) render;
}

/// The whole list, as lines.
///
/// One line per worktree, unlike the GUI's two. The row's second line is
/// evidence for its first; a terminal has no vertical pairing to make that
/// legible, so what survives is the answer. Dropped: the agent's last prompt and
/// the bucket split — texture, and neither decides anything.
///
/// A column every row leaves empty is not printed. A repo with no agents, a
/// machine with no `gh`, and an agent format that stopped parsing all produce
/// the same thing — a column of nothing — and the fix for all three is the same.
/// It is also what keeps this readable before the agent and forge providers
/// exist at all.
///
/// Widths come from the content. A branch name is what you would copy out of
/// this list and hand to `git`, so it is never truncated; sizing to the longest
/// one is what keeps the columns lined up anyway.
List<String> worktreeTable(
  List<(Worktree, WorktreeFacts)> rows, {
  required DateTime now,
}) {
  var columns = <_Column>[
    _Column((facts, _) => _dot(facts)),
    const _Column(_changesOf),
    const _Column(_stackOf),
    _Column(_agentOf),
    const _Column(_forgeOf),
    _Column(_whenOf),
  ];

  var names = [for (var (worktree, _) in rows) _name(worktree)];
  var cells = [
    for (var (index, (_, facts)) in rows.indexed)
      [names[index], for (var column in columns) column.render(facts, now)],
  ];

  var count = columns.length + 1;
  var used = [
    for (var i = 0; i < count; i++)
      cells.any((row) => row[i].trim().isNotEmpty),
  ];
  var widths = [
    for (var i = 0; i < count; i++)
      cells.fold(0, (max, row) => row[i].length > max ? row[i].length : max),
  ];

  return [
    for (var row in cells)
      [
        for (var i = 0; i < count; i++)
          if (used[i]) row[i].padRight(widths[i]),
      ].join('  ').trimRight(),
  ];
}

String _name(Worktree worktree) => worktree.branch ?? worktree.directoryName;

/// The aggregate, as the one character a terminal can spare for it.
String _dot(WorktreeFacts facts) => switch (facts.tone) {
  Tone.error => '✗',
  Tone.warn => '!',
  Tone.info => '●',
  Tone.good => '·',
  Tone.neutral => '',
};

String _changesOf(WorktreeFacts facts, DateTime now) {
  var fact = facts.git;
  if (fact.state == FactState.failed) return 'unreadable';
  var git = fact.value;
  if (git == null) return '';

  var shape = git.changes;
  var out = StringBuffer();
  if (shape == null || shape.isEmpty) {
    // A branch with no commits of its own, in a worktree full of edits, is
    // real and common — "in sync" would be true of the branch and a lie about
    // the worktree.
    out.write(git.dirty > 0 ? 'uncommitted' : 'in sync');
  } else {
    out.write('${shape.files}f +${shape.added} -${shape.removed}');
    if (git.dirty > 0) out.write(' ~${git.dirty}');
  }
  if (git.ahead > 0) out.write(' ^${git.ahead}');
  if (git.behind > 0) out.write(' v${git.behind}');
  return out.toString();
}

/// The stack, as a word and a port.
///
/// Shares the column-is-dropped-when-empty rule above, which is what keeps this
/// out of `fw worktrees` for the many repositories that declare no stack. What
/// it prints is deliberately the same vocabulary the GUI's cell uses — one set
/// of words for two renderers, so a terminal and a window never call the same
/// state different things.
String _stackOf(WorktreeFacts facts, DateTime now) {
  var reading = facts.stack.value;
  if (reading == null) return '';
  var count = reading.serviceCount;
  var word = switch (reading.state) {
    StackState.up when reading.isPartial => 'up ${count!.$1}/${count.$2}',
    StackState.up => 'up',
    StackState.down => 'down',
    StackState.starting => 'bringing up',
    StackState.stopping => 'tearing down',
    StackState.unavailable => "can't tell",
    StackState.unknown => '',
  };
  if (word.isEmpty) return '';
  var port = reading.services.map((s) => s.port).whereType<int>().firstOrNull;
  if (port != null && reading.state == StackState.up) word = '$word :$port';
  // The age only when it is old enough to doubt — the same rule the cell
  // follows, so the two agree about when a reading stops speaking for itself.
  var at = reading.at;
  if (facts.stack.isDim && at != null) word = '$word (${ago(at, now)})';
  return word;
}

String _agentOf(WorktreeFacts facts, DateTime now) {
  var agent = facts.agent.value;
  if (agent == null || agent.state == AgentState.none) return '';
  return switch (agent.state) {
    AgentState.waiting => 'waiting',
    AgentState.working => 'working',
    AgentState.idle => 'idle ${agent.at == null ? '' : ago(agent.at!, now)}',
    AgentState.none => '',
  }.trim();
}

String _forgeOf(WorktreeFacts facts, DateTime now) {
  var pr = facts.forge.value;
  if (pr == null) return '';
  var mark = switch (pr.checks) {
    ChecksState.failing => ' ✗',
    ChecksState.passing => ' ✓',
    ChecksState.pending => ' …',
    ChecksState.none => '',
  };
  var review = switch (pr.review) {
    ReviewState.changesRequested ||
    ReviewState.approved => ' ${pr.review.label}',
    // "A review is out with someone else" is not something you can act on, and
    // a terminal column is the place with the least room for what you cannot.
    ReviewState.awaiting || ReviewState.none => '',
  };
  var state = pr.state == PrState.open ? '' : ' ${pr.state.name}';
  return '#${pr.number}$mark$state$review';
}

String _whenOf(WorktreeFacts facts, DateTime now) {
  var activity = facts.activity.value;
  if (activity == null) return '';
  return '${ago(activity.at, now)} ${activity.sourceLabel}';
}

/// Coarse, and shared with the GUI's `when` column so the two never disagree
/// about what "4m" means.
String ago(DateTime then, DateTime now) {
  var d = now.difference(then);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}

/// The age [ago] would *print*, as a number — and the only thing the list may
/// be ordered by.
///
/// Two rows showing the same age must never swap places. Sorting by the raw
/// timestamp broke that: two agents working at once are both a few seconds old,
/// both render `now`, and their millisecond order changes every time either one
/// writes a line — so the list reshuffled every couple of seconds while saying
/// nothing had changed. The order was expressing a difference the row does not
/// show and the eye cannot use.
///
/// Ordering by what is displayed means the list can only move when a label
/// moves. It cannot be steadier than that without lying about freshness.
Duration coarseAge(DateTime then, DateTime now) {
  var d = now.difference(then);
  if (d.inMinutes < 1) return Duration.zero;
  if (d.inMinutes < 60) return Duration(minutes: d.inMinutes);
  if (d.inHours < 24) return Duration(hours: d.inHours);
  return Duration(days: d.inDays);
}

/// [coarseAge] for a whole worktree, oldest-last.
///
/// A worktree with no activity at all sorts to the end rather than to the top:
/// "never touched" is the opposite of "just touched", and a fresh clone full of
/// unknowns must not push the row you were in off the screen.
Duration activityAge(WorktreeFacts facts, DateTime now) {
  var at = facts.activity.value?.at;
  return at == null ? const Duration(days: 1000000) : coarseAge(at, now);
}
