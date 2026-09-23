import 'dart:async';

import 'package:clock/clock.dart';
import 'package:material_ui/material_ui.dart';

import 'design/design.dart';

/// One thing a start is waiting on, in the words of whatever is doing it.
///
/// [done] and [total] are set only where a real count exists, which across
/// everything this models is the render pass and nothing else. **A compile has
/// no denominator and must not be given a fake one**: a bar that fills at a
/// rate nobody measured is a bar that lies, and the seconds beside it already
/// do the one job — slow from hung — the bar would be pretending to do.
@immutable
class StartupTask {
  const StartupTask(this.label, {this.done, this.total});

  /// A sentence, already in the voice the strip will read it in.
  final String label;

  final int? done;
  final int? total;

  /// How far through, or null when there is nothing to be far through.
  double? get fraction {
    var total = this.total;
    var done = this.done;
    if (total == null || done == null || total <= 0) return null;
    return (done / total).clamp(0.0, 1.0);
  }

  @override
  bool operator ==(Object other) =>
      other is StartupTask &&
      other.label == label &&
      other.done == done &&
      other.total == total;

  @override
  int get hashCode => Object.hash(label, done, total);

  @override
  String toString() => total == null ? label : '$label ($done/$total)';
}

/// What a start is doing, merged across every lane doing it.
///
/// **One model because the person waiting is waiting for one thing.** Opening
/// the previews catalog runs two compilers of the same program at once — the
/// daemon building the live guest, and the `flutter_tester` harness
/// photographing the page — and neither knows the other exists. Two progress
/// surfaces reporting that would be an accurate description of the
/// implementation and a useless description of the wait.
///
/// It answers three questions and no others:
///
/// - **what is happening**, in the lane's own words
/// - **how long it has been happening**, in seconds, climbing, because a count
///   that is climbing is the only thing on screen that distinguishes slow from
///   hung
/// - **how much of it is left**, where a count exists — see [StartupTask]
///
/// Lane-agnostic on purpose: previews and scenarios come up through the same
/// harness and wait the same wait for the same reason.
class StartupProgress extends ChangeNotifier {
  StartupProgress({this.appearsAfter = const Duration(milliseconds: 300)});

  /// How long work must last before it is worth a surface.
  ///
  /// A warm start is tens of milliseconds — an attached daemon reports no
  /// phases at all, and a warm harness is a message and a frame — and a strip
  /// that appears and leaves inside that is a flash rather than news.
  final Duration appearsAfter;

  final _slots = <String, _Slot>{};

  /// Orders the slots by when their *label* was set, which is what makes the
  /// readout stable while several lanes overlap. See [task].
  var _sequence = 0;

  /// When this wait began, or null before there has been one.
  ///
  /// **Through `package:clock`, not a [Stopwatch].** A stopwatch reads the real
  /// clock, which a widget test cannot move — so the readout every rule below
  /// is about would be `0s` in every test that pumped an hour, and none of them
  /// could fail. The one thing this class is for is the number a person reads
  /// while they wait, and it has to be a number a test can advance.
  DateTime? _since;

  /// When the last lane closed, so a handover between lanes can be told from a
  /// wait that ended. See [_start].
  DateTime? _quietSince;

  Timer? _ticker;
  Timer? _floor;
  var _shown = false;
  var _disposed = false;

  /// What a surface should say, or null when nothing is worth saying.
  ///
  /// **The longest-running lane wins**, and the rule is there to stop the
  /// readout flickering: three lanes in flight would otherwise take turns being
  /// the label, several times a second, and a caption that changes faster than
  /// it can be read is a caption nobody reads. Picking the one that started
  /// first means the words change only when that lane finishes — which is news.
  StartupTask? get task {
    _Slot? best;
    for (var slot in _slots.values) {
      if (best == null || slot.at < best.at) best = slot;
    }
    return best?.task;
  }

  /// How long this whole wait has been going.
  ///
  /// The wait's own clock, not the current lane's. It is the number a person
  /// compares against the last time they opened the thing, and a figure that
  /// reset every time a phase handed over to the next would never reach it.
  Duration get elapsed {
    var since = _since;
    return since == null ? Duration.zero : clock.now().difference(since);
  }

  /// Whether there is something to show *and* it has lasted long enough to be
  /// worth showing. See [appearsAfter].
  bool get visible => _shown && _slots.isNotEmpty;

