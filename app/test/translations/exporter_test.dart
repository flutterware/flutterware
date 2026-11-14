import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/translations.dart';
import 'package:flutterware_app/src/translations/max_length.dart';
import 'package:flutterware_app/src/translations/exporter.dart';
import 'package:flutterware_app/src/translations/survey.dart';
import 'package:path/path.dart' as p;

late Directory worktree;
late Directory output;

/// A frame on disk where a run would have left one.
String frame(String name) {
  var relative = p.join('build', 'runs', name);
  var file = File(p.join(worktree.path, relative));
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync([0x89, 0x50, 0x4e, 0x47]);
  return relative;
}

KeySighting sighting({
  String key = 'save',
  String? image,
  String scenario = 'home_test.dart/Home',
  String step = 'Home',
  int stepIndex = 1,
  String? locale = 'en',
  String? device,
  String? rect = '10,20 100×40',
  bool overflowed = false,
  bool offstage = false,
  int textsOnScreen = 10,
  int area = 4000,
}) => KeySighting(
  catalog: 'app',
  key: key,
  scenario: scenario,
  step: step,
  stepIndex: stepIndex,
  position: '#$stepIndex',
  image: image ?? frame('$step-$stepIndex.png'),
  locale: locale,
  device: device,
  rect: rect,
  area: area,
  charStart: 0,
  charEnd: 4,
  overflowed: overflowed,
  offstage: offstage,
  textsOnScreen: textsOnScreen,
);

TranslationSurvey survey({
  List<KeySighting> sightings = const [],
  Map<String, Map<String, Map<String, String>>> read = const {},
  Map<String, String> en = const {'save': 'Save', 'greeting': 'Hello'},
  Map<String, String> nl = const {},
  List<UnkeyedSighting> unkeyed = const [],
}) => TranslationSurvey(
  catalogs: {
    'app': LoadedCatalog(
      name: 'app',
      template: 'en',
      byLocale: {'en': en, 'nl': nl},
    ),
  },
  sightings: sightings,
  unkeyed: unkeyed,
  read: read,
);

WrittenExport write(
  TranslationSurvey it, {
  double captureScale = 1,
  TranslationMaxLengths? maxLengths,
}) => TranslationExporter(worktreeRoot: worktree.path).write(
  survey: it,
  output: output.path,
  captureScale: captureScale,
  maxLengths: maxLengths,
);

