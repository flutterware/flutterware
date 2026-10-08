import 'dart:async';

/// The human's own steps, collected from a run that nobody is driving.
///
/// The guest records a tap the instant a finger lifts and photographs the
/// screen once a burst of them has settled, but it has no way to hand any of
/// that over: everything on this wire is pull, and the only puller was an
/// agent's `act`. A run the human is simply *using* therefore filled a buffer
/// and dropped it.
///
/// This is the puller for that case. It is the same shape as
/// [RunNetworkTracker] — a periodic poll with a re-entrancy guard and a
/// give-up after consecutive failures — over a much cheaper call: the guest's
/// `beats` extension neither settles nor walks a tree, it hands back records
/// that already exist and clears them.
class RunBeatTracker {
  RunBeatTracker({required this.drain, required this.onBeats});

  /// Takes everything the guest has buffered, and clears it.
  ///
  /// A function rather than a connection, because the run already has one:
  /// `DriveSession` holds a socket per run and repairs it on error, and a
  /// second socket polling the same app would be a second thing to keep alive
  /// for no gain.
  final Future<List<Map>> Function() drain;

  /// Called with each poll's records, oldest first, in the guest's own wire
  /// spelling — `at`, `verb`, `target`, and `screenshot`/`texts` on the one
  /// that ended a burst. Never called with an empty list.
  ///
  /// Whatever writes the journal must reconcile these against this process's
  /// own native input first: an `adb shell input tap` reaches the guest as
  /// ordinary platform input and comes back looking exactly like a finger.
  final void Function(List<Map> beats) onBeats;

  static const _maxFailures = 5;

  Timer? _timer;
  var _failures = 0;

  /// True once polling gave up — the app is gone, not idle.
  bool get broken => _failures >= _maxFailures;

  /// Takes everything the guest has buffered since the last poll. Returns how
  /// many records came back.
  ///
  /// A take clears, so this and an agent's `act` are two mouths on one buffer
  /// and never see the same record twice. Which of them gets a given tap is
  /// not worth controlling — both write it to the same story.
  Future<int> poll() async {
    var beats = await drain();
    if (beats.isEmpty) return 0;
    onBeats(beats);
    return beats.length;
  }

  /// Polls on [interval] until [stop] or the app stops answering.
  ///
  /// A second is generous rather than tuned: the guest's ring holds on the
  /// order of a hundred records, and a human producing one burst a second is
  /// already tapping hard, so the interval has two orders of magnitude of
  /// headroom before anything is dropped for being uncollected.
  void start([Duration interval = const Duration(seconds: 1)]) {
    if (_timer != null) return;
    _failures = 0;
    var polling = false;
    _timer = Timer.periodic(interval, (_) async {
      if (polling) return;
      polling = true;
      try {
        await poll();
        _failures = 0;
      } on Object {
        // An app mid-restart answers nothing for a moment, and that is not a
        // reason to stop watching it.
        _failures++;
        if (_failures >= _maxFailures) stop();
      } finally {
        polling = false;
      }
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => stop();
}