  /// [lane] is doing [task], or has stopped when it is null.
  ///
  /// Idempotent: reporting the same task twice changes nothing and notifies
  /// nobody, so a lane may call this from a build or on every line it reads.
  void report(String lane, StartupTask? task) {
    if (_disposed) return;
    var slot = _slots[lane];
    if (task == null) {
      if (slot == null) return;
      _slots.remove(lane);
      if (_slots.isEmpty) _stop();
      notifyListeners();
      return;
    }
    if (slot != null && slot.task == task) return;
    if (slot != null && slot.task.label == task.label) {
      // The same thing, further along. The sequence is kept so a lane that
      // counts does not keep restarting its own claim on the label.
      slot.task = task;
    } else {
      _slots[lane] = _Slot(task, _sequence++);
    }
    _start();
    notifyListeners();
  }

  /// Everything is over — drop every lane at once.
  ///
  /// For the caller that knows the wait ended rather than the one that knows
  /// its own lane did: a session that failed has no lane left to report a
  /// stop, and a strip counting the seconds of a start that died is the one
  /// reading worse than saying nothing.
  void finish() {
    if (_disposed || _slots.isEmpty) return;
    _slots.clear();
    _stop();
    notifyListeners();
  }

  void _start() {
    if (_quietSince == null && _since != null) return;
    // **One wait, across the handovers between the lanes doing it.** Every lane
    // closes before the next opens — the harness reports ready, and the render
    // pass it unblocked opens a frame later — and a clock that reset in that gap
    // would show a first open that took forty seconds as `0s`, which is exactly
    // what it did. A gap shorter than the floor is not the end of anything.
    var quiet = _quietSince;
    var continuing =
        quiet != null && clock.now().difference(quiet) < appearsAfter;
    _quietSince = null;
    if (!continuing) _since = clock.now();
    if (continuing) {
      // And it does not blink back off, either: [_shown] is left exactly as the
      // handover found it, so a surface that had earned its way on screen stays
      // there and one that had not has still not.
      _ticker?.cancel();
      _tick();
      return;
    }
    _shown = false;
    _floor?.cancel();
    _floor = Timer(appearsAfter, () {
      if (_disposed || _slots.isEmpty) return;
      _shown = true;
      notifyListeners();
    });
    _tick();
  }

  /// A second, because the readout is in seconds. Anything finer rebuilds a
  /// surface that draws the same pixels.
  void _tick() {
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed || _slots.isEmpty) return;
      notifyListeners();
    });
  }

  void _stop() {
    _quietSince = clock.now();
    // [_shown] is deliberately left standing: [visible] already answers false
    // with no lanes, and clearing it here is what would make a handover blink.
    // The next wait that is genuinely new clears it in [_start].
    _floor?.cancel();
    _floor = null;
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _stop();
    super.dispose();
  }
}

class _Slot {
  _Slot(this.task, this.at);

  StartupTask task;

  /// When this lane's current *label* was set, on [StartupProgress._sequence].
  final int at;
}

/// The strip a page waits behind: what is happening, for how long, and a bar.
///
/// **Under the content and not over it.** Covering the page while the page
/// fills in is the one arrangement that makes the filling invisible — and the
/// filling is the thing being waited for. So this is a band that takes its own
/// room at the top, and gives it back the moment there is nothing left to say.
class StartupStrip extends StatelessWidget {
  const StartupStrip({super.key, required this.progress});

  final StartupProgress progress;

  /// The strip's own height, so a caller that has to reserve room knows what
  /// to reserve. The bar and the rule sit inside it.
  static const height = 34.0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: progress,
      builder: (context, _) {
        var task = progress.task;
        if (!progress.visible || task == null) {
          return const SizedBox.shrink();
        }
        var colors = context.colors;
        var fraction = task.fraction;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: height,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
                child: Row(
                  spacing: FwSpacing.md,
                  children: [
                    Expanded(
                      child: Text(
                        task.label,
                        style: context.type.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (task.total case var total? when task.done != null)
                      Text(
                        '${task.done} / $total',
                        style: context.type.caption.copyWith(
                          color: colors.mut,
                          fontFeatures: const [
                            // Or the count jitters sideways as its digits
                            // change, which on a readout that updates several
                            // times a second is the most distracting thing on
                            // the page.
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    Text(
                      '${progress.elapsed.inSeconds}s',
                      style: context.type.caption.copyWith(
                        color: colors.mut,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Indeterminate for a compile and determinate for the pass, which
            // is the whole of what this bar claims.
            SizedBox(
              height: 2,
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 2,
                backgroundColor: colors.line,
                color: colors.accent,
              ),
            ),
          ],
        );
      },
    );
  }
}
