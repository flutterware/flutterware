import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutterware/comparison_report.dart';
import 'package:path/path.dart' as p;
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';

import 'cancel.dart';
import 'closure.dart';
import 'import_graph.dart';
import 'phase_clock.dart';
import 'shot_cache.dart';
import 'shot_key.dart';
import 'skip.dart';

/// One side of a comparison, as the runner needs to talk to it.
///
/// An interface rather than `HeadlessCatalog` directly, for one reason that
/// pays for itself immediately: the orchestration — what to skip, what is
/// added, which side broke, what the index says — is most of the risk in this
/// feature and none of it needs a compiler, a guest or a Flutter SDK to be
/// wrong. A fake renderer makes all of that testable in milliseconds.
abstract interface class ComparisonSide {
  /// Every entry id this checkout declares.
  Future<List<String>> entries(String checkout);

  /// What a person calls each entry of this checkout — the name it was
  /// declared under, `Order placed` for `demo/shop.dart#shopConfirmation` —
  /// for the ones that have one.
  ///
  /// Carried on the row as its label, because the id is the file and the
  /// function, and a reader of the page or the comment knows the preview by
  /// the name the panel shows.
  Future<Map<String, String>> names(String checkout);

  /// The package the entries live in, relative to a checkout root — where the
  /// pubspec declaring the assets and the lockfile recording the resolution
  /// sit, which is what [pixelInputsOf] reads.
  String get packagePath;

  /// Where [entryId]'s source lives, **relative to a checkout root**.
  ///
  /// Asked of the side rather than derived from the id, because an id is
  /// relative to its *package* and a checkout can hold several: in a
  /// workspace, `demo/buttons.dart#buttons` lives at
  /// `fixtures/probe_app/demo/buttons.dart`. Deriving it here made every entry
  /// look like a missing file, which hashes the same on both sides — so a
  /// comparison of a genuinely changed preview skipped it and reported no
  /// change at all.
  String fileOf(String entryId);

  /// Renders [entryIds] and hands each frame over as it lands.
  ///
  /// Streamed for the reason `HeadlessCatalog.captureAll` streams: a frame is
  /// megabytes and a catalog is hundreds of them.
  ///
  /// Returns entry id → why nothing was rendered, for the ones that refused.
  ///
  /// [guests] is how many renderers of this checkout may run at once. Frames
  /// then land in no particular order, and [onFrame] may be called for one
  /// entry while another's is still being filed.
  ///
  /// [onCompiled] is told how long getting a renderer up took, before the
  /// first frame — what separates a slow compile from slow entries.
  Future<Map<String, String>> render({
    required String checkout,
    required List<String> entryIds,
    required Future<void> Function(RenderedEntry frame) onFrame,
    int guests = 1,
    void Function(Duration elapsed)? onCompiled,
  });
}

/// One rendered entry, as a side hands it to the runner.
class RenderedEntry {
  RenderedEntry({
    required this.entryId,
    this.rgba,
    this.path,
    required this.width,
    required this.height,
    this.tree,
    this.treeFormat,
    this.complaint,
  }) : assert(
         (rgba == null) != (path == null),
         'a frame is either in memory or on disk',
       );

  final String entryId;

  /// The picture, raw rgba — or null when it is still at [path].
  final Uint8List? rgba;

  /// The raw rgba a renderer left on disk, which the cache takes by moving it
  /// rather than by reading megabytes in to write them straight back out.
  /// Nothing else is allowed to read it after [ComparisonSide.render]'s
  /// `onFrame` returns.
  final String? path;
  final int width;
  final int height;
  final InspectNode? tree;

  /// The format [tree] was read in — see `InspectTree.format`.
  final int? treeFormat;

  /// What the framework said while drawing it, when it drew it anyway — an
  /// overflow, a missing font. The picture is comparable and the complaint is
  /// still worth carrying, because "this overflows now" is a finding even when
  /// the pixels barely moved.
  final String? complaint;
}

