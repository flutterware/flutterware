/// What the explorer knows about one worktree, all of it plain data.
///
/// Deliberately not a `WorktreeSession`. A session exists only while a worktree
/// is open, because it costs a config subprocess; these facts are shell-owned
/// probes that never run project code, so they read the same for a checkout
/// that has never been opened. That split is what makes a screen listing *every*
/// worktree possible at all.
///
/// No Flutter in this file: `fw worktrees` renders the same values, and
/// `test/utils/entry_point_purity_test.dart` holds us to it.
library;

import 'package:flutterware/plugins.dart';

import '../plugins/native/dev_stack_results.dart';

/// How much a [Fact] is worth believing.
enum FactState {
  /// Never computed. The first launch, before anything is cached.
  unknown,

  /// A previous value, being refreshed or past its TTL. Shown, dimmed.
  stale,

  fresh,

  /// The probe ran and broke. Transient — retried on the next refresh.
  failed,

  /// There is nothing here to know, and there never will be. No `gh`
  /// installed, no remote, no agent session for this checkout.
  ///
  /// Distinct from [failed] on purpose: collapsing the two gives a red cell
  /// that never clears and that the user cannot act on. This one draws a quiet
  /// dash and is never retried on a schedule.
  unavailable,
}

/// One observation, carrying its own provenance.
class Fact<T> {
  const Fact._(
    this.state, {
    this.value,
    this.computedAt,
    this.validityKey,
    this.failure,
  });

  const Fact.unknown() : this._(FactState.unknown);

  const Fact.unavailable([String? reason])
    : this._(FactState.unavailable, failure: reason);

  const Fact.failed(String failure)
    : this._(FactState.failed, failure: failure);

  const Fact.fresh(T value, {DateTime? computedAt, String? validityKey})
    : this._(
        FactState.fresh,
        value: value,
        computedAt: computedAt,
        validityKey: validityKey,
      );

  const Fact.stale(T value, {DateTime? computedAt, String? validityKey})
    : this._(
        FactState.stale,
        value: value,
        computedAt: computedAt,
        validityKey: validityKey,
      );

  final FactState state;
  final T? value;
  final DateTime? computedAt;

  /// What this value was computed from. The refresh recomputes *this* first —
  /// it is cheap — and only re-runs the probe when it moved.
  final String? validityKey;

  /// Why it is [FactState.failed], or why it is [FactState.unavailable].
  final String? failure;

  bool get hasValue => value != null;

  /// Whether the row should dim this cell rather than trust it.
  bool get isDim => state == FactState.stale;

  /// [encode] rather than a `toJson` on `T`, so a fact can wrap a type that has
  /// no opinion about JSON — which is most of them.
  Map<String, Object?> toJson(Object? Function(T value) encode) => {
    'state': state.name,
    if (value case var v?) 'value': encode(v),
    'computedAt': ?computedAt?.toIso8601String(),
    'failure': ?failure,
  };
}

/// Where a branch's lines landed, bucketed by top-level directory.
///
/// The row draws this as a bar; `fw worktrees` prints it as percentages. It is
/// data rather than a widget for exactly that reason.
class ChangeShape {
  const ChangeShape({required this.buckets, required this.files});

  final List<ChangeBucket> buckets;
  final int files;

  int get added => buckets.fold(0, (sum, b) => sum + b.added);
  int get removed => buckets.fold(0, (sum, b) => sum + b.removed);
  int get lines => added + removed;

  bool get isEmpty => buckets.isEmpty;

  Map<String, Object?> toJson() => {
    'files': files,
    'buckets': [
      for (var b in buckets) [b.name, b.added, b.removed],
    ],
  };

  static ChangeShape fromJson(Map<String, Object?> json) => ChangeShape(
    files: json['files']! as int,
    buckets: [
      for (var entry in json['buckets']! as List)
        ChangeBucket(
          (entry as List)[0]! as String,
          added: entry[1]! as int,
          removed: entry[2]! as int,
        ),
    ],
  );

  /// Largest first — the row names the top two and the bar draws in this order.
  List<ChangeBucket> get ranked =>
      [...buckets]..sort((a, b) => b.lines.compareTo(a.lines));
}

class ChangeBucket {
  const ChangeBucket(this.name, {required this.added, required this.removed});

