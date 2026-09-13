/// The splash as the *generated files* describe it, not as the config predicts.
///
/// There is no runtime code in a splash. `flutter_native_splash:create` is a
/// pure generator: it writes files and exits, and the OS inflates those files at
/// launch. So the picture a device shows is fully determined by a recipe sitting
/// in the repo, and every ingredient of it is readable.
///
/// On Android the recipe is `drawable/launch_background.xml`, a layer-list:
///
/// ```xml
/// <layer-list>
///     <item><bitmap android:gravity="fill"   android:src="@drawable/background" /></item>
///     <item><bitmap android:gravity="center" android:src="@drawable/splash" /></item>
///     <item android:bottom="24dp"><bitmap android:src="@drawable/branding" /></item>
/// </layer-list>
/// ```
///
/// with `styles.xml` pointing `windowBackground` at it. The part that makes this
/// cheap: **even the colour is a PNG** — `_createBackground` renders it to
/// `background.png` rather than emitting a `<color>` drawable — so the whole
/// legacy splash is three bitmaps, one gravity each, and one padding number.
///
/// This is the panel's answer rather than a second opinion. Everything else
/// here reasons from the config through a hand-transcription of the generator's
/// `cli_commands.dart`, and a transcription can be confidently wrong — several
/// of them were, and the tests agreed with them, because the tests encoded the
/// same reading. What is on disk cannot be wrong about what is on disk. So a
/// cell shows this when it exists, and falls back to the prediction only where
/// there is nothing to read.
///
/// Web works the same way, in one file: 2.4.x inlines the stylesheet into
/// `web/index.html` as `<style id="splash-screen-style">` and puts the images in
/// two `<picture>` elements, so the colour, the dark media query, both srcsets
/// and the placement classes are all in one place.
///
/// iOS is the exception, permanently. `LaunchScreen.storyboard` is
/// constraints — a layout engine, not a recipe — and recomposing it would mean
/// implementing one. That surface stays predicted, and the panel says so on the
/// tile rather than leaving it to be inferred.
library;

import 'package:html/parser.dart' as html show parse;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'files.dart';
import 'color.dart';
import 'composition.dart';
import 'generated.dart';
import 'surface.dart';

/// What the generated Android resources say one cell will look like.
///
/// Null only when nothing has been generated for this package at all, or when
/// the surface is one whose output cannot be read back.
///
/// A dark cell with no dark resources is *not* null: it is the light splash,
/// because that is what the device shows. The generator writes
/// `drawable-night/` and `values-night-v31/` only when the config resolved
/// something dark, and Android falls back per file to the unqualified folder —
/// so resolving the same way is what makes this a readback of the device rather
/// than of the directory listing.
SplashComposition? recomposeSplash({
  required String packageRoot,
  required SplashSurface surface,
  required SplashTheme theme,
  required List<SplashArtifact> artifacts,
  String? flavor,
  SplashFiles files = const LiveSplashFiles(),
}) {
  if (surface == SplashSurface.web) {
    return _recomposeWeb(files, packageRoot, theme, artifacts);
  }
  if (surface != SplashSurface.android && surface != SplashSurface.android12) {
    return null;
  }
  var res = p.join(packageRoot, androidResFolder(flavor));
  if (!files.isDirectory(res)) return null;

  // **`launch_background.xml` is not evidence that anything was generated.**
  // `flutter create` writes one — `<item android:drawable="@android:color/white" />`
  // and a commented-out bitmap — into every project from the start. Reading it
  // as generator output produced a "What shipped" with no colour and no layers
  // in it, which the renderer drew as a **black rectangle**: a picture of a
  // splash no device would ever show, on a project that had simply never run
  // `create`.
  //
  // `background.png` is the honest marker, and it is exactly as unconditional as
  // `LaunchBackground.imageset` is on iOS (see `findSplashArtifacts`, which
  // already refuses to count the stock `LaunchImage.imageset` for the same
  // reason). `_createBackground` renders the colour to a 1×1 PNG and **throws**
  // when there is neither a colour nor a background image, so a successful
  // Android run always leaves one behind.
  var ran = artifacts.any(
    (a) =>
        a.role == SplashArtifactRole.background &&
        (a.surface == SplashSurface.android ||
            a.surface == SplashSurface.android12),
  );
  if (!ran) return null;

  return surface == SplashSurface.android12
      ? _recomposeAndroid12(files, packageRoot, res, theme, artifacts)
      : _recomposeLegacy(files, packageRoot, res, theme, artifacts);
}

