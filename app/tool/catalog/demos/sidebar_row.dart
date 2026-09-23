import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/plugins/native_plugin.dart';
import 'package:flutterware_app/src/shell/sidebar_row.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'command_palette.dart' show wrapInAppTheme;

/// The shell's sidebar rows — a plugin's own and a package's — in the states
/// they are actually seen in.
///
/// The arrangement is the whole point of having a demo for something this
/// small: the name takes the slack on the left and the status is pinned to the
/// right edge, so down the rail the statuses form one column whatever the
/// names say; a package row's ⋮ sits past its status at the far edge. All of
/// it has been wrong — the ⋮ used to follow the status text, fixing that
/// pushed the status into the middle of the row, and the plugin rows' flex
/// arrangement parked every status at whatever point two-thirds of the row
/// happened to be, truncating "5 devices…" beside three empty centimetres of
/// rail.
///
/// Stacked rather than one state per entry: the alignment claims above are
/// about rows *relative to each other*, and a gallery that showed them one at a
/// time could not have caught any of those bugs.
///
/// No Figma behind this — it is flutterware's own chrome, and the arrangement
/// was specified in review rather than drawn.
/// The sidebar's real width. These rows are as wide as they are, and a demo
/// that let them stretch to the window would not show the ellipsis that a long
/// package name actually hits.
const _sidebarWidth = 232.0;

/// Enough commands to open a menu with, for the states that have a ⋮.
List<PluginChildCommand> get _commands => [
  PluginChildCommand(
    label: 'Build a web page…',
    icon: Icons.language,
    onSelected: (_) {},
  ),
];

@Preview(name: 'Every state', group: 'Sidebar row', wrapper: wrapInAppTheme)
Widget sidebarRowStates() => const _Rail(
  children: [
    _Labelled(
      'idle',
      SidebarChildRow(
        label: 'app',
        status: Status.none,
        selected: false,
        onTap: _noop,
      ),
    ),
    _Labelled(
      'with a status',
      SidebarChildRow(
        label: 'fixtures/probe_app',
        status: Status.info('building'),
        selected: false,
        onTap: _noop,
      ),
    ),
    _Labelled(
      'selected — the ⋮ stays without the pointer',
      _WithCommands(
        label: 'fixtures/probe_app',
        status: Status.info('building'),
        selected: true,
      ),
    ),
    _Labelled(
      'every tone',
      Column(
        children: [
          SidebarChildRow(
            label: 'packages/core',
            status: Status.neutral('58 packages'),
            selected: false,
            onTap: _noop,
          ),
          SidebarChildRow(
            label: 'packages/ui',
            status: Status.warn('2 problems'),
            selected: false,
            onTap: _noop,
          ),
          SidebarChildRow(
            label: 'packages/legacy',
            status: Status.error('failed to scan'),
            selected: false,
            onTap: _noop,
          ),
        ],
      ),
    ),
    _Labelled(
      'the ⋮ lines up whatever the status says',
      Column(
        children: [
          _WithCommands(
            label: 'app',
            status: Status.info('building'),
            selected: true,
          ),
          _WithCommands(
            label: 'fixtures/probe_app',
            status: Status.warn('10 assets · 347 kB · 2 problems'),
            selected: true,
          ),
          _WithCommands(label: 'tools', status: Status.none, selected: true),
        ],
      ),
    ),
    _Labelled(
      'what a tester host says while it works',
      Column(
        children: [
          SidebarChildRow(
            label: 'app',
            status: Status.info('compiling the catalog…'),
            selected: false,
            onTap: _noop,
          ),
          SidebarChildRow(
            label: 'app',
            status: Status.info('restarting the harness…'),
            selected: false,
            onTap: _noop,
          ),
          SidebarChildRow(
            label: 'fixtures/probe_app',
            status: Status.info('reloading 3 files…'),
            selected: false,
            onTap: _noop,
          ),
        ],
      ),
    ),
    _Labelled(
      'a name too long for the rail keeps the status',
      _WithCommands(
        label: 'packages/design_system_foundations',
        status: Status.info('building'),
        selected: true,
      ),
    ),
  ],
);

@Preview(name: 'Plugin rows', group: 'Sidebar row', wrapper: wrapInAppTheme)
Widget sidebarPluginRows() => _Rail(
  children: [
    const _Labelled(
      'the statuses form a column down the right edge',
      Column(
        children: [
          SidebarRow(
            label: 'Overview',
            icon: Icons.home_outlined,
            selected: false,
            onTap: _noop,
          ),
          SidebarRow(label: 'Dependencies', selected: false, onTap: _noop),
          SidebarRow(
            label: 'Example server',
            status: Status.neutral('down'),
            selected: false,
            onTap: _noop,
          ),
          SidebarRow(
            label: 'Previews',
            status: Status.warn('2 warnings'),
            selected: false,
            onTap: _noop,
          ),
          SidebarRow(
            label: 'Scenarios',
            status: Status.error('scan failed'),
            selected: false,
            onTap: _noop,
          ),
        ],
      ),
    ),
    const _Labelled(
      'selected',
      SidebarRow(
        label: 'Run',
        status: Status.good('live'),
        selected: true,
        onTap: _noop,
      ),
    ),
    const _Labelled(
      'a long label yields before the status does',
      SidebarRow(
        label: 'A plugin with a name too long for the rail',
        status: Status.neutral('down'),
        selected: false,
        onTap: _noop,
      ),
    ),
    const _Labelled(
      'a long status ellipsises and the label keeps the rest',
      SidebarRow(
        label: 'Run',
        status: Status.info('Syncing files to device macOS...'),
        selected: false,
        onTap: _noop,
      ),
    ),
  ],
);

/// A row that offers commands, so the ⋮ is drawn.
///
/// Separate because [PluginChildCommand] holds a callback and so cannot be
/// const, and the states above are otherwise all const.
class _WithCommands extends StatelessWidget {
  const _WithCommands({
    required this.label,
    required this.status,
    required this.selected,
  });

  final String label;
  final Status status;
  final bool selected;

  @override
  Widget build(BuildContext context) => SidebarChildRow(
    label: label,
    status: status,
    selected: selected,
    commands: _commands,
    onTap: _noop,
  );
}

void _noop() {}

/// The rail these rows live in, at the width they live at.
class _Rail extends StatelessWidget {
  const _Rail({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return ColoredBox(
      color: colors.bg,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: FwSpacing.xl),
        children: [
          for (var child in children)
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(width: _sidebarWidth, child: child),
            ),
        ],
      ),
    );
  }
}

/// A caption above a state, so a screenshot of this entry says what each row is
/// meant to be showing.
class _Labelled extends StatelessWidget {
  const _Labelled(this.caption, this.child);

  final String caption;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: FwSpacing.xl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FwSpacing.lg,
            0,
            FwSpacing.lg,
            FwSpacing.xs,
          ),
          child: Text(
            caption,
            style: context.type.micro.copyWith(color: context.colors.mut3),
          ),
        ),
        child,
      ],
    ),
  );
}
