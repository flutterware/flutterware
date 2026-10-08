/// One splash, reduced to the layers that draw it — **as data**.
///
/// This is the seam that lets the same picture reach the panel and `fw`: the
/// panel builds widgets from it, drawing live as the config changes, and
/// `fw describe` reads [summary] and answers "where does my logo go?" without
/// rendering anything at all.
///
/// Every rule about *where things go* has already been applied by the time one
/// of these exists. A renderer that reasons about `android_gravity` is a
/// renderer that will disagree with the other one.
library;

import 'color.dart';
import 'config.dart';
import 'image_facts.dart';
import 'surface.dart';

/// One image placed on the splash.
class SplashLayer {
  const SplashLayer({
    required this.path,
    required this.fit,
    required this.alignment,
    this.absolutePath,
    this.naturalWidth,
    this.naturalHeight,
    this.missing = false,
  });

  /// As the config spelled it.
  final String path;

  /// Where the renderer loads it from. Null when [missing].
  final String? absolutePath;

  final SplashFit fit;
  final SplashAlignment alignment;

  /// Logical size for a [SplashFit.none] placement — the 4×-density source
  /// divided by four. Null when the file could not be measured, in which case a
  /// renderer falls back to whatever intrinsic size it can get.
  final double? naturalWidth;
  final double? naturalHeight;

  /// Referenced but not on disk. Kept as a layer rather than dropped, so the
  /// preview can draw the hole where it should have been instead of quietly
  /// looking fine.
  final bool missing;
}

/// Everything needed to draw one cell of the matrix.
class SplashComposition {
  const SplashComposition({
    required this.surface,
    required this.theme,
    required this.enabled,
    this.backgroundColor,
    this.backgroundImage,
    this.image,
    this.iconBackgroundColor,
    this.iconCanvas,
    this.iconMaskFraction,
    this.branding,
    this.brandingAlignment = SplashAlignment.bottomCenter,
    this.brandingBottomPadding = 0,
    this.fullscreen = false,
    this.fallsBackToLight = false,
    this.usesLauncherIcon = false,
  });

  final SplashSurface surface;
  final SplashTheme theme;

  /// False when the project switched this platform off — the cell draws as
  /// disabled rather than as an empty splash, which are different facts.
  final bool enabled;

  /// Opaque ARGB. Null when the config set no colour, which for every surface
  /// but Android 12 is a configuration error.
  final int? backgroundColor;

  /// Always drawn to cover the whole canvas — the generator scales it to the
  /// screen and offers no mode for it.
  final SplashLayer? backgroundImage;

  final SplashLayer? image;

  /// Android 12 only: the circle drawn behind the icon.
  final int? iconBackgroundColor;

  /// Android 12 only: the icon slot, in logical pixels. Android draws the
  /// splash icon at 240dp with the inner 160dp visible; [iconMaskFraction] is
  /// the ratio between them.
  final double? iconCanvas;

  /// Android 12 only: the fraction of [iconCanvas] that survives the circular
  /// mask.
  final double? iconMaskFraction;

  final SplashLayer? branding;
  final SplashAlignment brandingAlignment;
  final int brandingBottomPadding;

  /// The status-bar band is not drawn.
  final bool fullscreen;

  /// This is a dark cell showing the light configuration, because the dark
  /// chain resolved nothing and the OS will do the same.
  final bool fallsBackToLight;

  /// [image] is the app's launcher icon rather than anything the config named —
  /// what Android 12 draws when `android_12.image` resolves nothing.
  ///
  /// Carried separately from the layer because the picture is honest and the
  /// caption still has to say the image is not the author's choice.
  final bool usesLauncherIcon;

  bool get isEmpty =>
      backgroundColor == null && backgroundImage == null && image == null;