// ---- Legacy ---------------------------------------------------------------

SplashComposition? _recomposeLegacy(
  SplashFiles files,
  String packageRoot,
  String res,
  SplashTheme theme,
  List<SplashArtifact> artifacts,
) {
  var document = _readQualified(
    files,
    res,
    theme,
    'drawable',
    'launch_background.xml',
  );
  if (document == null) return null;

  SplashLayer? layerFor(SplashArtifactRole role, String? gravity) {
    var artifact = _bestArtifact(artifacts, SplashSurface.android, theme, role);
    if (artifact == null) return null;
    var (fit, alignment) = parseAndroidGravity(gravity);
    // The drawable's pixels divided by its own density bucket — which is what
    // Android does with it, and the number the prediction has to match.
    var scale = splashDensityScale(artifact.density) ?? 1;
    return SplashLayer(
      path: artifact.path,
      absolutePath: p.join(packageRoot, artifact.path),
      fit: fit,
      alignment: alignment,
      naturalWidth: artifact.pixelWidth == null
          ? null
          : artifact.pixelWidth! / scale,
      naturalHeight: artifact.pixelHeight == null
          ? null
          : artifact.pixelHeight! / scale,
    );
  }

  String? gravityOf(String drawable) {
    for (var item in document.findAllElements('item')) {
      var bitmap = item.getElement('bitmap');
      if (bitmap?.getAttribute('android:src') == '@drawable/$drawable') {
        return bitmap?.getAttribute('android:gravity');
      }
    }
    return null;
  }

  bool has(String drawable) => document
      .findAllElements('bitmap')
      .any((b) => b.getAttribute('android:src') == '@drawable/$drawable');

  // `android:bottom="24dp"` on the branding item — the only number in the file.
  var brandingPadding = 0;
  for (var item in document.findAllElements('item')) {
    var bitmap = item.getElement('bitmap');
    if (bitmap?.getAttribute('android:src') != '@drawable/branding') continue;
    var bottom = item.getAttribute('android:bottom');
    if (bottom != null) {
      brandingPadding =
          int.tryParse(bottom.replaceAll(RegExp(r'[^0-9-]'), '')) ?? 0;
    }
  }

  return SplashComposition(
    surface: SplashSurface.android,
    theme: theme,
    enabled: true,
    // The background is a bitmap here, exactly as the layer-list says. Reading
    // a colour back out of it would mean decoding a PNG to learn something the
    // picture already shows.
    backgroundImage: has('background')
        ? layerFor(SplashArtifactRole.background, 'fill')
        : null,
    image: has('splash')
        ? layerFor(SplashArtifactRole.image, gravityOf('splash'))
        : null,
    branding: has('branding')
        ? layerFor(SplashArtifactRole.branding, gravityOf('branding'))
        : null,
    brandingAlignment: parseBrandingMode(
      _brandingModeFrom(gravityOf('branding')),
    ),
    brandingBottomPadding: brandingPadding,
  );
}

/// `android_gravity`'s spelling of a branding position, back to `branding_mode`.
String? _brandingModeFrom(String? gravity) {
  if (gravity == null) return null;
  if (gravity.contains('left') || gravity.contains('start')) {
    return 'bottomLeft';
  }
  if (gravity.contains('right') || gravity.contains('end')) {
    return 'bottomRight';
  }
  return 'bottom';
}

