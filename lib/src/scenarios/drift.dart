/// The facets two runs compare a step on — what [ScenarioStepDrift.what]
/// names when one of them moved.
///
/// `pixels` is the captured surface, and for a long time it was the whole
/// comparison. It is not the whole step: the status bar's tint, the nav bar's,
/// the height of the soft keyboard and whether the step settled at all are
/// recorded per step and drawn *around* the capture rather than into it, so a
/// change in any of them is invisible to a digest. A behaviour change that
/// reads as "nothing moved" is the most dangerous answer this can give, which
/// is why they are compared too.
abstract final class ScenarioDriftFacet {
  /// The captured surface — the step's digest.
  static const pixels = 'pixels';

  /// `SystemChrome`'s status-bar icon brightness, which the capture never
  /// contains: the frame around it is drawn from this field.
  static const statusBrightness = 'statusBrightness';

  /// The navigation bar's icon brightness, drawn the same way.
  static const navBrightness = 'navBrightness';

  /// The soft keyboard's height — a keyboard that stopped opening moves no
  /// pixels in a capture that never included it.
  static const keyboard = 'keyboard';

  /// Whether the step's frames had stopped when it was captured. Flips under
  /// machine load as well as under a real change, so it is named separately
  /// rather than folded into the count of steps whose pixels moved.
  static const settled = 'settled';

  /// Whether the step's transition landed. Load-sensitive the same way.
  static const landed = 'landed';
}

/// One step that moved between two runs of the same suite.
class ScenarioStepDrift {
  const ScenarioStepDrift({
    required this.package,
    required this.file,
    required this.scenario,
    required this.position,
    this.axes,
    this.name,
    this.what = const [],
  });

  final String package;

  /// The axis slug this point ran under, for a matrix run — steps are only
  /// ever compared against the same point of it.
  final String? axes;

  final String file;
  final String scenario;

  /// Where the step sat in its run — the branch path and the ordinal within
  /// it, as [ScenarioRunStep.position] spells it.
  ///
  /// Reported, not matched on: the ordinal counts captures since the branch
  /// began, so inserting one step renumbers every step below it. What the two
  /// runs are actually paired by is the `Shot` name where a step has one — see
  /// [ScenarioRunDrift.nameMatched] for how much of a comparison that covered.
  final String position;

  /// The `Shot`'s name, where it had one — what a reader recognises the step
  /// by, and what the two runs matched it on.
  final String? name;

  /// Which facets of the step differ, from [ScenarioDriftFacet] — `pixels`
  /// alone for the everyday case. Empty for a step only one of the runs
  /// captured, which did not differ so much as arrive or leave.
  final List<String> what;

  /// True when nothing but the captured surface moved — the case a digest
  /// comparison could already see.
  bool get isPixelsOnly =>
      what.length == 1 && what.single == ScenarioDriftFacet.pixels;

  /// How it reads in a line of output.
  String get label => [
    scenario,
    name ?? position,
    ?axes,
    if (what.isNotEmpty && !isPixelsOnly) '(${what.join(', ')})',
  ].join(' · ');

  @override
  String toString() => '$file $label';

  /// This step, saying which facets moved.
  ScenarioStepDrift movedIn(List<String> facets) => ScenarioStepDrift(
    package: package,
    axes: axes,
    file: file,
    scenario: scenario,
    position: position,
    name: name,
    what: facets,
  );

  Map<String, Object?> toJson() => {
    'package': package,
    if (axes != null) 'axes': axes,
    'file': file,
    'scenario': scenario,
    'position': position,
    if (name != null) 'name': name,
    if (what.isNotEmpty) 'what': what,
  };

  static ScenarioStepDrift fromJson(Map<String, Object?> json) =>
      ScenarioStepDrift(
        package: json['package'] as String? ?? '',
        axes: json['axes'] as String?,
        file: json['file'] as String? ?? '',
        scenario: json['scenario'] as String? ?? '',
        position: json['position'] as String? ?? '',
        name: json['name'] as String?,
        what: [
          for (var entry in json['what'] as List? ?? const [])
            if (entry is String) entry,
        ],
      );
}

/// What changed between two runs of one suite — nothing, if the suite is
/// deterministic.
///
/// See [compareScenarioRuns] for why this is worth asking.
class ScenarioRunDrift {
  const ScenarioRunDrift({
    required this.compared,
    required this.changed,
    required this.added,
    required this.removed,
    this.nameMatched = 0,
    this.unanchored = 0,
    this.baseline,
    this.file,
    this.pixelsIgnored = false,
  });

  /// True when the pixels were left out of the comparison because one of the
  /// runs was on the real clock: its pictures came off live data and differ
  /// from the last run's by weather. Said here so a reader of a quiet drift
  /// knows what quiet covers.
  final bool pixelsIgnored;

  /// Steps both runs captured, both carrying a digest — the denominator.
  final int compared;

  /// How many of [compared] were paired by their own `Shot` name.
  ///
  /// The strongest guarantee on offer: the two runs agree about which step is
  /// which no matter how the suite was edited between them. The remainder is
  /// not all equal, which is what [unanchored] separates — an unnamed step is
  /// pinned to the nearest name above it, and only a step with no name above
  /// it at all is loose.
  final int nameMatched;

  /// How many of [compared] were paired by nothing but the position they
  /// happened to sit at — no `Shot` name at or above them in their branch.
  ///
  /// The number to read before the counts below it. A position's ordinal
  /// counts captures since its branch began, so a single inserted step
  /// renumbers every step after it and the comparison answers with a cascade:
  /// one changed, one added and one removed per step below the cut, repeating,
  /// which is unreadable exactly when a suite has been edited. Zero means no
  /// step in this comparison could do that. Naming the shots is the fix; this
  /// is how a reader knows whether they need it.
  final int unanchored;