  /// A top-level directory: `lib`, `app`, `docs`, or `·` for repo-root files.
  final String name;
  final int added;
  final int removed;

  int get lines => added + removed;
}

/// Everything git says, minus the working tree's own clock.
class GitFacts {
  const GitFacts({
    this.ahead = 0,
    this.behind = 0,
    this.dirty = 0,
    this.changes,
    this.base,
  });

  final int ahead;
  final int behind;

  /// Modified plus untracked, from `status --porcelain=v2`. Uncommitted work is
  /// a different question from branch size, so it is a different number.
  final int dirty;

  /// The branch diff against [base]. Null when there is nothing to diff —
  /// the main checkout, or a branch that has not left its base.
  final ChangeShape? changes;

  final String? base;

  bool get isInSync => (changes?.isEmpty ?? true) && ahead == 0 && behind == 0;

  Map<String, Object?> toJson() => {
    'ahead': ahead,
    'behind': behind,
    'dirty': dirty,
    'base': ?base,
    'changes': ?changes?.toJson(),
  };
}

enum AgentState {
  /// No session file for this checkout.
  none,

  working,

  /// The last record is the agent's, so the next move is yours.
  waiting,

  idle,
}

/// A coding agent's session, read from files on disk.
///
/// File-only, and it cannot be more than that. Nothing here distinguishes
/// "the agent is running" from "the agent was killed mid-turn" — a stale
/// [AgentState.working] decays to [AgentState.idle] by age. Do not read the
/// working state as a liveness guarantee.
class AgentFacts {
  const AgentFacts({
    required this.state,
    this.title,
    this.lastPrompt,
    this.at,
    this.model,
  });

  final AgentState state;

  /// The session's own title. Feeds the row's label-priority stack, which is
  /// why the agent cell does not show it again.
  final String? title;

  /// The last thing it was asked — "what is it doing", which is the one thing
  /// available nowhere else in the app.
  final String? lastPrompt;

  final DateTime? at;
  final String? model;

  Map<String, Object?> toJson() => {
    'state': state.name,
    'title': ?title,
    'lastPrompt': ?lastPrompt,
    'at': ?at?.toIso8601String(),
    'model': ?model,
  };
}

enum PrState { open, draft, merged, closed }

enum ChecksState { none, pending, passing, failing }

/// Where the review stands — **for a pull request you opened**.
///
/// Which every pull request in this list is: a worktree is a branch you are
/// working on. So the question is never "should I review this" but "is somebody
/// waiting on me", and [changesRequested] is the only value that means yes.
enum ReviewState {
  /// Nothing has been reviewed, and nothing is waiting on a review.
  none,

  /// A review is required or requested, and the ball is in someone else's
  /// court.
  awaiting,

  /// Somebody asked for changes. Yours.
  changesRequested,

  approved;

  /// One vocabulary for three renderers, so the row, the table and the detail
  /// panel never call the same state by different names.
  String get label => switch (this) {
    ReviewState.none => '',
    ReviewState.awaiting => 'in review',
    ReviewState.changesRequested => 'changes asked',
    ReviewState.approved => 'approved',
  };
}

class ForgeFacts {
  const ForgeFacts({
    required this.number,
    required this.title,
    required this.state,
    this.checks = ChecksState.none,
    this.failingChecks = 0,
    this.review = ReviewState.none,
    this.url,
  });

  final int number;
  final String title;
  final PrState state;
  final ChecksState checks;
  final int failingChecks;
  final ReviewState review;
  final String? url;

  Map<String, Object?> toJson() => {
    'number': number,
    'title': title,
    'state': state.name,
    'checks': checks.name,
    if (failingChecks > 0) 'failingChecks': failingChecks,
    if (review != ReviewState.none) 'review': review.name,
    'url': ?url,
  };

