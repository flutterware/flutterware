import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/splash/model/composition.dart';
import 'package:flutterware_app/src/splash/model/config.dart';
import 'package:flutterware_app/src/splash/model/generated.dart';
import 'package:flutterware_app/src/splash/model/scan.dart';
import 'package:flutterware_app/src/splash/model/surface.dart';
import 'package:flutterware_app/src/splash/model/validation.dart';
import 'package:flutterware_app/src/splash/ui/cell_inspector.dart';
import 'package:flutterware_app/src/splash/ui/panel_header.dart';
import 'package:flutterware_app/src/splash/ui/variant_tile.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'shell.dart';

/// The splash panel's chrome, with no package behind it.
///
/// Everything here is synthesised. `SplashComposition` and `SplashResolution`
/// are plain data and `SplashLayer` takes a path it never opens, so a tile can
/// be drawn for a project that does not exist — which is the whole reason these
/// are views rather than screens.
///
/// One thing cannot be here: a picture with pixels in it. A layer needs a
/// real file on disk to paint, so every composition below is colour and
/// geometry. The images are exercised by running the app against
/// `fixtures/probe_app`, which is generated and has all four surfaces.

@Preview(name: 'Header', group: 'Splash', wrapper: wrapInApp)
Widget splashHeader() => const _Headers();

@Preview(name: 'Tiles', group: 'Splash', wrapper: wrapInApp)
Widget splashTiles() => const _Tiles();

@Preview(name: 'Inspector', group: 'Splash', wrapper: wrapInApp)
Widget splashInspector() => const _Inspectors();

/// The three generation states, plus the flavored case.
///
/// Stacked rather than picked, so the pill that is one word too long or the
/// title that collides with it shows up on open instead of waiting for somebody
/// to select the variant it happens in.
class _Headers extends StatelessWidget {
  const _Headers();

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.colors.bg,
    body: ListView(
      children: [
        _Case(
          'Generated and current',
          SplashPanelHeader(
            package: 'fixtures/probe_app',
            configPath: 'flutter_native_splash.yaml',
            state: SplashGeneratedState.current,
            fileCount: 66,
            scannedAt: DateTime(2026, 8, 10, 11, 27, 2),
            onSize: (_) {},
            onReload: () async {},
          ),
        ),
        _Case(
          'Generated, then the config moved',
          SplashPanelHeader(
            package: 'fixtures/probe_app',
            configPath: 'pubspec.yaml',
            fromPubspec: true,
            state: SplashGeneratedState.stale,
            fileCount: 66,
            scannedAt: DateTime(2026, 8, 10, 11, 27, 2),
            size: SplashScreenSize.smallPhone,
            onSize: (_) {},
            onReload: () async {},
          ),
        ),
        _Case(
          'Never generated',
          SplashPanelHeader(
            package: 'fixtures/probe_app',
            configPath: 'flutter_native_splash.yaml',
            state: SplashGeneratedState.never,
            fileCount: 0,
            scannedAt: DateTime(2026, 8, 10, 11, 27, 2),
            size: SplashScreenSize.tablet,
            onSize: (_) {},
            onReload: () async {},
          ),
        ),
        _Case(
          'Flavors, and a long package path',
          SplashPanelHeader(
            package: 'packages/mobile/apps/the_customer_facing_one',
            configPath: 'flutter_native_splash-staging.yaml',
            state: SplashGeneratedState.current,
            fileCount: 1,
            flavors: const ['staging', 'production'],
            selectedFlavor: 'staging',
            onFlavor: (_) {},
            onSize: (_) {},
            onReload: () async {},
          ),
        ),
      ],
    ),
  );
}

/// The matrix cell in every state it has.
class _Tiles extends StatelessWidget {
  const _Tiles();

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.colors.bg,
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      child: Wrap(
        spacing: FwSpacing.xl,
        runSpacing: FwSpacing.xxl,
        children: [
          SplashVariantTile(
            picture: SplashPicture.generated(_composition()),
            resolution: _resolution(),
            problems: const [],
          ),
          SplashVariantTile(
            picture: SplashPicture.predicted(
              _composition(theme: SplashTheme.dark, background: 0xFF101418),
              reason:
                  'Predicted from the config. iOS cannot be read back — '
                  'LaunchScreen.storyboard describes constraints, not the '
                  'finished image.',
            ),
            resolution: _resolution(theme: SplashTheme.dark),
            problems: const [],
          ),
          SplashVariantTile(
            picture: SplashPicture.generated(
              _composition(theme: SplashTheme.dark, background: 0xFF101418),
            ),
            resolution: _resolution(
              theme: SplashTheme.dark,
              fallsBackToLight: true,
            ),
            problems: const [],
          ),
          SplashVariantTile(
            picture: SplashPicture.generated(
              _composition(
                surface: SplashSurface.android12,
                usesLauncherIcon: true,
              ),
            ),
            resolution: _resolution(surface: SplashSurface.android12),
            problems: const [
              SplashProblem(
                Tone.warn,
                'There is no android_12 section.',
                surface: SplashSurface.android12,
              ),
            ],
          ),
          SplashVariantTile(
            picture: SplashPicture.generated(
              _composition(surface: SplashSurface.web),
            ),
            resolution: _resolution(surface: SplashSurface.web),
            problems: const [
              SplashProblem(Tone.error, 'Broken.', surface: SplashSurface.web),
            ],
          ),
          SplashVariantTile(
            picture: SplashPicture.generated(_composition()),
            resolution: _resolution(enabled: false),
            problems: const [],
          ),
          SplashVariantTile(
            picture: SplashPicture.generated(_composition()),
            resolution: _resolution(),
            problems: const [],
            selected: true,
          ),
        ],
      ),
    ),
  );
}

