import 'package:material_ui/material_ui.dart';

import '../../ui/theme.dart';

/// Which channels fired on a row, in a fixed order so the column scans.
///
/// Named rather than coloured — the row already carries a `StateChip`, and
/// the events pane's channel palette collides with it on the two colours that
/// carry meaning. The one emphasis: `pixels` in ink, because *is this a
/// picture change or a behaviour change* is the row's triage question, and
/// when the fraction is known it rides along — `pixels 2%` says how much of
/// the frame moved before anything is clicked.
class ChannelSignature extends StatelessWidget {
  const ChannelSignature({
    super.key,
    required this.channels,
    this.pixelFraction,
    this.maxLines,
  });

  final List<String> channels;
  final double? pixelFraction;

  /// Bounded where the host budgets its height — a flow node's caption is a
  /// fixed slot, and an unbounded wrap overflows it rather than eliding.
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var micro = context.type.micro;
    var spans = <TextSpan>[];
    for (var channel in const ['pixels', 'tree', 'texts', 'events']) {
      if (!channels.contains(channel)) continue;
      if (spans.isNotEmpty) {
        spans.add(
          TextSpan(
            text: ' · ',
            style: TextStyle(color: colors.mut3),
          ),
        );
      }
      if (channel == 'pixels') {
        var fraction = pixelFraction;
        var label = fraction == null
            ? 'pixels'
            : 'pixels ${_percent(fraction)}';
        spans.add(
          TextSpan(
            text: label,
            style: TextStyle(color: colors.ink2, fontWeight: FontWeight.w600),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: channel,
            style: TextStyle(color: colors.mut),
          ),
        );
      }
    }
    return Text.rich(
      TextSpan(children: spans),
      style: micro,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }

  /// `0.0012` is a real finding and `0%` is a claim that nothing moved, so
  /// anything under a percent rounds up to the smallest honest number.
  static String _percent(double fraction) {
    var percent = fraction * 100;
    if (percent < 1) return '<1%';
    return '${percent.round()}%';
  }
}
