import 'dart:io';

import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/entrypoint_generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/generated_source.dart';

void main() {
  late Directory root;
  late EntrypointGenerator generator;

  const members = CatalogEntry(
    path: 'demo/team/avatar_tile.dart',
    symbol: 'avatarTileMembers',
    name: 'Members',
    annotation: "Demo(name: 'Members', wrapper: wrapInApp)",
  );
  const empty = CatalogEntry(
    path: 'demo/team/avatar_tile.dart',
    symbol: 'avatarTileEmpty',
    name: 'Empty',
    annotation: "Demo(name: 'Empty', wrapper: wrapInApp)",
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('fw_entrypoint_test');
    var demoDir = Directory(p.join(root.path, 'demo', 'team'))
      ..createSync(recursive: true);
    File(p.join(demoDir.path, 'avatar_tile.dart')).writeAsStringSync('''
import 'package:material_ui/material_ui.dart';

import '../shell.dart';

Widget avatarTileMembers() => const Placeholder();
Widget avatarTileEmpty() => const Placeholder();
''');
    generator = EntrypointGenerator(
      outputDir: p.join(root.path, 'build', 'entrypoint'),
      projectRoot: root.path,
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  String wrapper(int index) =>
      File(p.join(root.path, 'build', 'entrypoint', 'entry_$index.dart'))
          .readAsStringSync();
  String entrypoint() => File(generator.entrypointPath).readAsStringSync();

  test('the entrypoint pins the clock outside the binding', () {
    generator.select(members);

    var source = File(generator.entrypointPath).readAsStringSync();
    // Outside `install`, which is itself outside `ensureInitialized`: the
    // binding captures `Zone.current` when it sets `onBeginFrame`, so a clock
    // entered any later would not reach the builds that read it.
    expect(
      source,
      contains(
        "void main() => withClock(Clock.fixed(DateTime.parse('2026-01-01T09:41:00.000')), "
        '() => GuestLogs.instance',
      ),
    );
    expect(
      source.indexOf('withClock('),
      lessThan(source.indexOf('WidgetsFlutterBinding.ensureInitialized')),
    );
    // **`package:clock`, never flutterware's own wrapper.** This file is
    // compiled against the *target's* `package:flutterware`, which in a
    // comparison is the base checkout's older copy; a generated call into a
    // function the framework only just grew fails there, naming a file nobody
    // wrote. Measured: it broke every preview of every comparison this repo
    // ran against its own base.
    expect(source, contains("import 'package:clock/clock.dart';"));
    expect(source, isNot(contains('withPreviewClock')));
  });

  test('emits the annotation verbatim, never interpreted', () {
    generator.select(members);
    expect(
      wrapper(0),
      contains(
        "Preview get fwPreview => Demo(name: 'Members', "
        'wrapper: wrapInApp);',
      ),
    );
    expect(
      wrapper(0),
      contains('Widget Function() get fwBuilder => fw0.avatarTileMembers;'),
    );
    // Not const, and this is the whole point: a const holding a function
    // tear-off is inlined into the entrypoint's constant pool, and a reload
    // carrying only the entrypoint cannot re-resolve it against a demo file it
    // does not contain. The guest renders `Lookup failed: wrapInApp in
    // @methods in file:...` instead of the demo.
    expect(wrapper(0), isNot(contains('const fwPreview')));
    expect(wrapper(0), isNot(contains('const fwBuilder')));
  });

  test('a plain @Preview is typed as Preview, and can be', () {
    // The regression this exists for: the getter used to be declared `Demo`,
    // so an entry carrying Flutter's own annotation — which the scanner has
    // always accepted — assigned a supertype to a subtype and failed to
    // compile, pointing at generated code. Nothing downstream calls anything
    // `Demo` adds.
    generator.select(
      const CatalogEntry(
        path: 'demo/team/avatar_tile.dart',
        symbol: 'avatarTileMembers',
        name: 'Members',
        annotation: "Preview(name: 'Members')",
      ),
    );
    expect(
      wrapper(0),
      contains("Preview get fwPreview => Preview(name: 'Members');"),
    );
    // And the type has to be nameable: a file annotated `@Preview` never
    // imports ours, so the wrapper cannot rely on carrying it.
    expect(
      wrapper(0),
      contains("import 'package:flutter/widget_previews.dart';"),
    );
  });

  test('carries the demo file imports, re-relativised', () {
    generator.select(members);
    // Package URIs pass through untouched.
    expect(
      wrapper(0),
      contains("import 'package:material_ui/material_ui.dart';"),
    );
    // '../shell.dart' resolves to <root>/demo/shell.dart, which from
    // <root>/build/entrypoint/ is three levels up.
    expect(wrapper(0), contains("import '../../demo/shell.dart';"));
    expect(wrapper(0), isNot(contains("import '../shell.dart';")));
  });

  test('a fresh prefix per entry, so no prefix is ever rebound', () {
    generator.select(members);
    generator.select(empty);

    expect(entrypoint(), contains("import 'entry_0.dart' as fw0;"));
    expect(entrypoint(), contains("import 'entry_1.dart' as fw1;"));
    expect(wrapper(0), contains('as fw0;'));
    expect(wrapper(1), contains('as fw1;'));
  });

  test('the entrypoint accumulates, and names the entry the file means', () {
    generator.select(members);
    expect(entrypoint(), contains("_fileEntryId = '${members.id}'"));

    generator.select(empty);
    expect(entrypoint(), contains("import 'entry_0.dart' as fw0;"));
    expect(entrypoint(), contains("_fileEntryId = '${empty.id}'"));
    expect(entrypoint(), isNot(contains("_fileEntryId = '${members.id}'")));

    generator.select(members);
    expect(entrypoint(), contains("_fileEntryId = '${members.id}'"));
    expect(generator.visited, hasLength(2), reason: 'revisits reuse a wrapper');
  });

  test('every entry stays reachable, whichever one is selected', () {
    // The point of the whole thing: the program holds the catalog, so the host
    // can switch between entries with a message instead of a compile and a
    // reload. A selection that dropped the others from the file would put that
    // back — and it would do it silently, as a slow audit rather than a broken
    // one.
    generator.registerAll([members, empty]);
    generator.select(empty);

    expect(entrypoint(), contains("'${members.id}' => ("));
    expect(entrypoint(), contains("'${empty.id}' => ("));
    expect(entrypoint(), contains('preview: fw0.fwPreview.transform()'));
    expect(entrypoint(), contains('preview: fw1.fwPreview.transform()'));
    // And declared, because the guest refuses a switch to an id it does not
    // hold rather than rendering the wrong demo under the right name.
    expect(entrypoint(), contains("'${members.id}',"));
    expect(entrypoint(), contains("'${empty.id}',"));
  });

  test('an id the annotation pinned is escaped, not emitted raw', () {
    // `id:` is read off whatever annotation the project registered, so it is
    // free text a human typed — the same hazard as a display name, in the file
    // the panel compiles rather than the one the audit does.
    const pinned = CatalogEntry(
      path: 'demo/team/avatar_tile.dart',
      symbol: 'avatarTileMembers',
      name: 'Members',
      annotation: "Demo(id: 'team/avatar')",
      declaredId: "team/what's-new",
    );
    generator.select(pinned);

    expect(() => parseGenerated(entrypoint()), returnsNormally);
    expect(generatedStrings(entrypoint()), contains("team/what's-new"));
  });

  test('resolves through functions and getters, never top-level finals', () {
    // A final is initialised once and a hot reload does not re-run its
    // initialiser, so a table held in one would freeze at whatever the catalog
    // was when the guest started.
    generator.select(members);
    expect(entrypoint(), contains('_entry(String id) =>'));
    expect(entrypoint(), contains('List<String> get _entryIds'));
    expect(entrypoint(), isNot(contains('final _entry')));
    expect(entrypoint(), isNot(contains('final _entryIds')));
  });

  test('installs the switch before runApp, like every other extension', () {
    generator.select(members);
    var source = entrypoint();
    expect(
      source,
      contains('CatalogEntries.instance.install(() => _entryIds)'),
    );
    expect(source, contains('CatalogEntries.instance.registerExtensions()'));
    // The host may ask for another entry before the first frame, so the
    // extension has to be up before anything renders.
    expect(
      source.indexOf('CatalogEntries.instance.registerExtensions'),
      lessThan(source.indexOf('runApp(')),
    );
  });

  test('reports what to invalidate: the wrapper only on first visit', () {
    expect(generator.select(members), hasLength(2));
    expect(generator.select(empty), hasLength(2));
    expect(
      generator.select(members),
      hasLength(1),
      reason: 'a revisit rewrites only the entrypoint',
    );
  });

  group('registerAll — what makes one compiler safe to share', () {
    test('imports every entry, so a select only ever changes main.dart', () {
      generator.registerAll([members, empty]);
      expect(generator.visited, [members, empty]);
      expect(
        generator.select(empty),
        hasLength(1),
        reason:
            'the wrapper is already registered, so only the entrypoint is '
            'invalidated',
      );
      expect(entrypoint(), contains("import 'entry_0.dart' as fw0;"));
      expect(
        entrypoint(),
        contains("import 'entry_1.dart' as fw1;"),
        reason: 'an entry nobody has selected is still imported',
      );
    });

    test('a second client selecting first is not what adds the wrapper', () {
      // The hazard this closes: with lazy registration, whoever selects an
      // entry first adds its wrapper, and that is the only compile whose delta
      // carries it. A second client selecting the same entry later would be
      // handed a delta with the wrapper missing — unchanged since the baseline
      // — and its guest, which never had that library, would reload nothing.
      generator.registerAll([members, empty]);

      var first = generator.select(empty);
      var second = generator.select(empty);

      expect(first.map((u) => p.basename(u.path)), ['main.dart']);
      expect(second.map((u) => p.basename(u.path)), [
        'main.dart',
      ], reason: 'both clients see the same delta, whoever got there first');
    });

    test('is idempotent, so a rescan does not renumber live wrappers', () {
      generator.registerAll([members, empty]);
      var before = wrapper(0);
      expect(generator.registerAll([members, empty]), isEmpty);
      expect(wrapper(0), before);
    });
  });

  test('runs the published root over its own entry table', () {
    // Keying the subtree by entry, letting the file outrank a runtime switch,
    // calling the wrapper the one way — all of it lives in `CatalogHost`
    // now, the same widget an in-process guest puts in its tree, so the
    // generated file only has to hand it the table and the file's entry.
    generator.select(members);
    expect(
      entrypoint(),
      contains('CatalogHost(fileEntryId: _fileEntryId, entryOf: _entry)'),
    );
    expect(entrypoint(), contains('const _fileEntryId ='));
    expect(entrypoint(), isNot(contains('class _CatalogHost')));
  });

  group('carried imports', () {
    /// Rewrites the demo file and returns the wrapper generated for it.
    String wrapperFor(String source) {
      File(p.join(root.path, 'demo', 'team', 'avatar_tile.dart'))
          .writeAsStringSync(source);
      generator.select(members);
      return wrapper(0);
    }

    test('a directive split across lines is carried whole', () {
      // What the regex this replaced got wrong. `dart format` wraps a directive
      // as soon as a `show` clause makes it long enough, and a line-oriented
      // match then carried a fragment — or, if the URI was on the second line,
      // nothing at all.
      var generated = wrapperFor('''
import 'package:material_ui/material_ui.dart'
    show Widget, Placeholder;

import '../shell.dart'
    show wrapInApp;

Widget avatarTileMembers() => const Placeholder();
''');
      // Re-emitted on one line, because the directive is printed from the AST
      // rather than copied. Its meaning is what has to survive, not its
      // wrapping — and the generated file is not one anybody reads for style.
      expect(
        generated,
        contains(
          "import 'package:material_ui/material_ui.dart' "
          'show Widget, Placeholder;',
        ),
      );
      expect(
        generated,
        contains("import '../../demo/shell.dart' show wrapInApp;"),
      );
    });

    test('a prefix, a hide and a deferred load all survive', () {
      var generated = wrapperFor('''
import 'package:material_ui/material_ui.dart' as m hide Placeholder;
import '../shell.dart' as s;

m.Widget avatarTileMembers() => s.wrapInApp(const m.SizedBox());
''');
      expect(
        generated,
        contains(
          "import 'package:material_ui/material_ui.dart' as m hide Placeholder;",
        ),
      );
      expect(generated, contains("import '../../demo/shell.dart' as s;"));
    });

    test('an export is carried too, and a part is not', () {
      // A part belongs to the library that declares it; carrying one would
      // claim a second owner for the same file.
      var generated = wrapperFor('''
import 'package:material_ui/material_ui.dart';
export '../shell.dart';
part 'avatar_tile.g.dart';

Widget avatarTileMembers() => const Placeholder();
''');
      expect(generated, contains("export '../../demo/shell.dart';"));
      expect(generated, isNot(contains('part ')));
    });
  });

  group('a shell', () {
    const wrapped = CatalogEntry(
      path: 'demo/team/avatar_tile.dart',
      symbol: 'avatarTileMembers',
      name: 'Members',
      annotation: "Demo(name: 'Members', wrapper: wrapInApp)",
    );

    test('is called through preview.wrapper, like any other wrapper', () {
      // There is nothing else left to call. The axes used to live in named
      // parameters that `WidgetWrapper` erases, which is why the shell had to
      // be named here; they are declared inside the shell now, so this file has
      // no reason to know one exists.
      generator.select(wrapped);
      expect(entrypoint(), isNot(contains('fwShellWrap')));
      expect(entrypoint(), isNot(contains('CatalogAxesScope')));
      expect(wrapper(0), isNot(contains('CatalogAxes')));
    });

    test('the annotation carries the wrapper, so the demo imports suffice', () {
      // `wrapInApp` is named in the annotation's source text and resolved by
      // the compiler. The demo's own `import '../shell.dart'` — rebased to
      // resolve from the generated directory — is what puts it in scope. The
      // shell's file contributes nothing of its own, so two files' import sets
      // are never merged and can never collide.
      generator.select(wrapped);
      expect(wrapper(0), contains('wrapper: wrapInApp'));
      expect(wrapper(0), contains("import '../../demo/shell.dart';"));
    });
  });

  group('a preview under lib/', () {
    // The scan covers the whole package now, so previews sit in `lib/` next to
    // the widgets they show. Importing one of those by a relative path would
    // give the compiler a *second* library for the same file — everything else
    // reaches it as `package:…` — and the two share no types at all.
    late Directory libRoot;
    late EntrypointGenerator libGenerator;

    setUp(() {
      libRoot = Directory.systemTemp.createTempSync('fw_entrypoint_lib_test');
      File(p.join(libRoot.path, 'pubspec.yaml'))
          .writeAsStringSync('name: my_app\n');
      var widgets = Directory(p.join(libRoot.path, 'lib', 'widgets'))
        ..createSync(recursive: true);
      File(p.join(widgets.path, 'tile.dart')).writeAsStringSync('''
import 'package:material_ui/material_ui.dart';

import '../theme.dart';
import '../../demo/shell.dart';

Widget tile() => const Placeholder();
''');
      libGenerator = EntrypointGenerator(
        outputDir: p.join(libRoot.path, 'build', 'entrypoint'),
        projectRoot: libRoot.path,
      );
    });

    tearDown(() => libRoot.deleteSync(recursive: true));

    String libWrapper() =>
        File(p.join(libRoot.path, 'build', 'entrypoint', 'entry_0.dart'))
            .readAsStringSync();

    test('is imported by its package: URI, twice', () {
      libGenerator.select(
        const CatalogEntry(
          path: 'lib/widgets/tile.dart',
          symbol: 'tile',
          name: 'Tile',
          annotation: "Preview(name: 'Tile')",
        ),
      );
      expect(
        libWrapper(),
        contains("import 'package:my_app/widgets/tile.dart';"),
      );
      expect(
        libWrapper(),
        contains("import 'package:my_app/widgets/tile.dart' as fw0;"),
      );
      expect(libWrapper(), isNot(contains('../../lib/widgets/tile.dart')));
    });

    test(
      'carries a sibling as package:, and an outsider as a relative path',
      () {
        libGenerator.select(
          const CatalogEntry(
            path: 'lib/widgets/tile.dart',
            symbol: 'tile',
            name: 'Tile',
            annotation: "Preview(name: 'Tile')",
          ),
        );
        // `../theme.dart` is still inside lib/ and gets the same treatment.
        expect(libWrapper(), contains("import 'package:my_app/theme.dart';"));
        // `demo/` is not, and has no package: URI to be spelled with.
        expect(libWrapper(), contains("import '../../demo/shell.dart';"));
      },
    );
  });
}
