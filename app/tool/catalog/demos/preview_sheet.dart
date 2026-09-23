import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/catalog_tree.dart';
import 'package:flutterware_app/src/previews/preview_sheet.dart';

import 'app_theme.dart';

/// The catalog drawn as pictures, before there are any pictures.
///
/// What is under test is the **geometry**, which is the half that has to be
/// right before a single render is paid for: a full catalog is tens of seconds
/// of `flutter_tester`, so the sheet has to be a stable, readable page of
/// reserved boxes long before it is a page of photographs. Every tile here is
/// empty on purpose.
///
/// The two shapes a catalog holds are the reason the cells are uniform and the
/// boxes inside them are not — see [PreviewSheet]. A phone and a desktop panel
/// in one grid is the everyday case, not an edge one.
///
/// No Figma behind this; it is flutterware's own chrome.

/// The real thing: this repo's own catalog is 145 entries in 28 groups, which
/// is the size the whole design is for. A sheet that reads well at eight
/// entries and is a wall at a hundred and forty-five has not been tested.
@Preview(
  name: 'A whole catalog',
  group: 'Previews sheet',
  wrapper: wrapInAppTheme,
)
Widget sheetWhole() => _Sheet(sections: _sections(_wholeCatalog));

/// The other end. Most projects look like this, and a grid of ten tiles must
/// not read as a page that failed to load.
@Preview(
  name: 'A small catalog',
  group: 'Previews sheet',
  wrapper: wrapInAppTheme,
)
Widget sheetSmall() => _Sheet(sections: _sections(_smallCatalog));

/// The pane the sheet actually gets when the tree is open beside it — which is
/// the default, so this is the everyday width rather than the tight case.
@Preview(
  name: 'Beside the tree',
  group: 'Previews sheet',
  wrapper: wrapInAppTheme,
)
Widget sheetNarrow() => Align(
  alignment: Alignment.topLeft,
  child: SizedBox(
    width: 610,
    child: _Sheet(sections: _sections(_wholeCatalog)),
  ),
);

/// One tile lit. The picture will fill its box, so the mark has to read from
/// the box's edge and the name rather than from anything inside it.
@Preview(name: 'One selected', group: 'Previews sheet', wrapper: wrapInAppTheme)
Widget sheetSelected() => _Sheet(
  sections: _sections(_smallCatalog),
  selectedId: 'demo/input.dart#textFields',
);

/// Names that do not fit, which at this tile width is most of them. A name is
/// the only text on a tile and the only thing telling two identical grey boxes
/// apart, so where it truncates matters more here than in the tree.
@Preview(name: 'Long names', group: 'Previews sheet', wrapper: wrapInAppTheme)
Widget sheetLongNames() => _Sheet(sections: _sections(_longNames));

@Preview(name: 'Dark', group: 'Previews sheet', wrapper: wrapInDarkTheme)
Widget sheetDark() => _Sheet(sections: _sections(_wholeCatalog));

/// The page mid-fill, which is what it looks like for most of a first open.
///
/// All three waits at once, because telling them apart is the whole claim: the
/// tiles a cold harness has not reached shimmer, the one being photographed
/// carries a hairline in the accent, and the ones seconds away are the plain
/// reserved boxes they were before any of this. A page of a hundred and fifty
/// spinners reads as a hundred and fifty problems; this reads as one page
/// loading.
@Preview(
  name: 'While it fills',
  group: 'Previews sheet',
  wrapper: wrapInAppTheme,
)
Widget sheetFilling() => _filling();

/// And in dark, where the bands sweep the other way.
///
/// Both are translucent rather than a second flat tone, which is what makes
/// them read at all in either: the tile's ground is a near-white in one theme
/// and a slate in the other, and a fixed colour that showed against one would
/// vanish into the other.
@Preview(
  name: 'While it fills (dark)',
  group: 'Previews sheet',
  wrapper: wrapInDarkTheme,
)
Widget sheetFillingDark() => _filling();

Widget _filling() {
  var entries = _smallCatalog;
  var rendering = entries[2].id;
  return _Sheet(
    sections: _sections(entries),
    animate: true,
    waitOf: (entry) {
      if (entry.id == rendering) return PreviewTileWait.rendering;
      // The first two are done and the rest have not been reached, which is
      // where the pass is for most of its length.
      return entries.indexOf(entry) < 2
          ? PreviewTileWait.queued
          : PreviewTileWait.compiling;
    },
  );
}

class _Sheet extends StatelessWidget {
  const _Sheet({
    required this.sections,
    this.selectedId,
    this.waitOf,
    this.animate = false,
  });

  final List<PreviewSheetSection> sections;
  final String? selectedId;
  final PreviewTileWait? Function(CatalogEntry entry)? waitOf;
  final bool animate;

