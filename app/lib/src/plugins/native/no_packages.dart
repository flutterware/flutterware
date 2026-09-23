import 'package:material_ui/material_ui.dart';

import '../../ui/empty_state.dart';

/// What a plugin panel shows when the project declares no packages for it.
///
/// Six panels say this, and said it six times. Assets, Dependencies,
/// Launcher icon, Motion, Scenarios and Splash screen each carried their own
/// copy of the same two sentences, and the copies had already begun to drift:
/// four styled the text with `context.type.bodyMuted` and two with
/// `Theme.of(context).textTheme.bodyMedium`, which is a different grey for the
/// same sentence depending on which panel you happened to open.
///
/// It is a widget rather than six [EmptyState] calls because the message names
/// a file — `tool/flutterware.dart` — and a path that appears in six places is
/// a path that gets renamed in five.
///
/// The [icon] stays per-panel: which plugin you are looking at is the one thing
/// about this state that is not the same everywhere.
class NoPackagesConfigured extends StatelessWidget {
  const NoPackagesConfigured({super.key, required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: icon,
    title: 'No packages configured',
    message: 'Add them in tool/flutterware.dart.',
  );
}
