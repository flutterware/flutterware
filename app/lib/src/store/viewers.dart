/// The two ways to look closer at an export, each answering one question.
///
/// They replace a per-shot detail *page*, which answered neither cleanly. That
/// page drew a listing with one shot outlined — but a listing is a property of
/// the **set**, not of a shot, so the outline was arbitrary and the page had a
/// selection it could not justify. Under it sat a "Full size" pane, which was
/// the second question wearing the first question's clothes.
///
/// Split, each becomes obvious:
///
/// * [showStoreShot] — *is this image right?* One image, as large as the
///   window allows, arrows through the set. Reached by clicking any thumbnail,
///   anywhere.
/// * [showStoreListing] — *does this set read?* The whole set in a listing
///   arrangement, no selection, with the placement chips. Reached from the
///   card the set is on.
///
/// Dialogs rather than pages, which also removes the navigation question a
/// detail page raised — no back stack, no route grammar, no stale key.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/design/design.dart';
import '../ui/theme.dart';
import '../ui/zoomable_canvas.dart';
import 'stage.dart';

/// *Is this image right?* — the pixels a store will receive.
Future<void> showStoreShot(
  BuildContext context, {
  required List<ImageProvider> shots,
  required List<String> titles,
  required int index,
  required String setLabel,
  required int width,
  required int height,
}) => showDialog<void>(
  context: context,
  barrierColor: Colors.black.withValues(alpha: 0.72),
  builder: (context) => _ShotViewer(
    shots: shots,
    titles: titles,
    initial: index,
    setLabel: setLabel,
    width: width,
    height: height,
  ),
);

/// *Does this set read?* — the whole listing, in order.
Future<void> showStoreListing(
  BuildContext context, {
  required List<ImageProvider> shots,
  required double aspect,
  required String appName,
  required String subtitle,
  required String setLabel,
}) => showDialog<void>(
  context: context,
  barrierColor: Colors.black.withValues(alpha: 0.72),
  builder: (context) => _ListingViewer(
    shots: shots,
    aspect: aspect,
    appName: appName,
    subtitle: subtitle,
    setLabel: setLabel,
  ),
);

class _ShotViewer extends StatefulWidget {
  const _ShotViewer({
    required this.shots,
    required this.titles,
    required this.initial,
    required this.setLabel,
    required this.width,
    required this.height,
  });

  final List<ImageProvider> shots;
  final List<String> titles;
  final int initial;
  final String setLabel;
  final int width;
  final int height;

  @override
  State<_ShotViewer> createState() => _ShotViewerState();
}

class _ShotViewerState extends State<_ShotViewer> {
  late var _index = widget.initial;

  void _move(int by) {
    var next = _index + by;
    if (next < 0 || next >= widget.shots.length) return;
    setState(() => _index = next);
  }