  @override
  Widget build(BuildContext context) => PreviewSheet(
    sections: sections,
    selectedId: selectedId,
    screenOf: _screenOf,
    waitOf: waitOf,
    animate: animate,
    onTap: (_) {},
  );
}

List<PreviewSheetSection> _sections(List<CatalogEntry> entries) =>
    previewSheetSections(buildCatalogTree(entries), screenOf: _screenOf);

/// Which entries are phones, so the grid holds both shapes.
///
/// Stood in for rather than resolved: a package's canvases are a declaration in
/// `tool/flutterware.dart`, and what the sheet needs from them is one size per
/// entry. Everything under `mobile/` is a phone here; the rest is the plain
/// rectangle, which is the shape this repo's own demos actually have.
const _phone = Size(393, 852);

Size? _screenOf(CatalogEntry entry) =>
    entry.path.contains('/mobile/') ? _phone : null;

/// A stand-in for this repo's own catalog: the group names and counts the panel
/// reports for `app`, which is what makes this a picture of a real sheet rather
/// than of a round number.
const _groups = <String, int>{
  'Address bar': 2,
  'Asset inspector': 3,
  'Avatar tile': 3,
  'Changes': 2,
  'Chrome': 1,
  'Command palette': 10,
  'Comparison': 3,
  'Controls': 5,
  'Design system': 6,
  'Dev stack': 6,
  'JSON view': 8,
  'Launcher icon': 4,
  'Motion': 6,
  'Panels': 8,
  'Previews panel': 6,
  'Previews stage': 5,
  'Run cockpit': 2,
  'Scenarios': 4,
  'Semantics tab': 7,
  'Shell': 5,
  'Sidebar row': 2,
  'Splash': 3,
  'States': 7,
  'Syntax': 6,
  'Table': 7,
  'Worktree explorer': 4,
  'Worktree home': 4,
  'preview_popover': 6,
};

/// The names a real catalog's entries carry: short, and repeated across groups.
/// "Default" appearing eleven times is exactly why the sheet has headings.
const _names = [
  'Default',
  'Empty',
  'Loading',
  'One row',
  'Overflowing',
  'Dark',
  'Selected',
  'Disabled',
  'Failed',
  'Narrow',
];

List<CatalogEntry> get _wholeCatalog => [
  for (var group in _groups.entries)
    for (var i = 0; i < group.value; i++)
      _entry(
        // A file per group, which is how a group arises: discovery derives one
        // whenever a file holds more than one entry.
        path: 'demo/${group.key.toLowerCase().replaceAll(' ', '_')}.dart',
        symbol: 'e$i',
        name: _names[i % _names.length],
        group: group.key,
      ),
  _entry(path: 'demo/counter.dart', symbol: 'counter', name: 'Counter'),
  _entry(path: 'demo/dashboard.dart', symbol: 'dashboard', name: 'Dashboard'),
];

/// A catalog the size most projects have, and with both shapes in it.
List<CatalogEntry> get _smallCatalog => [
  _entry(
    path: 'demo/mobile/home.dart',
    symbol: 'home',
    name: 'Default',
    group: 'Home page',
  ),
  _entry(
    path: 'demo/mobile/home.dart',
    symbol: 'homePhone',
    name: 'On a phone',
    group: 'Home page',
  ),
  _entry(
    path: 'demo/input.dart',
    symbol: 'keyboards',
    name: 'Keyboards',
    group: 'Input',
  ),
  _entry(
    path: 'demo/input.dart',
    symbol: 'scrolling',
    name: 'Scrolling',
    group: 'Input',
  ),
  _entry(
    path: 'demo/input.dart',
    symbol: 'textFields',
    name: 'Text fields',
    group: 'Input',
  ),
  _entry(
    path: 'demo/asset_smoke.dart',
    symbol: 'assetSmoke',
    name: 'Asset smoke',
  ),
  _entry(path: 'demo/buttons.dart', symbol: 'buttons', name: 'Buttons'),
  _entry(path: 'demo/vector.dart', symbol: 'vectorSmoke', name: 'Vector smoke'),
];

List<CatalogEntry> get _longNames => [
  for (var (i, name) in const [
    'Empty',
    'A settings page with every row expanded',
    'Signing in over an expired session',
    'The receipt, after a partial refund',
    'Two-line title with a trailing action',
    'Étiquette très longue qui ne rentre pas',
  ].indexed)
    _entry(
      path: 'demo/long.dart',
      symbol: 'long$i',
      name: name,
      group: 'Names that do not fit',
    ),
];

CatalogEntry _entry({
  required String path,
  required String symbol,
  required String name,
  String? group,
}) => CatalogEntry(
  path: path,
  symbol: symbol,
  annotation: "Preview(name: '$name')",
  name: name,
  group: group,
);
