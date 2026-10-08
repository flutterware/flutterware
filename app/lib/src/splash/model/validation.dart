/// What is wrong with a splash config, and how wrong.
///
/// Every rule here is checked against the generator's own source rather than
/// its README, and the two disagree often enough to matter. Two rules were
/// nearly written the other way round from what the package actually does:
///
/// - **A non-PNG source is fine.** The README's "PNG" reads like a
///   requirement; `_checkImageExists` accepts jpg, gif, bmp, tga and more, and
///   `_createImage` converts anything that is not already a PNG. So this
///   reports a conversion, not an error.
/// - **An unknown key is fatal.** It is not ignored and not warned about — the
///   generator prints and calls `exit(1)`, so one typo stops the whole run.
/// - **A missing `android_12.image` does not leave a bare colour.** This one was
///   written the wrong way round and shipped that way. When `android12ImagePath`
///   is null the generator *removes* `windowSplashScreenAnimatedIcon` from the
///   launch theme (`android.dart`, `_applyAndroid12Styles`), and Android's
///   default for that attribute is the application's launcher icon. The package
///   says so itself, beside the call: `//create android 12 image if provided.
///   (otherwise uses launch icon)`. So the splash is the launcher icon on the
///   window background — which is both more alarming and more actionable than
///   "a bare colour", and is the "why is my app icon on my splash screen"
///   complaint everybody files.
///
/// [SplashProblem.blocksGeneration] marks the rules that stop `create` dead, so
/// a reader can tell "this will not build" from "this will look wrong".
///
/// Every rule here names the edit; none of them makes it. A problem is a
/// sentence with the key in it — "Set `branding_bottom_padding_ios` to at
/// least 34" — and the reader goes to the file. The buttons that used to write
/// those keys are gone with the rest of the editor: they were computed from a
/// transcription of somebody else's generator, and a wrong picture is a wrong
/// picture where a wrong button is a wrong edit to your project.
library;

import 'package:flutterware/plugins.dart';

import 'color.dart';
import 'composition.dart';
import 'config.dart';
import 'fit_check.dart';
import 'image_facts.dart';
import 'surface.dart';

/// Every key the generator accepts, transcribed from `_Parameter.all`.
///
/// Kept as a literal rather than derived, because it is the *other* project's
/// list: deriving it from what this plugin happens to read would make the
/// unknown-key check silently agree with itself.
const splashKnownKeys = {
  'android',
  'android_12',
  'android_min_sdk',
  'android_screen_orientation',
  'background_image',
  'background_image_android',
  'background_image_ios',
  'background_image_web',
  'background_image_dark',
  'background_image_dark_android',
  'background_image_dark_ios',
  'background_image_dark_web',
  'branding',
  'branding_android',
  'branding_ios',
  'branding_web',
  'branding_dark',
  'branding_dark_android',
  'branding_dark_ios',
  'branding_dark_web',
  'branding_mode',
  'branding_bottom_padding',
  'branding_bottom_padding_android',
  'branding_bottom_padding_ios',
  'color',
  'color_android',
  'color_ios',
  'color_web',
  'color_dark',
  'color_dark_android',
  'color_dark_ios',
  'color_dark_web',
  'image',
  'image_android',
  'image_ios',
  'image_web',
  'image_dark',
  'image_dark_android',
  'image_dark_ios',
  'image_dark_web',
  'fullscreen',
  'android_gravity',
  'icon_background_color',
  'icon_background_color_dark',
  'ios',
  'ios_content_mode',
  'info_plist_files',
  'web',
  'web_image_mode',
};

/// The keys the `android_12:` section accepts.
const splashAndroid12Keys = {
  'color',
  'color_dark',
  'image',
  'image_dark',
  'icon_background_color',
  'icon_background_color_dark',
  'branding',
  'branding_dark',
};

/// Formats the generator converts to PNG on the way in.
const splashConvertibleFormats = {
  'png',
  'apng',
  'jpg',
  'jpeg',
  'jpe',
  'jfif',
  'tga',
  'tpic',
  'gif',
  'ico',
  'bmp',
  'dib',
};

