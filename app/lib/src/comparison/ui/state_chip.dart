import 'package:flutterware/comparison_report.dart';
import 'package:material_ui/material_ui.dart';

import '../../ui/theme.dart';

/// What a verdict looks like, in one place.
///
/// Colour is the fastest thing on the screen and the least precise: red means
/// three different things here — something broke, something was already broken,
/// something went away — so every chip carries its word too. A reader scanning
/// for red finds the rows worth looking at; a reader who needs to know which
/// red reads two more characters.
extension ComparedStateLook on ComparedState {
  Color colorIn(BuildContext context) {
    var colors = context.colors;
    return switch (this) {
      ComparedState.broke || ComparedState.failed => colors.red,
      ComparedState.wasBroken => colors.warningText,
      ComparedState.added => colors.grn,
      ComparedState.removed => colors.red,
      ComparedState.changed => colors.amber,
      ComparedState.same || ComparedState.skipped => colors.mut,
    };
  }

  /// The colour of the sentence under a verdict — its `note`.
  ///
  /// Red for a failure and for nothing else. A note was a failure's message
  /// when there was one kind of note, so every one of them was drawn in red;
  /// since then a note is as often an explanation — *the test finds its target
  /// another way*, under a step that came out the same — and an explanation in
  /// red reads as the error it is there to rule out.
  Color noteColorIn(BuildContext context) {
    var colors = context.colors;
    return switch (this) {
      ComparedState.broke ||
      ComparedState.failed ||
      ComparedState.wasBroken => colors.red,
      _ => colors.ink2,
    };
  }

  /// How it reads in a row. `wasBroken` is the one that does not spell itself.
  String get word => switch (this) {
    ComparedState.broke => 'broke',
    ComparedState.failed => 'failed',
    ComparedState.wasBroken => 'was broken',
    ComparedState.added => 'added',
    ComparedState.removed => 'removed',
    ComparedState.changed => 'changed',
    ComparedState.same => 'same',
    ComparedState.skipped => 'skipped',
  };
}

/// A verdict, as a small filled label.
class StateChip extends StatelessWidget {
  const StateChip(this.state, {super.key, this.count}) : _unsure = false;

  /// A scenario that was replayed and produced no result — see
  /// `ScenarioComparison.inconclusive`. On the wire it is `skipped`, and
  /// drawn as `skipped` it would say the opposite of what happened: every one
  /// of these was looked at.
  const StateChip.notCompared({super.key, this.count})
    : state = ComparedState.skipped,
      _unsure = true;

  /// The chip [scenario]'s verdict is drawn as.
  factory StateChip.of(ScenarioComparison scenario, {Key? key}) =>
      scenario.compared
      ? StateChip(scenario.state, key: key)
      : StateChip.notCompared(key: key);

  final ComparedState state;
  final bool _unsure;

  /// How many rows are in this state, when the chip is standing for a group.
  final int? count;

  @override
  Widget build(BuildContext context) {
    var color = _unsure ? context.colors.warningText : state.colorIn(context);
    var word = _unsure ? 'no result' : state.word;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.sm,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      child: Text(
        count == null ? word : '$count $word',
        style: context.type.micro.copyWith(color: color),
      ),
    );
  }
}
