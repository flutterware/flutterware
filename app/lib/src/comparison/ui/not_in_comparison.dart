import 'package:flutter/material.dart';

import '../../ui/empty_state.dart';

const notInComparisonKey = Key('comparison.notInComparison');

/// A link naming something this comparison does not have — a preview, a flow,
/// a step or a whole tab — said where that thing would have been drawn.
///
/// The alternative was the one the tabs used to take: draw the first finding
/// instead. That is a page that looks like the link worked, under an address
/// still naming what it asked for, about something else. The studio's catalog
/// refuses the same quiet repair for the same reason. What was renamed or
/// removed since the link was written is the likeliest story, and the reader
/// can only tell it from a page that admits the miss.
class NotInComparison extends StatelessWidget {
  const NotInComparison({super.key, required this.address, this.action});

  /// What the link named, as the page's address spells it.
  final String address;

  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    // A sentence rather than a line: a step page is as wide as the window,
    // and a message run edge to edge is not read.
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: EmptyState(
        key: notInComparisonKey,
        icon: Icons.link_off_rounded,
        title: 'Not in this comparison',
        message:
            'The link names $address, and nothing in this comparison has that '
            'name. It may have been renamed or removed since the link was '
            'written.',
        selectableMessage: true,
        action: action,
      ),
    ),
  );
}