/// One thing wrong with a config.
class SplashProblem {
  const SplashProblem(
    this.tone,
    this.message, {
    this.key,
    this.surface,
    this.theme,
    this.device,
    this.blocksGeneration = false,
  });

  final Tone tone;
  final String message;

  /// The config key at fault, when one key is.
  final String? key;

  /// The cell this is about, when it is about one cell rather than the config.
  final SplashSurface? surface;
  final SplashTheme? theme;

  /// The device this is about — `iphone-se`, `android-small`.
  ///
  /// Only the fit rules set it, and they set it so the reader can *go and look*:
  /// a sentence saying the logo is clipped on a small phone is worth much less
  /// than the same sentence with the picture one click behind it.
  final String? device;

  /// `dart run flutter_native_splash:create` will `exit(1)` on this.
  final bool blocksGeneration;

  @override
  String toString() => message;
}

/// Checks [config] and returns everything wrong with it, worst first.
///
/// [facts] is looked up by the path the config wrote. [hasDevDependency] and
/// [generatedIsStale] are supplied by the core, which is the only thing that
/// can see the pubspec and the generated files.
List<SplashProblem> validateSplash(
  SplashConfig config, {
  required SplashImageFacts? Function(String path) facts,
  bool hasDevDependency = true,
  bool generatedIsStale = false,
}) {
  var problems = <SplashProblem>[];

  // ---- Fatal: the generator refuses to run -------------------------------

  for (var key in config.raw.keys) {
    if (!splashKnownKeys.contains(key)) {
      var meant = _nearest(key, splashKnownKeys, taken: config.raw.keys);
      problems.add(
        SplashProblem(
          Tone.error,
          '"$key" is not a flutter_native_splash parameter. The generator '
          'prints this and exits, so nothing is written at all.'
          '${meant == null ? '' : ' Did you mean "$meant"?'}',
          key: key,
          blocksGeneration: true,
        ),
      );
    }
  }
  for (var key in config.android12Section.keys) {
    if (!splashAndroid12Keys.contains(key)) {
      var meant = _nearest(
        key,
        splashAndroid12Keys,
        taken: config.android12Section.keys,
      );
      problems.add(
        SplashProblem(
          Tone.error,
          '"$key" is not valid inside android_12.'
          '${meant == null ? '' : ' Did you mean "$meant"?'}',
          key: 'android_12.$key',
          blocksGeneration: true,
        ),
      );
    }
  }

  // Colours and images are checked over every key the project actually wrote,
  // not over the resolved cells: a broken `color_ios` stops the run even when
  // some other surface resolves fine without it.
  config.raw.forEach((key, value) {
    if (!_isColorKey(key)) return;
    var text = SplashConfig.stringify(value);
    if (text != null && parseSplashColor(text) == null) {
      problems.add(
        SplashProblem(
          Tone.error,
          '"$key: $text" is not a colour the generator accepts. Use exactly '
          'six hex digits, like "1E1E1E". It fails on anything else, '
          'including eight-digit values with alpha.',
          key: key,
          blocksGeneration: true,
        ),
      );
    }
  });
  config.android12Section.forEach((key, value) {
    if (!_isColorKey(key)) return;
    var text = SplashConfig.stringify(value);
    if (text != null && parseSplashColor(text) == null) {
      problems.add(
        SplashProblem(
          Tone.error,
          '"android_12.$key: $text" is not a six-digit hex colour.',
          key: 'android_12.$key',
          blocksGeneration: true,
        ),
      );
    }
  });

  for (var (key, path) in _referencedImages(config)) {
    var known = facts(path);
    if (known == null || !known.exists) {
      problems.add(
        SplashProblem(
          Tone.error,
          'The file "$path" set as "$key" was not found. The generator stops '
          'at a missing file.',
          key: key,
          blocksGeneration: true,
        ),
      );
      continue;
    }
    var extension = _extension(path);
    if (!splashConvertibleFormats.contains(extension)) {
      problems.add(
        SplashProblem(
          Tone.error,
          '"$path" is a .$extension, which the generator cannot decode.',
          key: key,
          blocksGeneration: true,
        ),
      );
    } else if (extension != 'png' && extension != 'apng') {
      problems.add(
        SplashProblem(
          Tone.info,
          '"$path" is a .$extension, which the generator converts to PNG. '
          'Any transparency the format does not carry is already lost.',
          key: key,
        ),
      );
    }
  }

  // ---- The Android 12 divergence ----------------------------------------

  var hasLegacyArt =
      config
          .resolve('image', SplashSurface.android, SplashTheme.light)
          .isPresent ||
      config
          .resolve('background_image', SplashSurface.android, SplashTheme.light)
          .isPresent;

  if (config.enabled(SplashSurface.android) &&
      hasLegacyArt &&
      !config.android12Image(SplashTheme.light).isPresent) {
    problems.add(
      SplashProblem(
        Tone.warn,
        config.hasAndroid12Section
            ? 'The android_12 section sets no "image", so every device from '
                  'Android 12 on shows your launcher icon rather than this '
                  'image, masked to a circle. The top-level "image" does not '
                  'reach this surface.'
            : 'There is no android_12 section, so every device from Android 12 '
                  'on shows your launcher icon, masked to a circle. The '
                  'top-level "image" is read only by the legacy path.',
        key: 'android_12.image',
        surface: SplashSurface.android12,
      ),
    );
  }

  var iconBackground = config.android12IconBackgroundColor(SplashTheme.light);
  var expectedIcon = android12IconSize(
    hasIconBackground: iconBackground.isPresent,
  );
  for (var theme in SplashTheme.values) {
    var icon = config.android12Image(theme);
    if (!icon.isPresent) continue;
    var known = facts(icon.value!);
    if (known == null || !known.isMeasured) continue;
    if (known.pixelWidth != expectedIcon || known.pixelHeight != expectedIcon) {
      problems.add(
        SplashProblem(
          Tone.warn,
          'The Android 12 icon "${icon.value}" is ${known.dimensions}; it '
          'should be $expectedIcon×$expectedIcon '
          '${iconBackground.isPresent ? 'with' : 'without'} an icon '
          'background. Android masks it to a circle at '
          '${(android12MaskFraction * 100).round()}% of the canvas, so a '
          'wrong canvas crops the logo rather than scaling it.',
          key: icon.key,
          surface: SplashSurface.android12,
          theme: theme,
        ),
      );
      break;
    }
  }

  for (var theme in SplashTheme.values) {
    var branding = config.android12Branding(theme);
    if (!branding.isPresent) continue;
    var known = facts(branding.value!);
    if (known == null || !known.isMeasured) continue;
    if (known.pixelWidth != android12BrandingWidth ||
        known.pixelHeight != android12BrandingHeight) {
      problems.add(
        SplashProblem(
          Tone.warn,
          'The Android 12 branding "${branding.value}" is '
          '${known.dimensions}; it should be '
          '$android12BrandingWidth×$android12BrandingHeight.',
          key: branding.key,
          surface: SplashSurface.android12,
          theme: theme,
        ),
      );
      break;
    }
  }

  // ---- Per-surface completeness -----------------------------------------

  for (var surface in SplashSurface.values) {
    if (!config.enabled(surface)) continue;
    var light = resolveSplash(config, surface, SplashTheme.light);
    if (light.isEmpty) {
      problems.add(
        SplashProblem(
          Tone.warn,
          'Nothing resolves for ${surface.label}: no colour and no background '
          'image, so the splash is whatever the platform defaults to.',
          surface: surface,
        ),
      );
    }

    // **The two dark rules that lived here are gone.** They narrated what
    // `create` would write for dark and which image would be drawn — the panel
    // now reads both back off the disk and draws them, and the tile caption
    // already says "no dark config, the OS shows the light splash". Both were
    // also wrong at some point, in the same direction, from the same source.
  }

  // ---- Does it fit on a real screen? -------------------------------------
  //
  // The only rules here that are not about the generator. Everything above is
  // "what will `create` write"; this is "what will that look like on a phone",
  // and it is the question the eight fixed-size tiles could never answer.
  //
  // Reported per cell but **collapsed to the worst device**, not one problem per
  // device. Fourteen lines saying the same thing about fourteen Android phones
  // is how a warning list becomes wallpaper; the widest miss is the one that
  // decides the fix, and the others follow from it.
  for (var surface in SplashSurface.values) {
    if (!config.enabled(surface)) continue;
    for (var theme in SplashTheme.values) {
      var composition = composeSplash(
        resolveSplash(config, surface, theme),
        facts: facts,
      );
      var findings = checkSplashFit(composition);
      for (var issue in SplashFitIssue.values) {
        var worst = findings.where((f) => f.issue == issue).firstOrNull;
        if (worst == null) continue;
        problems.add(_fitProblem(worst, surface, theme));
      }
    }
  }

  // ---- Placement vocabularies -------------------------------------------

  _checkVocabulary(
    problems,
    'android_gravity',
    config.androidGravity,
    androidGravityValues,
    separator: '|',
  );
  _checkVocabulary(
    problems,
    'ios_content_mode',
    config.iosContentMode,
    iosContentModeValues,
  );
  _checkVocabulary(
    problems,
    'web_image_mode',
    config.webImageMode,
    webImageModeValues,
  );
  _checkVocabulary(
    problems,
    'branding_mode',
    config.brandingMode,
    brandingModeValues,
  );

  // ---- Project state -----------------------------------------------------

  if (!hasDevDependency) {
    problems.add(
      const SplashProblem(
        Tone.warn,
        'flutter_native_splash is not in dev_dependencies, so '
        '`dart run flutter_native_splash:create` will not resolve.',
      ),
    );
  }

  if (generatedIsStale) {
    problems.add(
      const SplashProblem(
        Tone.info,
        'The config has changed since the splash was last generated. What ships '
        'is still the old one until `create` runs again.',
      ),
    );
  }

  problems.sort((a, b) => _severity(b.tone).compareTo(_severity(a.tone)));
  return problems;
}

