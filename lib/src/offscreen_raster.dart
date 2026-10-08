import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Whether the app is being rasterised into an image rather than onto the
/// screen, and the way to say so around a raster.
///
/// **An external `Texture` cannot be in that raster.** `toImage` — on a layer,
/// on a `RenderRepaintBoundary` — flattens the retained layer tree offscreen,
/// and an external texture is not in the layer tree: it is a handle the
/// platform compositor resolves at raster time, against a graphics context the
/// offscreen path does not have. What that costs depends on the host, and
/// neither answer is one to build on:
///
/// - **macOS** draws the texture's rectangle fully transparent, every sample,
///   zero alpha. `WindowCapture` exists because of it, and composites the
///   guest's own frame into the hole afterwards.
/// - **Linux**, on the pinned engine, **segfaults the whole application** on
///   the raster thread. The engine hands `LayerTree::Flatten` a null graphics
///   context by construction under Impeller, and the embedder's external
///   texture resolves against it without a null check.
///
/// So the texture comes out of the tree for the frame the raster photographs.
/// Nothing is lost: that rectangle has never carried the guest on either host,
/// and the picture that does is two captures composited.
///
/// **This is a workaround for an engine bug and should not outlive it.** When
/// `Flatten` gets a context, or the resolve gets its null check, this whole
/// file and the `GuestTexture` that watches it go away together and every
/// `Texture` goes back to being written plainly.
abstract final class OffscreenRaster {
  static final _notice = _Notice();

  /// True while a raster is in flight. Watch it from anything that must not be
  /// in one.
  static ValueListenable<bool> get notice => _notice;

  /// Runs [raster] with [notice] up, one frame after raising it.
  ///
  /// The frame is the point: `toImage` rasterises the tree the *last* frame
  /// left behind, so raising the notice and rastering in the same turn
  /// photographs the tree that still holds the texture. Nothing watching means
  /// nothing to wait for, and the frame is skipped — an app with no external
  /// texture pays nothing for this.
  ///
  /// A frame that never arrives leaves the previous tree in place, which on
  /// Linux is the crash this exists to prevent. The wait is capped anyway, and
  /// forced when the window is hidden, on the same reasoning as `settleLive`:
  /// an engine that refuses even a forced frame has already broken more than
  /// this.
  static Future<T> around<T>(Future<T> Function() raster) async {
    if (!_notice.watched) return raster();
    // **Counted, not set.** This process holds two rasters — the drive guest's
    // per-step screenshot and `WindowCapture` — and nothing serialises them
    // against each other. On a plain bool the inner one's `finally` puts the
    // texture back into the tree the outer one is still reading, which is the
    // crash this file exists to prevent, arriving intermittently and pointing
    // at the wrong caller.
    _depth++;
    _notice.value = true;
    try {
      await _oneFrame();
      return await raster();
    } finally {
      // The frame that puts the texture back is nobody's to wait for: the app
      // is live and paints it when it paints anything else.
      if (--_depth == 0) _notice.value = false;
    }
  }

  static var _depth = 0;

  static Future<void> _oneFrame() async {
    var binding = WidgetsBinding.instance;
    if (!binding.framesEnabled) binding.scheduleForcedFrame();
    var arrived = Completer<void>();
    void arrive() {
      if (!arrived.isCompleted) arrived.complete();
    }

    // Cancelled the moment the frame lands, rather than raced against with
    // `Future.any`: the loser of that race is a timer that outlives the answer
    // it was hedging, and a widget test is right to call that a leak.
    var cap = Timer(const Duration(milliseconds: 250), arrive);
    unawaited(binding.endOfFrame.then((_) => arrive()));
    try {
      await arrived.future;
    } finally {
      cap.cancel();
    }
  }
}

/// A [ValueNotifier] that will say whether anyone is listening.
///
/// [ChangeNotifier.hasListeners] is protected, and the answer is what decides
/// whether [OffscreenRaster.around] spends a frame.
class _Notice extends ValueNotifier<bool> {
  _Notice() : super(false);

  bool get watched => hasListeners;
}
