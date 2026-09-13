import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutterware/comparison_report.dart';
import 'package:flutterware_app/src/comparison/shot_cache.dart';
import 'package:flutterware_app/src/comparison/web_export.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Everything after the compile — which is where all the logic is — without a
/// toolchain and a minute of `flutter build web`. The same seam the scenario
/// exporter's test uses, for the same reason.
void main() {
  late Directory temp;
  late ShotCache cache;
  late ComparisonWebExporter exporter;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fw_comparison_export');
    cache = ShotCache(p.join(temp.path, 'shots'));
    exporter =
        ComparisonWebExporter(
            flutterExecutable: 'flutter-not-invoked',
            appToolRoot: temp.path,
          )
          ..debugCompile = (arguments) async {
            // What a real build leaves behind: an index.html with a base tag.
            var viewer = Directory(exporter.viewerDir)
              ..createSync(recursive: true);
            File(
              p.join(viewer.path, 'index.html'),
            ).writeAsStringSync('<base href="/">\n<title>Comparison</title>');
            File(p.join(viewer.path, 'main.dart.js'))
                .writeAsStringSync('// js');
            return 0;
          };
  });

  tearDown(() => temp.deleteSync(recursive: true));

  // The page is read once, from a link. The caching worker Flutter is retiring
  // held the page back until it had fetched the page's files and activated.
  test('the viewer is built with no service worker', () async {
    var arguments = <String>[];
    var compile = exporter.debugCompile!;
    exporter.debugCompile = (given) {
      arguments.addAll(given);
      return compile(given);
    };

    await exporter.export(
      index: {
        'previews': {'items': <Object?>[]},
      },
      cache: cache,
      against: 'origin/master',
      output: p.join(temp.path, 'out'),
    );

    expect(arguments, contains('--pwa-strategy=none'));
  });

  void file(String key, int value, {int width = 4, int height = 4}) {
    cache.write(
      key,
      Uint8List(width * height * 4)..fillRange(0, width * height * 4, value),
      ShotRecord(
        format: 'raw',
        width: width,
        height: height,
        entryId: 'demo/card.dart#card',
      ),
    );
  }

  String writeFrame(String name, int value, {int width = 4, int height = 4}) {
    var path = p.join(temp.path, 'run', name);
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(
        Uint8List(width * height * 4)..fillRange(0, width * height * 4, value),
      );
    return path;
  }

  Map<String, Object?> index({String? framePath}) => {
    'base': 'abc123def456',
    'head': '/work/tree',
    'previews': {
      'items': [
        {
          'id': 'demo/card.dart#card',
          'state': 'changed',
          'shots': {'base': 'k-base', 'head': 'k-head'},
        },
      ],
    },
    if (framePath != null)
      'scenarios': {
        'items': [
          {
            'id': 'test/shop.dart#Checkout',
            'state': 'changed',
            'steps': [
              {
                'id': 'guest › Pay',
                'state': 'changed',
                'frames': {
                  'head': {'path': framePath, 'width': 4, 'height': 4},
                },
              },
            ],
          },
        ],
      },
  };

  // On a run where the skip rule did not earn its keep, an export is
  // overwhelmingly pictures of rows that came out identical: measured at
  // 18.1MB of unchanged frames against 1.5MB of findings.
  group('a page of the findings alone', () {
    Map<String, Object?> mixed() => {
      'base': 'abc123def456',
      'head': '/work/tree',
      'previews': {
        'items': [
          {
            'id': 'demo/card.dart#card',
            'state': 'changed',
            'shots': {'base': 'k-base', 'head': 'k-head'},
          },
          {
            'id': 'demo/quiet.dart#quiet',
            'state': 'same',
            'shots': {'base': 'q-base', 'head': 'q-head'},
          },
        ],
      },
    };

    setUp(() {
      file('k-base', 40);
      file('k-head', 200);
      file('q-base', 90);
      file('q-head', 90);
    });

    test('carries the findings and leaves the rest', () async {
      var out = p.join(temp.path, 'page');
      var export = await exporter.export(
        index: mixed(),
        cache: cache,
        against: 'master',
        output: out,
        frames: ExportedFrames.findings,
      );

      expect(export.frames, 2);
      expect(File(p.join(out, 'shots', 'k-head.png')).existsSync(), isTrue);
      expect(File(p.join(out, 'shots', 'q-head.png')).existsSync(), isFalse);
    });

    // The verdict is not what was trimmed. Every row is still in the file
    // with its state and its channels; a script over `index.json` sees what
    // it always saw.
    test('every row is still in the index', () async {
      var out = p.join(temp.path, 'page');
      await exporter.export(
        index: mixed(),
        cache: cache,
        against: 'master',
        output: out,
        frames: ExportedFrames.findings,
      );

      var written = jsonDecode(
        File(p.join(out, 'index.json')).readAsStringSync(),
      ) as Map<String, Object?>;
      var items = (written['previews']! as Map)['items'] as List;
      expect(items, hasLength(2));
      // And it says what it did, so a page reading this copy can tell a row
      // whose picture was left out from one that never had a picture.
      expect(written['exported'], 'findings');
    });

    test('a whole export says nothing about trimming', () async {
      var out = p.join(temp.path, 'page');
      await exporter.export(
        index: mixed(),
        cache: cache,
        against: 'master',
        output: out,
      );

      var written = jsonDecode(
        File(p.join(out, 'index.json')).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(written.containsKey('exported'), isFalse);
      expect(File(p.join(out, 'shots', 'q-head.png')).existsSync(), isTrue);
    });

    // A scenario is a picture per step laid out as one graph, and dropping
    // the unchanged steps out of a flow that is a finding would leave the
    // reader panning across holes.
    test('a finding scenario keeps every step it has', () async {
      var frame = writeFrame('pay.raw', 120);
      var out = p.join(temp.path, 'page');
      await exporter.export(
        index: {
          ...mixed(),
          'scenarios': {
            'items': [
              {
                'id': 'test/shop.dart#Checkout',
                'state': 'changed',
                'steps': [
                  {
                    'id': 'guest › Open',
                    'state': 'same',
                    'frames': {
                      'head': {'path': frame, 'width': 4, 'height': 4},
                    },
                  },
                ],
              },
            ],
          },
        },
        cache: cache,
        against: 'master',
        output: out,
        frames: ExportedFrames.findings,
      );

      // The step is `same` and its scenario is not, so its frame travels.
      expect(
        Directory(p.join(out, 'frames'))
            .listSync(recursive: true)
            .whereType<File>(),
        isNotEmpty,
      );
    });
  });

  test('the page holds the viewer, the index and a PNG per frame', () async {
    file('k-base', 40);
    file('k-head', 200);
    var frame = writeFrame('pay.raw', 120);

    var out = p.join(temp.path, 'page');
    var export = await exporter.export(
      index: index(framePath: frame),
      cache: cache,
      against: 'master',
      output: out,
    );

    expect(File(p.join(out, 'index.html')).existsSync(), isTrue);
    expect(export.frames, 3);

    var written = jsonDecode(
      File(p.join(out, 'index.json')).readAsStringSync(),
    ) as Map<String, Object?>;
    expect(written['against'], 'master');
    // And it says so: every reference below has just been rewritten to a PNG
    // beside this file, which is the whole difference between this copy and
    // the one in the cache. A reader takes it as a promise.
    expect(written['frames'], 'relative');

    // The preview row's cache keys became relative paths…
    var item =
        (((written['previews']! as Map)['items'] as List).single
                as Map)['shots']
            as Map;
    expect(item['base'], 'shots/k-base.png');
    expect(item['head'], 'shots/k-head.png');
    // …that resolve to real, decodable PNGs.
    var png = File(p.join(out, 'shots', 'k-head.png'));
    expect(png.existsSync(), isTrue);
    var decoded = img.decodePng(png.readAsBytesSync())!;
    expect(decoded.width, 4);

    // The scenario step's absolute path became a page-relative PNG too.
    var step =
        ((((written['scenarios']! as Map)['items'] as List).single
                        as Map)['steps']
                    as List)
                .single
            as Map;
    var head = (step['frames'] as Map)['head'] as Map;
    expect(head['path'], 'frames/s0/pay.png');
    expect(File(p.join(out, 'frames', 's0', 'pay.png')).existsSync(), isTrue);
  });

  test('a frame the cache no longer has stays a key, honestly', () async {
    file('k-base', 40);
    // k-head was never filed — evicted, say.

    var out = p.join(temp.path, 'page');
    await exporter.export(
      index: index(),
      cache: cache,
      against: 'master',
      output: out,
    );

    var written = jsonDecode(
      File(p.join(out, 'index.json')).readAsStringSync(),
    ) as Map<String, Object?>;
    var shots =
        (((written['previews']! as Map)['items'] as List).single
                as Map)['shots']
            as Map;
    expect(shots['base'], 'shots/k-base.png');
    // The page will 404 on it and say nothing rendered — nearer the truth
    // than silently dropping the reference.
    expect(shots['head'], 'k-head');
  });

  test('one key referenced twice is encoded once', () async {
    file('k-base', 40);
    var doubled = index();
    ((doubled['previews']! as Map)['items'] as List).add({
      'id': 'demo/card.dart#again',
      'state': 'same',
      'shots': {'base': 'k-base', 'head': 'k-base'},
    });

    var out = p.join(temp.path, 'page');
    var export = await exporter.export(
      index: doubled,
      cache: cache,
      against: 'master',
      output: out,
    );

    expect(export.frames, 1);
  });

  test('the page resolves against its own URL unless told otherwise', () async {
    var out = p.join(temp.path, 'page');
    await exporter.export(
      index: index(),
      cache: cache,
      against: 'master',
      output: out,
    );

    // The compiled-in `/` only ever worked at a domain root, and a CI
    // artifact is never at one.
    expect(
      File(p.join(out, 'index.html')).readAsStringSync(),
      contains('<base href="./">'),
    );
  });

  test('a base href points the page at its mount', () async {
    var out = p.join(temp.path, 'page');
    await exporter.export(
      index: index(),
      cache: cache,
      against: 'master',
      output: out,
      baseHref: '/pr-42/comparison/',
    );

    expect(
      File(p.join(out, 'index.html')).readAsStringSync(),
      contains('<base href="/pr-42/comparison/">'),
    );
  });
}