  /// Arrows move through the set, escape closes.
  ///
  /// A dialog is where a keyboard is expected to work, and a set is a sequence
  /// — the question *does shot 4 look like shot 3* is asked by pressing left,
  /// not by closing this and finding the previous thumbnail.
  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        _move(-1);
      case LogicalKeyboardKey.arrowRight:
        _move(1);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => _Shell(
    title: widget.titles[_index],
    subtitle:
        '${widget.setLabel}  ·  shot ${_index + 1} of ${widget.shots.length}'
        '  ·  ${widget.width} × ${widget.height} px',
    onKey: _onKey,
    leading: _Step(
      icon: Icons.chevron_left,
      tooltip: 'Previous shot',
      onPressed: _index == 0 ? null : () => _move(-1),
    ),
    trailing: _Step(
      icon: Icons.chevron_right,
      tooltip: 'Next shot',
      onPressed: _index == widget.shots.length - 1 ? null : () => _move(1),
    ),
    // **Sized explicitly, not fitted.** `ZoomableCanvas` runs its
    // `InteractiveViewer` with `constrained: false`, which is what lets you
    // pan past the edges — and it means the child is laid out against
    // unbounded constraints, so `BoxFit.contain` has nothing to contain
    // against and an `Image` takes its intrinsic size. A 1320×2868 screenshot
    // then opens at 1:1 with the viewport over its top-left corner, which on
    // this app's screenshots is a flat field of background: the first version
    // of this dialog looked like it had failed to load the image.
    //
    // Fitted to the window on arrival, because the first thing anyone wants is
    // the whole screenshot; zoom past 1:1 is what the canvas is for.
    child: LayoutBuilder(
      builder: (context, constraints) {
        var scale = math.min(
          constraints.maxWidth / widget.width,
          constraints.maxHeight / widget.height,
        );
        return ZoomableCanvas(
          minScale: 0.5,
          // Enough to pass native scale on any canvas this fits.
          maxScale: math.max(4, 1 / scale * 2),
          boundaryMargin: const EdgeInsets.all(400),
          // The child is given the viewport's own size and the image centred
          // in it — for the same reason it is sized explicitly: unbounded, the
          // canvas pins its child at the origin, so a centred image needs
          // something the size of the viewport to be centred *in*.
          child: SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: Center(
              child: Image(
                image: widget.shots[_index],
                width: widget.width * scale,
                height: widget.height * scale,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
                // The manifest and the images are read independently, so a
                // `flutter clean` under an open panel leaves entries pointing
                // at files that are gone. Every other image surface here
                // degrades to nothing; without this one the dialog throws and
                // paints Flutter's error box in the middle of itself.
                errorBuilder: (context, _, _) => Center(
                  child: Text(
                    'This image is no longer on disk. Export again.',
                    style: context.type.bodySmall.copyWith(
                      color: context.colors.mut2,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _ListingViewer extends StatefulWidget {
  const _ListingViewer({
    required this.shots,
    required this.aspect,
    required this.appName,
    required this.subtitle,
    required this.setLabel,
  });

  final List<ImageProvider> shots;
  final double aspect;
  final String appName;
  final String subtitle;
  final String setLabel;

  @override
  State<_ListingViewer> createState() => _ListingViewerState();
}

class _ListingViewerState extends State<_ListingViewer> {
  var _placement = StorePlacement.productPage;

  @override
  Widget build(BuildContext context) => _Shell(
    title: widget.setLabel,
    subtitle:
        '${widget.shots.length} shots, in the order a store will show them',
    trailing: _PlacementChips(
      placement: _placement,
      onChanged: (value) => setState(() => _placement = value),
    ),
    child: Center(
      child: SingleChildScrollView(
        child: StoreStage(
          shots: widget.shots,
          aspect: widget.aspect,
          appName: widget.appName,
          subtitle: widget.subtitle,
          placement: _placement,
        ),
      ),
    ),
  );
}

/// The frame both viewers sit in: a title row, a close, and the rest is the
/// thing being looked at.
class _Shell extends StatelessWidget {
  const _Shell({
    required this.title,
    required this.subtitle,
    required this.child,
    this.leading,
    this.trailing,
    this.onKey,
  });

  final String title;
  final String subtitle;
  final Widget child;

  /// Flanking the content — the shot viewer's prev/next arrows.
  final Widget? leading;

  /// A control in the title row — the listing viewer's placement chips.
  final Widget? trailing;
  final KeyEventResult Function(KeyEvent)? onKey;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var window = MediaQuery.sizeOf(context);
    // The arrows are a pair; `leading` alone would leave the content
    // off-centre by exactly one button.
    var tail = leading == null
        ? null
        : Opacity(opacity: 0, child: IgnorePointer(child: leading));
    return Dialog(
      backgroundColor: colors.bg,
      insetPadding: const EdgeInsets.all(FwSpacing.xxxl),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(context.radii.radiusLarge),
      ),
      child: Focus(
        autofocus: true,
        onKeyEvent: onKey == null ? null : (_, event) => onKey!(event),
        child: SizedBox(
          width: window.width,
          height: window.height,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  FwSpacing.xxl,
                  FwSpacing.lg,
                  FwSpacing.lg,
                  FwSpacing.lg,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: context.type.heading,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            subtitle,
                            style: context.type.caption.copyWith(
                              color: colors.mut2,
                            ),
                          ),
                        ],
                      ),
                    ),
                    ?trailing,
                    const Gap(FwSpacing.lg),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                      iconSize: FwIconSize.md,
                      tooltip: 'Close',
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: colors.line),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(FwSpacing.xl),
                  child: Row(
                    children: [
                      ?leading,
                      Expanded(child: child),
                      ?tail,
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    icon: Icon(icon),
    iconSize: FwIconSize.lg,
    tooltip: tooltip,
  );
}

/// Product page or search result — how much of a shot a person actually sees.
class _PlacementChips extends StatelessWidget {
  const _PlacementChips({required this.placement, required this.onChanged});

  final StorePlacement placement;
  final ValueChanged<StorePlacement> onChanged;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var value in StorePlacement.values)
          Padding(
            padding: const EdgeInsets.only(left: FwSpacing.xs),
            child: GestureDetector(
              onTap: () => onChanged(value),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: FwSpacing.lg,
                  vertical: FwSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: value == placement ? colors.accentSoft : null,
                  borderRadius: BorderRadius.circular(context.radii.pill),
                  border: Border.all(
                    color: value == placement ? colors.accent : colors.line,
                  ),
                ),
                child: Text(
                  value.label,
                  style: context.type.bodySmall.copyWith(
                    color: value == placement ? colors.accentDark : colors.mut,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
