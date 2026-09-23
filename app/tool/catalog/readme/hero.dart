import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';

/// The picture at the top of the README, drawn from the screenshots beside it.
///
/// A composition rather than a capture: one window of the studio says one
/// thing, and the top of a README has to say several at once. The pieces are
/// the other README shots, cropped, so the hero can never show a tool the
/// shots below it do not — `tool/screenshots.dart` takes those first and
/// renders this last, at 1280×720.
///
/// Read from `doc/screenshots/` by walking up from wherever the guest runs,
/// which is anywhere inside this repository.
@Preview(name: 'README hero', group: 'README')
Widget readmeHero() => const _Hero();

/// The four pictures in the README's grid: one region of one window shot each.
///
/// Cropped because the grid shows them at half the column's width, and a whole
/// window at that size is a rail and a tab bar around a panel too small to
/// read. All four are 4:3, so a row of two lines up.
@Preview(name: 'Previews card', group: 'README')
Widget readmePreviewsCard() => const _Card(_previewsPanel);

@Preview(name: 'Scenarios card', group: 'README')
Widget readmeScenariosCard() => const _Card(_flowCanvas);

@Preview(name: 'Store card', group: 'README')
Widget readmeStoreCard() => const _Card(_storeRows);

@Preview(name: 'Translations card', group: 'README')
Widget readmeTranslationsCard() => const _Card(_translationsTable);

const _previewsPanel = _Cut(
  'ui_catalog_device.png',
  Rect.fromLTWH(462, 70, 1638, 1228),
);
const _flowCanvas = _Cut('scenarios.png', Rect.fromLTWH(948, 90, 2052, 1539));
const _storeRows = _Cut(
  'store_listing.png',
  Rect.fromLTWH(490, 98, 1750, 1312),
);
const _translationsTable = _Cut(
  'translations.png',
  Rect.fromLTWH(469, 84, 2051, 1538),
);

class _Card extends StatelessWidget {
  const _Card(this.cut);
  final _Cut cut;

