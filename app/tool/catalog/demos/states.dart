import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/ui/empty_state.dart';
import 'package:flutterware_app/src/ui/error_state.dart';
import 'package:flutterware_app/src/ui/loading_state.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// The load → empty → error triad, together, which is the only way to see the
/// thing that matters about it: **a panel that loads, finds nothing, and then
/// fails should not move its own words around as it settles.**
///
/// Same 32px icon slot, same gaps, same two lines of type in all three. Read
/// the first entry below and the three states should look like one state in
/// three tenses. If a future edit breaks that, this is where it shows.
///
/// These are also the components with the widest reach in the app — measured
/// 2026-08-13: 23 empty, 16 loading, 12 error — and until now the only way to
/// look at one was to make a panel fail.

/// The alignment check. Three states stacked, so a drifted gap or icon size
/// in any one of them is a step in a line that should be straight.
@Preview(name: 'The triad, stacked', group: 'States', wrapper: wrapInAppTheme)
Widget triad() => const _Stack(
  children: [
    LoadingState(title: 'Scanning for scenarios…', minHeight: 200),
    EmptyState(
      icon: Icons.inbox_outlined,
      title: 'No scenarios here',
      message: 'Nothing declares one in test/.',
      minHeight: 200,
    ),
    ErrorState(
      title: 'The scan failed',
      message: 'Could not read test/: permission denied',
      minHeight: 200,
    ),
  ],
);

@Preview(
  name: 'The triad, stacked · dark',
  group: 'States',
  wrapper: wrapInDarkTheme,
)
Widget triadDark() => triad();

/// Every shape an empty state takes, including the one with an action.
@Preview(name: 'Empty', group: 'States', wrapper: wrapInAppTheme)
Widget empty() => _Stack(
  children: [
    const EmptyState(title: 'Nothing to show', minHeight: 180),
    const EmptyState(
      icon: Icons.inventory_2_outlined,
      title: 'No package matches "flutter_riverpod"',
      minHeight: 180,
    ),
    EmptyState(
      icon: Icons.movie_outlined,
      title: 'No scenes here',
      message:
          'No *.scene.dart under packages/app/lib, which is the directory '
          'this plugin was pointed at.',
      action: OutlinedButton(onPressed: () {}, child: const Text('Scan again')),
      minHeight: 180,
    ),
  ],
);

/// The reason `ErrorState` is not just `EmptyState` with a red icon. Its
/// message is selectable: try to drag-select the path in the second entry, then
/// try the same in any empty state above. An error message is a thing you paste
/// into a terminal or a bug.
@Preview(name: 'Error', group: 'States', wrapper: wrapInAppTheme)
Widget error() => _Stack(
  children: [
    const ErrorState(title: 'This app stopped answering', minHeight: 180),
    const ErrorState(
      title: 'Could not read the icons',
      message:
          '/Users/someone/projects/app/android/app/src/main/res: no such file '
          'or directory',
      minHeight: 180,
    ),
    ErrorState(
      title: 'Could not load dependencies',
      message: 'dart pub deps failed (exit 1)',
      onRetry: () {},
      minHeight: 180,
    ),
  ],
);

@Preview(name: 'Error · dark', group: 'States', wrapper: wrapInDarkTheme)
Widget errorDark() => error();

/// A long message with nothing to wrap on — a stack trace, a resolved
/// constraint, a base64 token. Centred text has no good answer to this, so the
/// answer has to be visible rather than assumed.
@Preview(name: 'Error · long message', group: 'States', wrapper: wrapInAppTheme)
Widget errorLong() => const _Stack(
  children: [
    ErrorState(
      title: 'Version solving failed',
      message:
          'Because every version of flutter_test from sdk depends on '
          'collection 1.19.1 and app depends on collection ^1.16.0, '
          'flutter_test from sdk is forbidden.\n\n'
          'So, because app depends on flutter_test from sdk, version solving '
          'failed.',
      minHeight: 220,
    ),
  ],
);

/// In the pane they actually live in, rather than across a desktop window. All
/// three are `Center`-based, so a narrow pane is where a too-wide message or a
/// clipped icon would first show.
@Preview(
  name: 'Narrow — the whole pane',
  group: 'States',
  wrapper: wrapInAppTheme,
)
Widget narrow() => const NarrowPane(
  child: _Stack(
    children: [
      LoadingState(title: 'Building the guest…', message: 'building'),
      ErrorState(
        title: 'The guest could not start',
        message: 'the compiler daemon exited with code 70',
      ),
    ],
  ),
);

/// One per band, so the boundaries between them are visible and a state that
/// silently sizes itself differently is obvious.
class _Stack extends StatelessWidget {
  const _Stack({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.panel,
    child: ListView(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      children: [
        for (var child in children)
          Padding(
            padding: const EdgeInsets.only(bottom: FwSpacing.lg),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.colors.bg,
                border: Border.all(color: context.colors.line),
                borderRadius: BorderRadius.circular(context.radii.radius),
              ),
              child: child,
            ),
          ),
      ],
    ),
  );
}
