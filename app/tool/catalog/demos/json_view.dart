import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/ui/json_view.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// The JSON view — **the largest widget in the app**, and until now the largest
/// with nothing to look at it.
///
/// It renders whatever a plugin action or a network response hands back, which
/// means it renders things nobody chose: a 40-deep tree, a string with a newline
/// in it, a number that is really an id, an empty object. Those are the entries
/// below, because they are the ones that break a renderer and the ones you
/// cannot arrange by clicking around a running app.

/// Everything it can draw, in one document: each scalar kind, an empty
/// container of each sort, and the awkward strings.
@Preview(name: 'Every kind', group: 'JSON view', wrapper: wrapInAppTheme)
Widget jsonKinds() => _Frame(
  data: {
    'string': 'a short one',
    'multiline': 'first line\nsecond line\nthird',
    'empty string': '',
    'int': 42,
    'big int': 9007199254740991,
    'double': 3.14159,
    'negative': -17,
    'true': true,
    'false': false,
    'null': null,
    'empty object': <String, Object?>{},
    'empty list': <Object?>[],
    'url': 'https://pub.dev/packages/flutterware',
    // The one that has bitten every JSON renderer: no spaces, so nothing to
    // wrap on, and long enough to force the decision.
    'token': 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk',
  },
);

/// A realistic payload — the shape an action actually returns.
@Preview(name: 'A real payload', group: 'JSON view', wrapper: wrapInAppTheme)
Widget jsonPayload() => _Frame(
  data: {
    'plugin': 'flutterware.run',
    'action': 'launch',
    'result': {
      'app': {
        'run': 'app-d1a860f99306-16417',
        'device': 'macos',
        'deviceName': 'macOS',
        'worktree': 'sad-moser-229552',
        'mine': true,
        'package': 'app',
        'entrypoint': 'lib/main_dev.dart',
        'defines': <String, Object?>{},
        'since': '2026-08-13T12:10:33.153370Z',
      },
      'status': 'running',
      'waited': true,
    },
  },
);

/// Deep enough to run out of horizontal room. Indentation is per level, so
/// past a certain depth a tree either scrolls sideways or squeezes its values
/// into nothing — this is the entry that says which.
@Preview(name: 'Deeply nested', group: 'JSON view', wrapper: wrapInAppTheme)
Widget jsonDeep() => _Frame(data: _nest(14), initialExpandDepth: 20);

/// A long flat list — the virtualisation case.
@Preview(name: 'Long list', group: 'JSON view', wrapper: wrapInAppTheme)
Widget jsonLong() => _Frame(
  data: {
    'packages': [
      for (var i = 0; i < 120; i++)
        {'name': 'package_$i', 'version': '1.$i.0', 'direct': i.isEven},
    ],
  },
);

/// Collapsed on arrival — what a viewer opening on a large document should do.
@Preview(name: 'Collapsed', group: 'JSON view', wrapper: wrapInAppTheme)
Widget jsonCollapsed() => _Frame(data: _nest(6), initialExpandDepth: 0);

/// No toolbar: the embedded form, where the surface around it already has a
/// search and a copy button of its own.
@Preview(name: 'Bare, no toolbar', group: 'JSON view', wrapper: wrapInAppTheme)
Widget jsonBare() => _Frame(
  data: {'ok': true, 'ms': 315, 'device': 'macos'},
  showToolbar: false,
);

@Preview(
  name: 'Narrow — the whole pane',
  group: 'JSON view',
  wrapper: wrapInAppTheme,
)
Widget jsonNarrow() => const NarrowPane(
  child: _Frame(
    data: {
      'nested': {
        'deeper': {'value': 'a string that has to fit'},
      },
    },
  ),
);

@Preview(
  name: 'Every kind · dark',
  group: 'JSON view',
  wrapper: wrapInDarkTheme,
)
Widget jsonKindsDark() => jsonKinds();

Map<String, Object?> _nest(int depth) => depth == 0
    ? {'leaf': 'bottom', 'depth': 0}
    : {'level $depth': _nest(depth - 1), 'sibling': 'at $depth'};

class _Frame extends StatelessWidget {
  const _Frame({
    required this.data,
    this.initialExpandDepth = 2,
    this.showToolbar = true,
  });

  final Object? data;
  final int initialExpandDepth;
  final bool showToolbar;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.panel,
    child: Padding(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      child: Align(
        alignment: Alignment.topLeft,
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: JsonView(
            data: data,
            initialExpandDepth: initialExpandDepth,
            showToolbar: showToolbar,
          ),
        ),
      ),
    ),
  );
}
