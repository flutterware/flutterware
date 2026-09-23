import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/ui/command_palette.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// The ⌘K palette, one state per entry.
///
/// Split rather than stacked because the headless capture is a fixed 900x700
/// frame regardless of the size an entry declares, so a single gallery entry
/// would only ever screenshot its first two states. One state per entry means
/// every one of them is reviewable as a picture — and it follows `Avatar tile /
/// …` next door.
///
/// Deliberately not using `shell.dart`'s `wrapInApp`: that stands in for a
/// *project's* shell and is being reworked alongside the axes. This wraps in the
/// app's own theme, which is what the palette actually renders against.
Widget wrapInAppTheme(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: appTheme,
  // `Material`, not a bare `ColoredBox`: text outside a Material ancestor draws
  // with Flutter's yellow debug underline, which turns every label in a demo
  // into a false defect.
  home: Material(color: appTheme.colorScheme.surface, child: child),
);

Address _address(String plugin, [List<String> segments = const []]) =>
    Address(worktree: 'main', plugin: plugin, segments: segments);

/// A hit, with the fuzzy highlight offsets spelled out rather than computed — a
/// demo should not depend on the matcher to show what a lit title looks like.
SearchHit _hit(
  String title, {
  required String group,
  required SearchReason reason,
  String? subtitle,
  List<int> matched = const [],
  List<String> segments = const [],
  String plugin = 'flutterware.previews',
}) => SearchHit(
  address: _address(plugin, segments),
  title: title,
  subtitle: subtitle,
  group: group,
  reason: reason,
  score: 0,
  matched: matched,
);

/// What typing "dash" really returns: an entry that carries its own address,
/// then the coarser things that also matched.
List<PaletteSection> get _populated => [
  PaletteSection('Previews', [
    _hit(
      'Dashboard',
      group: 'Previews',
      reason: SearchReason.item,
      subtitle: 'tool/catalog/demos/dashboard.dart#dashboard',
      matched: const [0, 1, 2, 3],
      segments: const ['app', 'tool/catalog/demos/dashboard.dart#dashboard'],
    ),
    _hit(
      'Avatar tile / Empty',
      group: 'Previews',
      reason: SearchReason.item,
      subtitle: 'tool/catalog/demos/avatar_tile.dart#avatarTileEmpty',
      segments: const ['app', 'tool/catalog/demos/avatar_tile.dart#empty'],
    ),
    _hit('app', group: 'Previews', reason: SearchReason.package),
  ]),
  PaletteSection('Dependencies', [
    _hit(
      'collection',
      group: 'Dependencies',
      reason: SearchReason.item,
      subtitle: '1.19.1',
      plugin: 'flutterware.dependencies',
    ),
    _hit(
      'Dependencies',
      group: 'Dependencies',
      reason: SearchReason.plugin,
      plugin: 'flutterware.dependencies',
    ),
  ]),
];

@Preview(name: 'Results', group: 'Command palette', wrapper: wrapInAppTheme)
Widget paletteResults() => _Case(query: 'dash', sections: _populated);

@Preview(
  name: 'Third row selected',
  group: 'Command palette',
  wrapper: wrapInAppTheme,
)
Widget paletteSelected() =>
    _Case(query: 'dash', sections: _populated, selected: 2);

@Preview(
  name: 'Nothing typed',
  group: 'Command palette',
  wrapper: wrapInAppTheme,
)
Widget paletteIdle() => const _Case(sections: []);

@Preview(name: 'No match', group: 'Command palette', wrapper: wrapInAppTheme)
Widget paletteNoMatch() => const _Case(query: 'zzzz', sections: []);

@Preview(
  name: 'Loading, nothing yet',
  group: 'Command palette',
  wrapper: wrapInAppTheme,
)
Widget paletteLoadingEmpty() =>
    const _Case(query: 'dash', sections: [], loading: true);

@Preview(
  name: 'Loading over results',
  group: 'Command palette',
  wrapper: wrapInAppTheme,
)
Widget paletteLoadingResults() =>
    _Case(query: 'dash', sections: _populated, loading: true);

@Preview(name: 'One result', group: 'Command palette', wrapper: wrapInAppTheme)
Widget paletteSingle() => _Case(
  query: 'dashboard',
  sections: [
    PaletteSection('Previews', [_populated.first.hits.first]),
  ],
);

/// Every provenance chip, so none of them is first seen in production.
@Preview(
  name: 'Every kind of hit',
  group: 'Command palette',
  wrapper: wrapInAppTheme,
)
Widget paletteKinds() => _Case(
  query: 'a',
  sections: [
    PaletteSection('Kinds', [
      for (var reason in SearchReason.values)
        _hit(
          reason.label,
          group: 'Kinds',
          reason: reason,
          subtitle: '${reason.name} hit',
        ),
    ]),
  ],
);

/// The shapes that break a row: no subtitle, a title past the edge, a subtitle
/// past the edge, RTL, and a title that is short but tall.
@Preview(
  name: 'Awkward content',
  group: 'Command palette',
  wrapper: wrapInAppTheme,
)
Widget paletteAwkward() => _Case(
  query: 'a',
  sections: [
    PaletteSection('Awkward', [
      _hit('No subtitle at all', group: 'Awkward', reason: SearchReason.item),
      _hit(
        'A demo name that runs well past the width of the palette and has to '
        'be cut off somewhere sensible',
        group: 'Awkward',
        reason: SearchReason.item,
        subtitle: 'packages/some/deeply/nested/path/to/a/file.dart#aLongSymbol',
      ),
      _hit(
        'Short title',
        group: 'Awkward',
        reason: SearchReason.item,
        subtitle:
            'A detail that is itself far too long to fit on one line and must '
            'ellipsize rather than wrap the row into two',
      ),
      _hit(
        'اختبار / لوحة القيادة',
        group: 'Awkward',
        reason: SearchReason.item,
        subtitle: 'rtl text in an otherwise ltr row',
      ),
      _hit('日本語のデモ', group: 'Awkward', reason: SearchReason.item),
    ]),
  ],
);

/// Enough rows to scroll, which proves the list scrolls inside the panel rather
/// than growing it.
@Preview(
  name: 'Long enough to scroll',
  group: 'Command palette',
  wrapper: wrapInAppTheme,
)
Widget paletteMany() => _Case(
  query: 'entry',
  sections: [
    PaletteSection('Many', [
      for (var i = 0; i < 30; i++)
        _hit(
          'Entry number $i',
          group: 'Many',
          reason: SearchReason.item,
          subtitle: 'demo/entry_$i.dart#entry$i',
        ),
    ]),
  ],
);

/// One palette, centred and sized the way the real overlay will be.
class _Case extends StatelessWidget {
  const _Case({
    required this.sections,
    this.query = '',
    this.loading = false,
    this.selected = 0,
  });

  final List<PaletteSection> sections;
  final String query;
  final bool loading;
  final int selected;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600, maxHeight: 520),
          child: CommandPalette(
            sections: sections,
            initialQuery: query,
            initialSelected: selected,
            loading: loading,
            onQueryChanged: (_) {},
            onActivate: (_) {},
            onDismiss: () {},
          ),
        ),
      ),
    );
  }
}

void main() => runApp(wrapInAppTheme(paletteResults()));