void main() {
  setUp(() {
    worktree = Directory.systemTemp.createTempSync('fw-worktree');
    output = Directory(p.join(worktree.path, 'build', 'translations'));
  });
  tearDown(() => worktree.deleteSync(recursive: true));

  group('the frames', () {
    test('one screen costs one file however many keys are on it', () {
      var shared = frame('Home-1.png');
      var written = write(
        survey(
          sightings: [
            sighting(key: 'save', image: shared),
            sighting(key: 'greeting', image: shared),
          ],
        ),
      );

      // The whole argument for whole frames over crops: the second key is
      // free, and both boxes point into the same picture.
      expect(written.shots, 1);
      expect(
        written.export['app/save']?.representative?.image,
        written.export['app/greeting']?.representative?.image,
      );
    });

    test('are named for where they came from, not hashed', () {
      var written = write(survey(sightings: [sighting()]));

      // Readable, because somebody opens this directory in a file browser.
      expect(
        written.export['app/save']?.representative?.image,
        'shots/en/home_test.dart/Home/1.png',
      );
      expect(
        File(
          p.join(output.path, 'shots', 'en', 'home_test.dart', 'Home', '1.png'),
        ).existsSync(),
        isTrue,
      );
    });

    test('a frame the run no longer has is counted, not fatal', () {
      var written = write(
        survey(sightings: [sighting(image: 'build/runs/gone.png')]),
      );

      expect(written.missingShots, 1);
      expect(written.shots, 0);
      // An export missing one screenshot is worth more than no export.
      expect(written.export['app/save'], isNotNull);
      expect(written.export['app/save']?.representative, isNull);
    });

    test('the rectangle arrives in image pixels', () {
      var written = write(survey(sightings: [sighting()]), captureScale: 3);

      expect(written.export['app/save']?.representative?.rect?.x, 30);
      expect(written.export['app/save']?.representative?.rect?.width, 300);
    });

    test('the scale they were captured at is in keys.json', () {
      var written = write(survey(sightings: [sighting()]), captureScale: 3);

      var json = jsonDecode(
        File(written.keysJson).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(json['captureScale'], 3);
      expect(written.export.captureScale, 3);
      expect(
        TranslationExport.fromJson(json).captureScale,
        3,
        reason: 'what a reader of the file gets back',
      );
    });
  });

  group('the index', () {
    test('carries declared keys the run never showed', () {
      var written = write(survey(sightings: [sighting(key: 'save')]));

      // `keys` is the whole catalog, not the part that photographed well —
      // a translator's list may not silently omit the untested screens.
      expect(written.export['app/greeting'], isNotNull);
      expect(written.export['app/greeting']?.representative, isNull);
      expect(written.export['app/greeting']?.values['en'], 'Hello');
      expect(written.export.seen.map((k) => k.key), ['save']);
    });

    test('seen keys come first, in most-seen order', () {
      var written = write(
        survey(
          sightings: [
            sighting(key: 'greeting', step: 'A'),
            sighting(key: 'save', step: 'B'),
            sighting(key: 'save', step: 'C'),
          ],
        ),
      );

      expect(written.export.keys.first.key, 'save');
    });

    test('findings are split by what they are', () {
      var written = write(
        survey(
          sightings: [sighting(key: 'save', overflowed: true)],
          nl: {'greeting': 'Hallo'},
          read: {
            'nl': {
              'app': {'save': 'Save', 'greeting': 'Anders', 'stale': 'x'},
            },
          },
          unkeyed: const [
            UnkeyedSighting(
              text: 'Fri, Dec 15',
              scenario: 'home_test.dart/Home',
              step: 'Home',
              source: 'home.dart:42:7',
            ),
          ],
        ),
      );

      var findings = written.export.findings;
      expect(findings.fallingBack.single.key, 'save');
      expect(findings.disagrees.single.key, 'greeting');
      expect(findings.disagrees.single.expected, 'Hallo');
      expect(findings.absentFromCatalog.single.key, 'stale');
      expect(findings.overflowing.single.overflowed, isTrue);
      expect(findings.unkeyed.single.source, 'home.dart:42:7');
    });
  });

  group('the directory', () {
    test('holds the index, the page and the frames', () {
      var written = write(survey(sightings: [sighting()]));

      expect(File(written.keysJson).existsSync(), isTrue);
      expect(File(written.indexHtml).existsSync(), isTrue);
      expect(
        jsonDecode(File(written.keysJson).readAsStringSync()),
        isA<Map<String, Object?>>().having(
          (json) => json['version'],
          'version',
          translationExportVersion,
        ),
      );
    });

    test('two exports of an unchanged survey are byte-identical', () {
      var it = survey(sightings: [sighting()]);
      var first = File(write(it).keysJson).readAsStringSync();
      var second = File(write(it).keysJson).readAsStringSync();

      // No timestamp anywhere in the format, on purpose: this is what makes a
      // `git diff` of two exports say what actually moved, and what lets a
      // push script upload only the difference.
      expect(second, first);
    });

    test('a max length rides its key, its shots filed apart', () {
      // The probe's shots come from probe-device runs whose scenario and
      // step names collide with the main baseline's — a shared `shots/` path
      // would overwrite one with the other.
      var screen = sighting(
        image: frame('probe-baseline.png'),
        device: 'pixel-4a',
      );
      var clipped = sighting(image: frame('probe-clip.png'), overflowed: true);
      var written = write(
        survey(sightings: [sighting()]),
        maxLengths: TranslationMaxLengths(
          devices: const ['pixel-4a'],
          byKey: {
            'app/save': KeyMaxLength(
              chars: 29,
              fitsText: 'Save padded to twenty-nine ch',
              clipsChars: 34,
              clipsText: 'Save padded to thirty-four chars.',
              screen: screen,
              clipped: clipped,
            ),
          },
          breaks: const [
            MaxLengthBreak(
              scenario: 'home_test.dart/Home',
              level: 35,
              step: 'Home',
              stepIndex: 1,
              overflows: 2,
            ),
          ],
        ),
      );

      var export = written.export;
      expect(export.measuredMaxLengths, isTrue);
      expect(export.maxLengthDevices, ['pixel-4a']);
      var limit = export['app/save']?.maxLength;
      expect(limit?.chars, 29);
      expect(limit?.clipsChars, 34);
      expect(limit?.screen?.image, startsWith('shots/max-length/'));
      expect(limit?.clipped?.image, startsWith('shots/max-length/clipped/'));
      expect(limit?.measuredOn, 'pixel-4a');
      expect(export.findings.expansionBreaks.single.overflows, 2);
    });

    test('no probe leaves the format without a max length anywhere', () {
      var written = write(survey(sightings: [sighting()]));

      var json = jsonDecode(
        File(written.keysJson).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(json.containsKey('maxLengths'), isFalse);
      expect('${json['keys']}'.contains('maxLength'), isFalse);
    });

    test('is emptied first, so a deleted key takes its frames with it', () {
      write(
        survey(
          sightings: [sighting(key: 'save', scenario: 'old_test.dart/Old')],
        ),
      );
      var gone = Directory(p.join(output.path, 'shots', 'en', 'old_test.dart'));
      expect(gone.existsSync(), isTrue);

      write(
        survey(
          sightings: [sighting(key: 'save', scenario: 'new_test.dart/New')],
        ),
      );

      expect(gone.existsSync(), isFalse);
    });
  });
}
