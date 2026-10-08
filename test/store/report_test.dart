import 'dart:io';

import 'package:test/test.dart';
import 'package:flutterware/store_report.dart';

/// The published reader for what an export wrote.
///
/// The merge is the test that matters. Everything else here is round-tripping,
/// and the version gate — which is what stops a newer flutterware's file being
/// half-decoded by an older script.
void main() {
  StoreShotsSet set(
    String store,
    String deviceClass,
    String appLocale, {
    String app = 'shop',
    List<String> images = const ['01-welcome.png'],
    DateTime? at,
  }) => StoreShotsSet(
    app: app,
    store: store,
    deviceClass: deviceClass,
    appLocale: appLocale,
    storeLocale: '$appLocale-UP',
    output: '/out',
    directory: '$store/$deviceClass',
    images: images,
    exportedAt: at ?? DateTime(2026, 8, 26, 12),
  );

  group('merging what an export wrote', () {
    // An export replaces the files of the listing it wrote and leaves the
    // others; this is the same statement about the panel's knowledge.
    // `export --listing=play` must not erase what the panel knows about the
    // App Store half, for exactly the reason it must not delete those files.
    test('a narrowed export leaves the sets it did not touch', () {
      var before = StoreShotsReport(
        sets: [
          set('app-store', 'iphone-6-9', 'en'),
          set('play', 'phone', 'en'),
        ],
      );
      var after = before.merge([
        set('play', 'phone', 'en', images: ['01-welcome.png', '02-menu.png']),
      ]);
      expect(after.sets, hasLength(2));
      expect(after['shop/app-store/iphone-6-9/en']!.images, hasLength(1));
      expect(after['shop/play/phone/en']!.images, hasLength(2));
    });

    test('a set new to the file is added', () {
      var after = StoreShotsReport(sets: [set('play', 'phone', 'en')])
          .merge([set('play', 'tablet-10', 'en')]);
      expect(after.sets.map((s) => s.key), [
        'shop/play/phone/en',
        'shop/play/tablet-10/en',
      ]);
    });

    // Two app locales can map to one store slot, and they are two sets. Keying
    // on the store's slot would have the second silently overwrite the first.
    test('the key is the app locale, not the store slot', () {
      var fr = set('play', 'phone', 'fr');
      var frCa = set('play', 'phone', 'fr-CA');
      var after = const StoreShotsReport().merge([fr, frCa]);
      expect(after.sets, hasLength(2));
    });
  });

  test('the age of an export is its most recent set', () {
    var manifest = StoreShotsReport(
      sets: [
        set('play', 'phone', 'en', at: DateTime(2026, 8, 20)),
        set('play', 'tablet-10', 'en', at: DateTime(2026, 8, 26)),
      ],
    );
    expect(manifest.exportedAt, DateTime(2026, 8, 26));
    expect(const StoreShotsReport().exportedAt, isNull);
  });

  group('reading a file', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('fw-manifest'));
    tearDown(() => temp.deleteSync(recursive: true));

    File file() => File('${temp.path}/manifest.json');

    test('round-trips everything the panel needs to find an image', () {
      StoreShotsReport(sets: [set('play', 'phone', 'en')]).writeTo(file());
      var read = StoreShotsReport.readFile(file())!;
      expect(read.sets, hasLength(1));
      expect(
        read['shop/play/phone/en']!.pathOf('01-welcome.png'),
        '/out/play/phone/01-welcome.png',
      );
      expect(read['shop/play/phone/en']!.storeLocale, 'en-UP');
    });

    // Three ways of having nothing, and a panel treats them alike: it draws
    // its placeholders and offers Export. None is worth an error, because the
    // remedy for all three is the same one click.
    test(
      'nothing at all',
      () => expect(StoreShotsReport.readFile(file()), isNull),
    );

    test('unreadable', () {
      file().writeAsStringSync('{not json');
      expect(StoreShotsReport.readFile(file()), isNull);
    });

    test('a version this build does not know', () {
      file().writeAsStringSync('{"version": 999, "sets": []}');
      expect(StoreShotsReport.readFile(file()), isNull);
    });
  });
}
