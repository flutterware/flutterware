/// The set card and the parts it is made of.
///
/// Pulled out of `store_plugin.dart`, where all of this was private, for the
/// reason the repo's rule gives: a control that cannot be an entry cannot be
/// looked at, and this one is about to grow a second half (the live listing)
/// whose shape is being chosen by rendering the candidates side by side.
///
/// Plain data only. The card takes shots as [StoreShotImage]s rather than
/// files and a report, so a demo can paint its own and a panel can hand it
/// `FileImage`s.
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../ui/design/design.dart';
import '../../ui/theme.dart';

/// One thumbnail's worth of set: what it is called, and where its pixels are.
class StoreShotImage {
  const StoreShotImage({required this.name, required this.image});

  /// The file's name, which is also the shot's — shown on hover, because at
  /// thumbnail size the picture cannot say which shot it is.
  final String name;

  final ImageProvider image;
}

/// The bordered box every card is drawn in.
class StoreCardShell extends StatelessWidget {
  const StoreCardShell({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(context.radii.radius),
        border: Border.all(color: colors.line),
      ),
      padding: const EdgeInsets.all(FwSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

/// A card's title row: what this set is, what can be done to it, and the
/// neutral facts about it on the right.
class StoreCardHeader extends StatelessWidget {
  const StoreCardHeader({
    super.key,
    required this.label,
    this.actions = const [],
    this.busy = false,
    this.facts = const [],
    this.trailing,
  });

  final String label;
  final List<Widget> actions;

  /// This set is the one being exported right now.
  final bool busy;

  /// The neutral, unabbreviated corner — canvas, locale, count. Joined with a
  /// separator; empties are dropped by the caller.
  final List<String> facts;

  /// Anything that replaces the facts line — a toggle, a live summary.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Row(
      children: [
        Text(label, style: context.type.bodyStrong),
        for (var action in actions) ...[const Gap(FwSpacing.lg), action],
        if (busy) ...[
          const Gap(FwSpacing.md),
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.accent,
            ),
          ),
        ],
        const Spacer(),
        if (trailing case var trailing?)
          trailing
        else
          Text(
            facts.join('  ·  '),
            style: context.type.bodySmall.copyWith(color: colors.mut),
          ),
      ],
    );
  }
}

/// A quiet text button on a card's title row.
class StoreCardAction extends StatelessWidget {
  const StoreCardAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: FwIconSize.sm, color: colors.accent),
            const Gap(FwSpacing.xs),
            Text(
              label,
              style: context.type.bodySmall.copyWith(color: colors.accent),
            ),
          ],
        ),
      ),
    );
  }
}

/// A line of explanation under a card's strip.
///
/// Every marking on this panel that is not a screenshot has to say what it
/// means where it means it. A colour alone is a riddle: amber on `15 of 10`
/// told the reader something was wrong without telling them what, and dimmed
/// thumbnails read as a rendering fault rather than as a store's limit.
class StoreNote extends StatelessWidget {
  const StoreNote({
    super.key,
    required this.tone,
    required this.icon,
    required this.text,
  });

  final Color tone;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: FwIconSize.sm, color: tone),
      const Gap(FwSpacing.sm),
      Expanded(
        child: Text(text, style: context.type.bodySmall.copyWith(color: tone)),
      ),
    ],
  );
}

/// A row of screenshots at one canvas's aspect, or the ghosts of them.
///
/// The strip is the card's whole point, so it gets the room; the width follows
/// from the canvas, which is why a 2:1 Play phone and a 4:3 iPad read as
/// visibly different shapes on one screen.
class StoreShotStrip extends StatelessWidget {
  const StoreShotStrip({
    super.key,
    required this.shots,
    required this.aspect,
    required this.height,
    this.cap,
    this.capLabel,
    this.onShot,
  });

  final List<StoreShotImage> shots;

  /// The canvas's width over its height.
  final double aspect;

  final double height;

  /// The store's limit per display class; shots past it are dimmed. Null caps
  /// nothing, which is what a live set wants — a store publishing ten is not
  /// showing you an eleventh.
  final int? cap;

  /// Whose limit [cap] is, so a tooltip can name it.
  final String? capLabel;

  final ValueChanged<int>? onShot;