  /// The composition in words — what `fw describe` prints.
  String get summary {
    if (!enabled) return 'disabled for this platform';
    var parts = <String>[
      if (backgroundColor != null)
        'background ${formatSplashColor(backgroundColor!)}',
      if (backgroundImage != null) 'background image ${backgroundImage!.path}',
      if (usesLauncherIcon)
        'the launcher icon ${image!.path} (no android_12 image)'
      else if (image != null)
        'image ${image!.path} ${_placement(image!)}'
      else
        'no image',
      if (iconBackgroundColor != null)
        'icon background ${formatSplashColor(iconBackgroundColor!)}',
      if (iconMaskFraction != null)
        'masked to a circle at ${(iconMaskFraction! * 100).round()}% of the icon',
      if (branding != null)
        'branding ${branding!.path} ${brandingAlignment.label}',
      if (fullscreen) 'fullscreen',
    ];
    if (fallsBackToLight) {
      parts.add('no dark config, so the OS shows the light splash');
    }
    return parts.join('; ');
  }

  static String _placement(SplashLayer layer) {
    var scale = switch (layer.fit) {
      SplashFit.none => 'at natural size',
      SplashFit.contain => 'scaled to fit',
      SplashFit.cover => 'scaled to fill, cropped',
      SplashFit.fill => 'stretched to fill',
      SplashFit.fillWidth => 'stretched horizontally',
      SplashFit.fillHeight => 'stretched vertically',
    };
    return '${layer.alignment.label}, $scale';
  }
}

/// Builds a composition from a resolution and what the referenced files turned
/// out to be.
///
/// [facts] is looked up by the path the config wrote, which is how a missing
/// file becomes a drawn hole rather than a silent omission.
SplashComposition composeSplash(
  SplashResolution resolution, {
  required SplashImageFacts? Function(String path) facts,
  SplashImageFacts? launcherIcon,
}) {
  SplashLayer? layerFor(
    Resolved<String> resolved, {
    required SplashFit fit,
    required SplashAlignment alignment,
  }) {
    var path = resolved.value;
    if (path == null) return null;
    var known = facts(path);
    if (known == null || !known.exists) {
      return SplashLayer(
        path: path,
        fit: fit,
        alignment: alignment,
        missing: true,
      );
    }
    return SplashLayer(
      path: path,
      absolutePath: known.absolutePath,
      fit: fit,
      alignment: alignment,
      naturalWidth: known.pixelWidth == null
          ? null
          : known.pixelWidth! / sourceDensity,
      naturalHeight: known.pixelHeight == null
          ? null
          : known.pixelHeight! / sourceDensity,
    );
  }

  var isAndroid12 = resolution.surface == SplashSurface.android12;

  // The Android 12 cell with no icon of its own is not empty — the generator
  // writes no `windowSplashScreenAnimatedIcon`, and Android draws the launcher
  // icon into that slot. Drawing nothing here would be the one thing a preview
  // must not do: show a picture no device will ever produce.
  var usesLauncherIcon =
      isAndroid12 && !resolution.image.isPresent && launcherIcon != null;

  var image = usesLauncherIcon
      ? SplashLayer(
          path: launcherIcon.path,
          absolutePath: launcherIcon.absolutePath,
          fit: SplashFit.contain,
          alignment: SplashAlignment.center,
        )
      : layerFor(
          resolution.image,
          fit: resolution.fit,
          alignment: resolution.alignment,
        );

  return SplashComposition(
    surface: resolution.surface,
    theme: resolution.theme,
    enabled: resolution.enabled,
    backgroundColor: parseSplashColor(resolution.color.value),
    backgroundImage: layerFor(
      resolution.backgroundImage,
      // The generator scales a background image to the screen; there is no key
      // to say otherwise, so neither is there a choice to model.
      fit: SplashFit.cover,
      alignment: SplashAlignment.center,
    ),
    image: image,
    usesLauncherIcon: usesLauncherIcon,
    iconBackgroundColor: parseSplashColor(resolution.iconBackgroundColor.value),
    iconCanvas: isAndroid12 ? android12IconCanvasDp : null,
    iconMaskFraction: isAndroid12 ? android12MaskFraction : null,
    branding: layerFor(
      resolution.branding,
      fit: SplashFit.none,
      alignment: resolution.brandingAlignment,
    ),
    brandingAlignment: resolution.brandingAlignment,
    brandingBottomPadding: resolution.brandingBottomPadding,
    fullscreen: resolution.fullscreen,
    fallsBackToLight: resolution.fallsBackToLight,
  );
}
