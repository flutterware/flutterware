import 'package:material_ui/material_ui.dart';
import 'package:flutterware/plugins.dart';
import 'package:path/path.dart' as p;

import '../../ui/field_row.dart';
import '../../ui/theme.dart';
import '../model/color.dart';
import '../model/config.dart';
import '../model/generated.dart';
import '../model/scan.dart';
import '../model/surface.dart';
import '../model/validation.dart';
import 'problem_list.dart';
import 'variant_tile.dart';

/// One cell, said in full, beside the matrix rather than instead of it.
///
/// This replaces a drill-in page and its back link. Selecting a tile used
/// to swap the whole panel for a single cell, which meant the comparison — the
/// only reason to draw eight of anything — disappeared at the moment you got
/// interested in one of them, and left a text link called "← All eight" as the
/// way home. Neither sibling panel navigates; the asset inspector and the
/// dependency list both put the detail beside the list and keep it there.
///
/// A view. The picture, the resolution, the problems and the files all arrive
/// as data; closing leaves as a callback.
class SplashCellInspector extends StatelessWidget {
  const SplashCellInspector({
    super.key,
    required this.picture,
    required this.resolution,
    required this.problems,
    required this.artifacts,
    this.device,
    this.onClose,
  });

  final SplashPicture picture;
  final SplashResolution resolution;

  /// Everything reported against this cell.
  final List<SplashProblem> problems;

  /// The generated files behind this cell — the ones a reader would open to
  /// check it themselves.
  final List<SplashArtifact> artifacts;

  /// The screen this cell is drawn as. Null falls back to the surface's own
  /// default.
  final Device? device;

  final VoidCallback? onClose;

  /// Wide enough for a 260px preview with the pane's padding either side, and
  /// for a [FieldRow] label column plus a path that does not immediately
  /// ellipsis.
  static const width = 380.0;

