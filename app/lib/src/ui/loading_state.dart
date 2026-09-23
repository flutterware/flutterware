import 'package:material_ui/material_ui.dart';

import 'design/design.dart';

/// The centred placeholder a list, table or panel shows *while it is working*:
/// a muted spinner, a [title] and an optional [message]. The load arm of the
/// load → empty/error triad, alongside [EmptyState].
///
/// It is deliberately the same anatomy as [EmptyState] — same 32px slot,
/// same gaps, same two lines of type — so a panel that loads and then finds
/// nothing does not move its own words around as it settles. The two states are
/// the same sentence in two tenses, and they should look it.
///
/// The size matters. A bare `CircularProgressIndicator` in a panel-sized
/// field renders as a small dot floating in white with nothing to say — which
/// is what the previews panel showed for the several seconds it takes to build
/// a guest and compile an entry. A spinner the size of an icon, with a line of
/// text under it, is a state; a dot is a rendering artefact.
class LoadingState extends StatelessWidget {
  const LoadingState({
    super.key,
    this.title = 'Loading…',
    this.message,
    this.minHeight = 160,
  });

  /// What is being waited for, in the panel's own words. The default is a
  /// fallback rather than the target — "Building the guest" beats "Loading…",
  /// because only one of them tells you whether to keep waiting.
  final String title;

  /// A second line: why it takes as long as it does, or what happens next.
  final String? message;

  final double minHeight;

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
              SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: context.colors.mut3,
                ),
              ),
              const Gap(FwSpacing.lg),
              Text(
                title,
                style: context.type.bodyStrong,
                textAlign: TextAlign.center,
              ),
              if (message != null) ...[
                const Gap(FwSpacing.xxs),
                Text(
                  message!,
                  style: context.type.bodyMuted,
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
