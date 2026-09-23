import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/reel.dart';
import 'package:flutterware/src/scenarios/film.dart';
import 'package:flutterware/src/scenarios/fonts.dart';
import 'package:flutterware/src/scenarios/run_args.dart';

/// Renders a small scenario as a **scene reel** — a dry pass for the take,
/// the stock scene edit, then the filming pass — and leaves the mp4 and a
/// still per second where they can be looked at. Not part of the suite (no
/// `_test` suffix); run it on purpose:
///
/// ```sh
/// fvm flutter test test/scenarios/manual_scene_reel_dump.dart
/// ```
///
/// Output: `build/reel-dump/` — `reel.mp4` and `stills/*.png`. It needs
/// `ffmpeg` on the path. The two-pass shape here — one `scenario` for the
/// take, one for the film, the second reading what the first wrote — is the
/// orchestration in miniature, before anything drives it.
void main() {
  var out = Directory('build/reel-dump').absolute;
  var dry = Directory('${out.path}/take');
  var wet = Directory('${out.path}/frames');

  setUpAll(() async {
    if (out.existsSync()) out.deleteSync(recursive: true);
    out.createSync(recursive: true);
    // A bare `flutter test` loads no font and draws every glyph as a box;
    // the harness lane loads real ones. This is the repair for a lane that
    // has none, so the captions can be read in the stills.
    await loadDefaultScenarioFonts();
  });

  group('take', () {
    setUp(() {
      scenarioRunArgs = ScenarioRunArgs(
        film: FilmSettings(directory: dry.path, scale: 1, pixels: false),
      );
    });
    tearDown(() {
      scenarioRunArgs = null;
      resetFilms();
    });
    scenario('Order a coffee', _body);
  });

  group('film', () {
    setUp(() {
      var take = Take.read(dry.path);
      scenarioRunArgs = ScenarioRunArgs(
        film: FilmSettings(directory: wet.path, scale: 2),
        reel: const StockSceneReel().edit(take),
      );
    });
    tearDown(() async {
      scenarioRunArgs = null;
      resetFilms();
      var head = File('${wet.path}/film.head.json').readAsStringSync();
      var w = RegExp(r'"width": (\d+)').firstMatch(head)!.group(1);
      var h = RegExp(r'"height": (\d+)').firstMatch(head)!.group(1);
      var size = '${w}x$h';
      var frames =
          wet
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.raw'))
              .map((f) => f.path)
              .toList()
            ..sort();
      var stills = Directory('${out.path}/stills')..createSync();
      for (var i = 0; i < frames.length; i += 30) {
        await Process.run('ffmpeg', [
          '-y',
          '-loglevel',
          'error',
          '-f',
          'rawvideo',
          '-pix_fmt',
          'rgba',
          '-video_size',
          size,
          '-i',
          frames[i],
          '${stills.path}/${(i ~/ 30).toString().padLeft(2, '0')}s.png',
        ]);
      }
      var encode = await Process.run('sh', [
        '-c',
        [
          'cat "${wet.path}"/*.raw | ffmpeg -y -loglevel error',
          '-f rawvideo -pix_fmt rgba -video_size $size -framerate 30 -i -',
          '-pix_fmt yuv420p -movflags +faststart "${out.path}/reel.mp4"',
        ].join(' '),
      ]);
      print('frames: ${frames.length} at $size');
      print(
        'clip:   ${out.path}/reel.mp4  (${encode.exitCode == 0 ? 'ok' : encode.stderr})',
      );
      print('stills: ${stills.path}');
    });
    scenario('Order a coffee', _body);
  });
}

Future<void> _body(ScenarioTester s) async {
  await s.pumpWidget(const _ReelApp());
  s.title('Order a coffee');
  await s.tap('Order');
  await s.screen('ordered');
}

class _ReelApp extends StatelessWidget {
  const _ReelApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: const Color(0xFF8B5A2B)),
    home: const _Menu(),
  );
}

class _Menu extends StatelessWidget {
  const _Menu();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('☕', style: TextStyle(fontSize: 64)),
          const SizedBox(height: 16),
          const Text(
            'Brewline',
            style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text('Your coffee, ready before you are.'),
          const SizedBox(height: 40),
          // Something that never stops moving: the proof a hold is not a
          // freeze is this still spinning through it.
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 40),
          FilledButton(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => const _Done())),
            child: const Text('Order'),
          ),
        ],
      ),
    ),
  );
}

class _Done extends StatelessWidget {
  const _Done();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Text(
        'Thanks! Ready in 4 minutes.',
        style: TextStyle(fontSize: 22),
      ),
    ),
  );
}