// ---- Android 12 -----------------------------------------------------------

SplashComposition? _recomposeAndroid12(
  SplashFiles files,
  String packageRoot,
  String res,
  SplashTheme theme,
  List<SplashArtifact> artifacts,
) {
  // `values-v31` and `values-night-v31`, the theme Android 12 and later read.
  var document = _readQualified(files, res, theme, 'values-v31', 'styles.xml');
  if (document == null) return null;

  var items = <String, String>{};
  for (var style in document.findAllElements('style')) {
    if (style.getAttribute('name') != 'LaunchTheme') continue;
    for (var item in style.findElements('item')) {
      var name = item.getAttribute('name');
      if (name != null) items[name] = item.innerText.trim();
    }
  }

  // These are literal `#RRGGBB` values in the generated theme, which is what
  // makes Android 12 the one surface whose *colour* can be checked against
  // ground truth without decoding anything.
  var background = parseSplashColor(
    _stripHash(items['android:windowSplashScreenBackground']),
  );
  var iconBackground = parseSplashColor(
    _stripHash(items['android:windowSplashScreenIconBackgroundColor']),
  );

  var hasIcon = items.containsKey('android:windowSplashScreenAnimatedIcon');
  var icon = hasIcon
      ? _bestArtifact(
          artifacts,
          SplashSurface.android12,
          theme,
          SplashArtifactRole.icon,
        )
      : null;

  // `windowSplashScreenBrandingImage`, which this used to ignore entirely — so
  // a project that generated an Android 12 branding image saw it in the
  // prediction and not in what shipped, and drift said nothing because
  // `compareSplash` had nothing to compare.
  //
  // The system positions this itself; there is no padding in the theme to read,
  // which is the same reason `branding_bottom_padding` does not reach this
  // surface (see `checkSplashFit`).
  var branding = items.containsKey('android:windowSplashScreenBrandingImage')
      ? _bestArtifact(
          artifacts,
          SplashSurface.android12,
          theme,
          SplashArtifactRole.branding,
        )
      : null;

  return SplashComposition(
    surface: SplashSurface.android12,
    theme: theme,
    enabled: true,
    backgroundColor: background,
    image: icon == null
        ? null
        : SplashLayer(
            path: icon.path,
            absolutePath: p.join(packageRoot, icon.path),
            fit: SplashFit.contain,
            alignment: SplashAlignment.center,
          ),
    iconBackgroundColor: iconBackground,
    iconCanvas: android12IconCanvasDp,
    iconMaskFraction: android12MaskFraction,
    // **The dp size is not optional on a `none` fit.** A layer with no natural
    // size falls back to the screen in `SplashRender`, so leaving it null drew
    // an 800×320 branding across the whole phone — three teal slabs behind the
    // icon, which is what "the Android 12 tile has two logos in it" turned out
    // to be. `drawable-xxxhdpi-v31/android12branding.png` is 800px because
    // 800 ÷ 4 is the 200dp Android sizes this slot at.
    branding: branding == null
        ? null
        : SplashLayer(
            path: branding.path,
            absolutePath: p.join(packageRoot, branding.path),
            fit: SplashFit.none,
            alignment: SplashAlignment.bottomCenter,
            naturalWidth: _dp(branding.pixelWidth, branding.density),
            naturalHeight: _dp(branding.pixelHeight, branding.density),
          ),
    // No animated icon in the theme means Android draws the launcher icon.
    usesLauncherIcon: !hasIcon,
  );
}

String? _stripHash(String? value) => value?.replaceFirst('#', '').trim();

/// A drawable's pixels as the dp Android draws them at — its own density bucket
/// divided out. Null when either half is unknown, which the renderer treats as
/// "size me to the screen".
double? _dp(int? pixels, String? density) {
  var scale = splashDensityScale(density);
  if (pixels == null || scale == null) return null;
  return pixels / scale;
}

// ---- Web ------------------------------------------------------------------

