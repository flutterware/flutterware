import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/ui/action_button.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'shell.dart';

/// The button that says what happened, in the four cases it has to survive.
///
/// These have to be pressed to be seen, and that is the point. Every state
/// but idle is transient and timing-dependent, so none of them appears in a
/// screenshot and none of them is reachable from a widget test without pumping
/// specific durations. The one below labelled *instant* is the case the button
/// exists for: work that finishes in a millisecond still has to acknowledge
/// itself, or pressing it looks like nothing happened.
@Preview(name: 'Action button', group: 'Controls', wrapper: wrapInApp)
Widget actionButton() => const _ActionButtons();

class _ActionButtons extends StatelessWidget {
  const _ActionButtons();

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.colors.bg,
    body: ListView(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      children: [
        _Case(
          'Instant — the case this exists for',
          'Returns immediately. The running state is held to its floor so the '
              'press is legible anyway.',
          FwActionButton(
            label: 'Reload',
            tooltip: 'Read the config and its images again',
            onPressed: () async {},
          ),
        ),
        _Case(
          'Slow',
          'Longer than the floor, so nothing is padded — running lasts as long '
              'as the work does.',
          FwActionButton(
            label: 'Resolve',
            onPressed: () =>
                Future<void>.delayed(const Duration(milliseconds: 2200)),
          ),
        ),
        _Case(
          'Fails',
          'The error keeps its own words, and stays up until the next press '
              'rather than timing out unread. Hover it.',
          FwActionButton(
            label: 'Reload',
            onPressed: () async {
              await Future<void>.delayed(const Duration(milliseconds: 600));
              throw StateError(
                'flutter_native_splash.yaml:4:3: expected a mapping',
              );
            },
          ),
        ),
        _Case(
          'Primary, and disabled',
          'Primary is for the one button on a bar that is the point of it. A '
              'null callback is the disabled state.',
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FwActionButton(
                label: 'Run',
                primary: true,
                onPressed: () =>
                    Future<void>.delayed(const Duration(milliseconds: 900)),
              ),
              const Gap(FwSpacing.md),
              const FwActionButton(label: 'Run', onPressed: null),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Case extends StatelessWidget {
  const _Case(this.title, this.note, this.child);

  final String title;
  final String note;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: FwSpacing.xxxl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: context.type.sectionLabel),
        const Gap(FwSpacing.xxs),
        Text(
          note,
          style: context.type.caption.copyWith(color: context.colors.mut2),
        ),
        const Gap(FwSpacing.md),
        Align(alignment: Alignment.centerLeft, child: child),
      ],
    ),
  );
}