/// Phrases one fit finding.
///
/// Every message carries the device *and the number*, because "too big" is not
/// actionable and "48dp too wide on a small phone" is: it names the edit.
SplashProblem _fitProblem(
  SplashFitFinding finding,
  SplashSurface surface,
  SplashTheme theme,
) {
  var over = finding.amount.round();
  return switch (finding.issue) {
    SplashFitIssue.imageClipped => SplashProblem(
      Tone.warn,
      'The image is ${over}dp wider than ${finding.device.label} '
      '(${finding.device.width.round()}×${finding.device.height.round()}), so '
      'its edges are cut off there. A source image is read at a quarter of its '
      'pixel size, so a ${sourceDensity.toInt()}× export is the usual cause.',
      surface: surface,
      theme: theme,
      device: finding.device.id,
    ),
    SplashFitIssue.brandingUnderSafeArea => _brandingPaddingProblem(
      finding,
      surface,
      theme,
      over,
    ),
  };
}

/// Branding under the home indicator, with the one number that clears it.
///
/// The key is platform-suffixed rather than global. The inset is a property of
/// *that* platform's hardware — 34dp on a notched iPhone, 24 on an Android
/// gesture bar — so a global `branding_bottom_padding` set from the worst iPhone
/// would over-pad every Android device to answer an iOS problem.
SplashProblem _brandingPaddingProblem(
  SplashFitFinding finding,
  SplashSurface surface,
  SplashTheme theme,
  int over,
) {
  var key = 'branding_bottom_padding_${surface.keySuffix}';
  var padding = finding.device.insetBottom.ceil();
  return SplashProblem(
    Tone.warn,
    'The branding sits ${over}dp inside the bottom safe area on '
    '${finding.device.label}, under the home indicator. Set "$key" to at '
    'least $padding.',
    key: key,
    surface: surface,
    theme: theme,
    device: finding.device.id,
  );
}

