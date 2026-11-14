import 'dart:convert';
import 'dart:io';

import 'package:flutterware/translations.dart';
import 'package:test/test.dart';

TranslationExport export({
  List<ExportedKey> keys = const [],
  ExportFindings findings = const ExportFindings(),
  String directory = '.',
}) => TranslationExport(
  directory: directory,
  catalogs: const [
    ExportedCatalog(
      name: 'app',
      template: 'en',
      locales: ['en', 'nl'],
      keys: 2,
    ),
  ],
  keys: keys,
  findings: findings,
);

void main() {
  group('a rectangle', () {
    test('is parsed out of the capture spelling', () {
      var rect = ExportedRect.parse('10,20 100×40');

      expect(rect?.x, 10);
      expect(rect?.y, 20);
      expect(rect?.width, 100);
      expect(rect?.height, 40);
    });

    test('is scaled into the image own pixels', () {
      // The whole reason the scale is applied here: a consumer cropping or
      // drawing this must never have to know what the run captured at.
      var rect = ExportedRect.parse('10,20 100×40', scale: 3);

      expect(rect?.x, 30);
      expect(rect?.width, 300);
    });

    test('that is not a rectangle is null, not a throw', () {
      // A key recorded without a box is ordinary. Taking the whole export down
      // for one would be the wrong trade by a wide margin.
      expect(ExportedRect.parse(null), isNull);
      expect(ExportedRect.parse('nonsense'), isNull);
      expect(ExportedRect.parse('10,20'), isNull);
    });
  });

  group('the format', () {
    test('survives a round trip', () {
      var original = export(
        keys: [
          const ExportedKey(
            catalog: 'app',
            key: 'save',
            values: {'en': 'Save', 'nl': 'Opslaan'},
            representative: ExportedShot(
              image: 'shots/en/home/1.png',
              scenario: 'home_test.dart/Home',
              step: 'Home',
              stepIndex: 1,
              rect: ExportedRect(x: 1, y: 2, width: 3, height: 4),
              charStart: 0,
              charEnd: 4,
              locale: 'en',
              device: 'iphone-16',
            ),
          ),
        ],
        findings: const ExportFindings(
          fallingBack: [
            ExportedLocaleFinding(
              catalog: 'app',
              key: 'save',
              locale: 'nl',
              rendered: 'Save',
            ),
          ],
          unkeyed: [
            ExportedUnkeyed(
              text: 'Fri, Dec 15',
              scenario: 'home_test.dart/Home',
              step: 'Home',
              source: 'home.dart:42:7',
            ),
          ],
        ),
      );

      var back = TranslationExport.fromJson(original.toJson());

      expect(back['app/save']?.values['nl'], 'Opslaan');
      expect(back['app/save']?.representative?.rect?.width, 3);
      expect(back['app/save']?.representative?.charEnd, 4);
      expect(back.findings.fallingBack.single.rendered, 'Save');
      expect(back.findings.fallingBack.single.expected, isNull);
      expect(back.findings.unkeyed.single.source, 'home.dart:42:7');
      expect(back.catalogs.single.locales, ['en', 'nl']);
    });

    test('a max length survives the round trip with its evidence', () {
      var original = TranslationExport(
        measuredMaxLengths: true,
        maxLengthDevices: const ['pixel-4a'],
        keys: const [
          ExportedKey(
            catalog: 'app',
            key: 'save',
            maxLength: ExportedMaxLength(
              chars: 29,
              fitsText: 'Warm spices, creamy milk. wor',
              clipsChars: 34,
              clipsText: 'Warm spices, creamy milk. word le',
              screen: ExportedShot(
                image: 'shots/max-length/en/home/1.png',
                scenario: 'home_test.dart/Home',
                step: 'Home',
                stepIndex: 1,
              ),
              clipped: ExportedShot(
                image: 'shots/max-length/clipped/en/home/1.png',
                scenario: 'home_test.dart/Home',
                step: 'Home',
                stepIndex: 1,
                overflowed: true,
              ),
              measuredOn: 'pixel-4a',
            ),
          ),
          // An open bound: proven to fit this much, nothing clipped it.
          ExportedKey(
            catalog: 'app',
            key: 'blurb',
            maxLength: ExportedMaxLength(chars: 120, fitsText: 'long…'),
          ),
          ExportedKey(catalog: 'app', key: 'title'),
        ],
        findings: const ExportFindings(
          expansionBreaks: [
            ExportedExpansionBreak(
              scenario: 'home_test.dart/Home',
              level: 70,
              step: 'Home',
              stepIndex: 1,
              overflows: 2,
            ),
            ExportedExpansionBreak(
              scenario: 'cart_test.dart/Cart',
              level: 35,
              failure: 'tap found nothing',
            ),
          ],
        ),
      );

      var back = TranslationExport.fromJson(original.toJson());

      expect(back.measuredMaxLengths, isTrue);
      expect(back.maxLengthDevices, ['pixel-4a']);
      var limit = back['app/save']?.maxLength;
      expect(limit?.chars, 29);
      expect(limit?.bounded, isTrue);
      expect(limit?.fitsText, 'Warm spices, creamy milk. wor');
      expect(limit?.clipsChars, 34);
      expect(limit?.clipsText, 'Warm spices, creamy milk. word le');
      expect(limit?.screen?.stepIndex, 1);
      expect(limit?.clipped?.overflowed, isTrue);
      expect(limit?.measuredOn, 'pixel-4a');
      var open = back['app/blurb']?.maxLength;
      expect(open?.chars, 120);
      expect(open?.bounded, isFalse, reason: 'an open bound is not a limit');
      expect(back['app/title']?.maxLength, isNull);
      expect(back.findings.expansionBreaks, hasLength(2));
      expect(back.findings.expansionBreaks.first.overflows, 2);
      expect(back.findings.expansionBreaks.last.failure, 'tap found nothing');
      // An unprobed export's JSON does not even mention max lengths —
      // absence of a probe must stay distinguishable from a probe that
      // found room.
      expect(export().toJson().containsKey('maxLengths'), isFalse);
      expect(export().measuredMaxLengths, isFalse);
    });

    test('a newer version is refused rather than half-decoded', () {
      // The message names both numbers, because whoever reads it is looking at
      // somebody else's build output and needs to know which half to move.
      expect(
        () => TranslationExport.fromJson({
          'version': translationExportVersion + 1,
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('${translationExportVersion + 1}'),
              contains('$translationExportVersion'),
            ),
          ),
        ),
      );
    });

    test('an older version still reads', () {
      // Added fields do not bump the version, so an older writer must stay
      // readable — otherwise nobody can add a field.
      var back = TranslationExport.fromJson({
        'version': 1,
        'keys': [
          {'catalog': 'app', 'key': 'save'},
        ],
      });

      expect(back['app/save'], isNotNull);
      expect(back.captureScale, isNull);
    });

    test('the capture scale survives the round trip', () {
      var original = TranslationExport(captureScale: 2.5);

      var back = TranslationExport.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, Object?>,
      );

      expect(back.captureScale, 2.5);
    });

    test('a whole-number capture scale reads back as a double', () {
      // `jsonEncode(3.0)` is `3.0`, but a file written by anything else may
      // well say `3`.
      var back = TranslationExport.fromJson({'version': 1, 'captureScale': 3});

      expect(back.captureScale, 3.0);
    });

    test('seen is the keys that were photographed', () {
      var it = export(
        keys: [
          const ExportedKey(
            catalog: 'app',
            key: 'save',
            representative: ExportedShot(
              image: 'a.png',
              scenario: 's',
              step: 'x',
              stepIndex: 1,
            ),
          ),
          const ExportedKey(catalog: 'app', key: 'never'),
        ],
      );

      expect(it.seen.map((k) => k.key), ['save']);
    });

    test('a lookup is a lookup, not a walk', () {
      // The join every reader performs — one probe per key it holds — so a
      // scan here is quadratic in the caller. 20k keys is a table nobody has;
      // as a walk this took minutes, so the assertion is the clock.
      var it = export(
        keys: [
          for (var i = 0; i < 20000; i++)
            ExportedKey(catalog: 'app', key: '$i'),
        ],
      );

      var watch = Stopwatch()..start();
      for (var i = 0; i < 20000; i++) {
        expect(it['app/$i'], isNotNull);
      }
      watch.stop();

      expect(it['app/nope'], isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('a duplicated id keeps the first one, as the walk did', () {
      var it = export(
        keys: const [
          ExportedKey(catalog: 'app', key: 'save', values: {'en': 'first'}),
          ExportedKey(catalog: 'app', key: 'save', values: {'en': 'second'}),
        ],
      );

      expect(it['app/save']?.values['en'], 'first');
    });
  });

  group('reading one back', () {
    late Directory directory;

    setUp(() => directory = Directory.systemTemp.createTempSync('fw-export'));
    tearDown(() => directory.deleteSync(recursive: true));

    test('finds the index and resolves a shot against it', () async {
      File('${directory.path}${Platform.pathSeparator}$translationExportFile')
          .writeAsStringSync(jsonEncode(export().toJson()));

      var read = await TranslationExport.read(directory.path);

      expect(read.version, translationExportVersion);
      // The path in the JSON is relative and url-spelled; what a script needs
      // is a file it can open on this machine.
      expect(read.file('shots/en/home/1.png').path, contains(directory.path));
      expect(
        read.file('shots/en/home/1.png').path,
        endsWith(['shots', 'en', 'home', '1.png'].join(Platform.pathSeparator)),
      );
    });

    test('a directory with no export says what to run', () async {
      await expectLater(
        TranslationExport.read(directory.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('export'),
          ),
        ),
      );
    });
  });
}
