import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/assets/detail.dart';
import 'package:flutterware_app/src/assets/folder.dart';
import 'package:flutterware_app/src/assets/list.dart';
import 'package:flutterware_app/src/assets/model/asset_tree.dart';
import 'package:flutterware_app/src/assets/popover.dart';
import 'package:flutterware_app/src/assets/model/asset_catalog.dart';
import 'package:flutterware_app/src/assets/model/asset_scan.dart';
import 'package:flutterware_app/src/assets/preview.dart';

import 'shell.dart';

/// The asset inspector's views, with no filesystem behind them.
///
/// Everything here is synthesised — `AssetFile` takes a `length` so an asset
/// that never existed can still be drawn, and every preview is handed bytes
/// rather than a path. That is the whole reason the views take data instead of
/// reading files themselves.
///
/// One variant is missing and cannot be here: a font that renders. A real
/// specimen needs real font bytes, and the app bundles none — so the font entry
/// below exercises the *failure* path, and the working one is verified by
/// running the app against `fixtures/probe_app`, which ships two weights of
/// Roboto for exactly this.

@Preview(name: 'List', group: 'Asset inspector', wrapper: wrapInApp)
Widget assetInspectorList() => const _Lists();

@Preview(name: 'Previews', group: 'Asset inspector', wrapper: wrapInApp)
Widget assetInspectorPreviews() => const _Previews();

@Preview(name: 'Detail', group: 'Asset inspector', wrapper: wrapInApp)
Widget assetInspectorDetail() => const _Detail();

@Preview(name: 'Folder', group: 'Asset inspector', wrapper: wrapInApp)
Widget assetInspectorFolder() => const _Folder();

@Preview(name: 'Peek', group: 'Asset inspector', wrapper: wrapInApp)
Widget assetInspectorPeek() => const _Peek();

/// Every state of the list at once, which is the point of stacking them: an
/// empty state that collapses or a key that overflows shows up here without
/// anyone selecting a variant to find it.
///
/// Scrolls sideways, because four fixed-width cases are wider than some of
/// the windows this is rendered in. Each case keeps a realistic width instead of
/// being squeezed — the list's own ellipsis behaviour is one of the things being
/// looked at, and it is a function of that width, so flexing the cases to fit
/// would quietly change what the demo demonstrates. Below 1184px you scroll; at
/// or above it, nothing looks different from before.
class _Lists extends StatefulWidget {
  const _Lists();

  @override
  State<_Lists> createState() => _ListsState();
}

class _ListsState extends State<_Lists> {
  String? _selected = 'assets/images/logo.png';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Case(
              'Filtered — matched characters lit',
              AssetListView(
                peek: false,
                initialQuery: 'log',
                own: _own,
                fromPackages: [
                  AssetOwner(package: 'flutterware', assets: _dependencyAssets),
                ],
                problems: const [],
                selected: _selected,
                onSelect: (key) => setState(() => _selected = key),
              ),
            ),
            _Case(
              'With problems',
              AssetListView(
                peek: false,
                own: _own.take(2).toList(),
                fromPackages: const [],
                problems: _problems,
                selected: null,
                onSelect: (_) {},
              ),
            ),
            _Case(
              'A bundle with a shape',
              AssetListView(
                peek: false,
                own: _deep,
                fromPackages: [
                  AssetOwner(package: 'flutterware', assets: _dependencyAssets),
                ],
                problems: const [],
                selected: _selected,
                onSelect: (key) => setState(() => _selected = key),
              ),
            ),
            _Case(
              'Nothing declared',
              AssetListView(
                peek: false,
                own: const [],
                fromPackages: const [],
                problems: const [],
                selected: null,
                onSelect: (_) {},
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The card a row shows when the pointer rests on it, drawn where it would be
/// rather than summoned by a hover — a catalog entry cannot hold a pointer
/// still, and this is the face worth looking at.
class _Peek extends StatelessWidget {
  const _Peek();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          for (var (index, asset) in [
            _logo,
            _asset('assets/icons/check.svg', length: 273),
            _asset('assets/config.json', length: 36),
          ].indexed)
            AssetPopover(
              asset: asset,
              anchor: Rect.fromLTWH(0, 90 + index * 330, 180, 28),
              bytes: switch (assetKindOf(asset.key)) {
                AssetKind.image => _png,
                AssetKind.vector => _svg,
                AssetKind.data => _json,
                _ => null,
              },
            ),
        ],
      ),
    );
  }
}

