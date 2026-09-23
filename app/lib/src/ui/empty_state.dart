import 'package:material_ui/material_ui.dart';

import 'design/design.dart';

/// The centred placeholder a list, table, or panel shows when it has nothing to
/// display: a muted icon, a [title], an optional [message] and an optional
/// [action]. The empty arm of the load → empty/error triad alongside
/// [LoadingState] and `ErrorPanel`.
///
/// Ported from `cms/packages/admin_ui/lib/src/common/ui/empty_state.dart`.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final double minHeight;

  /// Overrides the muted icon. The one caller that needs it is [ErrorState],
  /// which paints the icon red — the single mark that separates "nothing here"
  /// from "this did not work" at a glance.
  final Color? iconColor;

  /// Makes [message] selectable. Off by default, because an empty state's
  /// message is prose rather than something to copy. [ErrorState]
  /// turns it on: an error message is a path, a command or a stack, and the
  /// first thing anyone does with one is paste it somewhere.
  final bool selectableMessage;

  const EmptyState({
    super.key,
    this.icon = Icons.inbox_outlined,
    required this.title,
    this.message,
    this.action,
    this.minHeight = 160,
    this.iconColor,
    this.selectableMessage = false,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(FwSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: FwIconSize.xl,
                color: iconColor ?? context.colors.mut3,
              ),
              const Gap(FwSpacing.md),
              Text(
                title,
                style: context.type.bodyStrong,
                textAlign: TextAlign.center,
              ),
              if (message != null) ...[
                const Gap(FwSpacing.xxs),
                if (selectableMessage)
                  SelectableText(
                    message!,
                    style: context.type.bodyMuted,
                    textAlign: TextAlign.center,
                  )
                else
                  Text(
                    message!,
                    style: context.type.bodyMuted,
                    textAlign: TextAlign.center,
                  ),
              ],
              if (action != null) ...[const Gap(FwSpacing.lg), action!],
            ],
          ),
        ),
      ),
    );
  }
}