  /// Which run this one was compared against, worktree-relative — the
  /// directory holding its `run.json`.
  ///
  /// A baseline picked by walking backwards past panel sessions is not a
  /// baseline a reader can guess, and a number they cannot place the origin of
  /// is a number they cannot act on.
  final String? baseline;

  /// Where the whole of this is on disk, worktree-relative — every step of
  /// every list, uncapped, as `drift.json` beside the run's own report.
  ///
  /// [toJson] caps the lists it writes; this is the other half of that answer.
  final String? file;

  /// Steps both runs captured whose records disagree — the pixels, or one of
  /// the facets around them. Each says which in [ScenarioStepDrift.what].
  final List<ScenarioStepDrift> changed;

  /// Steps only the later run captured, and only the earlier one.
  final List<ScenarioStepDrift> added;
  final List<ScenarioStepDrift> removed;

  bool get isEmpty => changed.isEmpty && added.isEmpty && removed.isEmpty;

  /// How many changed steps moved in each facet, most-moved first. A step that
  /// moved in two is counted under both.
  Map<String, int> get byFacet {
    var counts = <String, int>{};
    for (var step in changed) {
      for (var facet in step.what) {
        counts[facet] = (counts[facet] ?? 0) + 1;
      }
    }
    return Map.fromEntries(
      counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)),
    );
  }

  /// The one line worth printing after a run, or null when the two runs agree
  /// about everything and there is nothing to say.
  ///
  /// Breaks the changed count down by facet whenever anything but the pixels
  /// moved — not merely when *several* facets did. "51 steps differ" reads as
  /// 51 screenshots that moved, so a drift where all 51 are a settle that ran
  /// out of budget on a loaded machine has to say so in the one line anybody
  /// reads. Pixels alone need no breakdown: that is what the sentence already
  /// means.
  String? get summary {
    if (isEmpty) return null;
    var facets = byFacet;
    var pixelsOnly =
        facets.length == 1 && facets.keys.single == ScenarioDriftFacet.pixels;
    var breakdown = facets.isEmpty || pixelsOnly
        ? ''
        : ' (${facets.entries.map((e) => '${e.value} ${e.key}').join(' · ')})';
    return [
      if (changed.isNotEmpty)
        '${changed.length} of $compared steps differ$breakdown',
      if (added.isNotEmpty) '${added.length} new',
      if (removed.isNotEmpty) '${removed.length} gone',
      // Only when it is the news. An unnamed step pinned to a name above it is
      // not fragile, and warning about those — most steps in most suites —
      // would train a reader to skip the line that matters.
      if (unanchored > 0) '$unanchored matched by position alone',
      if (pixelsIgnored) 'pictures not compared (real clock)',
    ].join(' · ');
  }

  /// [maxSteps] caps each list, the way every other projection in this report
  /// caps: a suite that moved everywhere would otherwise spend the whole
  /// answer saying so, and the count above the list is the part that matters.
  /// Null writes every step, which is what [file] holds.
  Map<String, Object?> toJson({int? maxSteps = 20}) {
    List<Map<String, Object?>> steps(List<ScenarioStepDrift> all) => [
      for (var step in maxSteps == null ? all : all.take(maxSteps))
        step.toJson(),
    ];
    return {
      'compared': compared,
      if (compared > 0) ...{
        'nameMatched': nameMatched,
        if (unanchored > 0) 'unanchored': unanchored,
      },
      if (baseline != null) 'baseline': baseline,
      if (file != null) 'file': file,
      if (pixelsIgnored) 'pixelsIgnored': true,
      if (changed.isNotEmpty) ...{
        'changed': changed.length,
        'byFacet': byFacet,
        'changedSteps': steps(changed),
      },
      if (added.isNotEmpty) ...{
        'added': added.length,
        'addedSteps': steps(added),
      },
      if (removed.isNotEmpty) ...{
        'removed': removed.length,
        'removedSteps': steps(removed),
      },
    };
  }

  /// Decodes what [toJson] wrote. The lists come back capped as they were
  /// written; the counts are whole, so `changed.length` and the count they
  /// were made from can disagree — [file] names the copy where they do not.
  static ScenarioRunDrift fromJson(Map<String, Object?> json) =>
      ScenarioRunDrift(
        compared: json['compared'] as int? ?? 0,
        nameMatched: json['nameMatched'] as int? ?? 0,
        unanchored: json['unanchored'] as int? ?? 0,
        baseline: json['baseline'] as String?,
        file: json['file'] as String?,
        pixelsIgnored: json['pixelsIgnored'] == true,
        changed: _steps(json['changedSteps']),
        added: _steps(json['addedSteps']),
        removed: _steps(json['removedSteps']),
      );

  /// This drift, saying where the whole of it was written.
  ScenarioRunDrift inFile(String path) => ScenarioRunDrift(
    compared: compared,
    nameMatched: nameMatched,
    unanchored: unanchored,
    baseline: baseline,
    file: path,
    pixelsIgnored: pixelsIgnored,
    changed: changed,
    added: added,
    removed: removed,
  );

  static List<ScenarioStepDrift> _steps(Object? raw) => switch (raw) {
    List list => [
      for (var entry in list)
        if (entry is Map<String, Object?>) ScenarioStepDrift.fromJson(entry),
    ],
    _ => const [],
  };
}