  double get width => height * aspect;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: shots.isEmpty
        ? StoreGhostStrip(width: width)
        : ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: shots.length,
            separatorBuilder: (_, _) => const Gap(FwSpacing.md),
            itemBuilder: (context, index) => StoreShotThumb(
              shot: shots[index],
              width: width,
              store: capLabel,
              cap: cap,
              position: index + 1,
              onTap: onShot == null ? null : () => onShot!(index),
            ),
          ),
  );
}

/// One screenshot, at 1×.
///
/// The export pays for the device's real pixel ratio; the panel does not — the
/// same split `captureScale` already makes. An image that has gone missing
/// under the panel draws as a gap rather than as an exception, because a
/// deleted build directory is an ordinary thing and not an error to report.
class StoreShotThumb extends StatelessWidget {
  const StoreShotThumb({
    super.key,
    required this.shot,
    required this.width,
    required this.position,
    this.store,
    this.cap,
    this.onTap,
  });

  final StoreShotImage shot;
  final double width;

  /// 1-based place in the set.
  final int position;

  final String? store;
  final int? cap;

  final VoidCallback? onTap;

  /// Past the store's limit. Dimmed rather than hidden: the shots exist, and
  /// which of them will not be published is the thing worth seeing. The card
  /// says so in words underneath — a dimmed thumbnail on its own reads as a
  /// bug.
  bool get _overCap => cap != null && position > cap!;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tooltip(
      message: _overCap
          ? "${shot.name} — past $store's limit of $cap, not published"
          : shot.name,
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
          child: Opacity(
            opacity: _overCap ? 0.35 : 1,
            child: Container(
              width: width,
              decoration: BoxDecoration(
                color: colors.panel2,
                borderRadius: BorderRadius.circular(context.radii.radiusSmall),
                border: Border.all(color: colors.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image(
                image: shot.image,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The empty arm of a card, and the reason this panel has no separate empty
/// screen.
///
/// Ghost canvases at the set's real aspect ratio, filling the strip — which
/// says more than a sentence can: the shapes on screen are the shapes the
/// store will receive, so a 2:1 Play phone sitting two cards above a 4:3 iPad
/// shows what §1's canvas-is-not-a-device argument means without a word of it.
///
/// They fade rightwards because the count is unknown. A fixed number of solid
/// placeholders would be a claim about how many shots this set has, and the
/// panel has no idea — that is what the source scan decision 11 declined would
/// have bought.
class StoreGhostStrip extends StatelessWidget {
  const StoreGhostStrip({super.key, required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    var color = context.colors.mut3;
    return LayoutBuilder(
      builder: (context, constraints) {
        var step = width + FwSpacing.md;
        var count = (constraints.maxWidth / step).ceil().clamp(1, 12);
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            maxWidth: count * step,
            child: Row(
              children: [
                for (var i = 0; i < count; i++) ...[
                  Opacity(
                    opacity: (1 - i / count).clamp(0.15, 1.0),
                    child: DottedFrame(
                      width: width,
                      color: color,
                      radius: context.radii.radiusSmall,
                    ),
                  ),
                  const Gap(FwSpacing.md),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A dashed outline of the canvas — the shape an export will fill.
class DottedFrame extends StatelessWidget {
  const DottedFrame({
    super.key,
    required this.width,
    required this.color,
    required this.radius,
  });

  final double width;
  final Color color;
  final double radius;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(width, double.infinity),
    painter: _DashedBorder(color: color, radius: radius),
    child: SizedBox(width: width, height: double.infinity),
  );
}

class _DashedBorder extends CustomPainter {
  const _DashedBorder({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    var paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    var rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    // Walked rather than stroked: Flutter has no dashed stroke, and a metric
    // walk is the whole of what a dash pattern is.
    for (var metric in (Path()..addRRect(rect)).computeMetrics()) {
      for (var at = 0.0; at < metric.length; at += 8) {
        canvas.drawPath(
          metric.extractPath(at, (at + 4).clamp(0, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) =>
      old.color != color || old.radius != radius;
}

/// How tall a thumbnail is on a card. The live half draws shorter — see the
/// mockup: it is evidence, and the export is the deliverable.
const storeThumbHeight = 168.0;

/// Kept so a card that has to fit two strips can shrink both together rather
/// than letting the live one dictate.
double storeThumbWidthFor(double height, double aspect) =>
    math.max(24, height * aspect);