/// Flags a value that is not in its vocabulary. The generator does not check
/// these — it silently falls back to its default — so a typo here is invisible
/// until someone looks at a device.
void _checkVocabulary(
  List<SplashProblem> problems,
  String key,
  String? value,
  List<String> legal, {
  String? separator,
}) {
  if (value == null || value.trim().isEmpty) return;
  var parts = separator == null ? [value.trim()] : value.split(separator);
  for (var part in parts) {
    var token = part.trim();
    if (token.isEmpty || legal.contains(token)) continue;
    var meant = _nearest(token, legal);
    problems.add(
      SplashProblem(
        Tone.warn,
        '"$key: $value" uses "$token", which is not one of '
        '${legal.join(', ')}. The generator does not check this and uses its '
        'default instead.'
        '${meant == null ? '' : ' Did you mean "$meant"?'}',
        key: key,
      ),
    );
  }
}

/// The entry of [candidates] that [word] was probably meant to be, or null when
/// nothing is close enough to say so.
///
/// Three guards, all of which exist to stop a confident wrong suggestion — which
/// is worse than none, because a rename button that writes the wrong key turns
/// one broken config into a differently broken one:
///
/// - **Short words are never suggested for.** At three characters a distance of
///   two is most of the alphabet.
/// - **A tie is not a suggestion.** `color_dark_ois` is one edit from
///   `color_dark_ios` and nothing else; `image_dark_xyz` is three from several
///   things and should get silence.
/// - **A key the config already uses is not offered**, since renaming onto it
///   would overwrite a value the author wrote on purpose.
String? _nearest(
  String word,
  Iterable<String> candidates, {
  Iterable<String> taken = const [],
}) {
  if (word.length < 4) return null;
  String? best;
  // Strictly less than 3, so a distance of 2 is the most that ever matches.
  var bestDistance = 3;
  for (var candidate in candidates) {
    if (taken.contains(candidate)) continue;
    var distance = _editDistance(word, candidate);
    if (distance < bestDistance) {
      bestDistance = distance;
      best = candidate;
    } else if (distance == bestDistance) {
      best = null;
    }
  }
  return best;
}

