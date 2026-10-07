import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The bundle a scenario reads its assets through: one that caches **values**,
/// never futures.
///
/// `rootBundle` is a [CachingAssetBundle], which memoizes the *future* of a
/// read. Under fake time that future belongs to the fake zone — it completes
/// when a pump flushes the fake microtask queue and at no other moment. Hand it
/// to `tester.runAsync`, where no pump can run, and the scenario stops dead:
/// no error, no output, until something far away times out.
///
/// Neither half of that is exotic. A screen showing an SVG puts the key in the
/// cache; a later step reading the same SVG inside `runAsync` is what the
/// blank-screen hint recommends. One screen and one step is the whole recipe.
///
/// So this caches what came back rather than the promise of it. A hit is a
/// [SynchronousFuture], which resolves in whichever zone awaits it and
/// schedules nothing; a miss inside `runAsync` starts its own read, on the real
/// event loop, and completes there. No future here can be completable by only
/// one zone.
///
/// The cost of that is the cache being useless until the first read *returns*:
/// callers that all ask before then each start their own read, where
/// [CachingAssetBundle] would have handed them one future. That is a few extra
/// platform reads in the first frame of a scenario, and it is the trade the
/// whole class is — sharing an in-flight read is exactly the thing that
/// deadlocks.
///
/// A scenario has one, reachable as `s.assets` and installed over the tree it
/// pumps, so anything reaching for `DefaultAssetBundle.of(context)` — an
/// `Image.asset`, an `AssetImage`, a `SvgPicture.asset` — is already reading
/// through it.
class ScenarioAssetBundle extends AssetBundle {
  ScenarioAssetBundle({AssetBundle? source}) : _source = source ?? rootBundle;

  /// Where a miss actually reads from. Only [AssetBundle.load] and
  /// [AssetBundle.loadBuffer] are ever asked of it, and [CachingAssetBundle]
  /// caches neither — so the source's own memoization never comes into it, even
  /// when the source is `rootBundle`.
  final AssetBundle _source;

  final _strings = <String, String>{};
  final _structured = <String, Object?>{};
  final _structuredBinary = <String, Object?>{};

  /// Reads started here and not finished — the count a scenario reads to know
  /// that work it cannot see is genuinely in flight, rather than taking a turn
  /// of the real event loop to guess. See `landRealWork`.
  ///
  /// Everything an app reads through the bundle passes here, so an
  /// `SvgPicture.asset` or a `Lottie.asset` is counted for as long as its bytes
  /// are on the way — the part of those loads that costs the most and announces
  /// the least. The decode on the other end is not in it. A quick one lands on
  /// a guessed turn; a parse in an isolate — Lottie's `backgroundLoading` — can
  /// outlast every turn, and is the app's to announce through `RealWork`.
  int get readsInFlight => _readsInFlight;
  var _readsInFlight = 0;

  Future<T> _counted<T>(Future<T> read) {
    _readsInFlight++;
    return read.whenComplete(() => _readsInFlight--);
  }

  @override
  Future<ByteData> load(String key) => _counted(_source.load(key));

  @override
  Future<ui.ImmutableBuffer> loadBuffer(String key) =>
      _counted(_source.loadBuffer(key));

  @override
  Future<String> loadString(String key, {bool cache = true}) {
    if (cache) {
      if (_strings[key] case var cached?) return SynchronousFuture(cached);
    }
    return load(key).then((data) {
      // Decoded here rather than through `AssetBundle.loadString`, which hands
      // anything over 50KB to `compute`. That is an isolate, its result arrives
      // on the real event loop, and under fake time the real event loop turns
      // only inside `runAsync` — so a bundle of translations would load in
      // every lane except this one. Inline costs a millisecond or two.
      var value = utf8.decode(Uint8List.sublistView(data));
      if (cache) _strings[key] = value;
      return value;
    });
  }

  @override
  Future<T> loadStructuredData<T>(
    String key,
    Future<T> Function(String value) parser,
  ) {
    // `containsKey` rather than a null check: a parser that legitimately
    // produces null would otherwise be re-run on every call forever.
    if (_structured.containsKey(key)) {
      return SynchronousFuture(_structured[key] as T);
    }
    // `cache: false` for the same reason the SDK passes it: what is worth
    // keeping is the parsed value, not the string it was parsed from. Failures
    // cache nothing, so a read that threw is retried rather than remembered.
    return loadString(
      key,
      cache: false,
    ).then(parser).then((value) => _structured[key] = value);
  }

  @override
  Future<T> loadStructuredBinaryData<T>(
    String key,
    FutureOr<T> Function(ByteData data) parser,
  ) {
    if (_structuredBinary.containsKey(key)) {
      return SynchronousFuture(_structuredBinary[key] as T);
    }
    return load(key)
        .then(parser)
        .then((value) => _structuredBinary[key] = value);
  }

  @override
  void evict(String key) {
    _strings.remove(key);
    _structured.remove(key);
    _structuredBinary.remove(key);
  }

  @override
  void clear() {
    _strings.clear();
    _structured.clear();
    _structuredBinary.clear();
  }
}
