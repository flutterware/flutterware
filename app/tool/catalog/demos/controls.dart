import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/ui/hover_card.dart';
import 'package:flutterware_app/src/ui/menu.dart';
import 'package:flutterware_app/src/ui/split_button.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// The split button and the hover card — two controls whose interesting states
/// only exist while a pointer is somewhere.
///
/// This is the case previews are actually best at. Neither of these can be
/// screenshotted in a useful state from a running app without holding a cursor
/// still at the right pixel, and neither is reachable from a widget test
/// without pumping specific durations. Here the menu is one click away and the
/// card is one hover away, in every shape they take.

@Preview(name: 'Split button', group: 'Controls', wrapper: wrapInAppTheme)
Widget splitButton() => const _SplitButtons();

@Preview(
  name: 'Split button · dark',
  group: 'Controls',
  wrapper: wrapInDarkTheme,
)
Widget splitButtonDark() => const _SplitButtons();

/// The hover card, with its delays intact — 450ms to open, 260ms to close.
///
/// Those numbers are the whole design: a card that opens instantly fires on
/// every pointer that crosses it, and one that closes instantly cannot be moved
/// into. Hover the rows and try to reach the card.
@Preview(name: 'Hover card', group: 'Controls', wrapper: wrapInAppTheme)
Widget hoverCard() => const _HoverCards();

class _SplitButtons extends StatelessWidget {
  const _SplitButtons();

  static List<MenuEntry> get _entries => [
    const MenuHeader('Reload'),
    MenuItem('Resolve again', icon: Icons.refresh, onSelected: () {}),
    MenuItem(
      'Resolve offline',
      icon: Icons.cloud_off,
      shortcut: '⌘⇧R',
      onSelected: () {},
    ),
    const MenuDivider(),
    MenuItem(
      'Delete the lockfile',
      icon: Icons.delete_outline,
      danger: true,
      onSelected: () {},
    ),
  ];

  @override
  Widget build(BuildContext context) => _Page(
    title: 'Split button',
    cases: [
      (
        'Label and a menu',
        'The primary segment does the common thing; the chevron holds the rest.',
        FwSplitButton(label: 'Reload', onPressed: () {}, entries: _entries),
      ),
      (
        'With an icon',
        'The icon rides with the label rather than replacing it.',
        FwSplitButton(
          label: 'Run',
          icon: Icons.play_arrow,
          onPressed: () {},
          entries: _entries,
        ),
      ),
      (
        'Icon only — the toolbar shape',
        'Borderless, sized for a strip where the words are already elsewhere.',
        FwSplitButton.icon(
          icon: Icons.more_horiz,
          tooltip: 'Row actions',
          onPressed: () {},
          entries: _entries,
        ),
      ),
      (
        'No menu',
        'With no entries the chevron stays but goes quiet. It follows the '
            'entries, not the primary — which is what lets a menu of '
            'alternatives outlive a primary that is momentarily unavailable.',
        FwSplitButton(label: 'Reload', onPressed: () {}),
      ),
      (
        'Disabled',
        'A null callback. The menu stays reachable — the actions in it are not '
            'necessarily disabled too.',
        FwSplitButton(label: 'Reload', onPressed: null, entries: _entries),
      ),
    ],
  );
}

class _HoverCards extends StatelessWidget {
  const _HoverCards();

  @override
  Widget build(BuildContext context) => _Page(
    title: 'Hover card',
    cases: [
      (
        'A row that explains itself',
        'Point at it and wait — the enter delay is deliberate.',
        _Card(
          label: 'built_value  8.12.6',
          body: const [
            ('Constraint', '^8.3.0'),
            ('Resolved', '8.12.6'),
            ('Origin', 'pub.dev'),
            ('Kind', 'Direct'),
          ],
        ),
      ),
      (
        'Long content',
        'The card sizes to its content and flips side when it would run off.',
        _Card(
          label: 'a_package_with_a_long_name',
          body: const [
            ('Description', 'A package that exists to make this card wrap'),
            ('Publisher', 'example.dev'),
            ('Constraint', '>=0.6.0 <0.8.0'),
            ('Resolved', '0.7.12'),
            ('Origin', 'git · someone/a-very-long-repository-name.dart'),
          ],
        ),
      ),
    ],
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.label, required this.body});

  final String label;
  final List<(String, String)> body;

  @override
  Widget build(BuildContext context) {
    return HoverCard(
      anchor: (context, controller) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.lg,
          vertical: FwSpacing.md,
        ),
        decoration: BoxDecoration(
          color: context.colors.bg,
          border: Border.all(color: context.colors.line),
          borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        ),
        child: Text(label, style: context.type.bodyStrong),
      ),
      content: (context, controller) => Container(
        width: 320,
        padding: const EdgeInsets.all(FwSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var (key, value) in body)
              Padding(
                padding: const EdgeInsets.only(bottom: FwSpacing.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 90,
                      child: Text(key, style: context.type.micro),
                    ),
                    Expanded(child: Text(value, style: context.type.caption)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The same case-with-a-note frame the action button demo uses, so the control
/// demos read as one family.
class _Page extends StatelessWidget {
  const _Page({required this.title, required this.cases});

  final String title;
  final List<(String, String, Widget)> cases;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.panel,
    child: ListView(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      children: [
        Text(title, style: context.type.pageTitle),
        const Gap(FwSpacing.xl),
        for (var (heading, note, child) in cases)
          Padding(
            padding: const EdgeInsets.only(bottom: FwSpacing.xxxl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(heading, style: context.type.sectionLabel),
                const Gap(FwSpacing.xxs),
                Text(
                  note,
                  style: context.type.caption.copyWith(
                    color: context.colors.mut2,
                  ),
                ),
                const Gap(FwSpacing.md),
                Align(alignment: Alignment.centerLeft, child: child),
              ],
            ),
          ),
      ],
    ),
  );
}