/// The whole web splash, read out of `web/index.html`.
///
/// There is no `style.css`. Older versions of the generator wrote one and
/// linked it; 2.4.x inlines everything — a `<style id="splash-screen-style">`
/// and a `<script id="splash-screen-script">` appended to `<head>`, and up to
/// two `<picture>` elements inserted at the top of `<body>` — and `_updateHtml`
/// removes the old `<link href="splash/style.css">` on sight. So one file holds
/// the colour, the media query, both `<source>` sets and the placement classes,
/// and `web/splash/img/` holds the pixels.
///
/// That makes web the *second* surface with a real readback, and the cheaper of
/// the two remaining: the CSS is four declarations we care about and the
/// placement is a class name. iOS stays predicted — a storyboard is constraints,
/// which is a layout engine rather than a recipe.
SplashComposition? _recomposeWeb(
  SplashFiles files,
  String packageRoot,
  SplashTheme theme,
  List<SplashArtifact> artifacts,
) {
  var index = files.readString(p.join(packageRoot, 'web', 'index.html'));
  if (index == null) return null;
  var document = html.parse(index);

  // The marker, and it is as unconditional here as `background.png` is on
  // Android: `_createSplashCss` always appends this element, and the only other
  // thing that touches it is the branch that removes the splash entirely. A
  // stock `web/index.html` has no `<style>` in its head at all, so — unlike
  // `launch_background.xml` — there is nothing here to mistake for output.
  var style = document.querySelector('style#splash-screen-style');
  if (style == null) return null;

  var css = style.text;
  var light = _cssBodyRule(css);
  var declarations = <String, String>{...light};
  if (theme == SplashTheme.dark) {
    // The `@media (prefers-color-scheme: dark)` block, layered on top rather
    // than read alone — it only ever sets `background-color` and
    // `background-image`, and everything it does not set keeps the light value,
    // which is the cascade doing what a cascade does.
    var dark = _cssDarkBlock(css);
    if (dark != null) declarations.addAll(_cssBodyRule(dark));
  }

  SplashLayer? layerFor(SplashArtifactRole role, String className) {
    var artifact = _bestWebArtifact(artifacts, theme, role);
    if (artifact == null) return null;
    var (fit, alignment) = _webClassPlacement(className);
    // The 1x file is the source quartered and the 4x file is the source, so
    // every density lands on the same CSS size — which is the number the
    // `<img>` is drawn at when nothing sizes it.
    var scale = _webDensityScale(artifact.density) ?? 1;
    return SplashLayer(
      path: artifact.path,
      absolutePath: p.join(packageRoot, artifact.path),
      fit: fit,
      alignment: alignment,
      naturalWidth: artifact.pixelWidth == null
          ? null
          : artifact.pixelWidth! / scale,
      naturalHeight: artifact.pixelHeight == null
          ? null
          : artifact.pixelHeight! / scale,
    );
  }

  var splash = document.querySelector('picture#splash');
  var brandingPicture = document.querySelector('picture#splash-branding');

  return SplashComposition(
    surface: SplashSurface.web,
    theme: theme,
    enabled: true,
    backgroundColor: parseSplashColor(
      _stripHash(declarations['background-color']),
    ),
    // `background-size: 100% 100%` in the template, on the element the image is
    // set on — so a web background image stretches to the viewport, whatever
    // its aspect.
    backgroundImage: declarations.containsKey('background-image')
        ? _webBackgroundLayer(packageRoot, artifacts, theme)
        : null,
    image: splash == null
        ? null
        : layerFor(
            SplashArtifactRole.image,
            splash.querySelector('img')?.className ?? '',
          ),
    branding: brandingPicture == null
        ? null
        : layerFor(
            SplashArtifactRole.branding,
            brandingPicture.querySelector('img')?.className ?? '',
          ),
    brandingAlignment: parseBrandingMode(
      brandingPicture?.querySelector('img')?.className,
    ),
    // The template has no offset on either branding class — `bottom: 0` — so
    // there is no number to read, and `branding_bottom_padding` never reaches
    // web in the first place.
    brandingBottomPadding: 0,
  );
}

