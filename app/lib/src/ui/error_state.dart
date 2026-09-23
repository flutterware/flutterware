import 'package:material_ui/material_ui.dart';

import 'design/design.dart';
import 'empty_state.dart';
import 'loading_state.dart';

/// The centred placeholder a list, table or panel shows when the thing it was
/// asked to do **failed**: a red icon, a [title] naming what failed, the
/// [message] the failure came with, and an optional retry.
///
/// The error arm of the load → empty/error triad, alongside [EmptyState] and
/// [LoadingState].
///
/// It is [EmptyState] with different defaults rather than a third layout, and
/// that is deliberate. The component this replaced — `ErrorPanel` — was a fourth
/// anatomy with raw `10.0`/`8.0` paddings, an uncoloured icon and text off
/// `Theme.of` rather than the tokens, and it had exactly one call site after
/// years in the tree. Panels did not adopt it because it did not look like the
/// panel around it. So the shape here is the shape a panel already shows when
/// it is empty or loading, and only the two things that genuinely differ are
/// changed:
///
/// - **The icon is red.** It is the one mark that separates "nothing here" from
///   "this did not work" without reading a word.
/// - **The message is selectable.** An error message is a path, a command or a
///   stack trace, and the first thing anyone does with one is paste it into a
///   terminal or a bug. An empty state's message is prose and is not copied.
///
/// Four panels had already worked this out and were writing
/// `EmptyState(icon: Icons.error_outline, …)` by hand; this is that, named, and
/// with the selectable message they were missing.
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.error_outline,
    this.onRetry,
    this.retryLabel = 'Try again',
    this.minHeight = 160,
  });

  /// What failed, as a sentence — `Could not read the icons`. Not the
  /// exception: that is [message]. A title built from an exception cannot be
  /// scanned.
  final String title;

  /// What the failure said. Shown selectable, and safe to be long.
  final String? message;

  final IconData icon;

  /// Offered only when retrying is actually a thing the caller can do. A retry
  /// button that re-runs something already known to fail is worse than none.
  final VoidCallback? onRetry;

  final String retryLabel;

  final double minHeight;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: icon,
      iconColor: context.colors.red,
      title: title,
      message: message,
      selectableMessage: true,
      minHeight: minHeight,
      action: onRetry == null
          ? null
          : OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: FwIconSize.md),
              label: Text(retryLabel),
            ),
    );
  }
}
