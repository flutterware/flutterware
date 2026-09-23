import 'package:material_ui/material_ui.dart';

import 'design/design.dart';
import 'tappable.dart';

/// A labelled section that opens.
///
/// The answer to a panel with twenty properties is not a longer column: what
/// is usually set stays in view, and what is rarely set sits one tap behind
/// this. The row is a caption and a chevron — the same weight as a section
/// label, because that is what it is, not a control competing with the ones
/// under it.
class Disclosure extends StatefulWidget {
  const Disclosure({
    super.key,
    required this.label,
    required this.children,
    this.initiallyOpen = false,
  });

  final String label;
  final List<Widget> children;
  final bool initiallyOpen;

  @override
  State<Disclosure> createState() => _DisclosureState();
}

class _DisclosureState extends State<Disclosure> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    var caption = context.type.caption.copyWith(color: context.colors.mut2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tappable(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(context.radii.radiusSmall),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: FwSpacing.xs),
            child: Row(
              children: [
                Icon(
                  _open ? Icons.keyboard_arrow_down : Icons.chevron_right,
                  size: FwIconSize.sm,
                  color: context.colors.mut2,
                ),
                const Gap(FwSpacing.xxs),
                Text(widget.label, style: caption),
              ],
            ),
          ),
        ),
        if (_open) ...[const Gap(FwSpacing.xs), ...widget.children],
      ],
    );
  }
}