/// Everything a comparison concluded.
class ComparisonResult {
  ComparisonResult({
    required this.items,
    required this.baseSha,
    required this.headRoot,
    required this.elapsed,
    required this.rendered,
    this.because = const {},
    this.packages = const [],
    this.note,
  });

  /// Several packages' halves as one.
  ///
  /// The rows concatenate and re-rank, the counters add, and the causes fold
  /// together — but [elapsed] is measured by the caller around the whole loop
  /// rather than summed, because summing would report a number no clock ever
  /// showed.
  ///
  /// [note] joins whatever the packages could not do, each naming itself. One
  /// package whose catalog will not compile is a sentence about that package;
  /// it used to be the end of the comparison, which is the right answer when
  /// it is the only package and the wrong one when three others compared
  /// cleanly.
  static ComparisonResult merged(
    List<ComparisonResult> results, {
    required String baseSha,
    required String headRoot,
    required Duration elapsed,
    Map<String, String> refusals = const {},
  }) => ComparisonResult(
    items: [for (var result in results) ...result.items]
      ..sort((a, b) {
        var byState = a.state.index.compareTo(b.state.index);
        return byState != 0 ? byState : a.id.compareTo(b.id);
      }),
    baseSha: baseSha,
    headRoot: headRoot,
    elapsed: elapsed,
    rendered: results.fold(0, (sum, result) => sum + result.rendered),
    because: mergeBecause(results.map((result) => result.because)),
    packages: [for (var result in results) ...result.packages],
    note: refusals.isEmpty
        ? null
        : [for (var entry in refusals.entries) '${entry.key}: ${entry.value}']
              .join('\n'),
  );

  /// Worst first — [ComparedState] is declared in that order, so ranking is a
  /// sort.
  final List<ComparedItem> items;

  final String baseSha;
  final String headRoot;
  final Duration elapsed;

  /// How many renders actually happened, against how many entries there are.
  /// The number that says whether the skip rule earned its keep.
  final int rendered;

  /// Why the skip rule could not answer the entries it could not answer,
  /// folded — see [foldReasons].
  ///
  /// The other half of [rendered]. That number says the skip rule did not
  /// earn its keep; this one says which path it was that both checkouts
  /// disagreed about, which is the only form of the answer anybody can act
  /// on.
  final Map<String, int> because;

  /// Which packages this half covered, worktree-relative and in the order
  /// they were compared. What lets a page facet by package and a comment
  /// group by it without walking every row.
  final List<String> packages;

  /// Why part of this half has nothing to say, when part of it has nothing to
  /// say — a package whose catalog would not compile, naming itself.
  ///
  /// The twin of [ScenarioResults.note], and it arrived for the same reason:
  /// the rows are simply absent, and absence is indistinguishable from a
  /// package with no entries unless something says otherwise. `verdictGapOf`
  /// reads it, so a run carrying one exits non-zero.
  final String? note;

  /// This half, with every row addressed inside [package] — the half-level
  /// twin of [ComparedItem.inPackage], and the same [qualify] rule.
  ComparisonResult inPackage(String package, {required bool qualify}) =>
      ComparisonResult(
        items: [
          for (var item in items) item.inPackage(package, qualify: qualify),
        ],
        baseSha: baseSha,
        headRoot: headRoot,
        elapsed: elapsed,
        rendered: rendered,
        because: because,
        packages: [package],
        note: note,
      );

  int countOf(ComparedState state) =>
      items.where((item) => item.state == state).length;

  /// This half alone. Which base it was against and where head sits belong to
  /// the whole comparison rather than to one of its halves, so
  /// `ComparisonArtifact` writes them once at the top.
  Map<String, Object?> toJson() => {
    'rendered': rendered,
    'because': ?(because.isEmpty ? null : because),
    'packages': ?(packages.isEmpty ? null : packages),
    'note': ?note,
    'ms': elapsed.inMilliseconds,
    'counts': {
      for (var state in ComparedState.values)
        if (countOf(state) > 0) state.name: countOf(state),
    },
    'items': [for (var item in items) item.toJson()],
  };
}

