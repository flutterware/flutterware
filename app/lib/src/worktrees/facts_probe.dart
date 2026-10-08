/// Turns a list of worktrees into a list of facts.
///
/// Batches what git can batch, pays the per-worktree cost only for the working
/// tree, and never recomputes a branch diff whose two shas have not moved.
///
/// Pure Dart. `fw worktrees` links this; the GUI wraps it in a controller with
/// watchers, and both get the same numbers because both call this.
library;

import 'dart:async';

import '../plugins/native/dev_stack_results.dart';
import '../shell/worktree.dart';
import 'facts.dart';
import 'facts_store.dart';
import 'providers/agent.dart';
import 'providers/forge.dart';
import 'providers/git.dart';
import 'providers/stack.dart';

/// A forge answer plus the clock it was answered on — which is *not* now when
/// it came from the cache, and the row shows the difference.
typedef _ForgeAnswer = ({ForgeReport report, DateTime at});

class WorktreeFactsProbe {
  WorktreeFactsProbe({
    required this.repoRoot,
    required this.store,
    GitProbe? git,
    AgentProbe? agent,
    ForgeProbe? forge,
    StackProbe? stack,
    this.concurrency = 4,
    this.forgeTtl = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : git = git ?? GitProbe(),
       agent = agent ?? ClaudeAgentProbe(),
       forge = forge ?? RemoteForgeProbe(),
       stack = stack ?? RunDirStackProbe(),
       _now = now ?? DateTime.now;

  /// The main checkout — where the batched calls run, and where every
  /// commit-only question is answered from.
  final String repoRoot;

  final WorktreeFactsStore store;
  final GitProbe git;

  /// Nice to have, never required. Everything it reports is optional, and a
  /// probe that finds nothing is indistinguishable from a repo with no agents,
  /// which is the intended behaviour.
  final AgentProbe agent;

  /// Also nice to have: a machine with no `gh` is a repo with no PR column.
  final ForgeProbe forge;

  /// The cheapest of the lot — one `stat` and, at most, one small file read per
  /// worktree. It never runs project code, which is the whole reason the column
  /// can exist on a screen that lists every checkout.
  final StackProbe stack;

  /// How long a pull request answer is believed.
  ///
  /// The only fact here with a TTL, because it is the only one whose truth
  /// lives on someone else's computer. Everything git says is either instant to
  /// recompute or keyed by a sha that cannot change; a check that turns red does
  /// so without anything local moving, so this one is a clock.
  ///
  /// Five minutes is chosen against the measured 0.74 s cost: long enough that
  /// glancing at the explorer repeatedly is free, short enough that a push and a
  /// coffee come back to the truth.
  final Duration forgeTtl;

  /// How many worktrees are probed at once.
  ///
  /// Four rather than all of them: fourteen concurrent `git status` calls on a
  /// cold page cache is a thundering herd against one disk, and the wall-clock
  /// win over four is nil.
  final int concurrency;

  final DateTime Function() _now;

  /// [refreshForge] ignores [forgeTtl] and asks the forge again — what the
  /// explorer's refresh button and `fw worktrees --refresh` mean by "now".
  Future<Map<String, WorktreeFacts>> probe(
    List<Worktree> worktrees, {
    bool refreshForge = false,
  }) async {
    // Nothing to report, and — the reason this is here rather than being
    // obviously pointless — nothing to await the forge call either, so asking a
    // server about a list we are not going to draw would leave its answer
    // arriving after the cache had already been written.
    if (worktrees.isEmpty) return {};

    // **Started first, awaited last.** The forge is a network call an order of
    // magnitude slower than everything else here (0.74 s against ~25 ms), so it
    // runs underneath the whole git sweep rather than in front of it.
    var forge = _pullRequests(refresh: refreshForge);

    // The two batched calls, before anything per-worktree. One process each,
    // for every branch in the repository.
    var tips = await git.branchTips(repoRoot);
    var base = await git.defaultBranch(repoRoot);
    var baseSha = base == null ? null : tips[base]?.sha;

    var facts = <String, WorktreeFacts>{};
    await _pooled(worktrees, (worktree) async {
      facts[worktree.path] = await _probeOne(
        worktree,
        tips: tips,
        base: base,
        baseSha: baseSha,
        forge: forge,
      );
    });

    store.save();
    return facts;
  }

  /// Re-reads **only** the agents, keeping every other fact as it was.
  ///
  /// What a `~/.claude/projects` event costs: a `stat` and a 64 KB tail read per
  /// worktree, and not one subprocess. An agent mid-answer writes to its session
  /// file continuously, so this path is taken every couple of seconds for as
  /// long as work is going on — which is affordable exactly because it runs no
  /// git.
  ///
  /// Activity is folded rather than recomputed: no git event fired, so the
  /// commit and opened clocks cannot have moved past what [previous] already
  /// took the maximum of.
  Future<Map<String, WorktreeFacts>> probeAgents(
    List<Worktree> worktrees,
    Map<String, WorktreeFacts> previous,
  ) async {
    var facts = <String, WorktreeFacts>{};
    await _pooled(worktrees, (worktree) async {
      var was = previous[worktree.path] ?? const WorktreeFacts();
      var agentFacts = await agent.probe(worktree.path);
      facts[worktree.path] = was.copyWith(
        agent: _agentFact(agentFacts),
        activity: _laterActivity(was.activity, agentFacts),
      );
    });
    return facts;
  }

  /// Re-reads **only** the stacks, keeping every other fact as it was.
  ///
  /// The cheapest refresh here by a wide margin: one `stat` and one small JSON
  /// read per worktree, no subprocesses and no git. That is what lets a cache
  /// file changing under `~/.flutterware/run` drive a live column without
  /// dragging fourteen `git status` calls behind it — the same separation the
  /// agent path already makes, and for the same reason.
  Future<Map<String, WorktreeFacts>> probeStacks(
    List<Worktree> worktrees,
    Map<String, WorktreeFacts> previous,
  ) async {
    var facts = <String, WorktreeFacts>{};
    await _pooled(worktrees, (worktree) async {
      var was = previous[worktree.path] ?? const WorktreeFacts();
      facts[worktree.path] = was.copyWith(
        stack: _stackFact(await stack.probe(worktree.path)),
      );
    });
    return facts;
  }

  Fact<ActivityFacts> _laterActivity(
    Fact<ActivityFacts> previous,
    AgentFacts? agent,
  ) {
    var at = agent?.at;
    if (at == null) return previous;
    if (previous.value case var was? when was.at.isAfter(at)) return previous;
    return Fact.fresh(
      ActivityFacts(at: at, source: ActivitySource.agent),
      computedAt: _now(),
    );
  }

  Future<WorktreeFacts> _probeOne(
    Worktree worktree, {
    required Map<String, BranchTip> tips,
    required String? base,
    required String? baseSha,
    required Future<_ForgeAnswer> forge,
  }) async {
    var agentFacts = await agent.probe(worktree.path);
    var stackFact = _stackFact(await stack.probe(worktree.path));

    var status = await git.status(worktree.path);
    if (status == null) {
      return WorktreeFacts(
        git: const Fact.failed('git could not read this worktree'),
        agent: _agentFact(agentFacts),
        forge: _forgeFact(worktree.branch, await forge),
        activity: _activity(worktree, null, agentFacts),
        stack: stackFact,
      );
    }

    var branch = status.branch ?? worktree.branch;
    var headSha = status.head ?? tips[branch]?.sha;

    var diff = await _branchDiff(
      branch: branch,
      base: base,
      baseSha: baseSha,
      headSha: headSha,
    );

    return WorktreeFacts(
      git: Fact.fresh(
        GitFacts(
          dirty: status.dirty,
          ahead: diff?.ahead ?? status.ahead ?? 0,
          behind: diff?.behind ?? status.behind ?? 0,
          changes: diff?.shape,
          base: base,
        ),
        computedAt: _now(),
        validityKey: baseSha == null || headSha == null
            ? null
            : WorktreeFactsStore.diffKey(baseSha, headSha),
      ),
      agent: _agentFact(agentFacts),
      forge: _forgeFact(branch, await forge),
      activity: _activity(worktree, tips[branch]?.committedAt, agentFacts),
      stack: stackFact,
    );
  }

  /// A cached reading, aged.
  ///
  /// Never [FactState.failed]: there is no probe here to fail, only a file that
  /// is there or is not. Absent means [FactState.unavailable] — *there is
  /// nothing here to know* — which is what most checkouts in most repositories
  /// will report, since most projects declare no stack at all.
  ///
  /// Past [stackFreshFor] the reading is [FactState.stale] rather than dropped.
  /// It is still the last reading taken, and a stack that was up an hour ago is
  /// very probably still up — the row dims it and prints its age rather than
  /// claiming either certainty or ignorance.
  Fact<StackReading> _stackFact(StackReading? reading) {
    if (reading?.at == null) return const Fact.unavailable('no stack');
    var age = _now().difference(reading!.at!);
    return age > stackFreshFor
        ? Fact.stale(reading, computedAt: reading.at)
        : Fact.fresh(reading, computedAt: reading.at);
  }

  /// One sweep's worth of pull requests, from the cache or from the forge.
  ///
  /// Failure is [FactState.unavailable] rather than [FactState.failed], with the
  /// tool's own first line as the reason. A forge is optional equipment: a
  /// machine with no `gh` must show a repository with no PR column, not fourteen
  /// red cells complaining about a program the user chose not to install.
  Future<_ForgeAnswer> _pullRequests({required bool refresh}) async {
    var now = _now();
    if (!refresh) {
      if (store.pullRequests() case var cached?
          when now.difference(cached.at) < forgeTtl) {
        return (report: ForgeReport.ready(cached.byBranch), at: cached.at);
      }
    }

    ForgeReport report;
    try {
      report = await forge.probe(repoRoot);
    } catch (e) {
      // The probes promise not to throw; this is the backstop that keeps that
      // promise true for the sweep even if one of them forgets.
      report = ForgeReport.unavailable('$e');
    }
    if (report.isReady) store.putPullRequests(report.pullRequests, now);
    return (report: report, at: now);
  }

  Fact<ForgeFacts> _forgeFact(String? branch, _ForgeAnswer answer) {
    if (answer.report.unavailable case var why?) return Fact.unavailable(why);
    var pr = branch == null ? null : answer.report.pullRequests[branch];
    if (pr == null) {
      return const Fact.unavailable('no pull request for this branch');
    }
    return Fact.fresh(pr, computedAt: answer.at);
  }

  /// `unavailable`, not `failed`, when there is no session.
  ///
  /// Nothing is broken about a checkout no agent has ever touched, and the two
  /// states render differently on purpose — one is a quiet dash, the other is a
  /// complaint that would never clear.
  Fact<AgentFacts> _agentFact(AgentFacts? facts) =>
      facts == null || facts.state == AgentState.none
      ? const Fact.unavailable('no agent session for this checkout')
      : Fact.fresh(facts, computedAt: _now());

  /// The cached half. A sha pair has one diff forever, so a hit is not a stale
  /// answer that happens to be right — it is *the* answer, and the only reason
  /// to recompute it would be that we lost it.
  ///
  /// The base branch itself is skipped rather than diffed against itself: `git`
  /// would happily report nothing, but it would be one process per launch to
  /// learn something already known.
  Future<CachedDiff?> _branchDiff({
    required String? branch,
    required String? base,
    required String? baseSha,
    required String? headSha,
  }) async {
    if (branch == null || base == null || baseSha == null || headSha == null) {
      return null;
    }
    if (branch == base || baseSha == headSha) return null;

    var cached = store.diff(baseSha, headSha);
    if (cached != null) return cached;

    var computed = await git.branchDiff(repoRoot, base: baseSha, head: headSha);
    if (computed == null) return null;

    var diff = CachedDiff(
      shape: computed.shape,
      ahead: computed.ahead,
      behind: computed.behind,
    );
    store.putDiff(baseSha, headSha, diff);
    return diff;
  }

  /// The maximum of the clocks we have, and *which one it was*.
  ///
  /// "Last touched" is three clocks that disagree, so this takes the newest and
  /// records which one won. A bare relative time meaning a commit on one row and
  /// an agent message on the next is worse than no time at all.
  Fact<ActivityFacts> _activity(
    Worktree worktree,
    DateTime? committedAt,
    AgentFacts? agent,
  ) {
    var candidates = <(DateTime, ActivitySource)>[
      if (committedAt != null) (committedAt, ActivitySource.commit),
      if (store.openedAt(worktree.path) case var at?)
        (at, ActivitySource.opened),
      if (agent?.at case var at?) (at, ActivitySource.agent),
    ];
    if (candidates.isEmpty) return const Fact.unknown();
    candidates.sort((a, b) => b.$1.compareTo(a.$1));
    return Fact.fresh(
      ActivityFacts(at: candidates.first.$1, source: candidates.first.$2),
      computedAt: _now(),
    );
  }

  /// Runs [work] over [items], at most [concurrency] at a time.
  ///
  /// Hand-rolled rather than pulled in: it is eight lines, and the alternative
  /// is a dependency for one call site.
  Future<void> _pooled<T>(
    List<T> items,
    Future<void> Function(T item) work,
  ) async {
    var next = 0;
    Future<void> worker() async {
      while (true) {
        var index = next++;
        if (index >= items.length) return;
        await work(items[index]);
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency && i < items.length; i++) worker(),
    ]);
  }
}
