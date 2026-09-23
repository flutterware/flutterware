import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';

/// The profile lane end to end: no runner, no daemon — the folder's
/// `flutter_test_config.dart` is the only thing that said anything, and the app
/// sees it the way it would see a real phone.
void main() {
  scenario('runs as the profile says, and says which', (s) async {
    // Correct in both lanes: the head of the profile under a bare
    // `flutter test`, and whatever CI named under an override.
    var device = s.assignment?.device ?? Devices.iphone16;
    late MediaQueryData media;
    await s.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            media = MediaQuery.of(context);
            return const Scaffold(body: Text('hello'));
          },
        ),
      ),
    );

    expect(media.size, Size(device.width, device.height));
    expect(media.devicePixelRatio, device.pixelRatio);
    expect(media.padding.top, device.insetTop);
    expect(media.padding.bottom, device.insetBottom);
    expect(defaultTargetPlatform, switch (device.platform) {
      DevicePlatform.ios => TargetPlatform.iOS,
      DevicePlatform.android => TargetPlatform.android,
      DevicePlatform.macos => TargetPlatform.macOS,
      DevicePlatform.windows => TargetPlatform.windows,
      DevicePlatform.linux => TargetPlatform.linux,
    });
    // The platform locale rather than `Localizations.localeOf`: this fixture
    // ships no delegates, and what the axis sets is the platform's answer.
    expect(
      s.tester.platformDispatcher.locale,
      Locale(s.assignment?.language ?? 'fr'),
    );
  });

  scenario('measures text in the project fonts, not the fallback', (s) async {
    // `runScenarios` is the only thing standing between a `flutter test`
    // scenario and fallback metrics, and for a while nothing stood there at
    // all: the harness loaded the bundle's fonts and this lane did not, so the
    // same screen was a few pixels wider here and reported it as
    // `RenderFlex overflowed by 3.5 pixels`. Not-null and not the families —
    // this fixture's project declares none, and what broke was the loading,
    // not the manifest.
    expect(loadedScenarioFonts, isNotNull);
  });
}