/// What a comparison already knows before it renders anything.
class ComparisonPlan {
  const ComparisonPlan({
    required this.settled,
    required this.toRender,
    required this.keys,
    required this.total,
    this.onlyOnHead = const [],
    this.onlyOnBase = const [],
    this.because = const {},
    this.names = const {},
  });

  /// Entry id → its declared name, the head's where both sides have one — see
  /// [ComparisonSide.names].
  final Map<String, String> names;

  /// Rows whose **verdict** needed no picture: added, removed, skipped.
  ///
  /// Not the same as needing no render. An added entry's verdict is settled
  /// the moment the two listings disagree, and it is still the entry a reader
  /// most wants to look at — see [onlyOnHead].
  final List<ComparedItem> settled;

  /// The entries that have to be rendered to be answered.
  final List<String> toRender;

  /// Entries this branch **added**: nothing to compare, one side to draw.
  ///
  /// Rendered even though the verdict does not need it. The page used to say
  /// *"Neither side rendered"* over a preview the branch had just introduced,
  /// which is exactly the row somebody opened the page for — and the head
  /// side is sitting in the checkout. [onlyOnBase] is its mirror: what a
  /// branch deleted is worth a last look.
  final List<String> onlyOnHead;

  final List<String> onlyOnBase;

  /// Why [toRender] has to be rendered, folded — see [foldReasons].
  final Map<String, int> because;

  /// Each entry's cache key on both sides.
  final Map<String, ({String base, String head})> keys;

  /// Every entry either side declares, settled and unsettled together.
  final int total;
}

