/// The previews stage: the guest's edge, and the one control its keyboard has.
///
/// What a stage *is* — the ground and the edge — moved to `ui/stage.dart` when
/// the run cockpit's Screen tab needed the same convention. What stays here is
/// what only a live guest has: an edge that says where the keyboard is going,
/// and a key that takes it back.
library;

import 'package:material_ui/material_ui.dart';

import '../ui/stage.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';

/// A [StageEdge] that also says where the keyboard is going.
///
/// The same line doing a second job: otherwise the only way to find out where
/// your keystrokes are landing is to type and see. Drawn only where nothing
/// else already draws an edge — a device body *is* one, and a border inside a
/// silhouette would be a second frame a millimetre in.
class StageSpecimen extends StatelessWidget {
  const StageSpecimen({super.key, required this.focus, required this.child});

  /// The node the guest's input region focuses on a click. The edge turns
  /// accent while it holds focus, which is the same line doing a second job:
  /// otherwise the only way to find out where your keystrokes are going is to
  /// type and see.
  final FocusNode focus;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // **The release, which the guest cannot do for itself.** Its input region
    // requests focus on pointer-down and nothing in the studio ever takes it
    // back — no panel control is focusable — so a node focused once stayed
    // focused until the panel was torn down, and the ring was permanently lit:
    // true, and useless for being true of everything.
    //
    // A `TapRegion` rather than a listener at the panel's root: the question is
    // whether the press landed on the picture, which is exactly what a region
    // knows, and which a root listener would have to work out from a rect that
    // moves with every zoom, pan and device change.
    return TapRegion(
      onTapOutside: (_) {
        if (focus.hasFocus) focus.unfocus();
      },
      child: ListenableBuilder(
        listenable: focus,
        // The picture passed through rather than rebuilt: what a focus change
        // moves is one colour, and rebuilding the texture underneath it for
        // that would drop the guest's frame on every click.
        child: child,
        builder: (context, child) => StageEdge(
          color: focus.hasFocus ? context.colors.accent : null,
          child: child!,
        ),
      ),
    );
  }
}

/// The one control the keyboard has: a key that takes it away.
///
/// Drawn by the host, over the guest's own pixels, and that split is the
/// design rather than an accident of where it was easy to put. The slab is
/// inside the guest so that every capture already contains a keyboard; this is
/// a tool affordance, and a tool affordance inside the guest would be in every
/// screenshot, every thumbnail and every web export of a demo that has nothing
/// to do with the studio.
///
/// It sits in the picture's own coordinates rather than the panel's, so it
/// scales with the specimen: magnify the stage and the key grows with the
/// keyboard it is on, which is what it would do if it were painted there.
///
/// Pressing it is not a mode change. [onDismiss] tells the guest its text
/// input connection went away — what a platform sends when the user closes the
/// IME without touching the app — so the field unfocuses and the keyboard
/// comes down *because the view dismissed it*. Making the artwork vanish
/// instead would be a keyboard the app never noticed leaving.
class StageKeyboardDismiss extends StatelessWidget {
  const StageKeyboardDismiss({
    super.key,
    required this.band,
    required this.onDismiss,
    required this.child,
  });

  /// How tall the keyboard is on screen, in the picture's logical pixels. Zero
  /// draws nothing at all — not a disabled key, nothing.
  final double band;

  final VoidCallback onDismiss;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (band <= 0) return child;
    // Proportional to the band, because the band is a measurement: the same
    // key on an iPhone SE's 260 points and an iPad Pro's 501 has to be the
    // same fraction of a keyboard, not the same number of pixels.
    var size = (band * 0.13).clamp(18.0, 34.0);
    var inset = size * 0.4;
    return Stack(
      children: [
        child,
        Positioned(
          right: inset,
          bottom: inset,
          child: Tooltip(
            message: 'Dismiss the keyboard',
            child: Tappable(
              onTap: onDismiss,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  // Its own ink and its own ground rather than the theme's:
                  // this is drawn over a keyboard whose colours come from the
                  // *staged* platform, which has no idea what the studio's
                  // palette is doing.
                  color: const Color(0xCC1F2023),
                  borderRadius: BorderRadius.circular(size * 0.25),
                ),
                child: Icon(
                  Icons.keyboard_hide,
                  size: size * 0.62,
                  color: const Color(0xFFFFFFFF),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
