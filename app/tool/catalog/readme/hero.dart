import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/previews.dart';

/// The README's composed pictures, drawn from what `tool/screenshots.dart`
/// photographed first.
///
/// Nothing here is a capture. The window, the cards and the guides' pictures
/// are named steps of the studio's own scenarios, written to
/// `build/screenshots/raw/`; the store images are the demo app's own export,
/// and the screens in the agent's session are the recording's own comparison
/// of its feature branch.
/// These entries lay them out and scale them to the size a README wants —
/// so the hero can never show a screen the scenarios did not reach.
///
/// Every file is found by walking up from wherever the guest runs, which is
/// anywhere inside this repository.
@Preview(name: 'README hero', group: 'README')
Widget readmeHero() => const _Hero();

/// One picture from `build/screenshots/raw/`, scaled to the canvas, with a
/// hairline: a light window on a white page has no edge of its own. The
/// `file` knob names it.
@Preview(name: 'README shot', group: 'README')
Widget readmeShot() => Builder(
  builder: (context) => _Shot(context.knobs.string('file', 'card-store')),
);

/// Four finished App Store images, as the store will show them, for the store
/// guide. The demo's export, read where `fw run store export` wrote it.
@Preview(name: 'Store strip', group: 'README')
Widget readmeStoreStrip() => const _StoreStrip();

