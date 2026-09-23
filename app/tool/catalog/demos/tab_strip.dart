import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/inspect/inspect_dock.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'command_palette.dart' show wrapInAppTheme;

/// [InspectTabStrip], the strip three panels share — the server panel, the run
/// cockpit and the lints panel.
///
/// It exists as a demo because of what it got wrong for as long as it existed:
/// its tabs were `InkWell`s inside the strip's own opaque
/// `Container(color: colors.panel)`, and a [Material] paints its ink features
/// *below* its child — so every hover wash the tabs asked for was painted and
/// then covered. Hovering a tab moved no pixel in any of the three panels.
///
/// A hover state is a colour rather than a widget, so no probe can read it and
/// no widget test can photograph it — the test binding loads no font and draws
/// every glyph as a box. `previews screenshot` on this entry can, which is the
/// whole reason it is here: the claim "the tabs answer the pointer now" is one
/// somebody has to be able to check.
///
/// Three strips, because the states are about the row rather than about one
/// tab: a selected tab with a badge, an unselected one, and a strip whose tabs
/// have no badges at all.
@Preview(name: 'Tab strip', wrapper: wrapInAppTheme)
Widget tabStrip() => const _TabStripDemo();

class _TabStripDemo extends StatefulWidget {
  const _TabStripDemo();

  @override
  State<_TabStripDemo> createState() => _TabStripDemoState();
}

class _TabStripDemoState extends State<_TabStripDemo> {
  var _current = 'requests';

  static Widget _unused(BuildContext context) => const SizedBox.shrink();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return ColoredBox(
      color: colors.bg,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var tabs in [
              const [
                InspectDockTab(
                  id: 'requests',
                  label: 'Requests',
                  badge: 14,
                  body: _unused,
                ),
                InspectDockTab(id: 'sql', label: 'SQL', body: _unused),
                InspectDockTab(id: 'events', label: 'Events', body: _unused),
              ],
              const [
                InspectDockTab(id: 'screen', label: 'Screen', body: _unused),
                InspectDockTab(id: 'steps', label: 'Steps', body: _unused),
                InspectDockTab(id: 'logs', label: 'Logs', body: _unused),
              ],
            ]) ...[
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: colors.line),
                ),
                child: InspectTabStrip(
                  tabs: tabs,
                  current: tabs.any((tab) => tab.id == _current)
                      ? _current
                      : tabs.first.id,
                  onSelect: (id) => setState(() => _current = id),
                  trailing: [
                    InspectStripButton(
                      icon: Icons.refresh,
                      tooltip: 'Read it all again',
                      onTap: () {},
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ],
        ),
      ),
    );
  }
}