SplashLayer? _webBackgroundLayer(
  String packageRoot,
  List<SplashArtifact> artifacts,
  SplashTheme theme,
) {
  var artifact = _bestWebArtifact(
    artifacts,
    theme,
    SplashArtifactRole.background,
  );
  if (artifact == null) return null;
  return SplashLayer(
    path: artifact.path,
    absolutePath: p.join(packageRoot, artifact.path),
    fit: SplashFit.fill,
    alignment: SplashAlignment.center,
  );
}

/// The `<img class="…">` the generator wrote, back to a placement.
///
/// The four image classes and the three branding ones share this: they are
/// disjoint, so one lookup serves both. Anything unrecognised is a hand-edit,
/// and drawing it at natural size in the centre is the least wrong guess.
Placement _webClassPlacement(String className) =>
    switch (className.trim().split(RegExp(r'\s+')).first) {
      'contain' => (SplashFit.contain, SplashAlignment.center),
      'stretch' => (SplashFit.fill, SplashAlignment.center),
      'cover' => (SplashFit.cover, SplashAlignment.center),
      'bottom' => (SplashFit.none, SplashAlignment.bottomCenter),
      'bottomLeft' => (SplashFit.none, SplashAlignment.bottomLeft),
      'bottomRight' => (SplashFit.none, SplashAlignment.bottomRight),
      _ => (SplashFit.none, SplashAlignment.center),
    };

/// `4x` → 4. The web equivalent of a density bucket, and the reason
/// [SplashArtifact.logicalWidth] refuses to answer for this surface: the
/// generator writes `source * density ~/ 4`, so the CSS size is the file's
/// pixels over its own multiplier.
double? _webDensityScale(String? density) {
  if (density == null) return null;
  var digits = density.replaceAll('x', '');
  return double.tryParse(digits);
}

/// The densest generated file for a role, falling back to light.
///
/// The fallback should never fire — `_createWebSplash` says
/// `darkImagePath ??= imagePath` and `brandingDarkImagePath ??=
/// brandingImagePath`, so both themes are always written together. It is here
/// because a browser given a `<source>` whose files are missing shows the
/// `<img src="splash/img/light-1x.png">` default, and a readback that returned
/// nothing would be describing a blank page nobody sees.
SplashArtifact? _bestWebArtifact(
  List<SplashArtifact> artifacts,
  SplashTheme theme,
  SplashArtifactRole role,
) {
  SplashArtifact? pick(SplashTheme wanted) {
    SplashArtifact? best;
    for (var artifact in artifacts) {
      if (artifact.surface != SplashSurface.web ||
          artifact.theme != wanted ||
          artifact.role != role) {
        continue;
      }
      var scale = _webDensityScale(artifact.density) ?? 1;
      var bestScale = best == null
          ? -1.0
          : (_webDensityScale(best.density) ?? 1);
      if (best == null || scale > bestScale) best = artifact;
    }
    return best;
  }

  return pick(theme) ??
      (theme == SplashTheme.dark ? pick(SplashTheme.light) : null);
}

/// The declarations of the first `body { … }` rule in [css].
///
/// A three-line scanner rather than a CSS parser, and that is a judgement about
/// the input: this stylesheet is one template with two substitutions in it, and
/// the rules that matter — `body` and the `body` inside the dark media query —
/// contain nothing but flat declarations. A parser would be more code for the
/// same four strings.
Map<String, String> _cssBodyRule(String css) {
  var match = RegExp(r'(^|[},])\s*body\s*\{').firstMatch(css);
  if (match == null) return const {};
  var open = css.indexOf('{', match.start);
  var close = css.indexOf('}', open);
  if (close < 0) return const {};

  var declarations = <String, String>{};
  for (var part in css.substring(open + 1, close).split(';')) {
    var colon = part.indexOf(':');
    if (colon < 0) continue;
    declarations[part.substring(0, colon).trim()] = part
        .substring(colon + 1)
        .trim();
  }
  return declarations;
}

