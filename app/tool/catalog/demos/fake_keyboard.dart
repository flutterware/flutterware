import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/devices.dart';
import 'package:flutterware/previews_guest.dart';

import 'app_theme.dart';

/// The fake keyboard's artwork — both platforms, both themes, at the heights
/// they are actually drawn at.
///
/// What this is for. The slab is a `CustomPainter` with no widgets in it,
/// so nothing about it can be asserted except by looking: whether the rows
/// read as rows, whether the modifier keys are distinguishable from the
/// letters, whether a 219-point landscape keyboard is still legible as one at
/// the size it is drawn. And it has to hold up at four combinations, which in
/// the running studio is four device picks and two theme switches away.
///
/// The heights are the measured ones — see
/// `docs/superpowers/specs/2026-08-21-fake-keyboard-design.md`. Drawn against
/// the *widths* of the phones they were measured on, because the painter is
/// proportional to its box: an iPhone SE's 260 points over 375 is not the same
/// picture as an iPad's 405 over 1024.

@Preview(
  name: 'Fake keyboard',
  group: 'Previews panel',
  wrapper: wrapInAppTheme,
)
Widget fakeKeyboardSlabs() => const _Sheet(dark: false);

@Preview(
  name: 'Fake keyboard · dark',
  group: 'Previews panel',
  wrapper: wrapInDarkTheme,
)
Widget fakeKeyboardSlabsDark() => const _Sheet(dark: true);

class _Sheet extends StatelessWidget {
  const _Sheet({required this.dark});

  /// Passed rather than read off `MediaQuery.platformBrightness`, which in a
  /// preview is the studio's rather than the staged phone's. The two entries
  /// above are the switch.
  final bool dark;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Slab(
          'iPhone 16 · letters',
          platform: DevicePlatform.ios,
          dark: dark,
          width: 393,
          height: 336,
        ),
        _Slab(
          'iPhone 16 · email — an @ and a dot out of the space bar',
          platform: DevicePlatform.ios,
          dark: dark,
          width: 393,
          height: 336,
          variant: KeyboardVariant.email,
        ),
        _Slab(
          'iPhone 16 · url — a slash, and .com where the space bar was',
          platform: DevicePlatform.ios,
          dark: dark,
          width: 393,
          height: 336,
          variant: KeyboardVariant.url,
        ),
        _Slab(
          'iPhone 16 · keypad — 45 points shorter, and no strip to predict with',
          platform: DevicePlatform.ios,
          dark: dark,
          width: 393,
          height: 291,
          variant: KeyboardVariant.keypad,
        ),
        _Slab(
          'Pixel · keypad — Gboard swaps the keys and keeps the height',
          platform: DevicePlatform.android,
          dark: dark,
          width: 412,
          height: 336.4,
          variant: KeyboardVariant.keypad,
        ),
        _Slab(
          'iPhone 16 · landscape',
          platform: DevicePlatform.ios,
          dark: dark,
          width: 852,
          height: 219,
        ),
        _Slab(
          'iPhone SE — the shortest keyboard in the table',
          platform: DevicePlatform.ios,
          dark: dark,
          width: 375,
          height: 260,
        ),
        _Slab(
          'Pixel · Gboard',
          platform: DevicePlatform.android,
          dark: dark,
          width: 412,
          height: 336.4,
        ),
        _Slab(
          'iPad Pro — the tallest, and wider keys with it',
          platform: DevicePlatform.ios,
          dark: dark,
          width: 1024,
          height: 405.5,
        ),
      ],
    ),
  );
}

class _Slab extends StatelessWidget {
  const _Slab(
    this.label, {
    required this.platform,
    required this.dark,
    required this.width,
    required this.height,
    this.variant = KeyboardVariant.letters,
  });

  final String label;
  final DevicePlatform platform;
  final bool dark;
  final double width;
  final double height;
  final KeyboardVariant variant;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label · ${width.round()}×${height.round()}',
          style: Theme.of(context).textTheme.labelSmall,
        ),
        const SizedBox(height: 6),
        // Scaled down rather than resized: the painter is proportional, so a
        // smaller box would draw a *different* keyboard rather than a smaller
        // picture of this one — and this sheet is looked at inside a panel
        // narrower than an iPad.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: CustomPaint(
            size: Size(width, height),
            painter: FakeKeyboardPainter(
              platform: platform,
              dark: dark,
              variant: variant,
            ),
          ),
        ),
      ],
    ),
  );
}
