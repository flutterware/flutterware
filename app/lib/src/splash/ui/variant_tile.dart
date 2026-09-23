import 'package:material_ui/material_ui.dart';
import 'package:flutterware/plugins.dart';

import '../../ui/theme.dart';
import '../model/composition.dart';
import '../model/config.dart';
import '../model/scan.dart';
import '../model/surface.dart';
import '../model/validation.dart';
import 'splash_render.dart';

/// One cell of the matrix: a splash at device scale, its name, and where the
/// picture came from.
///
/// Two lines, and they used to be six. The tile carried the whole
/// resolution — a colour swatch and its key, the image and its key, the
/// branding and its key, the placement sentence — because those lines were the
/// editor's click targets. The editor is gone, and eight tiles of wrapped grey
/// text were competing with the eight pictures they were under. The values
/// moved to `SplashCellInspector`, where they are a table and where a reader
/// has gone looking for them.
///
/// What is left is what changes how you read the picture rather than what is
/// in it: that the platform is off, that dark resolved nothing, that Android is
/// drawing your launcher icon. Those are states, not values, and each is a
/// short chip with the full sentence in its tooltip.
class SplashVariantTile extends StatelessWidget {
  const SplashVariantTile({
    super.key,
    required this.picture,
    required this.resolution,
    required this.problems,
    this.device,
    this.selected = false,
    this.onTap,
    this.width = 168,
    this.slotHeight = defaultSlotHeight,
  });

  /// The height every cell's screen is centred in, whatever its aspect. Tall
  /// enough that a portrait phone at the default [width] fills it.
  ///
  /// Fixed rather than per-aspect because the `Wrap` would otherwise size each
  /// cell to its own shape, and the one landscape cell among six portrait ones
  /// comes out a third of the height with its caption stranded halfway up the
  /// phones beside it.
  static const defaultSlotHeight = 320.0;

  final SplashPicture picture;
  final SplashResolution resolution;
  final List<SplashProblem> problems;

  SplashComposition get composition => picture.composition;

  /// The screen to draw as, already resolved from the size axis. Null falls
  /// back to the surface's own canvas, which is what a matrix with no `?size=`
  /// shows.
  final Device? device;

  final bool selected;
  final VoidCallback? onTap;

  final double width;
  final double slotHeight;

  Tone? get _worst {
    Tone? worst;
    for (var problem in problems) {
      if (problem.tone == Tone.error) return Tone.error;
      if (problem.tone == Tone.warn) worst = Tone.warn;
    }
    return worst;
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var tone = _worst;

    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SplashScreenBox(
            composition: composition,
            device: device,
            enabled: resolution.enabled,
            selected: selected,
            slotHeight: slotHeight,
            onTap: onTap,
          ),
          const Gap(FwSpacing.md),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${composition.surface.label} · ${composition.theme.label}',
                  style: context.type.bodyStrong,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (tone != null)
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tone == Tone.error ? colors.red : colors.amber,
                  ),
                ),
            ],
          ),
          const Gap(FwSpacing.xxs),
          _Origin(picture),
          ..._notes(context),
        ],
      ),
    );
  }

  /// The state chips — never more than one in practice, and usually none.
  List<Widget> _notes(BuildContext context) {
    if (!resolution.enabled) {
      return [
        _Note(
          'Disabled',
          tooltip: 'This platform is switched off in the config.',
        ),
      ];
    }
    return [
      if (resolution.fallsBackToLight)
        _Note(
          'No dark config',
          warn: true,
          tooltip:
              'The dark keys are a chain of their own and never fall through '
              'to the light ones, so the OS shows the light splash.',
        ),
      if (composition.usesLauncherIcon)
        _Note(
          'Launcher icon',
          warn: true,
          tooltip:
              'No android_12 image is set, so Android draws your launcher '
              'icon here, masked to a circle.',
        ),
    ];
  }
}

/// A short state chip under a tile.
class _Note extends StatelessWidget {
  const _Note(this.label, {this.tooltip, this.warn = false});

  final String label;
  final String? tooltip;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var chip = Container(
      margin: const EdgeInsets.only(top: FwSpacing.xs),
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.sm,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(context.radii.pill),
        border: Border.all(color: warn ? colors.amber : colors.line),
      ),
      child: Text(
        label,
        style: context.type.micro.copyWith(
          color: warn ? colors.amber : colors.mut2,
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

/// Where the picture above came from, on every tile without exception.
///
/// Both states are labelled, not just the weak one. A line that appears only
/// on predictions reads as a warning badge, and its absence reads as nothing at
/// all rather than as "this one is real" — which leaves the reader unable to
/// tell a checked cell from an unlabelled one. Saying both costs one micro line
/// and makes the matrix answerable at a glance.
class _Origin extends StatelessWidget {
  const _Origin(this.picture);

  final SplashPicture picture;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var text = Text(
      picture.label,
      style: context.type.micro.copyWith(
        color: picture.isGenerated ? colors.accent : colors.mut3,
      ),
    );
    var reason = picture.reason;
    return reason == null ? text : Tooltip(message: reason, child: text);
  }
}

/// One splash drawn at device size and scaled to fit its slot.
///
/// Public because the inspector draws the selected cell at its own size, and the
/// tile and the pane must be the same widget — otherwise a difference on screen
/// is between two renderers rather than between two compositions.
class SplashScreenBox extends StatelessWidget {
  const SplashScreenBox({
    super.key,
    required this.composition,
    required this.enabled,
    required this.selected,
    this.slotHeight = SplashVariantTile.defaultSlotHeight,
    this.device,
    this.onTap,
  });

  final SplashComposition composition;
  final Device? device;
  final bool enabled;
  final bool selected;
  final double slotHeight;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var (width, height) = splashPreviewSize(
      composition.surface,
      width: device?.width,
      height: device?.height,
    );
    var radius = BorderRadius.circular(
      composition.surface == SplashSurface.web ? 6 : 18,
    );

    return GestureDetector(
      onTap: onTap,
      // A fixed slot, with the screen centred inside it.
      //
      // Without it the `Wrap` sizes each tile to its own aspect, and the web
      // surface — the one landscape cell among six portrait ones — comes out a
      // third of the height and hangs off the top of the row with its caption
      // stranded halfway up the phones beside it. One slot height puts every
      // caption on the same line, which is what makes eight cells scan as a
      // matrix rather than as a pile.
      child: SizedBox(
        height: slotHeight,
        child: Center(
          child: AspectRatio(
            aspectRatio: width / height,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(
                  color: selected ? colors.accent : colors.line,
                  width: selected ? 2 : 1,
                ),
              ),
              padding: const EdgeInsets.all(2),
              child: ClipRRect(
                borderRadius: radius,
                child: Opacity(
                  opacity: enabled ? 1 : 0.25,
                  // Rendered at device dimensions, then scaled — see
                  // `splashPreviewSize`. Without this a "natural size"
                  // placement would be measured against the thumbnail.
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: SizedBox(
                      width: width,
                      height: height,
                      child: SplashRender(
                        composition,
                        device: device,
                        // **Never on web.** The web cell borrows a phone's
                        // dimensions so the size axis can move it — a browser
                        // on a phone is a real place a splash is seen — but a
                        // browser has no notch and no home indicator, and
                        // drawing that hardware would be inventing it.
                        showSafeAreas:
                            device != null &&
                            composition.surface != SplashSurface.web,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
