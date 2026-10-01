import 'dart:convert';
import 'dart:developer' as developer;

import '../guest_extensions.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'error.dart';

/// Catches what the framework reports while an entry builds and paints, so
/// that "it rendered" and "it rendered without exploding" stop being the same
/// answer.
///
/// A demo that throws paints Flutter's red `ErrorWidget` and **nothing else
/// changes**: the compile succeeded, the reload succeeded, the capture
/// succeeded, and every check that asserts on those passes while the picture is
/// an error. The generated entrypoint has printed `FW-ERROR:` to stdout for a
/// while, which makes it visible to a human watching a terminal and to nothing
/// else — the headless session reads stdout only to find the VM service URI.
///
/// This is the same information kept where it can be asked for.
class GuestErrors {
  GuestErrors._();

  static final instance = GuestErrors._();

  /// Bounded, because a demo that throws in `build` throws on every frame and
  /// an unbounded buffer in a live app is a leak. Distinct errors, not
  /// occurrences — repeats are counted rather than stored.
  static const _limit = 50;

  final _errors = <String, InspectError>{};

  String? _entryId;

  /// Installs the handler. Call once, before `runApp`.
  ///
  /// Chains rather than replaces: `FlutterError.presentError` is what puts the
  /// error on the console and in the red box, and swallowing that to collect
  /// it would trade a visible failure for a queryable one.
  void install() {
    var previous = FlutterError.onError;
    FlutterError.onError = (details) {
      report(details);
      (previous ?? FlutterError.presentError)(details);
    };
  }

  /// Records [details] without owning `FlutterError.onError`.
  ///
  /// [install] is for a guest that owns the handler for the life of the
  /// process. A **test binding does not allow that**: it installs its own
  /// handler per test, which is what makes a reported error fail the test, and
  /// replacing that would trade a red test for a queryable one. The preview
  /// harness chains onto it for the length of a single entry and calls this.
  ///
  /// Same buffer either way, deliberately: the embedder guest and the
  /// tester harness report the same errors, deduplicated by the same key and
  /// counted the same way, so their audits are comparable row for row.
  void report(FlutterErrorDetails details) {
    var first = _record(details);
    // Kept, and kept first, for a human watching the terminal — still the
    // fastest reader there is. Nothing greps for it any more: the check that
    // did needed a rendering guest, and went when `headless_check` did.
    //
    // **Only the first of each**, which the buffer has always known and the
    // print did not. An error thrown from `paint` fires once per frame, so
    // against a host that draws continuously this printed sixty lines a
    // second, for ever — through the embedder's log handler and out to the
    // GUI's own console. One overflowing demo was enough to drown the
    // process it was being inspected from.
    if (first) {
      // ignore: avoid_print
      print('FW-ERROR: ${details.exceptionAsString()}');
    }
  }

  /// Whether this is the first time this exact error has been seen.
  bool _record(FlutterErrorDetails details) {
    var error = InspectError(
      exception: details.exceptionAsString(),
      library: details.library,
      context: details.context?.toDescription(),
      network: details.exception is NetworkImageLoadException,
      frames: InspectError.framesOf(details.stack),
    );
    var existing = _errors[error.key];
    if (existing != null) {
      _errors[error.key] = InspectError(
        exception: existing.exception,
        library: existing.library,
        context: existing.context,
        count: existing.count + 1,
        network: existing.network,
        frames: existing.frames,
      );
      return false;
    }
    // Full: not recorded and not new, so it does not print either. A buffer
    // that has stopped listening should not go on shouting.
    if (_errors.length >= _limit) return false;
    _errors[error.key] = error;
    return true;
  }

  /// Forgets the previous entry's errors.
  ///
  /// Called from the same place the knobs and axes reset, and for the same
  /// reason: carrying one entry's failures into the next reports a demo as
  /// broken because the one before it was.
  ///
  /// Only on a change of entry, because this runs from `didUpdateWidget`
  /// and therefore on every rebuild — turning a knob would otherwise wipe the
  /// record of the throw the previous knob caused. Which leaves reloading *the
  /// same* entry with nothing to clear it, and that is what [clear] is for.
  void resetFor(String entryId) {
    if (_entryId == entryId) return;
    _entryId = entryId;
    _errors.clear();
  }

  /// Forgets everything, keeping the entry.
  ///
  /// The host decides when, because only the host knows what it just asked
  /// for. This is a record of what has been reported, not a reading of what
  /// is wrong now — nothing arrives to say an overflow *stopped*, so a demo
  /// that overflowed once keeps reporting it until this is called. That is
  /// right for a log and wrong for a panel headed Problems: you fix the
  /// overflow, reload, and the fixed problem is still listed.
  ///
  /// So a reload clears first and collects again. Doing it in the guest on
  /// every frame instead would make a transient layout error flicker in and
  /// out of the list, which is worse than either.
  void clear() => _errors.clear();

  InspectErrors describe() =>
      InspectErrors(entryId: _entryId, errors: [..._errors.values]);

  /// Registers the extension. Call once, before `runApp`.
  void registerExtensions() {
    GuestExtensions.register('ext.flutterware.errors', (_, _) async {
      return developer.ServiceExtensionResponse.result(
        jsonEncode(describe().toJson()),
      );
    });
    GuestExtensions.register('ext.flutterware.clearErrors', (_, _) async {
      clear();
      return developer.ServiceExtensionResponse.result(
        jsonEncode({'cleared': true}),
      );
    });
  }
}
