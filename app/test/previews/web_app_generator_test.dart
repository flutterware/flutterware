import 'dart:io';

import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/web_app_generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/generated_source.dart';

/// The generated app is only ever read by `flutter build web`, which means a
/// mistake here surfaces as a compile error inside generated code — a long way
/// from the entry that caused it. These assert the shape directly.
void main() {
  late Directory root;
  late WebAppGenerator generator;

  const members = CatalogEntry(
    path: 'demo/team/avatar_tile.dart',
    symbol: 'avatarTileMembers',
    name: 'Members',
    group: 'Avatar tile',
    annotation: "Demo(name: 'Members', group: 'Avatar tile')",
  );
  const empty = CatalogEntry(
    path: 'demo/team/avatar_tile.dart',
    symbol: 'avatarTileEmpty',
    name: "Empty — nobody's here",
    group: 'Avatar tile',
    annotation: "Demo(name: 'Empty', group: 'Avatar tile')",
  );
  const settings = CatalogEntry(
    path: 'demo/settings.dart',
    symbol: 'settings',
    name: 'Settings',
    annotation: 'Demo()',
  );

  /// Another file, another symbol, the *same* display name — which discovery
  /// allows, because it rejects a duplicate id and not a duplicate name.
  const otherSettings = CatalogEntry(
    path: 'demo/settings_wide.dart',
    symbol: 'settingsWide',
    name: 'Settings',
    annotation: 'Demo()',
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('fw_web_app_test');
    Directory(p.join(root.path, 'demo', 'team')).createSync(recursive: true);
    File(p.join(root.path, 'demo', 'team', 'avatar_tile.dart'))
        .writeAsStringSync('''
import 'package:material_ui/material_ui.dart';

import '../shell.dart';

Widget avatarTileMembers() => const Placeholder();
Widget avatarTileEmpty() => const Placeholder();
''');
    File(p.join(root.path, 'demo', 'settings.dart')).writeAsStringSync('''
import 'package:material_ui/material_ui.dart';

Widget settings() => const Placeholder();
''');
    File(p.join(root.path, 'demo', 'settings_wide.dart')).writeAsStringSync('''
import 'package:material_ui/material_ui.dart';

Widget settingsWide() => const Placeholder();
''');
    generator = WebAppGenerator(
      outputDir: p.join(root.path, 'build', 'web_src'),
      projectRoot: root.path,
      title: 'Example',
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  String generate(List<CatalogEntry> entries) {
    generator.generate(entries);
    return File(generator.entrypointPath).readAsStringSync();
  }

  test('every entry gets a wrapper, and the entrypoint imports them all', () {
    var main = generate([members, empty, settings]);

    for (var i = 0; i < 3; i++) {
      expect(
        File(p.join(root.path, 'build', 'web_src', 'entry_$i.dart'))
            .existsSync(),
        isTrue,
        reason: 'entry_$i.dart should have been written',
      );
      expect(main, contains("import 'entry_$i.dart' as fw$i;"));
    }
  });

  test('the map nests the way the panel tree does', () {
    var main = generate([members, empty, settings]);

    // `demo/` is the directory every entry shares, so it is dropped; the group
    // survives as a level. This is `buildCatalogTree`'s arrangement, and the
    // point of reusing it is that the page and the panel agree.
    expect(main, contains("'Avatar tile': <String, dynamic>{"));
    expect(main, contains("'Members': _entry(fw0.fwPreview, fw0.fwBuilder)"));
    expect(main, contains("'Settings': _entry(fw2.fwPreview, fw2.fwBuilder)"));
  });

  test(
    'a name with an apostrophe is escaped rather than breaking the file',
    () {
      var main = generate([members, empty, settings]);
      // A display name is written by a human in an annotation. Unescaped, this
      // one closes the literal and the generated file does not parse.
      //
      // Asserted as the value rather than the quoting: which delimiter the
      // escaper picks is its business, and pinning the test to one of them is
      // how a legitimate change to escaping would read as a regression.
      expect(() => parseGenerated(main), returnsNormally);
      expect(generatedStrings(main), contains("Empty — nobody's here"));
    },
  );

  test('the wrapper is applied, and nothing else the annotation carries', () {
    var main = generate([settings]);
    // Parity with `_CatalogHost` in the guest's entrypoint, which also applies
    // only `wrapper`. An entry that looked one way in the panel and another on
    // the page would be worse than one ignoring an annotation in both.
    expect(main, contains('var wrapper = demo.transform().wrapper;'));
    expect(main, isNot(contains('preview.size')));
  });

  test('regenerating clears a wrapper whose entry is gone', () {
    generate([members, empty, settings]);
    var third = File(p.join(root.path, 'build', 'web_src', 'entry_2.dart'));
    expect(third.existsSync(), isTrue);

    generate([members]);

    // Left behind, it would name a demo that no longer exists and fail the
    // build inside generated code.
    expect(third.existsSync(), isFalse);
  });

  test('two entries with one name both reach the page', () {
    var main = generate([settings, otherSettings]);

    // Emitted as-is this was `'Settings': …, 'Settings': …` — a repeated key in
    // a map literal, where the last one wins and the other demo is simply not on
    // the page. The panel keys its tree by id and shows both, so this was the
    // page and the panel disagreeing about what exists.
    expect(main, contains("'Settings': _entry(fw0.fwPreview, fw0.fwBuilder)"));
    expect(
      main,
      contains(
        "'Settings (settingsWide)': _entry(fw1.fwPreview, fw1.fwBuilder)",
      ),
    );
  });

  test('every key in a branch is distinct', () {
    var main = generate([settings, otherSettings, members, empty]);

    // Whatever the disambiguation looks like, this is the property that matters.
    var keys = RegExp(
      r"^\s+('(?:[^'\\]|\\.)*'):",
      multiLine: true,
    ).allMatches(main).map((m) => m.group(1)!).toList();
    expect(keys, isNotEmpty);
    expect(keys.toSet(), hasLength(keys.length), reason: 'keys: $keys');
  });

  test('an entry with no wrapper still reaches its builder', () {
    generator.generate([settings]);
    var wrapper = File(p.join(root.path, 'build', 'web_src', 'entry_0.dart'))
        .readAsStringSync();

    expect(wrapper, contains('Preview get fwPreview => Demo();'));
    expect(
      wrapper,
      contains('Widget Function() get fwBuilder => fw0.settings;'),
    );
    // Carried from the demo file, with the relative URI rewritten to resolve
    // from the generated directory rather than from the demo's own.
    expect(wrapper, contains("import 'package:material_ui/material_ui.dart';"));
  });
}
