import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

/// A black shadow cast by an opaque white square onto a white ground.
///
/// Everything about it is integer-aligned at 1× so the only soft pixels in the
/// frame are the shadow's own: a rectangle with no radius, no antialiased edge
/// and no text. What the two renderings differ in is then countable —
/// see [greyLevels].
class ShadowFixture extends StatelessWidget {
  const ShadowFixture({super.key});

  @override
  Widget build(BuildContext context) => Container(
    color: Colors.white,
    padding: const EdgeInsets.all(40),
    alignment: Alignment.topLeft,
    child: Container(
      width: 100,
      height: 100,
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Colors.black, blurRadius: 12, offset: Offset(0, 8)),
        ],
      ),
    ),
  );
}

/// How many distinct greys a raw RGBA capture holds.
///
/// The measurement the whole thing turns on. A blur is a ramp, so it lands
/// dozens of levels between the ground and the shadow's core; `flutter_test`'s
/// stand-in drops the mask filter and fills the shape flat, which leaves the
/// two the fixture painted itself and nothing in between.
int greyLevels(Uint8List raw) {
  var seen = <int>{};
  for (var i = 0; i + 3 < raw.length; i += 4) {
    if (raw[i] == raw[i + 1] && raw[i + 1] == raw[i + 2]) seen.add(raw[i]);
  }
  return seen.length;
}