  @override
  Widget build(BuildContext context) {
    var dir = _screenshots();
    if (dir == null) {
      return const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: Text('doc/screenshots not found')),
      );
    }
    return Directionality(
      textDirection: TextDirection.ltr,
      child: LayoutBuilder(
        builder: (context, box) => Stack(
          children: [
            _Crop(dir, cut, width: box.maxWidth),
            // A hairline, because the crops start mid-window and a light panel
            // on a white page has no edge of its own.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFD0D7DE), width: 2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Four finished App Store images, as the store will show them.
///
/// Not a crop of a window: these are the demo's own export, read from the
/// clone `tool/screenshots.dart` photographs, so the store page shows what the
/// export wrote rather than the panel's thumbnails of it. The first four in
/// listing order, because the scene behind them runs continuously across the
/// set and four is enough to see it.
@Preview(name: 'Store strip', group: 'README')
Widget readmeStoreStrip() => const _StoreStrip();

class _StoreStrip extends StatelessWidget {
  const _StoreStrip();

  static const _export =
      'build/flutterware_example/build/flutterware/store/brewline/ios/en-US';

  @override
  Widget build(BuildContext context) {
    var files = _exported();
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Colors.white,
        child: files.isEmpty
            ? const Center(child: Text('No store export in the demo clone'))
            : LayoutBuilder(
                builder: (context, box) {
                  var k = box.maxWidth / 1600;
                  return Padding(
                    padding: EdgeInsets.all(24 * k),
                    child: Row(
                      spacing: 20 * k,
                      children: [
                        for (var file in files)
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(18 * k),
                              child: Image.file(
                                file,
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.high,
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }

  List<File> _exported() {
    var dir = Directory.current.absolute;
    while (true) {
      var export = Directory('${dir.path}/$_export');
      if (export.existsSync()) {
        var files =
            export
                .listSync()
                .whereType<File>()
                .where((f) => f.path.split('/').last.startsWith('iphone-'))
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));
        return files.take(4).toList();
      }
      var parent = dir.parent;
      if (parent.path == dir.path) return const [];
      dir = parent;
    }
  }
}

/// The shots this reads, by file name, with the pixel rect cut out of each.
/// Coordinates are in the PNG's own pixels (2x), so a retaken shot whose
/// layout moved needs these moved with it.
const _phone = _Cut('ui_catalog.png', Rect.fromLTRB(1158, 186, 1828, 1585));
const _flow = _Cut('scenarios.png', Rect.fromLTWH(0, 0, 3000, 2000));
const _store = _Cut('store_listing.png', Rect.fromLTRB(540, 414, 1558, 760));

class _Cut {
  const _Cut(this.file, this.rect);
  final String file;
  final Rect rect;
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    var dir = _screenshots();
    return Directionality(
      textDirection: TextDirection.ltr,
      child: DefaultTextStyle(
        style: const TextStyle(
          fontSize: 14,
          color: Colors.white,
          decoration: TextDecoration.none,
        ),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF0B2A6B), Color(0xFF1668E3)],
            ),
          ),
          child: dir == null
              ? const Center(child: Text('doc/screenshots not found'))
              : LayoutBuilder(
                  builder: (context, box) => _layout(dir, box.biggest),
                ),
        ),
      ),
    );
  }

  Widget _layout(String dir, Size size) {
    // Laid out on a 1280×720 board and scaled to whatever the canvas is, so
    // the composition holds at any render size.
    var k = size.width / 1280;
    Widget at(double l, double t, Widget child) =>
        Positioned(left: l * k, top: t * k, child: child);
    return Stack(
      children: [
        at(
          360,
          56,
          _Framed(
            label: 'Scenarios',
            radius: 10 * k,
            k: k,
            child: _Crop(dir, _flow, width: 860 * k),
          ),
        ),
        at(
          84,
          96,
          _Framed(
            label: 'Previews',
            radius: 37 * k,
            k: k,
            child: _Crop(dir, _phone, width: 272 * k),
          ),
        ),
        at(
          640,
          506,
          _Framed(
            label: 'Store screenshots',
            radius: 8 * k,
            k: k,
            child: _Crop(dir, _store, width: 560 * k),
          ),
        ),
        at(232, 560, _Terminal(k: k)),
      ],
    );
  }
}

/// A piece of the composition: its shadow, its corners and its name.
class _Framed extends StatelessWidget {
  const _Framed({
    required this.label,
    required this.radius,
    required this.k,
    required this.child,
  });

  final String label;
  final double radius;
  final double k;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            boxShadow: [
              BoxShadow(
                color: const Color(0x66000000),
                blurRadius: 40 * k,
                offset: Offset(0, 16 * k),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: child,
          ),
        ),
        Positioned(
          left: 12 * k,
          top: -14 * k,
          child: _Pill(label, k: k),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {required this.k});
  final String text;
  final double k;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10 * k, vertical: 4 * k),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13 * k,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// The other two surfaces, as the commands that reach them.
class _Terminal extends StatelessWidget {
  const _Terminal({required this.k});
  final double k;

  @override
  Widget build(BuildContext context) {
    var mono = TextStyle(
      fontFamily: 'Menlo',
      fontSize: 12.5 * k,
      height: 1.6,
      color: const Color(0xFFE5E7EB),
    );
    var dim = mono.copyWith(color: const Color(0xFF6B7280));
    Widget line(String command) => Text.rich(
      TextSpan(
        children: [
          TextSpan(text: r'$ ', style: dim),
          TextSpan(text: command, style: mono),
        ],
      ),
    );
    return _Framed(
      label: 'Command line',
      radius: 10 * k,
      k: k,
      child: Container(
        width: 384 * k,
        padding: EdgeInsets.fromLTRB(16 * k, 18 * k, 16 * k, 14 * k),
        color: const Color(0xFF111827),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            line('fw run scenarios run'),
            line('fw run store export'),
            line(r'fw run previews screenshot \'),
            Text('    --entry=demo/shop.dart#shopMenu', style: mono),
          ],
        ),
      ),
    );
  }
}

/// [cut] of its file, scaled to [width].
class _Crop extends StatelessWidget {
  const _Crop(this.dir, this.cut, {required this.width});

  final String dir;
  final _Cut cut;
  final double width;

  @override
  Widget build(BuildContext context) {
    var file = File('$dir/${cut.file}');
    var src = cut.rect;
    var scale = width / src.width;
    var full = _pngSize(file);
    return SizedBox(
      width: width,
      height: src.height * scale,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 0,
          minHeight: 0,
          maxWidth: double.infinity,
          maxHeight: double.infinity,
          child: Transform.translate(
            offset: -src.topLeft * scale,
            child: Image.file(
              file,
              width: full.width * scale,
              height: full.height * scale,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.high,
            ),
          ),
        ),
      ),
    );
  }
}

/// A PNG's size from its header, so a crop can be laid out before the image
/// has decoded.
Size _pngSize(File file) {
  var bytes = file.readAsBytesSync().sublist(16, 24);
  int be(int i) =>
      bytes[i] << 24 | bytes[i + 1] << 16 | bytes[i + 2] << 8 | bytes[i + 3];
  return Size(be(0).toDouble(), be(4).toDouble());
}

String? _screenshots() {
  var dir = Directory.current.absolute;
  while (true) {
    var candidate = Directory('${dir.path}/doc/screenshots');
    if (File('${candidate.path}/scenarios.png').existsSync()) {
      return candidate.path;
    }
    var parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}
