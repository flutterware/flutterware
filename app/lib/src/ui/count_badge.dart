import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// A count beside a label, as an object rather than as more text.
///
/// `Events 7` reads as a two-word label and the number disappears into it;
/// `Events ⟨7⟩` reads as a label with a quantity attached. One widget because
/// the dock's tab strip and the Events tab's channel filters both need it, and
/// two hand-rolled pills would drift apart by the second one.
///
/// Round at one digit and a pill beyond it — the minimum width does that on its
/// own, with no branch on the number.
class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key, this.active = true});

  final int count;

  /// Whether the thing this counts is currently on — a selected tab, an
  /// enabled filter. Off recedes rather than disappears: the count is still
  /// the reason a reader would turn it back on.
  final bool active;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    // No `alignment:` on the Container, deliberately. It wraps the child in an
    // `Align`, which has no height factor and so grows to whatever the parent
    // offers — inside a tab strip that is the strip's full height, and the
    // badge became a bar. Sizing to the child and centring the digits with
    // `textAlign` gives the same look and keeps the pill the size of what is
    // in it.
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: active ? colors.accentSoft2 : colors.line,
        borderRadius: BorderRadius.circular(context.radii.pill),
      ),
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: context.type.micro.copyWith(
          color: active ? colors.accentDark : colors.mut,
          fontWeight: FontWeight.w600,
          // Without it the micro style's line height pads the pill into an
          // oval taller than the text it holds.
          height: 1.2,
        ),
      ),
    );
  }
}