/// The contact sheet for a directory, with the pictures coming from bytes
/// rather than from disk — which is the seam that keeps this widget in the
/// catalog at all. In the app each tile reads its own file.
class _Folder extends StatelessWidget {
  const _Folder();

  @override
  Widget build(BuildContext context) {
    var tree = AssetTree.of(_deep);
    return Scaffold(
      body: AssetFolderView(
        node: tree.nodeAt('assets/images')!,
        path: 'assets/images',
        onSelect: (_) {},
        bytesFor: (asset) =>
            assetKindOf(asset.key) == AssetKind.image ? _png : null,
      ),
    );
  }
}

class _Case extends StatelessWidget {
  const _Case(this.label, this.child);

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 296,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Text(label, style: const TextStyle(fontSize: 11)),
          ),
          Expanded(child: child),
          const VerticalDivider(width: 1),
        ],
      ),
    );
  }
}

class _Previews extends StatelessWidget {
  const _Previews();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (var (label, background) in const [
              ('Checker', PreviewBackground.checker),
              ('Light', PreviewBackground.light),
              ('Dark', PreviewBackground.dark),
            ])
              _Tile(
                label: 'PNG · $label',
                child: AssetPreview(
                  bytes: _png,
                  kind: AssetKind.image,
                  name: 'assets/images/logo.png',
                  background: background,
                ),
              ),
            _Tile(
              label: 'PNG · 4× (nearest)',
              child: AssetPreview(
                bytes: _png,
                kind: AssetKind.image,
                name: 'assets/images/logo.png',
                zoom: 4,
              ),
            ),
            _Tile(
              label: 'SVG',
              child: AssetPreview(
                bytes: _svg,
                kind: AssetKind.vector,
                name: 'assets/icons/check.svg',
              ),
            ),
            _Tile(
              label: 'Lottie',
              child: AssetPreview(
                bytes: _lottie,
                kind: AssetKind.data,
                name: 'assets/animations/pulse.json',
              ),
            ),
            _Tile(
              label: 'JSON that is not an animation',
              child: AssetPreview(
                bytes: _json,
                kind: AssetKind.data,
                name: 'assets/config.json',
              ),
            ),
            _Tile(
              label: 'Font, unusable bytes',
              child: AssetPreview(
                bytes: _png,
                kind: AssetKind.font,
                name: 'assets/fonts/Broken.ttf',
              ),
            ),
            _Tile(
              label: 'Image that will not decode',
              child: AssetPreview(
                bytes: _json,
                kind: AssetKind.image,
                name: 'assets/images/truncated.png',
              ),
            ),
            _Tile(
              label: 'No preview for this kind',
              child: AssetPreview(
                bytes: _json,
                kind: AssetKind.media,
                name: 'assets/audio/chime.mp3',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      height: 200,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: const TextStyle(fontSize: 11)),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0x22000000)),
              ),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class _Detail extends StatefulWidget {
  const _Detail();

  @override
  State<_Detail> createState() => _DetailState();
}

class _DetailState extends State<_Detail> {
  var _background = PreviewBackground.checker;
  var _zoom = 1.0;
  late AssetFile _file = _logo.main;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AssetDetailView(
        asset: _logo,
        file: _file,
        bytes: _png,
        error: null,
        dimensions: const Size(48, 48),
        background: _background,
        onBackground: (value) => setState(() => _background = value),
        zoom: _zoom,
        onZoom: (value) => setState(() => _zoom = value),
        onDensity: (value) => setState(() => _file = value),
      ),
    );
  }
}

// --- Synthesised data ------------------------------------------------------

AssetFile _file(String key, {double? scale, int length = 400}) =>
    AssetFile(path: '/project/$key', key: key, scale: scale, length: length);

ResolvedAsset _asset(
  String key, {
  String? package,
  String? declaration,
  List<AssetFile>? files,
  int length = 400,
}) => ResolvedAsset(
  key: key,
  package: package,
  packageRoot: '/project',
  declaration: declaration ?? key,
  files: files ?? [_file(key, length: length)],
);

final _logo = _asset(
  'assets/images/logo.png',
  declaration: 'assets/images/',
  files: [
    _file('assets/images/logo.png', length: 663),
    _file('assets/images/2.0x/logo.png', scale: 2, length: 1840),
    _file('assets/images/3.0x/logo.png', scale: 3, length: 3120),
  ],
);