  SplashSurface get _surface => picture.composition.surface;
  SplashTheme get _theme => picture.composition.theme;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border(left: BorderSide(color: colors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            title: '${_surface.label} · ${_theme.label}',
            // Stated, not set: the size axis moves all eight cells at once, so
            // its control belongs over the matrix rather than on one pane.
            subtitle: device == null
                ? null
                : '${device!.label}  ·  '
                      '${device!.width.round()}×${device!.height.round()}',
            onClose: onClose,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(FwSpacing.xl),
              children: [
                Center(
                  child: SplashScreenBox(
                    composition: picture.composition,
                    enabled: resolution.enabled,
                    selected: false,
                    device: device,
                    slotHeight: 300,
                  ),
                ),
                const Gap(FwSpacing.xl),
                _Origin(picture),
                const Gap(FwSpacing.xxl),
                ..._values(context),
                if (problems.isNotEmpty) ...[
                  const Gap(FwSpacing.xxl),
                  Text('Problems', style: context.type.sectionLabel),
                  const Gap(FwSpacing.md),
                  for (var problem in problems) SplashProblemRow(problem),
                ],
                if (artifacts.isNotEmpty) ...[
                  const Gap(FwSpacing.xxl),
                  Text('Files', style: context.type.sectionLabel),
                  const Gap(FwSpacing.md),
                  for (var artifact in artifacts) _Artifact(artifact),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The caption block the tiles used to carry, tabulated.
  ///
  /// Six wrapped grey lines under a 168px thumbnail — times eight — is the
  /// thing that made the matrix unreadable. The same facts in a fixed label
  /// column, with the config key that won in the provenance slot, read as a
  /// table and answer the same question: *why is it that colour, and where do I
  /// change it.*
  List<Widget> _values(BuildContext context) {
    if (!resolution.enabled) {
      return [
        Text(
          'This platform is switched off in the config, so the generator '
          'writes nothing for it.',
          style: context.type.bodyMuted,
        ),
      ];
    }

    var background = resolution.backgroundImage.isPresent
        ? resolution.backgroundImage
        : resolution.color;

    return [
      for (var (label, resolved) in [
        ('Background', background),
        ('Image', resolution.image),
        ('Icon background', resolution.iconBackgroundColor),
        ('Branding', resolution.branding),
      ])
        if (resolved.isPresent)
          FieldRow(
            label,
            _isColour(label) ? '#${resolved.value!}' : resolved.value!,
            note: resolved.key,
            leading: _isColour(label) ? _Swatch(resolved.value!) : null,
            labelWidth: _labelWidth,
          ),
      if (resolution.image.isPresent)
        FieldRow(
          'Placement',
          resolution.placementSummary,
          labelWidth: _labelWidth,
        ),
      if (resolution.fallsBackToLight)
        FieldRow(
          'Dark',
          'No dark configuration, so the OS shows the light splash. The dark '
              'keys are a chain of their own and never fall through to the '
              'light ones.',
          labelWidth: _labelWidth,
        ),
      if (picture.composition.usesLauncherIcon)
        FieldRow(
          'Icon',
          'No android_12 image is set, so Android draws your launcher icon '
              'here, masked to a circle.',
          labelWidth: _labelWidth,
        ),
    ];
  }
}

/// Narrower than the shared default: the pane is 380 wide and the labels here
/// are one word.
const _labelWidth = 104.0;

bool _isColour(String label) =>
    label == 'Background' || label == 'Icon background';

/// The pane's own title bar, with the close control.
///
/// An × on the pane, not a back arrow on the page: nothing was navigated to, so
/// there is nowhere to go back to. Escape closes it too — see the panel.
class _Header extends StatelessWidget {
  const _Header({required this.title, this.subtitle, this.onClose});

  final String title;
  final String? subtitle;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.xl,
        FwSpacing.lg,
        FwSpacing.md,
        FwSpacing.lg,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.type.heading),
                if (subtitle != null) ...[
                  const Gap(FwSpacing.xxs),
                  Text(
                    subtitle!,
                    style: context.type.caption.copyWith(color: colors.mut2),
                  ),
                ],
              ],
            ),
          ),
          if (onClose != null)
            Tooltip(
              message: 'Close  ·  Esc',
              child: InkWell(
                onTap: onClose,
                borderRadius: BorderRadius.circular(context.radii.radius),
                child: Padding(
                  padding: const EdgeInsets.all(FwSpacing.xs),
                  child: Icon(
                    Icons.close,
                    size: FwIconSize.md,
                    color: colors.mut2,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Where the picture came from, at the size this view can afford.
///
/// On a tile this is one micro line, because eight of them have to stay out of
/// the way. Here it is the first thing under the picture and it carries the
/// full sentence, because this is the view opened to ask that question.
class _Origin extends StatelessWidget {
  const _Origin(this.picture);

  final SplashPicture picture;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var generated = picture.isGenerated;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              generated ? Icons.check_circle_outline : Icons.article_outlined,
              size: FwIconSize.sm,
              color: generated ? colors.accent : colors.mut2,
            ),
            const Gap(FwSpacing.xs),
            Text(
              picture.label,
              style: context.type.bodyStrong.copyWith(
                color: generated ? colors.accent : colors.mut,
              ),
            ),
          ],
        ),
        if (picture.reason case var reason?) ...[
          const Gap(FwSpacing.xs),
          Text(reason, style: context.type.caption),
        ],
      ],
    );
  }
}

class _Artifact extends StatelessWidget {
  const _Artifact(this.artifact);

  final SplashArtifact artifact;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var size = artifact.pixelWidth == null
        ? null
        : '${artifact.pixelWidth}×${artifact.pixelHeight}';
    // The basename and its folder, not the whole path: a 380px pane wraps
    // `android/app/src/main/res/drawable-mdpi/splash.png` onto two lines and
    // then repeats the density it has already printed in its own column. The
    // full paths are in the Generated output list at the foot of the matrix,
    // which has the width for them.
    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              p.basename(artifact.path),
              style: context.type.caption.copyWith(color: colors.mut),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Gap(FwSpacing.md),
          Text(
            p.basename(p.dirname(artifact.path)),
            style: context.type.micro.copyWith(color: colors.mut3),
          ),
          if (size != null) ...[
            const Gap(FwSpacing.md),
            SizedBox(
              width: 58,
              child: Text(
                size,
                textAlign: TextAlign.right,
                style: context.type.micro.copyWith(color: colors.mut3),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.value);

  final String value;

  @override
  Widget build(BuildContext context) => Container(
    width: 12,
    height: 12,
    margin: const EdgeInsets.only(top: 2),
    decoration: BoxDecoration(
      color: Color(parseSplashColor(value) ?? 0xFF000000),
      borderRadius: BorderRadius.circular(context.radii.micro),
      border: Border.all(color: context.colors.line),
    ),
  );
}
