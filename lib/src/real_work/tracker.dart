/// Work an app announces so a scenario can wait for it. Pure Dart: this file
/// is imported by app code through `package:flutterware/real_work.dart`, so it
/// reaches for nothing in Flutter or `flutter_test`.
library;

import 'dart:async';

/// Work that finishes on the **real** event loop, announced so a scenario's
/// next verb waits for it instead of guessing.
///
/// A scenario runs under fake time, where a settle follows frames and nothing
/// else. Work that resolves on the real event loop — a file read, a model
/// import, a decode on an engine thread, an isolate — schedules no frame while
/// it is in flight, so the tree looks finished and the step photographs a
/// placeholder. The harness lands the two kinds of such work it can see for
/// itself (a pending `ImageProvider`, an asset read through the scenario's
/// bundle) and spends a dozen turns of the real loop *guessing* at the rest —
/// enough for an SVG, nowhere near enough for a 6 MB import.
///
/// This is the third counter, and the only one the app fills in. Hand the
/// future here and every verb that follows waits, in real milliseconds, until
/// it has completed — then pumps, so whatever it set state on is drawn before
/// the step is judged or photographed:
///
/// ```dart
/// @override
/// void initState() {
///   super.initState();
///   _model = RealWork.track(_loadModel(), label: 'scene model');
/// }
/// ```
///
/// Outside a scenario it is a set insert, a listener on the future and a set
/// remove: no zone, no timer, no stack trace — that is captured only once a
/// scenario has started in the process, because only a scenario's deadline
/// ever reads it. A future tracked by one scenario is forgotten when the next
/// begins, so a load that never finished cannot hold every later scenario
/// hostage.
///
/// There is deliberately no counter-registration form. A process-wide counter
/// cannot be reset between scenarios by anything but the app, and a count left
/// non-zero by one scenario would be waited on by every scenario after it —
/// the shape the image cache already bit with. A counter is easy to turn into
/// a future: complete one when it reaches zero, and track that.
abstract final class RealWork {
  static final _pending = <TrackedRealWork>{};

  /// Whether anything will ever read [TrackedRealWork.announcedAt]. Set by
  /// the harness as the first scenario begins and never cleared: a stack
  /// unwind per call is nothing against a scenario and everything against a
  /// list rebuilding at 60Hz in a release build.
  static var _observed = false;

  /// What [TrackedRealWork.pendingFor] is measured on. Real time on purpose:
  /// the work is on the real event loop, and a scenario's clock is fake.
  static final _clock = Stopwatch()..start();

  /// Announces [work] and hands it straight back.
  ///
  /// [label] is what a diagnosis calls it — the deadline message names every
  /// tracked future still pending when a scenario runs out of time, and
  /// `scene model` reads better there than `Future<void>`.
  static Future<T> track<T>(Future<T> work, {String? label}) {
    var entry = _observed
        ? TrackedRealWork(label, StackTrace.current, since: _clock.elapsed)
        : TrackedRealWork(label, null);
    _pending.add(entry);
    void done(Object? _) => _pending.remove(entry);
    // `then` with an error handler rather than `whenComplete`: the future
    // this produces is nobody's, and an error propagated onto it would be an
    // unhandled one in whatever zone announced the work. The caller keeps the
    // original future, errors and all.
    work.then<void>(
      done,
      onError: (Object error, StackTrace stack) => done(null),
    );
    return work;
  }

  /// Runs [work] in the root zone and announces it, the way [track] does.
  ///
  /// The root zone is not a detail. A harness runs each screen in a zone of
  /// its own, and a future a dependency memoizes — an engine's one-time
  /// initialisation, an importer's shared tables — belongs to the zone that
  /// first created it. An `await` on that future from a *later* screen's
  /// zone never resumes: the continuation is queued to a zone whose queue
  /// nobody drains any more. Measured 2026-09-05: the first mount of a 3D
  /// probe loaded in two seconds, every mount after it waited out the whole
  /// ceiling with the load still pending. Run from the root zone, the
  /// continuations of [work] live on the real event loop, which every zone
  /// shares, and the caller's own `await` on the returned future resumes in
  /// the caller's zone as it should.
  ///
  /// This is the entry point for loading anything a dependency caches:
  /// `await RealWork.run(() => loadModel(bundle), label: 'model')`.
  ///
  /// Its outcome — value or error — is handed back through a future that
  /// belongs to the caller's zone, so an error is the caller's to catch and
  /// never the root zone's to report as unhandled, which under a test binding
  /// ends the process.
  static Future<T> run<T>(Future<T> Function() work, {String? label}) {
    var done = Completer<T>();
    Zone.root.run(() {
      work().then(done.complete, onError: done.completeError);
    });
    return track(done.future, label: label);
  }

  /// How many tracked futures have not completed.
  static int get pending => _pending.length;

  /// The pending ones, oldest first, for whoever is about to say why a
  /// scenario is stuck.
  static List<TrackedRealWork> get pendingWork => _pending.toList();
}

/// One announced future that has not completed yet.
class TrackedRealWork {
  TrackedRealWork(this.label, this.announcedAt, {Duration? since})
    // A named parameter cannot be private.
    // ignore: prefer_initializing_formals
    : _since = since;

  /// What the app called it, or null.
  final String? label;

  /// Where [RealWork.track] was called from — the app's own frames are the
  /// answer to "which load is this". Null outside a scenario, where nobody
  /// would read it.
  final StackTrace? announcedAt;

  final Duration? _since;

  /// How long it has been pending, in real time — or null outside a scenario,
  /// where nothing reads it and nothing is paid to know it.
  Duration? get pendingFor =>
      _since == null ? null : RealWork._clock.elapsed - _since;

  @override
  String toString() => label ?? 'untitled real work';
}

/// Forgets every tracked future. The harness calls this as each scenario
/// begins, for the reason `resetAnnouncedWork` clears the image cache: what a
/// scenario waits for should be work it started itself.
void resetTrackedRealWork() {
  RealWork._pending.clear();
  RealWork._observed = true;
}