final _own = [
  _logo,
  _asset('assets/animations/pulse.json', declaration: 'assets/animations/'),
  _asset('assets/fonts/Roboto-Regular.ttf', length: 171272),
  _asset('assets/icons/check.svg', length: 273),
  // Long enough to need the ellipsis, and the tail is the part worth keeping.
  _asset(
    'assets/images/illustrations/onboarding/step-three-with-a-long-name.png',
    declaration: 'assets/images/illustrations/onboarding/',
    files: [
      _file(
        'assets/images/illustrations/onboarding/step-three-with-a-long-name.png',
        length: 1048576,
      ),
    ],
  ),
];

/// A bundle deep enough to fold: a chain nobody branches in the middle of, a
/// directory heavy enough that its total is the point, and a loose key at the
/// top that has to sit beside the directories rather than inside one.
final _deep = [
  _logo,
  _asset('assets/images/hero.png', length: 421888),
  _asset('assets/images/wordmark.png', length: 22528),
  _asset('assets/images/icons/star.png', length: 18432),
  _asset(
    'assets/images/illustrations/onboarding/step-one.png',
    declaration: 'assets/images/illustrations/onboarding/',
    length: 311296,
  ),
  _asset(
    'assets/images/illustrations/onboarding/step-two.png',
    declaration: 'assets/images/illustrations/onboarding/',
    length: 297984,
  ),
  _asset('assets/icons/check.svg', length: 273),
  _asset('assets/icons/heart.svg', length: 412),
  _asset('assets/i18n/en.json', length: 3072),
  _asset('assets/i18n/fr.json', length: 3180),
  _asset('assets/fonts/Roboto-Regular.ttf', length: 171272),
  _asset('assets/config.json', length: 1024),
];

final _dependencyAssets = [
  _asset(
    'packages/flutterware/assets/figma_logo.png',
    package: 'flutterware',
    length: 3815,
  ),
];

final _problems = [
  AssetProblem(
    kind: AssetProblemKind.unreachablePackageFile,
    package: null,
    packageRoot: '/project',
    declaration: 'packages/brand/assets/missing.png',
  ),
  AssetProblem(
    kind: AssetProblemKind.missingFontFile,
    package: null,
    packageRoot: '/project',
    declaration: 'assets/fonts/Roboto-Italic.ttf',
  ),
];

/// The 48×48 fixture from `fixtures/probe_app`, inline so the demo needs no file.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAIAAADYYG7QAAAARklEQVR42u3YMQ0AIAwAwepgI/hE'
  'Ro1ioB5YoMklL+Dmj7H2VwVQa9DM8yQgICAgICAgICAgICAgICAgICAgICAgJx/osgK8LWl1SxSv'
  '2QAAAABJRU5ErkJggg==',
);

final _svg = _utf8('''
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">
  <circle cx="12" cy="12" r="11" fill="#4CAF50"/>
  <path d="M6 12.5 L10.5 17 L18 8" stroke="#FFFFFF" stroke-width="2.5"
        stroke-linecap="round" stroke-linejoin="round" fill="none"/>
</svg>
''');

final _lottie = _utf8('''
{"v":"5.7.4","fr":30,"ip":0,"op":60,"w":200,"h":200,"nm":"Pulse","ddd":0,
 "assets":[],"layers":[{"ddd":0,"ind":1,"ty":4,"nm":"Dot","sr":1,"ao":0,
 "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[100,100,0]},
 "a":{"a":0,"k":[0,0,0]},"s":{"a":1,"k":[
   {"t":0,"s":[40,40,100],"i":{"x":[0.5],"y":[1]},"o":{"x":[0.5],"y":[0]}},
   {"t":30,"s":[100,100,100],"i":{"x":[0.5],"y":[1]},"o":{"x":[0.5],"y":[0]}},
   {"t":60,"s":[40,40,100]}]}},
 "shapes":[{"ty":"gr","nm":"g","it":[
   {"ty":"el","nm":"e","p":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]}},
   {"ty":"fl","nm":"f","c":{"a":0,"k":[0.129,0.588,0.953,1]},
    "o":{"a":0,"k":100},"r":1},
   {"ty":"tr","p":{"a":0,"k":[0,0]},"a":{"a":0,"k":[0,0]},
    "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}],
 "ip":0,"op":60,"st":0,"bm":0}]}
''');

final _json = _utf8('{"flavour": "staging", "retries": 3}');

Uint8List _utf8(String source) => Uint8List.fromList(utf8.encode(source));

void main() => runApp(wrapInApp(assetInspectorPreviews()));