/// One side could not render *anything* — it did not compile.
///
/// One finding, not one per entry. This used to be mapped onto every entry
/// the side was asked for, on the reasoning that a per-entry verdict lands on
/// the severity ladder rather than ending the comparison. Measured against a
/// base whose catalog did not compile, that reasoning produced twenty-four
/// identical rows, each saying the same sentence once, burying everything else
/// the run found. It is the argument the split branches already settled: one
/// decision in the source is one row, however many things hang off it.
///
/// Thrown by the side, which knows the reason; named by the runner, which knows
/// which checkout it handed over.
class SideDidNotCompile implements Exception {
  SideDidNotCompile(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Refused before anything is rendered.
class ComparisonRefused implements Exception {
  ComparisonRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Runs one comparison: decide, render what is left, diff, report.
///
/// The order is the design. **Deciding comes first and costs only hashing**,
/// so every row's verdict exists before the first render starts — which is
/// what lets a screen draw its full shape immediately and fill in the pictures
/// behind it, and what makes a branch that changed nothing cost no renders at
/// all.
class ComparisonRunner {
  ComparisonRunner({
    required this.headRoot,
    required this.baseRoot,
    required this.baseSha,
    required this.side,
    required this.cache,
    required this.sdk,
    this.packageConfig,
    this.only,
    this.onItem,
    this.onPlan,
    this.onProgress,
    this.cancel,
    this.jobs = 1,
    this.clock,
  });

  /// Where this half records its phases — see [PhaseClock].
  final PhaseClock? clock;

  Future<T> _timed<T>(String name, Future<T> Function() work) =>
      clock?.time<T>(name, work) ?? work();

  /// How many renderers each side runs, and whether the two sides render at
  /// once.
  ///
  /// One renders the base and then the head on one guest each, which is what
  /// a runner sized for one build can take. More renders both sides together,
  /// each across this many guests of one compiled harness — twice this many
  /// testers in all.
  final int jobs;

  /// The worktree as it sits on disk, uncommitted and untracked included.
  final String headRoot;

  /// The base, already checked out — see `BaseCheckout`.
  final String baseRoot;

  final String baseSha;

  final ComparisonSide side;
  final ShotCache cache;

  /// The SDK both sides are rendered with, as `FlutterSdkPath.identity` names
  /// it — so switching SDKs invalidates the cache rather than handing back
  /// pictures the current engine would not draw.
  ///
  /// Handed in rather than found. It was found, with `findSdk`, which answers
  /// null inside the studio — a compiled app has no SDK above its binary — so
  /// every picture the panel rendered was keyed `unknown`: shared with no
  /// `fw compare`, and served unchanged across an SDK upgrade.
  ///
  /// **Not checked against what the base commit wanted.** Two checkouts that
  /// pin different Flutter versions differ in every pixel for reasons that are
  /// not the branch's, and both are rendered with this one: the SDK is
  /// whichever one the invocation names, and teaching a comparison to invoke
  /// an older one is not built. What is built is saying so — see
  /// `SdkPin.caveat`.
  final String sdk;

  /// Relative path of the package config inside each checkout, for resolving
  /// `package:` imports. Null falls back to the conventional location.
  final String? packageConfig;

  /// Compare only these entry ids. A focus device rather than a performance
  /// one — the skip rule already renders nothing it does not have to.
  final List<String>? only;

  /// Called as each verdict is reached, so a host can fill a list in rather
  /// than wait for the whole run.
  final void Function(ComparedItem item)? onItem;

  /// Called once the plan is made — the moment the run's shape is known: how
  /// many entries there are, and which of them still owe a verdict.
  final void Function(ComparisonPlan plan)? onPlan;

  /// One sentence of what the run is doing right now, replaced as it moves.
  final void Function(String phase)? onProgress;

  /// Checked between stages and between frames. See [CancelToken].
  final CancelToken? cancel;

  /// Everything that can be decided without rendering anything.
  ///
  /// The whole skip rule, and none of the rendering. Split out of [run]
  /// because it is what makes a screen honest while it fills: every row that is
  /// added, removed or skipped is already settled here, so the list draws its
  /// full shape immediately and only the pictures arrive late.
  ///
  /// It is no longer split out so that a *tab* can be priced before it is
  /// opened. It was, and the price was the problem — see
  /// [ComparisonController].
  ///
  /// The deciding runs on an isolate, because its size is the *project's*
  /// and not ours: one sha1 per file in every entry's closure, plus the asset
  /// tree. This was once measured at 142ms, on this repository, which has a
  /// handful of previews and no assets to speak of; a real catalog of 90
  /// previews put the same loop at minutes, and on the UI isolate that is not a
  /// slow screen but a dead window — `plan` is one uninterruptible microtask,
  /// since nothing in the loop awaits.
  Future<ComparisonPlan> plan() async {
    onProgress?.call('listing the entries on both sides');
    var headEntries = await side.entries(headRoot);
    var baseEntries = await side.entries(baseRoot);
    cancel?.check();
    if (only case var only?) {
      headEntries = [
        for (var id in headEntries)
          if (only.contains(id)) id,
      ];
      baseEntries = [
        for (var id in baseEntries)
          if (only.contains(id)) id,
      ];
    }

    var settled = <ComparedItem>[];
    var common = [
      for (var id in headEntries)
        if (baseEntries.contains(id)) id,
    ];
    var onlyOnHead = [
      for (var id in headEntries)
        if (!baseEntries.contains(id)) id,
    ];
    var onlyOnBase = [
      for (var id in baseEntries)
        if (!headEntries.contains(id)) id,
    ];

    // `side` and `cache` are live objects and stay here; what crosses is the
    // ids, the paths and the one file each entry starts from. A tear-off of
    // `decide` sends its receiver, which is why the receiver is plain data.
    onProgress?.call(
      'deciding what changed — hashing ${common.length} '
      '${common.length == 1 ? 'closure' : 'closures'}',
    );
    var decided = await Isolate.run(
      _PlanInputs(
        ids: common,
        oneSided: [...onlyOnHead, ...onlyOnBase],
        files: {
          for (var id in [...common, ...onlyOnHead, ...onlyOnBase])
            id: side.fileOf(id),
        },
        headRoot: headRoot,
        baseRoot: baseRoot,
        packagePath: side.packagePath,
        packageConfig: packageConfig,
        memoDirectory: cache.memo.directory,
        sdkKey: sdk,
      ).decide,
    );

    cancel?.check();
    for (var id in decided.skipped) {
      settled.add(ComparedItem(id: id, state: ComparedState.skipped));
    }
    // The one-sided rows carry their keys from the start, so the row a screen
    // draws never changes: only the picture behind the key arrives late.
    for (var id in onlyOnHead) {
      settled.add(
        ComparedItem(
          id: id,
          state: ComparedState.added,
          shots: decided.keys[id],
        ),
      );
    }
    for (var id in onlyOnBase) {
      settled.add(
        ComparedItem(
          id: id,
          state: ComparedState.removed,
          shots: decided.keys[id],
        ),
      );
    }
    return ComparisonPlan(
      // The base's first so the head's win: a renamed preview is called what
      // this branch calls it, and a removed one keeps the name it had.
      names: {...await side.names(baseRoot), ...await side.names(headRoot)},
      settled: settled,
      toRender: decided.toRender,
      keys: decided.keys,
      onlyOnHead: onlyOnHead,
      onlyOnBase: onlyOnBase,
      total: settled.length + decided.toRender.length,
      because: decided.because,
    );
  }

  /// Renders what [plan] left and diffs it.
  ///
  /// Takes a plan when the caller already made one, since remaking it would
  /// hash every closure a second time to reach the same answer.
  ///
  /// A verdict lands the moment it is answerable rather than when the run ends.
  /// The settled rows come first, in a burst; an entry both sides already have
  /// cached is diffed before any render starts; and during the head pass each
  /// frame is diffed as it lands, because by then the base side is final. What
  /// waits until the end is only what has to: entries whose head render
  /// *failed* produce no frame, so their rows come last.
  Future<ComparisonResult> run({ComparisonPlan? from}) async {
    var watch = Stopwatch()..start();
    cancel?.check();
    var plan = from ?? await _timed<ComparisonPlan>('previews.plan', this.plan);
    onPlan?.call(plan);
    var comparing = PhaseTally();

    var items = <String, ComparedItem>{};
    void report(ComparedItem item) {
      // Named here, the one door every row leaves through, rather than at the
      // half-dozen places a row is built.
      if (item.label == null) {
        if (plan.names[item.id] case var name?) item = _named(item, name);
      }
      items[item.id] = item;
      onItem?.call(item);
    }

    for (var item in plan.settled) {
      report(item);
    }
    var toRender = plan.toRender;
    var keys = plan.keys;

    // Only what is not already filed under its key. After the first
    // comparison against a base, that is the head side alone; after an
    // unrelated edit, it can be nothing at all.
    //
    // The one-sided entries ride along on the side that has them. Their
    // verdict was settled without a picture and their row is already out; what
    // this buys is that the row has something to *show* — an added preview is
    // the one a reader opened the page for.
    var wantedByBase = [
      for (var id in [...toRender, ...plan.onlyOnBase])
        if (!cache.has(keys[id]!.base)) id,
    ];
    var wantedByHead = [
      for (var id in [...toRender, ...plan.onlyOnHead])
        if (!cache.has(keys[id]!.head)) id,
    ];

    var rendered = wantedByBase.length + wantedByHead.length;
    // A side that will not compile ends the half with one sentence. Which side
    // is the reader's first question and the side cannot answer it, so it is
    // answered here.
    var baseFailures = const <String, String>{};
    var headFailures = const <String, String>{};

    /// Answers [id] from what is on hand, once — a failure on the side that
    /// was asked, or the diff. Callers only invoke this when the sides it
    /// reads are final for [id].
    void resolve(String id) {
      if (items.containsKey(id)) return;
      var key = keys[id]!;
      var baseOk = !baseFailures.containsKey(id) && cache.has(key.base);
      var headOk = !headFailures.containsKey(id) && cache.has(key.head);
      if (!baseOk || !headOk) {
        report(
          ComparedItem.of(
            id: id,
            baseRendered: baseOk,
            headRendered: headOk,
            note: headFailures[id] ?? baseFailures[id],
            // Even here: the side that *did* render is worth looking at, and
            // "renders on base, throws here" is a row somebody will want to
            // see the base of.
            shots: key,
          ),
        );
        return;
      }
      report(comparing.time<ComparedItem>(() => _compare(id, key)));
    }

    // Both frames already in the cache: answerable before anything renders.
    for (var id in toRender) {
      if (!wantedByBase.contains(id) && !wantedByHead.contains(id)) {
        resolve(id);
      }
    }

    var baseDone = 0;
    var headDone = 0;
    var headStarted = false;
    void progress() => onProgress?.call(
      jobs > 1
          ? 'rendering both sides · ${baseDone + headDone} of $rendered'
          : headStarted
          ? 'rendering this side · $headDone of ${wantedByHead.length}'
          : 'rendering the base side · $baseDone of ${wantedByBase.length}',
    );

    Future<void> renderBase() async {
      try {
        baseFailures = await _renderInto(
          baseRoot,
          wantedByBase,
          keys,
          isBase: true,
          onEntry: (id) {
            cancel?.check();
            baseDone++;
            progress();
            // Rendering beside the head pass, this may be the frame that
            // entry was waiting on.
            if (jobs > 1 && cache.has(keys[id]!.head)) resolve(id);
          },
        );
      } on SideDidNotCompile catch (e) {
        // A side compiled only to draw what the branch *removed* owes the run
        // nothing: those rows were settled without a picture, and before they
        // were given one this side was never compiled at all. Refusing here
        // would turn a comparison that used to succeed into exit 64 for the
        // sake of an optional frame.
        if (!wantedByBase.every(plan.onlyOnBase.contains)) {
          throw ComparisonRefused(
            'the base checkout does not compile, so there is nothing to '
            'compare against: ${e.reason}',
          );
        }
      }
    }

    Future<void> renderHead() async {
      headStarted = true;
      try {
        headFailures = await _renderInto(
          headRoot,
          wantedByHead,
          keys,
          isBase: false,
          onEntry: (id) {
            cancel?.check();
            headDone++;
            progress();
            // This entry's head frame just landed. Rendered after the base
            // pass, the base side is final and the row is answerable while
            // its neighbours are still rendering; rendered beside it, only
            // when the base frame is already here.
            if (jobs <= 1 || cache.has(keys[id]!.base)) resolve(id);
          },
        );
      } on SideDidNotCompile catch (e) {
        // The same rule as the base pass, for what the branch *added*.
        if (!wantedByHead.every(plan.onlyOnHead.contains)) {
          throw ComparisonRefused(
            'this worktree does not compile, so its previews cannot be '
            'rendered: ${e.reason}',
          );
        }
      }
    }

    if (jobs > 1) {
      await Future.wait([renderBase(), renderHead()]);
    } else {
      await renderBase();
      cancel?.check();
      // The base pass is over, so entries whose head frame was already cached
      // are final now — including the ones whose base render just failed.
      for (var id in toRender) {
        if (!wantedByHead.contains(id)) resolve(id);
      }
      await renderHead();
    }
    cancel?.check();

    // What is left is the entries a render pass refused: they produced no
    // frame, so their failure is only known now the pass has returned.
    for (var id in toRender) {
      resolve(id);
    }

    clock?.add('previews.compare', comparing.elapsed);

    var ordered = items.values.toList()
      ..sort((a, b) {
        var byState = a.state.index.compareTo(b.state.index);
        return byState != 0 ? byState : a.id.compareTo(b.id);
      });
    return ComparisonResult(
      items: ordered,
      baseSha: baseSha,
      headRoot: headRoot,
      elapsed: watch.elapsed,
      rendered: rendered,
      because: plan.because,
    );
  }

  static ComparedItem _named(ComparedItem item, String name) => ComparedItem(
    id: item.id,
    state: item.state,
    label: name,
    pixels: item.pixels,
    tree: item.tree,
    texts: item.texts,
    events: item.events,
    note: item.note,
    shots: item.shots,
    package: item.package,
  );

  ComparedItem _compare(String id, ({String base, String head}) key) {
    var baseMeta = cache.meta(key.base)!;
    var headMeta = cache.meta(key.head)!;
    // The head side's, or the base's said as the base's. A complaint present on
    // both is the state of the world rather than something this branch did; one
    // the *base* alone makes is usually a skew in the tooling that rendered it,
    // and that is the sentence which separates "the branch changed this" from
    // "the two sides were photographed by different rules".
    var complaint = headMeta.complaint;
    complaint ??= baseMeta.complaint == null
        ? null
        : 'on base: ${baseMeta.complaint}';
    return ComparedItem.of(
      id: id,
      shots: key,
      note: headMeta.complaint == baseMeta.complaint ? null : complaint,
      pixels: PixelDiff.of(
        base: cache.read(key.base)!,
        baseWidth: baseMeta.width,
        baseHeight: baseMeta.height,
        head: cache.read(key.head)!,
        headWidth: headMeta.width,
        headHeight: headMeta.height,
      ),
      tree: TreeDiff.of(_treeOf(key.base), _treeOf(key.head)),
      treeSkewed: baseMeta.treeFormat != headMeta.treeFormat,
    );
  }

  InspectNode? _treeOf(String key) {
    var json = cache.readTree(key);
    return json == null ? null : InspectNode.fromJson(json);
  }

  Future<Map<String, String>> _renderInto(
    String checkout,
    List<String> entryIds,
    Map<String, ({String base, String head})> keys, {
    required bool isBase,
    void Function(String entryId)? onEntry,
  }) async {
    if (entryIds.isEmpty) return const {};
    var sideName = isBase ? 'base' : 'head';
    var watch = Stopwatch()..start();
    var compiled = Duration.zero;
    try {
      return await _render(
        checkout,
        entryIds,
        keys,
        isBase: isBase,
        onEntry: onEntry,
        onCompiled: (elapsed) {
          compiled = elapsed;
          clock?.add('previews.compile', elapsed, side: sideName);
        },
      );
    } finally {
      clock?.add('previews.render', watch.elapsed - compiled, side: sideName);
    }
  }

  Future<Map<String, String>> _render(
    String checkout,
    List<String> entryIds,
    Map<String, ({String base, String head})> keys, {
    required bool isBase,
    required void Function(Duration elapsed) onCompiled,
    void Function(String entryId)? onEntry,
  }) {
    return side.render(
      checkout: checkout,
      entryIds: entryIds,
      guests: jobs,
      onCompiled: onCompiled,
      onFrame: (frame) async {
        var key = keys[frame.entryId];
        if (key == null) return;
        var record = ShotRecord(
          format: 'raw',
          width: frame.width,
          height: frame.height,
          entryId: frame.entryId,
          complaint: frame.complaint,
          treeFormat: frame.treeFormat,
        );
        if (frame.path case var path?) {
          cache.adoptFile(isBase ? key.base : key.head, path, record);
        } else {
          cache.write(isBase ? key.base : key.head, frame.rgba!, record);
        }
        if (frame.tree case var tree?) {
          cache.writeTree(isBase ? key.base : key.head, tree.toJson());
        }
        onEntry?.call(frame.entryId);
      },
    );
  }
}

/// [ComparisonRunner.plan]'s deciding half, as the plain data it needs.
///
/// A class rather than a closure because [Isolate.run] copies whatever the
/// closure captures, and a closure over the runner would capture `side` and
/// `cache` — a compiler, a guest and a cache handle, none of which can cross
/// and none of which the deciding wants.
///
/// The memo is opened here from its directory rather than sent: it is a file
/// on disk, and the isolate is the one writing it.
class _PlanInputs {
  _PlanInputs({
    required this.ids,
    required this.oneSided,
    required this.files,
    required this.headRoot,
    required this.baseRoot,
    required this.packagePath,
    required this.packageConfig,
    required this.memoDirectory,
    required this.sdkKey,
  });

  /// The entries both sides declare — the only ones a skip rule applies to.
  final List<String> ids;

  /// The entries one side declares. No decision to make about them, and a key
  /// to compute anyway: the side that has one is going to be drawn.
  ///
  /// Both keys are computed, and the one for the side that does not have the
  /// file is a key nothing will ever write bytes under — which is exactly what
  /// the stage reads as "this side rendered nothing". Fabricating an absence
  /// rather than expressing one is a compromise the shape forces: a row's
  /// `shots` is a pair, and a pair cannot say *head only*.
  final List<String> oneSided;

  /// Entry id → its source file, relative to a checkout root. Resolved by the
  /// side before the hop, since only the side knows how.
  final Map<String, String> files;

  final String headRoot;
  final String baseRoot;
  final String packagePath;
  final String? packageConfig;
  final String memoDirectory;
  final String sdkKey;

  ({
    List<String> skipped,
    List<String> toRender,
    Map<String, ({String base, String head})> keys,
    Map<String, int> because,
  })
  decide() {
    var memo = ClosureMemo(memoDirectory);
    // Opened here and dropped at the end of this method, which is the whole
    // of its life: a digest is true of the file as it was read, and a plan is
    // the longest stretch over which that stays true.
    var digests = DigestCache();
    // The graphs are built once per side and reused across every entry: their
    // closures overlap almost entirely, so this is one parse of each package
    // rather than one per entry.
    var headGraph = _graphFor(headRoot);
    var baseGraph = _graphFor(baseRoot);

    // Listed and hashed once for the whole plan: the same lockfiles and assets
    // decide every entry's pixels, and they go into the skip rule and the shot
    // key together — a key that ignored what the skip rule watches would serve
    // a stale picture for exactly the change the skip rule re-rendered for.
    var pixels = PixelInputs.of(
      packagePath: packagePath,
      roots: [headRoot, baseRoot],
    );
    // Head first: the reach is closed over the head's dependency graph. See
    // [LockSides].
    var locks = LockSides(
      packagePath: packagePath,
      roots: [headRoot, baseRoot],
    );

    var skipped = <String>[];
    var toRender = <String>[];
    var reasons = <String>[];
    var keys = <String, ({String base, String head})>{};
    for (var id in oneSided) {
      var file = files[id]!;
      var lock = locks.forPackages(headGraph.packagesOf(file));
      keys[id] = (
        base: _keyFor(id, baseGraph, baseRoot, file, pixels, lock, digests),
        head: _keyFor(id, headGraph, headRoot, file, pixels, lock, digests),
      );
    }
    for (var id in ids) {
      var file = files[id]!;
      memo.remember(id, headGraph.closureOf(file));

      // Which dependencies this entry could possibly be changed by. Taken
      // from the head graph, like the closure above it and for the same
      // reason.
      var lock = locks.forPackages(headGraph.packagesOf(file));
      var decision = SkipDecision.of(
        entryId: id,
        memo: memo,
        baseRoot: baseRoot,
        headRoot: headRoot,
        pixels: pixels,
        digests: digests,
        lock: lock,
      );
      keys[id] = (
        base: _keyFor(id, baseGraph, baseRoot, file, pixels, lock, digests),
        head: _keyFor(id, headGraph, headRoot, file, pixels, lock, digests),
      );

      if (decision.skip) {
        skipped.add(id);
        continue;
      }
      toRender.add(id);
      if (decision.reason case var reason?) reasons.add(reason);
    }
    return (
      skipped: skipped,
      toRender: toRender,
      keys: keys,
      because: foldReasons(reasons),
    );
  }

  ImportGraph _graphFor(String checkout) => ImportGraph.read(
    root: checkout,
    packageConfig: p.join(
      checkout,
      packageConfig ?? p.join('.dart_tool', 'package_config.json'),
    ),
  );

  /// The entry's own sources hashed here, the pixel inputs folded in from the
  /// per-checkout closure. [SourceClosure.merge] makes that the same
  /// fingerprint hashing the union produced, so no key moves.
  String _keyFor(
    String id,
    ImportGraph graph,
    String root,
    String file,
    PixelInputs pixels,
    LockReach lock,
    DigestCache digests,
  ) => ShotKey.of(
    kind: 'preview',
    entryId: id,
    closure: SourceClosure.of(
      graph.closureOf(file),
      root: root,
      digests: digests,
    ).merge(pixels.inRoot(root)).merge(lock.inRoot(root)).fingerprint,
    sdk: sdkKey,
  );
}