/// The pane, at the width it is pinned to.
class _Inspectors extends StatelessWidget {
  const _Inspectors();

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.colors.bg,
    body: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Pane(
            'Read back, with files',
            SplashCellInspector(
              picture: SplashPicture.generated(_composition()),
              resolution: _resolution(),
              problems: const [],
              artifacts: _artifacts,
              device: Devices.androidTall,
              onClose: () {},
            ),
          ),
          _Pane(
            'Predicted, with a problem and no files',
            SplashCellInspector(
              picture: SplashPicture.predicted(
                _composition(surface: SplashSurface.ios),
                reason:
                    'Nothing has been generated yet, so this is what the '
                    'config will produce — not what any device shows. Run '
                    'flutter_native_splash:create to make it real.',
              ),
              resolution: _resolution(
                surface: SplashSurface.ios,
                fallsBackToLight: true,
              ),
              problems: const [
                SplashProblem(
                  Tone.warn,
                  'The branding sits 34dp inside the bottom safe area on '
                  'iPhone 13 mini — under the home indicator. Set '
                  '"branding_bottom_padding_ios" to at least 34.',
                  key: 'branding_bottom_padding_ios',
                  surface: SplashSurface.ios,
                ),
                SplashProblem(
                  Tone.error,
                  'The file "assets/gone.png" set as "image" was not found. '
                  'The generator exits rather than skipping it.',
                  key: 'image',
                  surface: SplashSurface.ios,
                  blocksGeneration: true,
                ),
              ],
              artifacts: const [],
              device: Devices.iphone13Mini,
              onClose: () {},
            ),
          ),
          _Pane(
            'A platform switched off',
            SplashCellInspector(
              picture: SplashPicture.generated(
                _composition(surface: SplashSurface.web),
              ),
              resolution: _resolution(
                surface: SplashSurface.web,
                enabled: false,
              ),
              problems: const [],
              artifacts: const [],
              onClose: () {},
            ),
          ),
        ],
      ),
    ),
  );
}

// ---- Fixtures ---------------------------------------------------------------

SplashComposition _composition({
  SplashSurface surface = SplashSurface.android,
  SplashTheme theme = SplashTheme.light,
  int background = 0xFFFFFF00,
  bool usesLauncherIcon = false,
}) => SplashComposition(
  surface: surface,
  theme: theme,
  enabled: true,
  backgroundColor: background,
  usesLauncherIcon: usesLauncherIcon,
);

SplashResolution _resolution({
  SplashSurface surface = SplashSurface.android,
  SplashTheme theme = SplashTheme.light,
  bool enabled = true,
  bool fallsBackToLight = false,
}) {
  var dark = theme == SplashTheme.dark;
  return SplashResolution(
    surface: surface,
    theme: theme,
    enabled: enabled,
    fallsBackToLight: fallsBackToLight,
    color: Resolved(dark ? '101418' : 'FFFF00', dark ? 'color_dark' : 'color'),
    backgroundImage: const Resolved.absent(),
    image: const Resolved('assets/splash/logo.png', 'image'),
    branding: const Resolved('assets/splash/branding.png', 'branding'),
    iconBackgroundColor: surface == SplashSurface.android12
        ? const Resolved('FFFFFF', 'android_12.icon_background_color')
        : const Resolved.absent(),
    fit: SplashFit.none,
    alignment: SplashAlignment.center,
    brandingAlignment: SplashAlignment.bottomCenter,
    brandingBottomPadding: 24,
    fullscreen: false,
  );
}

final _artifacts = [
  for (var density in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'])
    SplashArtifact(
      path: 'android/app/src/main/res/drawable-$density/splash.png',
      surface: SplashSurface.android,
      theme: SplashTheme.light,
      role: SplashArtifactRole.image,
      density: density,
      pixelWidth: 256,
      pixelHeight: 256,
      modified: DateTime(2026, 8, 10),
    ),
];

/// One header case, labelled, with a rule under it.
class _Case extends StatelessWidget {
  const _Case(this.label, this.child);

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          FwSpacing.xxl,
          FwSpacing.xxl,
          FwSpacing.xxl,
          0,
        ),
        child: Text(label, style: context.type.micro),
      ),
      child,
      const Gap(FwSpacing.xxl),
    ],
  );
}

/// One inspector case, at the real pinned width so the field column and the
/// paths are read at the size they will actually be.
class _Pane extends StatelessWidget {
  const _Pane(this.label, this.child);

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.all(FwSpacing.md),
        child: Text(label, style: context.type.micro),
      ),
      Expanded(child: child),
    ],
  );
}
