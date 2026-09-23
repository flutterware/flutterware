import 'package:material_ui/material_ui.dart';

/// Motion that carries no information, declared by the app so a scenario can
/// photograph it standing still.
///
/// A spinner says "busy" whatever phase it is at. So does a shimmering
/// skeleton, a pulsing dot, a looping Lottie. None of them ever stops asking
/// for frames, so every scenario step with one on screen runs out its settle
/// budget, records `settled: false`, and costs the scenario its whole budget
/// on every replay — measured on a real suite, one spinner in a list row made
/// its scenario ten times slower than its siblings. Changing the app for the
/// test runner, or shortening the budget and still reporting the step
/// unsettled, both answer the wrong question.
///
/// ```dart
/// import 'package:flutterware/ambient.dart';
///
/// Ambient(child: CircularProgressIndicator())
/// ```
///
/// Outside a scenario it builds [child] and nothing else. Inside one, [child]
/// builds under `TickerMode(enabled: false)`, so nothing in it schedules a
/// frame, and every Material progress indicator in it without a controller of
/// its own is drawn at one fixed phase — the same picture on every run and
/// every machine, however many frames a step happened to pump.
///
/// The indicators take their phase from a stopped [AnimationController]
/// supplied through [ProgressIndicatorTheme], the framework's own seam for
/// who drives an indeterminate indicator. It takes both halves: the theme
/// controller alone still leaves the indicator's internal controller
/// repeating, and the ticker mode alone freezes the indicator at the start of
/// its cycle, which draws a dot where the spinner was. Anything else under
/// here freezes at its own start.
///
/// `Settle.strict` is not relaxed by it. A suite that calls a spinner in a
/// picture a bug still fails a step that ends with an [Ambient] on screen,
/// frozen or not: freezing makes the picture deterministic, not the loader
/// acceptable.
class Ambient extends StatefulWidget {
  const Ambient({super.key, required this.child});

  final Widget child;

  @override
  State<Ambient> createState() => _AmbientState();
}

/// Where in its cycle an indeterminate Material indicator is frozen.
///
/// Measured on each of them — circular and linear in both Material 3 styles,
/// and the refresh indicator: at 0.3 each draws a long arc or bar, where 0.5
/// draws the circular ones as a dot and 0 draws them as nothing at all.
const ambientPhase = 0.3;

/// Whether a scenario is running, and [Ambient] freezes what it holds. Set by
/// the harness for the length of each scenario body.
var ambientFrozen = false;

final _mounted = <_AmbientState>{};

/// Whether an [Ambient] is on screen: mounted, and under a [TickerMode] that
/// would let it animate if it were not frozen — so not on a route pushed
/// under another.
bool get ambientOnScreen => _mounted.any(
  (state) => state.mounted && TickerMode.valuesOf(state.context).enabled,
);

class _AmbientState extends State<Ambient> with SingleTickerProviderStateMixin {
  AnimationController? _still;

  @override
  void initState() {
    super.initState();
    _mounted.add(this);
  }

  @override
  void dispose() {
    _mounted.remove(this);
    _still?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ambientFrozen) return widget.child;
    var still = _still ??= AnimationController(
      vsync: this,
      value: ambientPhase,
    );
    return ProgressIndicatorTheme(
      data: ProgressIndicatorTheme.of(context).copyWith(controller: still),
      child: TickerMode(enabled: false, child: widget.child),
    );
  }
}
