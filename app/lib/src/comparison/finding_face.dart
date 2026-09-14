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
