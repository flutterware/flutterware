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