/// Levenshtein distance, two rows rather than a full matrix.
int _editDistance(String a, String b) {
  var previous = List<int>.generate(b.length + 1, (i) => i);
  var current = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    current[0] = i;
    for (var j = 1; j <= b.length; j++) {
      var substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
      var deletion = previous[j] + 1;
      var insertion = current[j - 1] + 1;
      current[j] = substitution < deletion ? substitution : deletion;
      if (insertion < current[j]) current[j] = insertion;
    }
    var swap = previous;
    previous = current;
    current = swap;
  }
  return previous[b.length];
}

/// Every image path the config names, with the key that named it.
List<(String, String)> _referencedImages(SplashConfig config) {
  var found = <(String, String)>[];
  for (var base in ['image', 'background_image', 'branding']) {
    for (var key in [
      base,
      '${base}_dark',
      for (var suffix in ['android', 'ios', 'web']) ...[
        '${base}_$suffix',
        '${base}_dark_$suffix',
      ],
    ]) {
      var value = SplashConfig.stringify(config.raw[key]);
      if (value != null) found.add((key, value));
    }
  }
  for (var key in ['image', 'image_dark', 'branding', 'branding_dark']) {
    var value = SplashConfig.stringify(config.android12Section[key]);
    if (value != null) found.add(('android_12.$key', value));
  }
  return found;
}

bool _isColorKey(String key) =>
    key.startsWith('color') || key.startsWith('icon_background_color');

String _extension(String path) {
  var dot = path.lastIndexOf('.');
  return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
}

int _severity(Tone tone) => switch (tone) {
  Tone.error => 3,
  Tone.warn => 2,
  Tone.info => 1,
  Tone.good || Tone.neutral => 0,
};
