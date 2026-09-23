/// One of the app's own screenshots, by path — the seam a store scene injects
/// real pixels through.
///
/// A scene carries *data*, so the thing a scene can hold is a path; turning
/// that path into pixels is the app's business, which is what makes this an
/// external widget rather than a node kind. The path is a scene **parameter**,
/// so `StoreHero(shot: …)` is the whole of what injecting a screenshot takes,
/// and the editor still sees a real picture on the canvas while you place it.
///
/// **Why `Image.file` and nothing cleverer.** The harness lane waits on
/// `ImageCache.pendingImageCount` before it photographs anything (see
/// `landRealWork`), and every `ImageProvider` passes through that counter — so
/// a scenario, a preview screenshot and a `scene video` frame all wait for this
/// decode without being told to. The one lane that does not is the offscreen
/// render lane, which mounts and pumps once; see the note in
/// the design note (2026-09-09-store-assets-from-scenes.md § 2d).
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'store_hero.dart';

class ShotImage extends StatelessWidget {
  const ShotImage(this.path, {super.key});

  /// Where the screenshot is. An absolute path is taken as it stands — that is
  /// what an export hands in. A relative one is resolved against the package,
  /// wherever the renderer happens to have been started, so a scene's *mockup
  /// default* can be a committed relative path and the editor canvas shows
  /// real pixels while you place things.
  final String path;

  @override
  Widget build(BuildContext context) {
    if (path.isEmpty) return const _NoShot();
    var file = p.isAbsolute(path) ? File(path) : findPackageFile(path);
    if (file == null || !file.existsSync()) return _NoShot(missing: path);
    return Image.file(
      file,
      // The screen mesh and this box are both 19.5:9, so `cover` crops
      // nothing; it is here for the day somebody points the scene at a
      // tablet shot and would rather see it cropped than stretched.
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
    );
  }
}

/// What stands in for a screenshot nobody has exported yet.
///
/// Deliberately a picture rather than a blank: a scene whose phone is empty on
/// the canvas is a scene you cannot judge the composition of, and a scene whose
/// phone is empty in an *export* is a bug that has to be loud.
class _NoShot extends StatelessWidget {
  const _NoShot({this.missing});

  final String? missing;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF1C2230),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          missing == null ? 'no screenshot' : 'no such file:\n$missing',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 22),
        ),
      ),
    ),
  );
}