  /// Read back from the cache — the one fact worth persisting, because it is
  /// the one that cost a network round trip. Tolerant of a file written by a
  /// version that spelled things differently: anything unrecognised reads as
  /// the quiet value.
  static ForgeFacts fromJson(Map<String, Object?> json) => ForgeFacts(
    number: json['number']! as int,
    title: json['title'] as String? ?? '',
    state: PrState.values.firstWhere(
      (s) => s.name == json['state'],
      orElse: () => PrState.open,
    ),
    checks: ChecksState.values.firstWhere(
      (s) => s.name == json['checks'],
      orElse: () => ChecksState.none,
    ),
    failingChecks: json['failingChecks'] as int? ?? 0,
    review: ReviewState.values.firstWhere(
      (s) => s.name == json['review'],
      orElse: () => ReviewState.none,
    ),
    url: json['url'] as String?,
  );
}

/// Which clock won.
enum ActivitySource {
  commit,
  agent,

  /// You opened this worktree in flutterware. Shell-local state.
  opened,
}

/// Freshness, and *why* — the two are one fact.
///
/// "Last touched" is at least three clocks that disagree, so the explorer takes
/// the max and says which one it took. A bare relative time that silently means
/// something different per row is worse than no time at all.
class ActivityFacts {
  const ActivityFacts({required this.at, required this.source});

  final DateTime at;
  final ActivitySource source;

  String get sourceLabel => switch (source) {
    ActivitySource.commit => 'commit',
    ActivitySource.agent => 'agent',
    ActivitySource.opened => 'opened',
  };

  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    'source': source.name,
  };
}

/// Every fact about one worktree, however well known.
class WorktreeFacts {
  const WorktreeFacts({
    this.git = const Fact.unknown(),
    this.agent = const Fact.unknown(),
    this.forge = const Fact.unknown(),
    this.activity = const Fact.unknown(),
    this.stack = const Fact.unknown(),
  });

  final Fact<GitFacts> git;
  final Fact<AgentFacts> agent;
  final Fact<ForgeFacts> forge;
  final Fact<ActivityFacts> activity;

  /// What this checkout's dev stack was last seen doing.
  ///
  /// The one fact here the shell does not compute. Everything else on this
  /// screen is a git call or a file the shell itself wrote; a stack's state
  /// belongs to the project and costs a subprocess to find out. So this is read
  /// from the cache a session left behind — a fact that happened, drawn with
  /// its age — and it is the only fact here that is *empty for most repos*, as
  /// most projects declare no stack at all.
  final Fact<StackReading> stack;

  /// For the refresh that only re-reads one provider — an agent writing to its
  /// session file must not drag fourteen `git status` calls behind it.
  WorktreeFacts copyWith({
    Fact<GitFacts>? git,
    Fact<AgentFacts>? agent,
    Fact<ForgeFacts>? forge,
    Fact<ActivityFacts>? activity,
    Fact<StackReading>? stack,
  }) => WorktreeFacts(
    git: git ?? this.git,
    agent: agent ?? this.agent,
    forge: forge ?? this.forge,
    activity: activity ?? this.activity,
    stack: stack ?? this.stack,
  );

  /// Will this worktree fail to progress until you act?
  ///
  /// Not a count of agents and not a count of worktrees — that is what makes it
  /// worth a permanent badge on the pinned tab rather than a number you learn
  /// to ignore.
  bool get needsYou {
    if (agent.value?.state == AgentState.waiting) return true;
    var pr = forge.value;
    if (pr == null) return false;
    // Deliberately not [ReviewState.approved], however tempting. An approved
    // pull request does want merging, but it is a badge that stays lit while
    // you are busy elsewhere — and a permanent badge is a badge you stop
    // reading, which would cost the states that mean something.
    return pr.checks == ChecksState.failing ||
        pr.review == ReviewState.changesRequested;
  }

  /// The row's one dot: worst wins.
  Tone get tone {
    if (forge.value?.checks == ChecksState.failing) return Tone.error;
    if (agent.value?.state == AgentState.waiting) return Tone.info;
    if (forge.value?.review == ReviewState.changesRequested) return Tone.warn;
    if (agent.value?.state == AgentState.working) return Tone.good;
    return Tone.neutral;
  }

  Map<String, Object?> toJson() => {
    'needsYou': needsYou,
    'tone': tone.name,
    'git': git.toJson((v) => v.toJson()),
    'agent': agent.toJson((v) => v.toJson()),
    'forge': forge.toJson((v) => v.toJson()),
    'activity': activity.toJson((v) => v.toJson()),
    'stack': stack.toJson((v) => v.toJson()),
  };
}
