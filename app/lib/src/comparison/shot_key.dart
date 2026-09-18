import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The name a rendered picture is filed under: everything that decides its
/// pixels, hashed.
///
/// Two renders with the same key are the same picture, so a key that is
/// already in the cache is a render that does not have to happen. That is what
/// makes the base side free after the first comparison against a commit, and
/// what makes five worktrees branched off one base share one set of pictures.
///
/// The rule for what belongs in here is blunt: **if it can change a pixel, it
/// is in the key.** A forgotten input is a cache that serves a wrong picture,
/// and a wrong picture in a comparison is worse than no comparison — it is a
/// regression reported as clean.
class ShotKey {
  /// What the *tooling* renders like, as opposed to what the code says.
  ///
  /// Bump this whenever a change to the renderer changes a pixel — the
  /// generated entrypoint, the capture settings, the guest's own setup. None of
  /// those are in the closure of the entry being rendered, so without it a
  /// picture taken by last week's generator is served against one taken by
  /// today's, and the comparison reports a difference in the tooling as a
  /// difference in the branch. Measured: a warm cache answered *2 changed*
  /// where a cold one answered *3*, twice.
  ///
  /// v2 — the generated entrypoint pins the clock through `package:clock`
  /// rather than through flutterware's own wrapper.
  /// v3 — a capture waits for animations to stop, not only for images.
  /// v4 — the closure folds in the pixel inputs no compile names (assets,
  /// lockfiles, l10n bundles); every v3 key was computed without them and
  /// could be serving a picture of the wrong asset.
  /// v5 — previews render under `flutter_tester` (the audit's lane) rather
  /// than the embedder guest: a different engine, different settle, and a
  /// clock parked at a fake instant instead of read off the wall.
  /// v7 — the `flutter_tester` lane pins `package:clock`. Every v6 preview
  /// picture was taken at the wall clock of the run that took it, so an entry
  /// showing a date differs from itself across two runs; the pin is not in any
  /// entry's closure, so nothing else here would notice one side predating it.
  /// v6 — the framework's fragment shaders are bundled with a Metal stage. On
  /// macOS every v5 picture was taken from a bundle whose `ink_sparkle.frag`
  /// and `stretch_effect.frag` would not load, so an M3 ripple and a stretch
  /// overscroll are drawn now where they were absent then. Neither shader is
  /// in an entry's closure, and neither moves with the SDK, so nothing else
  /// here would have noticed.
  /// v8 — the bundle carries a real `NativeAssetsManifest.json`, so a render
  /// loads the hook-built native libraries where a v7 one took the VM's
  /// process fallback — on macOS, the *system's* SQLite rather than the
  /// bundled one. A picture whose pixels depend on the loaded library (a
  /// version string, a behavior the versions disagree on) differs across that
  /// line, and no library is in any entry's closure.
  /// v9 — `pubspec.lock` is folded in **per package** rather than whole. A
  /// v8 key hashed the entire lockfile into every entry; a v9 key hashes the
  /// entries of the packages that entry reaches, so the two disagree for
  /// every project with more than one dependency. Nothing about the pictures
  /// changed — the *keys* did, and a key that means something different is a
  /// key that must not be reused.
  /// v10 — the SDK is keyed by its framework and engine revisions rather than
  /// by its path, and a record says which tree format its tree was captured
  /// in. A v9 record has no such field, so it would read as captured before
  /// formats existed whatever captured it; re-rendering once is cheaper than
  /// reasoning about which ones that is true of. Scenario replays are filed
  /// under these keys from here on, so a change to how the scenario harness
  /// is generated or run bumps this too.
  /// v11 — a project's own `flutter: shaders:` load in the harness, and each
  /// declared shader and the local `#include`s it reaches are pixel inputs.
  /// Every v10 picture that asked for one was taken while its load failed
  /// with "Asset not found", so a pass it paints is drawn now where it was
  /// blank then; and a v10 key never read a `.frag`, so a branch that edited
  /// only a shader was served its base's picture as "same".
  /// v12 — a preview's settle waits for tracked real work up to
  /// `auditTrackedWait` rather than one second. Every v11 picture of an entry
  /// whose announced load took longer than that second on the machine that
  /// rendered it was taken with the load still in flight — its spinner rather
  /// than its content — and filed as if it were the entry.
  /// v13 — a package's `pubspec.yaml` is hashed as its pixel-relevant parts
  /// (`pubspecPixelDigest`) rather than as bytes, and a lockfile entry without
  /// its `dependency:` kind. Nothing about the pictures changed — the keys
  /// did, as at v9.
  /// v14 — every `split` branch of a scenario starts its pinned clock where
  /// the first run did. A v13 replay of a later branch read the fake time of
  /// the branches replayed before it, so anything it dated with `clock.now()`
  /// is drawn with an earlier date now.
  static const revision = 'v14';

  /// [closure] is a [SourceClosure.fingerprint]; [sdk] identifies the SDK both
  /// sides are rendered with; [axes] and [knobs] are whatever was applied.
  ///
  /// [extra] is for the inputs one caller has and another does not — a
  /// scenario's device and language, a preview's viewport — rather than a
  /// parameter per surface. Names are the caller's; ordering is not, because
  /// this sorts.
  static String of({
    required String kind,
    required String entryId,
    required String closure,
    required String sdk,
    Map<String, String> axes = const {},
    Map<String, String> knobs = const {},
    Map<String, String> extra = const {},
  }) {
    var buffer = StringBuffer()
      ..writeln(revision)
      ..writeln(kind)
      ..writeln(entryId)
      ..writeln(closure)
      ..writeln(sdk);
    _writeSorted(buffer, 'axes', axes);
    _writeSorted(buffer, 'knobs', knobs);
    _writeSorted(buffer, 'extra', extra);
    return sha1.convert(utf8.encode(buffer.toString())).toString();
  }

  /// Sorted, because a map's iteration order is its insertion order — so two
  /// callers applying the same two axes in the other order would otherwise
  /// render twice and cache twice.
  ///
  /// The name is written even when the section is empty, so "no knobs" and "a
  /// knob named nothing" cannot collide.
  static void _writeSorted(
    StringBuffer buffer,
    String section,
    Map<String, String> values,
  ) {
    buffer.writeln('[$section]');
    var keys = values.keys.toList()..sort();
    for (var key in keys) {
      buffer.writeln('$key=${values[key]}');
    }
  }
}
