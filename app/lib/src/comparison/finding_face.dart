import 'package:flutterware/comparison_report.dart';

/// Whether a picture of [item] shows its change.
///
/// Only a `changed` row can fail to: every other finding is a side that threw
/// or is missing, and that is on the picture. A `changed` row whose pixels did
/// not move changed only what no screenshot sees — events, texts, the tree —
/// and pictures as two identical frames. That is a finding, and the list says
/// so; it is not a picture.
bool showsInPicture(ComparedItem item) =>
    item.state != ComparedState.changed || (item.pixels?.changed ?? false);

/// The channels a `changed` [item] moved on when no picture shows it —
/// `[events]` for a step that only logged something new. Empty when a picture
/// does show the change.
///
/// What a reader skimming for visual changes has to be told: to them a
/// `changed` row reads as a screen that moved.
List<String> unseenChannels(ComparedItem item) =>
    showsInPicture(item) ? const [] : item.channelsFired;

/// [unseenChannels] for a whole flow: the channels its finding steps moved on,
/// when not one of them shows its change in a picture.
///
/// Empty as soon as one does, and for a flow that gained or lost a step or a
/// branch, which is a change to what the flow shows.
List<String> scenarioUnseenChannels(ScenarioComparison scenario) {
  if (scenario.state != ComparedState.changed || scenario.branches.isNotEmpty) {
    return const [];
  }
  var channels = <String>{};
  for (var step in scenario.items) {
    if (!isComparedFinding(step.state)) continue;
    if (showsInPicture(step)) return const [];
    channels.addAll(step.channelsFired);
  }
  // In the order every item names them, whichever step fired first.
  return [
    for (var channel in const ['tree', 'texts', 'events'])
      if (channels.contains(channel)) channel,
  ];
}

/// Whether [item] is `changed` and its two pictures are the same: it moved
/// only on channels no screenshot shows.
bool hasSamePicture(ComparedItem item) => unseenChannels(item).isNotEmpty;

/// [hasSamePicture] for a whole flow.
bool scenarioHasSamePicture(ScenarioComparison scenario) =>
    scenarioUnseenChannels(scenario).isNotEmpty;

/// The channels [finding] moved on when its pictures are the same, and nothing
/// when one shows the change — see [unseenChannels].
List<String> findingUnseenChannels(ComparedFinding finding) =>
    switch (finding) {
      ComparedFinding(:var preview?) => unseenChannels(preview),
      ComparedFinding(:var scenario?) => scenarioUnseenChannels(scenario),
      _ => const [],
    };

/// What a reader can see, apart from what they cannot.
///
/// [different] is ordered by state then by the largest pixel change, and
/// [samePicture] keeps the order it came in. Ranked by state and id alone, a
/// refactor that touched no pixel filled the first screen and the screen that
/// did move sat below it.
typedef SplitByLook<T> = ({List<T> different, List<T> samePicture});

SplitByLook<ComparedItem> splitItems(Iterable<ComparedItem> items) => _split(
  items,
  samePicture: hasSamePicture,
  state: (item) => item.state,
  change: (item) => _pictureChange([item]),
);

/// [splitItems] over flows.
SplitByLook<ScenarioComparison> splitScenarios(
  Iterable<ScenarioComparison> scenarios,
) => _split(
  scenarios,
  samePicture: scenarioHasSamePicture,
  state: (scenario) => scenario.state,
  change: (scenario) => _pictureChange(scenario.items),
);

/// [splitItems] over the findings of both halves.
SplitByLook<ComparedFinding> splitFindings(
  Iterable<ComparedFinding> findings,
) => _split(
  findings,
  samePicture: (finding) => findingUnseenChannels(finding).isNotEmpty,
  state: (finding) => finding.state,
  change: (finding) =>
      _pictureChange([?finding.preview, ...?finding.scenario?.items]),
);

/// The largest share of a frame any of [items] repainted.
double _pictureChange(Iterable<ComparedItem> items) {
  var largest = 0.0;
  for (var item in items) {
    var pixels = item.pixels;
    if (pixels == null || !pixels.changed) continue;
    if (pixels.diff.fraction > largest) largest = pixels.diff.fraction;
  }
  return largest;
}

SplitByLook<T> _split<T>(
  Iterable<T> entries, {
  required bool Function(T) samePicture,
  required ComparedState Function(T) state,
  required double Function(T) change,
}) {
  var different = <(int, T)>[];
  var same = <T>[];
  for (var (index, entry) in entries.indexed) {
    if (samePicture(entry)) {
      same.add(entry);
    } else {
      different.add((index, entry));
    }
  }
  different.sort((a, b) {
    var by = state(a.$2).index.compareTo(state(b.$2).index);
    if (by != 0) return by;
    by = change(b.$2).compareTo(change(a.$2));
    // The order they came in between equals, which is by id.
    return by != 0 ? by : a.$1.compareTo(b.$1);
  });
  return (
    different: [for (var (_, entry) in different) entry],
    samePicture: same,
  );
}

/// The verdict in words, as the page's title says it: how many findings are in
/// each state, worst first, then how many changed under the same picture —
/// `2 added · 9 changed · 3 same picture`.
String verdictWords(Iterable<({ComparedState state, bool samePicture})> rows) {
  var counts = <ComparedState, int>{};
  var same = 0;
  for (var row in rows) {
    if (row.samePicture) {
      same++;
    } else {
      counts[row.state] = (counts[row.state] ?? 0) + 1;
    }
  }
  return [
    for (var state in ComparedState.values)
      if (counts[state] case var count?) '$count ${state.name}',
    if (same > 0) '$same same picture',
  ].join(' · ');
}

/// The step a picture of [scenario] is taken from, or null when no finding
/// step has frames.
///
/// A flow's own verdict is a roll-up and carries no picture. Of its finding
/// steps that have frames, the face is the worst one whose picture
/// [showsInPicture], and only when none does, the worst of the rest. Ranked by
/// state alone, a flow that fired an event at its first step and moved a
/// layout at its third showed the first: two identical frames standing for a
/// change that is visible two steps later.
ComparedItem? scenarioFace(ScenarioComparison scenario) {
  ComparedItem? face;
  for (var step in scenario.items) {
    if (!isComparedFinding(step.state)) continue;
    if (scenario.frames[step.id] == null) continue;
    if (face == null || _outranks(step, face)) face = step;
  }
  return face;
}

bool _outranks(ComparedItem step, ComparedItem face) {
  var shows = showsInPicture(step);
  if (shows != showsInPicture(face)) return shows;
  return step.state.index < face.state.index;
}