class _Shot extends StatelessWidget {
  const _Shot(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    var file = _raw(name);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: file == null
          ? Center(child: Text('build/screenshots/raw/$name.png not found'))
          : Stack(
              fit: StackFit.expand,
              children: [
                Image.file(
                  file,
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.high,
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.fromBorderSide(
                      BorderSide(color: Color(0xFFD0D7DE), width: 2),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _StoreStrip extends StatelessWidget {
  const _StoreStrip();

  @override
  Widget build(BuildContext context) {
    var files = _storeImages('ios/en-US', prefix: 'iphone-').take(4).toList();
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Colors.white,
        child: files.isEmpty
            ? const Center(child: Text('No store export in examples/brewline'))
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
}

/// The studio's window, on the flow of the demo's flagship scenario, with the
/// two other ways in held in front of it: a coding agent's session, and the
/// commands a terminal takes.
class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    var window = _raw('hero-window');
    var work = _agentWork();
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
          child: window == null || work == null
              ? const Center(
                  child: Text(
                    'Run tool/screenshots.dart: the window shot or the '
                    'recorded comparison is missing',
                  ),
                )
              : LayoutBuilder(
                  builder: (context, box) => _layout(box.biggest, window, work),
                ),
        ),
      ),
    );
  }

  Widget _layout(Size size, File window, _AgentWork work) {
    // Laid out on a 1600×900 board and scaled to whatever the canvas is, so
    // the composition holds at any render size.
    var k = size.width / 1600;
    Widget at(double left, double top, Widget child) =>
        Positioned(left: left * k, top: top * k, child: child);
    return ClipRect(
      child: Stack(
        children: [
          // Bleeding off the right edge: the window is bigger than the board,
          // which is what makes the pieces in front of it read as in front.
          at(
            520,
            56,
            _Framed(
              radius: 14 * k,
              k: k,
              child: Image.file(
                window,
                width: 1280 * k,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
          at(36, 84, _AgentSession(k: k, work: work)),
          at(900, 640, _Terminal(k: k)),
        ],
      ),
    );
  }
}

/// A coding agent's session: asked for a feature, it reports back with the
/// screens it changed. The feature is the one the recording's branch adds —
/// the tab of the window beside it carries its name — and the two screens are
/// that branch's own comparison, so the pictures are the app's and only the
/// words are written here.
class _AgentSession extends StatelessWidget {
  const _AgentSession({required this.k, required this.work});

  final double k;
  final _AgentWork work;

  static const _ink = Color(0xFF15181D);
  static const _mut = Color(0xFF6B7280);
  static const _line = Color(0xFFE8EAEE);
  static const _green = Color(0xFF2F9E63);
  static const _amber = Color(0xFF9A6700);

  @override
  Widget build(BuildContext context) {
    var body = TextStyle(fontSize: 17 * k, height: 1.45, color: _ink);
    var mono = TextStyle(
      fontFamily: 'Menlo',
      fontSize: 13.5 * k,
      height: 1.3,
      color: _ink,
    );
    Widget call(String action, String result) => Container(
      padding: EdgeInsets.symmetric(horizontal: 12 * k, vertical: 8 * k),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(8 * k),
      ),
      child: Row(
        spacing: 10 * k,
        children: [
          Text('flutterware', style: mono.copyWith(color: _mut)),
          Expanded(child: Text(action, style: mono)),
          Text('✓ $result', style: mono.copyWith(color: _green)),
        ],
      ),
    );
    return _Framed(
      radius: 14 * k,
      k: k,
      child: Container(
        width: 470 * k,
        color: Colors.white,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: 16 * k,
                vertical: 11 * k,
              ),
              color: const Color(0xFFF3F4F6),
              child: Text(
                'Coding agent',
                style: body.copyWith(
                  fontSize: 14 * k,
                  fontWeight: FontWeight.w600,
                  color: _mut,
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20 * k, 18 * k, 20 * k, 20 * k),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16 * k,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      constraints: BoxConstraints(maxWidth: 360 * k),
                      padding: EdgeInsets.symmetric(
                        horizontal: 16 * k,
                        vertical: 11 * k,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE7F0FB),
                        borderRadius: BorderRadius.circular(16 * k),
                      ),
                      child: Text(
                        'Add a stamp card: a stamp for every drink, and a '
                        'free one when it is full.',
                        style: body,
                      ),
                    ),
                  ),
                  Column(
                    spacing: 6 * k,
                    children: [
                      call('scenarios run', '${work.scenarios} scenarios'),
                      call(
                        'previews compare',
                        '${work.changed} changed · ${work.added} new',
                      ),
                    ],
                  ),
                  Text(
                    'Done. The menu opens a stamp card now, and a new '
                    'scenario covers it. Here is what changed on screen:',
                    style: body,
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 14 * k,
                    children: [
                      for (var screen in work.screens)
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: 8 * k,
                            children: [
                              DecoratedBox(
                                position: DecorationPosition.foreground,
                                decoration: BoxDecoration(
                                  border: Border.all(color: _line, width: k),
                                  borderRadius: BorderRadius.circular(10 * k),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10 * k),
                                  // The top of the screen, where both the
                                  // new icon and the new card are.
                                  child: Align(
                                    alignment: Alignment.topCenter,
                                    heightFactor: 0.6,
                                    child: Image.file(
                                      screen.picture,
                                      filterQuality: FilterQuality.high,
                                    ),
                                  ),
                                ),
                              ),
                              Row(
                                spacing: 8 * k,
                                children: [
                                  Text(
                                    screen.label,
                                    style: body.copyWith(
                                      fontSize: 14 * k,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    screen.added ? 'new' : 'changed',
                                    style: body.copyWith(
                                      fontSize: 13 * k,
                                      color: screen.added ? _green : _amber,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A piece of the composition: its shadow and its corners.
class _Framed extends StatelessWidget {
  const _Framed({required this.radius, required this.k, required this.child});

  final double radius;
  final double k;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      boxShadow: [
        BoxShadow(
          color: const Color(0x73000000),
          blurRadius: 48 * k,
          offset: Offset(0, 18 * k),
        ),
      ],
    ),
    child: ClipRRect(borderRadius: BorderRadius.circular(radius), child: child),
  );
}

/// The same work, from a terminal — which is also what an agent drives.
class _Terminal extends StatelessWidget {
  const _Terminal({required this.k});

  final double k;

  @override
  Widget build(BuildContext context) {
    var mono = TextStyle(
      fontFamily: 'Menlo',
      fontSize: 15 * k,
      height: 1.7,
      color: const Color(0xFFE5E7EB),
    );
    var dim = mono.copyWith(color: const Color(0xFF6B7280));
    var ok = mono.copyWith(color: const Color(0xFF4ADE80));
    Widget line(String command, String result) => Row(
      children: [
        Text(r'$ ', style: dim),
        Expanded(child: Text(command, style: mono)),
        Text('✓ $result', style: ok),
      ],
    );
    return _Framed(
      radius: 12 * k,
      k: k,
      child: Container(
        width: 600 * k,
        color: const Color(0xFF111827),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: 14 * k,
                vertical: 10 * k,
              ),
              color: const Color(0xFF1F2937),
              child: Row(
                spacing: 7 * k,
                children: [
                  for (var dot in const [
                    Color(0xFFFF5F57),
                    Color(0xFFFEBC2E),
                    Color(0xFF28C840),
                  ])
                    Container(
                      width: 11 * k,
                      height: 11 * k,
                      decoration: BoxDecoration(
                        color: dot,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20 * k, 14 * k, 20 * k, 16 * k),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  line('fw run scenarios run', 'every step captured'),
                  line('fw run store export', '20 images'),
                  line('fw run previews screenshot …', 'shopMenu.png'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

typedef _AgentWork = ({
  int scenarios,
  int changed,
  int added,
  List<({String label, bool added, File picture})> screens,
});

/// What the recording's feature branch did to the app, as its own comparison
/// measured it — the numbers the Changes panel shows, and two of its
/// pictures: the menu, which gained the way in, and the preview the branch
/// added. Null when the recording has no such comparison.
_AgentWork? _agentWork() {
  var comparison = _up('app/demo/fixture/comparison');
  if (comparison == null) return null;
  var index = File('${comparison.path}/index.json');
  if (!index.existsSync()) return null;
  if (jsonDecode(index.readAsStringSync()) case {
    'counts': {'changed': int changed, 'added': int added},
    'scenarios': {'ran': int scenarios},
    'previews': {'items': List<Object?> items},
  }) {
    var screens = [
      for (var item in items)
        if (item
            case {
              'id': String id,
              'state': String state,
              'label': String label,
              'shots': {'head': String head},
            }
            when state == 'added' || id.endsWith('#shopMenu'))
          (
            label: label,
            added: state == 'added',
            picture: File('${comparison.path}/$head'),
          ),
    ]..sort((a, b) => (a.added ? 1 : 0) - (b.added ? 1 : 0));
    if (screens.length < 2 || screens.any((s) => !s.picture.existsSync())) {
      return null;
    }
    return (
      scenarios: scenarios,
      changed: changed,
      added: added,
      screens: screens,
    );
  }
  return null;
}

/// A named shot from `build/screenshots/raw/`, or null when the scenarios
/// behind it have not been photographed yet.
File? _raw(String name) {
  var dir = _up('build/screenshots/raw');
  if (dir == null) return null;
  var file = File('${dir.path}/$name.png');
  return file.existsSync() ? file : null;
}

/// The demo's store export for one store and locale, in listing order.
Iterable<File> _storeImages(String set, {required String prefix}) {
  var dir = _up('examples/brewline/build/flutterware/store/brewline/$set');
  if (dir == null) return const [];
  return dir
      .listSync()
      .whereType<File>()
      .where((f) => f.uri.pathSegments.last.startsWith(prefix))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

Directory? _up(String path) {
  var dir = Directory.current.absolute;
  while (true) {
    var candidate = Directory('${dir.path}/$path');
    if (candidate.existsSync()) return candidate;
    var parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}
