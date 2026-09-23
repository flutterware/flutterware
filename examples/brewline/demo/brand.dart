import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/previews.dart';

/// The shop's launcher icon, drawn here and nowhere else — every variant on
/// one sheet: a row per set, told apart by tint, a column per role. One set
/// today; a flavor with an icon of its own is a second row.
///
/// Every icon file under `android/`, `ios/`, `macos/` and `web/` is a picture
/// of one cell of this grid, photographed through [appIconVariant] below into
/// `assets/brand/` and written into place by `tool/brand_icons.dart` at the
/// size each file already has.
@Preview(name: 'App icon', group: 'Brewline')
Widget appIcon() => const BrandIconSheet();

/// One variant, chosen by its two knobs — the set and the role — filling the
/// canvas. What the script photographs at 1024; the sheet above is what a
/// reader looks at.
@Preview(
  name: 'App icon · one variant',
  group: 'Brewline',
  size: Size(1024, 1024),
)
Widget appIconVariant() => const BrandIconVariant();

class BrandIconSheet extends StatelessWidget {
  const BrandIconSheet({super.key});

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: const Color(0xFFF5F0EA),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var set in BrandIcon.tints.keys)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var role in BrandIcon.roles)
                        Padding(
                          padding: const EdgeInsets.only(right: 16),
                          child: SizedBox(
                            width: 72,
                            height: 72,
                            // Foreground and monochrome are transparent; a
                            // mid grey behind them says so at this size.
                            child: ColoredBox(
                              color: role == 'icon'
                                  ? const Color(0x00000000)
                                  : const Color(0xFF8A8A8A),
                              child: BrandIcon(set: set, role: role),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class BrandIconVariant extends StatelessWidget {
  const BrandIconVariant({super.key});

  @override
  Widget build(BuildContext context) {
    var knobs = context.knobs;
    var set = knobs.picker('set', {
      for (var name in BrandIcon.tints.keys) name: name,
    }, 'main');
    var role = knobs.picker('role', {
      for (var name in BrandIcon.roles) name: name,
    }, 'icon');
    return Directionality(
      textDirection: TextDirection.ltr,
      child: BrandIcon(set: set, role: role),
    );
  }
}

/// One variant of the icon: [set] picks the tint, [role] what the file is
/// for. Fills whatever box it is given.
class BrandIcon extends StatelessWidget {
  const BrandIcon({super.key, required this.set, required this.role});

  final String set;
  final String role;

  static const tints = {'main': Color(0xFF6F4E37)};

  static const roles = ['icon', 'foreground', 'monochrome'];

  @override
  Widget build(BuildContext context) {
    var tint = tints[set] ?? tints['main']!;
    return LayoutBuilder(
      builder: (context, constraints) {
        var side = constraints.biggest.shortestSide;
        return switch (role) {
          // Opaque and square: iOS masks its own corners and refuses alpha,
          // and a legacy Android launcher shows the file as it is.
          'icon' => ColoredBox(
            color: tint,
            child: Center(
              child: Icon(
                Icons.coffee_rounded,
                size: side * 0.62,
                color: const Color(0xFFFFF3E0),
              ),
            ),
          ),
          // The adaptive foreground: transparent, with the cup inside the
          // 66% safe zone a launcher may mask to.
          'foreground' => Center(
            child: Icon(
              Icons.coffee_rounded,
              size: side * 0.44,
              color: const Color(0xFFFFF3E0),
            ),
          ),
          // The themed icon: one colour, same geometry as the foreground.
          _ => Center(
            child: Icon(
              Icons.coffee_rounded,
              size: side * 0.44,
              color: Colors.white,
            ),
          ),
        };
      },
    );
  }
}