/// The body of the `@media (prefers-color-scheme: dark)` rule, or null when the
/// generator wrote no dark block at all — which is itself the answer, and the
/// same fact `-night` folders carry on Android.
String? _cssDarkBlock(String css) {
  var match = RegExp(r'@media\s*\(\s*prefers-color-scheme\s*:\s*dark\s*\)\s*\{')
      .firstMatch(css);
  if (match == null) return null;

  var depth = 0;
  for (var i = match.end - 1; i < css.length; i++) {
    if (css[i] == '{') depth++;
    if (css[i] == '}') {
      depth--;
      if (depth == 0) return css.substring(match.end, i);
    }
  }
  return null;
}

// ---- Shared ---------------------------------------------------------------

/// One generated resource, resolved the way the platform resolves it.
///
/// `-night` falls back per file, not per folder. A dark cell whose project
/// has no `drawable-night/launch_background.xml` is not a cell with no answer —
/// it is the light splash, because that is the file Android will inflate. The
/// same holds for `values-night-v31/styles.xml`. Reading only the qualified
/// folder and calling its absence "nothing generated" describes the directory
/// listing rather than the device.
///
/// The qualifier goes directly after the resource type, before any others:
/// `drawable` → `drawable-night`, `values-v31` → `values-night-v31`.
XmlDocument? _readQualified(
  SplashFiles files,
  String res,
  SplashTheme theme,
  String base,
  String file,
) {
  if (theme == SplashTheme.dark) {
    var cut = base.indexOf('-');
    var night = cut < 0
        ? '$base-night'
        : '${base.substring(0, cut)}-night${base.substring(cut)}';
    var dark = _readXml(files, p.join(res, night, file));
    if (dark != null) return dark;
  }
  return _readXml(files, p.join(res, base, file));
}

/// The densest generated file for a role, so the recomposed picture is drawn
/// from the same pixels a modern phone would use.
SplashArtifact? _bestArtifact(
  List<SplashArtifact> artifacts,
  SplashSurface surface,
  SplashTheme theme,
  SplashArtifactRole role,
) {
  SplashArtifact? pick(SplashTheme wanted) {
    SplashArtifact? best;
    for (var artifact in artifacts) {
      if (artifact.surface != surface ||
          artifact.theme != wanted ||
          artifact.role != role) {
        continue;
      }
      var scale = splashDensityScale(artifact.density) ?? 0;
      var bestScale = best == null
          ? -1.0
          : (splashDensityScale(best.density) ?? 0);
      if (best == null || scale > bestScale) best = artifact;
    }
    return best;
  }

  // **Android's own resource resolution, and the reason it belongs here.** The
  // dark `launch_background.xml` references `@drawable/splash` and
  // `@drawable/branding` whether or not a dark copy of either exists — the
  // generator writes it with the *light* paths. With no
  // `drawable-night-xxxhdpi/branding.png`, Android picks
  // `drawable-xxxhdpi/branding.png`, and so must a readback that claims to say
  // what shipped.
  //
  // Reporting "no branding" here was wrong in exactly the same way the
  // prediction was — both halves agreed, and both were describing a device that
  // does not exist.
  return pick(theme) ??
      (theme == SplashTheme.dark ? pick(SplashTheme.light) : null);
}

/// Parsed, or null when the file is absent or not XML at all.
///
/// A malformed `styles.xml` is somebody's hand-edit in progress, not a reason
/// for the panel to throw.
XmlDocument? _readXml(SplashFiles files, String path) {
  var text = files.readString(path);
  if (text == null) return null;
  try {
    return XmlDocument.parse(text);
  } on XmlException {
    return null;
  }
}
