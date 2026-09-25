import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/previews/authoring.dart';
import 'package:flutterware_app/src/previews/catalog_tree.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/previews_core.dart';
import 'package:flutterware_app/src/plugins/native/previews_results.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:flutterware_app/src/session/job.dart';
import 'package:path/path.dart' as p;

/// Everything asserted here is read through [PluginReport] — the same data the
/// sidebar, `fw` and an agent see. Nothing touches a widget, which is the point:
/// a capability that only exists in the panel is invisible to every other
/// renderer.
///
/// So the subject is [PreviewsCore], not the panel over it. The panel has no
/// report and no `invoke` to test: it builds a widget, and that is all it
/// does.
void main() {
  late Directory root;

  PreviewsCore catalog({
    String? directory,
    List<String>? previewAnnotations,
    List<String> packages = const ['.'],
    String flutterSdkRoot = '/tmp/flutter',
  }) {
    var worktree = Worktree(path: root.path);
    return PreviewsCore(
      PluginHost(
        id: uiCatalogPluginId,
        label: 'Previews',
        worktree: worktree,
        workspace: Workspace(
          root: worktree.path,
          declared: [for (var path in packages) Pkg(path)],
          discovered: packages,
          appContext: AppContext(logger: LogClient.print()),
          flutterSdk: FlutterSdkPath(flutterSdkRoot),
        ),
        config: {
          'packages': [
            for (var path in packages)
              {
                'path': path,
                'directory': ?directory,
                'previewAnnotations': ?previewAnnotations,
              },
          ],
        },
      ),
    );
  }

  void write(String relative, String content) {
    var file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('fw_catalog_plugin_test');
    write('demo/team/avatar_tile.dart', '''
@Preview(name: 'Members')
Widget members() => const Placeholder();

@Preview(name: 'Empty')
Widget empty() => const Placeholder();
''');
    write('demo/counter.dart', '''
@Preview(name: 'Counter')
Widget counter() => const Placeholder();
''');
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('addressFor — the identity every surface carries', () {
    test('is legible: only the # is escaped, the path stays a path', () {
      var subject = catalog();
      var address = subject.addressFor('.', 'demo/counter.dart#counter');
      expect(
        address.toString(),
        'fw:///worktrees/${p.basename(root.path)}/flutterware.previews'
        '/./demo/counter.dart%23counter',
      );
    });

    test('round-trips back to the same segments', () {
      var subject = catalog();
      var address = subject.addressFor('.', 'demo/counter.dart#counter');
      var parsed = Address.parse(address.toString());
      expect(parsed, address);
      expect(parsed.segments, ['.', 'demo', 'counter.dart#counter']);
    });

    test('carries the package, so two packages cannot collide', () {
      var subject = catalog(packages: ['.', 'app']);
      expect(
        subject.addressFor('.', 'demo/x.dart#x'),
        isNot(subject.addressFor('app', 'demo/x.dart#x')),
      );
    });

    test('axes are applied, not identity — bare strips them', () {
      var subject = catalog();
      var sized = subject.addressFor(
        '.',
        'demo/counter.dart#counter',
        axes: {'width': '900', 'height': '700'},
      );
      expect(sized.axes, {'height': '700', 'width': '900'});
      expect(sized.bare, subject.addressFor('.', 'demo/counter.dart#counter'));
      // Different axes are different addresses: a 420-wide capture is not the
      // same artifact as a 900-wide one, and the file names must differ too.
      expect(
        sized,
        isNot(
          subject.addressFor(
            '.',
            'demo/counter.dart#counter',
            axes: {'width': '420', 'height': '320'},
          ),
        ),
      );
    });
  });

  /// Waits for the scan [track] kicked off. It runs in another isolate, so the
  /// report is only meaningful once it lands.
  Future<void> scanned(PreviewsCore subject) async {
    while (subject.isScanning) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('reports nothing and scans nothing until something asks', () {
    var subject = catalog();

    expect(subject.report.status, Status.none);
    expect(subject.entries, isEmpty);
    expect(
      subject.report.children.single.status,
      Status.none,
      reason: 'constructing the plugin must not read the disk',
    );
  });

  test('track starts the scan, and stays quiet about a healthy one', () async {
    var subject = catalog()..track('.');
    await scanned(subject);

    expect(subject.entries, hasLength(3));
    // A count is not news, and it cannot be known before something asks for it.
    // The row keeps its room for what is actually moving.
    expect(subject.report.status, Status.none);
    expect(subject.report.children.single.status, Status.none);
  });

  test('the entries reach a non-GUI renderer through the view', () async {
    var subject = catalog()..track('.');
    await scanned(subject);

    var text = subject.report.toText();
    expect(text, contains('avatar_tile / Members'));
    expect(text, contains('avatar_tile / Empty'));
    expect(text, contains('Counter'));
    expect(text, contains('demo/counter.dart#counter'));
  });

  test('the report round-trips to JSON', () async {
    var subject = catalog()..track('.');
    await scanned(subject);

    var json = subject.report.toJson();
    expect(json['id'], uiCatalogPluginId);
    expect([
      for (var a in json['actions']! as List) (a as Map)['id'],
    ], containsAll(['entries', 'check', 'describe', 'screenshot']));
    expect(json['view'], isNotEmpty);
  });

  test('a package with no demos says so rather than looking healthy', () async {
    var subject = catalog(directory: 'nonexistent')..track('.');
    await scanned(subject);

    expect(subject.report.status.tone, Tone.warn);
    // Names the directory, because "no entries" sends a reader looking for the
    // setting where this *is* the setting.
    expect(subject.report.status.message, 'no entries in nonexistent/');
  });

  test('a directory that is not there reads differently from an empty one', () {
    Future<void> check(String directory, CatalogSetup expected) async {
      var subject = catalog(directory: directory)..track('.');
      await scanned(subject);
      expect(subject.setupFor('.'), expected);
    }

    // A misspelt `directory:` is otherwise indistinguishable from a directory
    // nobody has written a demo in yet — the scanner skips a missing root
    // without a word.
    return Future.wait([
      check('nonexistent', CatalogSetup.missing),
      (() async {
        Directory(p.join(root.path, 'blank')).createSync(recursive: true);
        await check('blank', CatalogSetup.empty);
      })(),
    ]);
  });

  test('a package with no demos never starts a session', () async {
    var subject = catalog(directory: 'nonexistent')..track('.');
    await scanned(subject);

    // The gate the thirty seconds hung on: with nothing to compile, the panel
    // must not ask for a compile loop. A daemon started here binds, scans the
    // same empty directory in a millisecond, refuses, and exits before the
    // client's first poll — which then waits out its full 30s deadline.
    expect(subject.setupFor('.'), isNot(CatalogSetup.ready));
  });

  test('new writes a demo that the scan then finds', () async {
    // A directory that does not exist yet — `new` creates it, which is the
    // case that matters: somebody with no demos has no demo directory either.
    var subject = catalog(directory: 'fresh')..track('.');
    await scanned(subject);
    expect(subject.setupFor('.'), CatalogSetup.missing);

    var result = await subject.newPreview(name: 'Primary Buttons');

    expect(result.file, 'fresh/primary_buttons.dart');
    expect(result.id, 'fresh/primary_buttons.dart#primaryButtons');
    expect(File(p.join(root.path, result.file)).existsSync(), isTrue);
    // The rescan is part of `new`: the entry it just wrote has to be there for
    // the caller that is about to navigate to it.
    expect(subject.setupFor('.'), CatalogSetup.ready);
    expect(subject.entries.map((e) => e.id), [result.id]);
  });

  test('the scaffold it writes is a demo discovery can find', () async {
    // The template is the first thing a new user reads, and it is written in
    // one string far from the scanner that has to recognise it. Verified by
    // scanning what was actually written rather than by eye: a scaffold whose
    // annotation or signature drifts out of what discovery accepts would
    // otherwise go on being handed to exactly the people least able to tell.
    //
    // That it also *renders* is checked by hand rather than here — it needs a
    // compile and a frame. Confirmed on 2026-07-31: `ok: true, errors: []`.
    var subject = catalog(directory: 'fresh')..track('.');
    await scanned(subject);
    var result = await subject.newPreview(name: 'Buttons');

    var entry = subject.entries.singleWhere((e) => e.id == result.id);
    expect(entry.name, 'Buttons');
    expect(entry.symbol, 'buttons');
    // The commented-out knob example must stay a comment: uncommented by the
    // scanner it would be a second entry nobody asked for.
    expect(subject.entries, hasLength(1));
  });

  test('the knob examples in the scaffold are previews too', () async {
    // The test above only checks that the examples stay *commented*. They were
    // also wrong: one of them took a `BuildContext` parameter, which the scan
    // refuses outright — a required parameter makes a target ineligible — so
    // the file handed to somebody writing their first preview taught a form
    // that cannot work, to exactly the people least able to tell.
    //
    // So they are lifted out of the comment and scanned. Every `// @Preview`
    // in the scaffold starts an example and runs to the next blank comment
    // line, which is a shape the scaffold has to keep for this to keep
    // meaning anything — an example that stops being lifted fails the count
    // below rather than passing quietly.
    var examples = <String>[];
    var lines = catalogScaffold('Buttons').split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('// @Preview')) continue;
      var block = <String>[];
      for (var j = i; j < lines.length && lines[j].startsWith('// '); j++) {
        block.add(lines[j].substring(3));
      }
      examples.add(block.join('\n'));
    }
    expect(examples, hasLength(2), reason: 'both knob spellings are examples');

    write('demo/knobs.dart', '''
import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';

${examples.join('\n\n')}
''');
    var subject = catalog()..track('.');
    await scanned(subject);

    expect(
      subject.entries.map((e) => e.name),
      containsAll(['Buttons, parameterised', 'Buttons, from a context']),
    );
    // A knob read off the signature is one the panel can offer without running
    // anything, which is the half of the pair the comment claims is free.
    var parameterised = subject.entries.singleWhere(
      (e) => e.name == 'Buttons, parameterised',
    );
    expect(parameterised.knobs.map((k) => k.name), ['label']);
    expect(subject.report.status.tone, isNot(Tone.error));
  });

  test('the scaffold names a legal Dart identifier, whatever it is called', () {
    // `Switch` is the most likely name in a catalog of previews, and it is a
    // reserved word — `Widget switch()` does not parse. A leading digit is the
    // other way a perfectly reasonable name produces an illegal one.
    expect(catalogSymbolName('Switch'), 'previewSwitch');
    expect(catalogSymbolName('class'), 'previewClass');
    expect(catalogSymbolName('404 page'), 'preview404Page');
    expect(catalogSymbolName('2FA setup'), 'preview2faSetup');
    // Everything else is left alone.
    expect(catalogSymbolName('Primary Buttons'), 'primaryButtons');
    expect(catalogSymbolName('Buttons'), 'buttons');
    // `get` and `required` are built-in identifiers, legal as function names —
    // renaming those would be officious.
    expect(catalogSymbolName('get'), 'get');

    var identifier = RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$');
    for (var name in ['Switch', '404 page', '!!!', 'void', 'yield', '9']) {
      var symbol = catalogSymbolName(name);
      expect(
        identifier.hasMatch(symbol),
        isTrue,
        reason: '"$name" produced "$symbol", which is not an identifier',
      );
    }
  });

  test('new writes anywhere in the package, because everywhere is scanned', () {
    var subject = catalog()..track('.');

    return scanned(subject).then((_) async {
      var beside = await subject.newPreview(
        name: 'Tile',
        file: 'lib/tile.dart',
      );
      expect(beside.id, 'lib/tile.dart#tile');
      expect(
        subject.entries.map((e) => e.id),
        contains(beside.id),
        reason: 'a file the scan can no longer miss',
      );

      // Nothing named a directory, so the default authoring one is where an
      // unnamed file lands.
      var unnamed = await subject.newPreview(name: 'Card');
      expect(unnamed.id, 'demo/card.dart#card');
    });
  });

  test('new refuses a file outside a *declared* directory', () async {
    // Narrowing the scan brings the old failure back, and only then: discovery
    // walks the declared directory and nothing else, so a file written beside
    // it compiles, is never found, and leaves `new` handing back an id and a
    // `next` command for an entry that does not exist.
    var subject = catalog(directory: 'demo')..track('.');
    await scanned(subject);

    await expectLater(
      subject.newPreview(name: 'Tile', file: 'lib/tile.dart'),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          contains('must be under demo/'),
        ),
      ),
    );
    expect(File(p.join(root.path, 'lib', 'tile.dart')).existsSync(), isFalse);

    // A subdirectory of it is fine — grouping demos in folders is normal.
    var nested = await subject.newPreview(
      name: 'Tile',
      file: 'demo/forms/t.dart',
    );
    expect(nested.id, 'demo/forms/t.dart#tile');
    expect(subject.entries.map((e) => e.id), contains(nested.id));
  });

  test('an annotation the scan rejected is reported, not hidden', () async {
    // Zero entries does not mean nobody wrote one. An annotated function with a
    // required parameter is refused *with a diagnostic* and produces no entry —
    // and the empty state used to answer that with "no previews yet, here is how
    // to write one", to somebody who had just written one.
    write('fresh/tile.dart', '''
@Preview(name: 'Tile')
Widget tile(String label) => const Placeholder();
''');
    var subject = catalog(directory: 'fresh')..track('.');
    await scanned(subject);

    expect(subject.entries, isEmpty);
    expect(subject.diagnosticsFor('.'), isNotEmpty);
    expect(
      subject.report.toText(),
      contains('required parameters'),
      reason: 'the reason has to reach the reader that sees no entries',
    );
  });

  test('new refuses to overwrite, and refuses to escape the package', () async {
    var subject = catalog(directory: 'fresh')..track('.');
    await scanned(subject);
    await subject.newPreview(name: 'Buttons');

    await expectLater(
      subject.newPreview(name: 'Buttons'),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      subject.newPreview(name: 'Buttons', file: '../outside.dart'),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('entries reports where it looked, and how to write one', () async {
    var subject = catalog(directory: 'nonexistent');
    var result = (await subject.invoke('entries'))! as CatalogEntriesResult;

    var package = result.packages.single;
    expect(package.directory, 'nonexistent');
    // Only when there are none: the one moment the reader is certainly asking.
    expect(package.authoring, contains('@Preview'));
    expect(package.authoring, contains('nonexistent/'));
  });

  test('directory overrides the demo/ convention', () async {
    write('catalog/thing.dart', '''
@Preview(name: 'Elsewhere')
Widget thing() => const Placeholder();
''');
    var subject = catalog(directory: 'catalog')..track('.');
    await scanned(subject);

    expect(subject.entries.map((e) => e.name), ['Elsewhere']);
  });

  test('a project can register its own annotation', () async {
    // `@Preview`'s dartdoc has always told projects to register a subclass "in
    // previewAnnotations". The field existed on the scanner and on the wire and
    // was reachable from neither the config nor anything a user could write, so
    // the advice named a knob that did not exist.
    write('demo/tablet.dart', '''
@Tablet(name: 'Wide')
Widget wide() => const Placeholder();
''');
    var subject = catalog(previewAnnotations: ['Preview', 'Tablet'])
      ..track('.');
    await scanned(subject);

    expect(subject.entries.map((e) => e.name), contains('Wide'));
    // Listed rather than replaced: the defaults are still in force because the
    // registration named them too, which is what the dartdoc says to do.
    expect(subject.entries.map((e) => e.name), contains('Counter'));
  });

  test('a scan error is reported, not swallowed', () async {
    // Two declared ids that collide leave one entry unreachable, which
    // discovery refuses. The plugin must surface that rather than show a short
    // list. (Stacked annotations no longer do this: they take an ordinal.)
    write('demo/broken.dart', '''
@Preview(name: 'A', id: 'clash')
Widget a() => const Placeholder();

@Preview(name: 'B', id: 'clash')
Widget b() => const Placeholder();
''');
    var subject = catalog()..track('.');
    await scanned(subject);

    expect(subject.report.status.tone, Tone.error);
    expect(subject.report.toText(), contains('same id'));
  });

  test('entries lists everything, with ids and addresses', () async {
    var subject = catalog();
    // No track() first: the action loads what it needs, which is the whole
    // point of it existing. A report would have answered "not computed".
    var result = (await subject.invoke('entries'))! as CatalogEntriesResult;
    var entries = result.packages.single.entries;

    expect(entries, hasLength(3));
    expect(entries.map((e) => e.id), contains('demo/counter.dart#counter'));
    expect(
      entries.first.address,
      startsWith('fw:///'),
      reason: 'an agent should be able to take this straight to screenshot',
    );
    // The wire form is generated from those fields, so it cannot disagree
    // with them — but every surface reads it, so it is worth one look.
    expect(result.toJson()['packages'], isA<List<Object?>>());
  });

  group('the tree entries reports', () {
    /// The shape, as `label` and `label/child` lines.
    List<String> outline(List<CatalogEntryNode> nodes, [String prefix = '']) =>
        [
          for (var node in nodes) ...[
            '$prefix${node.label}',
            ...outline(node.children, '$prefix${node.label}/'),
          ],
        ];

    test('is the arrangement, not the ids re-sorted', () async {
      var subject = catalog();
      var result = (await subject.invoke('entries'))! as CatalogEntriesResult;

      // Every rule at once, and every one of them is a rule a reader
      // reconstructing this from the ids has to guess: `demo` is dropped
      // because every entry shares it, `team` and `avatar_tile` are spelled the
      // way the directory and the file are spelled — nothing in this tree is
      // prettified, which is what stops one row following a rule the row above
      // it does not — a file holding two entries becomes a level of its own,
      // folders come before entries, and both are alphabetical by name.
      expect(outline(result.packages.single.tree), [
        'team',
        'team/avatar_tile',
        'team/avatar_tile/Empty',
        'team/avatar_tile/Members',
        'Counter',
      ]);
    });

    test('names the entry on a leaf and nothing on a branch', () async {
      var subject = catalog();
      var result = (await subject.invoke('entries'))! as CatalogEntriesResult;
      var tree = result.packages.single.tree;

      var counter = tree.singleWhere((node) => node.label == 'Counter');
      expect(counter.entry, 'demo/counter.dart#counter');
      expect(counter.children, isEmpty);

      var team = tree.singleWhere((node) => node.label == 'team');
      expect(team.entry, isNull);
      expect(team.children, isNotEmpty);
    });

    test('is what the panel draws, not a second arrangement', () async {
      var subject = catalog()..track('.');
      await scanned(subject);
      var result = (await subject.invoke('entries'))! as CatalogEntriesResult;

      // The claim the wire form makes is that it *is* `buildCatalogTree` — so
      // it is asserted against that function rather than against a literal,
      // which would pass just as well if the two drifted apart.
      String flatten(List<CatalogNode> nodes) => [
        for (var node in nodes)
          switch (node) {
            CatalogLeaf() => node.label,
            CatalogBranch(:var children) =>
              '${node.label}(${flatten(children)})',
          },
      ].join(',');
      String flattenWire(List<CatalogEntryNode> nodes) => [
        for (var node in nodes)
          node.entry != null
              ? node.label
              : '${node.label}(${flattenWire(node.children)})',
      ].join(',');

      expect(
        flattenWire(result.packages.single.tree),
        flatten(buildCatalogTree(subject.entries)),
      );
    });

    test('a package that could not be scanned has none', () async {
      var subject = catalog(directory: 'nonexistent');
      var result = (await subject.invoke('entries'))! as CatalogEntriesResult;

      expect(result.packages.single.entries, isEmpty);
      expect(result.packages.single.tree, isEmpty);
    });
  });

  test('entries picks up a file added after an earlier scan', () async {
    var subject = catalog()..track('.');
    await scanned(subject);
    expect(subject.entries, hasLength(3));

    write('demo/added.dart', '''
@Preview(name: 'Added')
Widget added() => const Placeholder();
''');
    var result = (await subject.invoke('entries'))! as CatalogEntriesResult;
    expect(
      result.packages.single.entries.map((e) => e.name),
      contains('Added'),
    );
  });

  test('describe answers from the scan, address included', () async {
    var subject = catalog();
    var described =
        (await subject.invoke(
              'describe',
              arguments: {'entry': 'demo/counter.dart#counter'},
            ))!
            as CatalogEntryDescription;

    expect(described.name, 'Counter');
    expect(described.package, '.');
    expect(described.file, 'demo/counter.dart');
    expect(described.symbol, 'counter');
    expect(described.address, startsWith('fw:///'));
    // Knobs are a runtime fact and cost a build, so they are absent until
    // asked for by name — null, not empty, because "none declared" is a
    // different answer from "we did not look".
    expect(described.knobs, isNull);
    expect(described.toJson().containsKey('knobs'), isFalse);
  });

  test('`knobs` and `axes` mean a selection on every action', () async {
    var subject = catalog()..track('.');
    await scanned(subject);

    // The four actions are listed side by side in `fw run previews --help`,
    // so a name that means "include this in the answer" on one and "set this
    // on the render" on the others is knowledge nothing teaches. `describe`
    // asks with `with-`; the bare names are a selection wherever they appear.
    for (var action in subject.report.actions) {
      for (var parameter in action.parameters) {
        if (parameter.id != 'knobs' && parameter.id != 'axes') continue;
        expect(
          parameter.kind,
          isNot(ActionParameterKind.boolean),
          reason: '${action.id} --${parameter.id} is a boolean',
        );
      }
    }

    var describe = subject.report.actions.firstWhere((a) => a.id == 'describe');
    expect([
      for (var parameter in describe.parameters) parameter.id,
    ], containsAll(['with-knobs', 'with-axes']));
  });

  test('describe refuses an entry that is not there', () async {
    expect(
      catalog().invoke('describe', arguments: {'entry': 'nope#nope'}),
      throwsArgumentError,
    );
    expect(catalog().invoke('describe'), throwsArgumentError);
  });

  group('an id a comparison of several packages reports', () {
    // A comparison that spans packages puts the package in front of every id,
    // and those ids are what a reader copies out of its report.
    PreviewsCore twoPackages() {
      write('packages/gallery/demo/card.dart', '''
@Preview(name: 'Card')
Widget card() => const Placeholder();
''');
      write('packages/forms/demo/field.dart', '''
@Preview(name: 'Field')
Widget field() => const Placeholder();
''');
      return catalog(packages: ['packages/gallery', 'packages/forms']);
    }

    test('describes the entry in the package it names', () async {
      var described =
          (await twoPackages().invoke(
                'describe',
                arguments: {'entry': 'packages/forms/demo/field.dart#field'},
              ))!
              as CatalogEntryDescription;

      expect(described.package, 'packages/forms');
      expect(described.id, 'demo/field.dart#field');
      expect(
        described.address,
        '${twoPackages().addressFor('packages/forms', 'demo/field.dart#field')}',
      );
    });

    test("the entry's own id still works", () async {
      var described =
          (await twoPackages().invoke(
                'describe',
                arguments: {'entry': 'demo/field.dart#field'},
              ))!
              as CatalogEntryDescription;

      expect(described.package, 'packages/forms');
    });

    test('has to name the package the entry is in', () async {
      expect(
        twoPackages().invoke(
          'describe',
          arguments: {'entry': 'packages/gallery/demo/field.dart#field'},
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            // Listed the way a comparison prints them, so the list shows which
            // package each is in.
            contains('packages/forms/demo/field.dart#field'),
          ),
        ),
      );
    });
  });

  test('entries refuses a package the plugin does not declare', () async {
    expect(
      catalog().invoke('entries', arguments: {'package': 'nope'}),
      throwsArgumentError,
    );
  });

  test('an unknown action is refused loudly', () async {
    expect(catalog().invoke('nope'), throwsArgumentError);
  });

  test('the screenshot action declares what it needs', () async {
    var subject = catalog()..track('.');
    await scanned(subject);

    var action = subject.report.actions.firstWhere((a) => a.id == 'screenshot');
    var entry = action.parameters.firstWhere((p) => p.id == 'entry');

    expect(entry.kind, ActionParameterKind.choice);
    expect(entry.required, isTrue);
    expect(
      entry.options.map((o) => o.value),
      contains('demo/counter.dart#counter'),
      reason: 'a small catalog inlines its options',
    );
    expect(
      entry.optionsFrom,
      'entries',
      reason:
          'a large one points at the action that returns them all — not at '
          'the report view, which stops at 20',
    );
    expect(
      action.parameters.firstWhere((p) => p.id == 'output').required,
      isFalse,
    );
    var opaque = action.parameters.firstWhere((p) => p.id == 'opaque');
    expect(opaque.kind, ActionParameterKind.boolean);
    expect(
      opaque.defaultValue,
      'false',
      reason: 'a preview is looked at, and its transparency is part of that',
    );
  });

  test('the action survives a JSON round trip', () async {
    var subject = catalog()..track('.');
    await scanned(subject);

    var original = subject.report.actions.firstWhere(
      (a) => a.id == 'screenshot',
    );
    var restored = PluginAction.fromJson(original.toJson());

    expect(restored.parameters, hasLength(original.parameters.length));
    var entry = restored.parameters.first;
    expect(entry.id, 'entry');
    expect(entry.kind, ActionParameterKind.choice);
    expect(entry.optionsFrom, 'entries');
    expect(entry.options.first.label, isNotNull);
  });

  test('screenshot refuses a missing or unknown entry', () async {
    var subject = catalog()..track('.');
    await scanned(subject);

    expect(subject.invoke('screenshot'), throwsArgumentError);
    expect(
      subject.invoke('screenshot', arguments: {'entry': 'nope#nope'}),
      throwsArgumentError,
    );
  });

  /// The collapse: `tree`, `find`, `at` and `errors` became projections of one
  /// `inspect`, because they had the same inputs and the same precondition and
  /// each paid a whole render to answer one question about a frame the others
  /// also had to produce.
  ///
  /// What is asserted here is the *surface* — that the four are gone, that one
  /// action offers all of it, and that a caller who gets a flag wrong is told so
  /// before anything is compiled. What the projections actually *contain* needs
  /// a rendering guest, and is asserted nowhere: `headless_check.dart` covered
  /// it and was deleted, because a guest composites through Metal and a check
  /// that needs one cannot block CI.
  group('inspect — one render, every projection', () {
    test('replaced the four actions rather than joining them', () {
      var ids = [for (var a in catalog().report.actions) a.id];

      expect(ids, contains('inspect'));
      expect(
        ids,
        isNot(anyElement(isIn(['tree', 'find', 'at', 'errors']))),
        reason: 'a collapse that left the originals would be an addition',
      );
      // Kept, deliberately: many entries and a different cost model, and "give
      // me a picture" should not require flags.
      expect(
        ids,
        containsAll(['entries', 'check', 'describe', 'screenshot', 'audit']),
      );
    });

    test('offers every projection, and errors is the one that is on', () {
      var action = catalog().report.actions.firstWhere(
        (a) => a.id == 'inspect',
      );
      var byId = {for (var p in action.parameters) p.id: p};

      expect(
        byId.keys,
        containsAll(['tree', 'find', 'at', 'errors', 'logs', 'screenshot']),
      );
      // No flags is the "is it OK" answer — so this one defaults on and the
      // rest default off. That asymmetry is the design, not an oversight.
      expect(byId['errors']!.defaultValue, 'true');
      for (var off in ['tree', 'logs', 'annotate', 'screenshot']) {
        expect(byId[off]!.defaultValue, 'false', reason: '$off is opt-in');
      }
      // Pinned deliberately. Reading the window somebody has open answers
      // questions nothing else can, and it makes the same command answer
      // differently depending on whether that window is open — which is the
      // wrong default for CI and for a caller that did not know to look.
      expect(
        byId['live']!.defaultValue,
        'false',
        reason: 'attaching to an open session is opt-in',
      );
      expect(byId['entry']!.required, isTrue);
      for (var optional in ['tree', 'find', 'at', 'logs', 'screenshot']) {
        expect(byId[optional]!.required, isFalse);
      }
    });

    test('refuses a missing or unknown entry', () async {
      var subject = catalog()..track('.');
      await scanned(subject);

      expect(subject.invoke('inspect'), throwsArgumentError);
      expect(
        subject.invoke('inspect', arguments: {'entry': 'nope#nope'}),
        throwsArgumentError,
      );
    });

    test(
      'refuses a point that is not one, before it compiles anything',
      () async {
        var subject = catalog()..track('.');
        await scanned(subject);

        // Checked ahead of the guest on purpose: a typo in a flag should cost
        // nothing, and a compile-and-render is the most expensive thing here.
        for (var bad in ['nonsense', '120', '120,', 'a,b', '120,300,5', '']) {
          expect(
            subject.invoke(
              'inspect',
              arguments: {'entry': 'demo/counter.dart#counter', 'at': bad},
            ),
            throwsArgumentError,
            reason: '"$bad" is not a point',
          );
        }
      },
    );

    test('refuses a find that is not text', () async {
      var subject = catalog()..track('.');
      await scanned(subject);

      expect(
        subject.invoke(
          'inspect',
          arguments: {'entry': 'demo/counter.dart#counter', 'find': 12},
        ),
        throwsArgumentError,
      );
    });
  });

  group('build-web', () {
    // Every case here is refused *before* anything is compiled. A web build is
    // tens of seconds, so an argument that cannot work should cost none of it —
    // and the one a user hits most, web not being enabled, is a property of the
    // package rather than of what they typed.

    test('refuses a package that is not declared', () async {
      var subject = catalog();

      expect(
        subject.invoke('build-web', arguments: {'package': 'packages/nope'}),
        throwsArgumentError,
      );
    });

    test('asks which package when the plugin has several', () async {
      var subject = catalog(packages: const ['.', 'packages/ui']);

      // Not "build the first one": two catalogs are declared separately
      // because they are separate, and picking silently produces a page of the
      // wrong demos.
      await expectLater(
        subject.invoke('build-web'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            allOf(contains('packages/ui'), contains('more than one')),
          ),
        ),
      );
    });

    test('refuses a base href that is not a directory path', () async {
      var subject = catalog();

      // `--base-href` is checked here rather than left to the tool, which
      // rejects it only after the whole compile has run.
      await expectLater(
        subject.invoke('build-web', arguments: {'base-href': '/catalog'}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            contains('begins and ends with a slash'),
          ),
        ),
      );
    });

    test('refuses a second build, and teardown stops the first', () async {
      // A fake SDK whose `flutter` ignores its arguments and does not finish, so
      // the first build is genuinely in flight. With a real (missing) path it
      // failed at `Process.start` and cleared the guard before the second call
      // even ran, which made this race rather than test anything.
      var bin = Directory(p.join(root.path, 'fakesdk', 'bin'))
        ..createSync(recursive: true);
      var flutter = File(p.join(bin.path, 'flutter'))
        ..writeAsStringSync('#!/bin/sh\nexec sleep 30\n');
      Process.runSync('chmod', ['+x', flutter.path]);
      Directory(p.join(root.path, 'web')).createSync(recursive: true);

      var subject = catalog(flutterSdkRoot: p.join(root.path, 'fakesdk'));
      var first = subject.buildWeb();
      // Long enough for the child to be up and the guard registered.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Both builds share `build/catalog/web_src`, and the generator deletes it
      // recursively before writing — so a second build started mid-compile pulls
      // the first one's sources out from under it.
      await expectLater(
        subject.buildWeb(),
        throwsA(
          isA<ActionRefusal>().having(
            (e) => e.message,
            'message',
            contains('already running'),
          ),
        ),
      );

      // And closing the worktree ends it. A `flutter build web` child is not
      // reaped when the Dart process exits, so without this it outlives the
      // window and keeps writing into the user's project.
      subject.dispose();
      await expectLater(
        first,
        throwsA(
          isA<ActionRefusal>().having(
            (e) => e.message,
            'message',
            contains('cancelled'),
          ),
        ),
      );
    });

    test('says how to enable web when the package has none', () async {
      var subject = catalog();

      // The fixture has demos and no `web/`, which is the ordinary state of a
      // package nobody has built for the web before. The message has to carry
      // the command, because nothing else on screen will.
      await expectLater(
        subject.invoke('build-web'),
        throwsA(
          isA<ActionRefusal>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('no web/ directory'),
              contains('flutter create --platforms=web'),
            ),
          ),
        ),
      );
    });
  });

  group('search — the palette reaches the whole catalog', () {
    test('an entry says where it is', () async {
      var subject = catalog();
      await subject.computeAll();

      var hits = subject.search('Counter');
      expect(hits, isNotEmpty);
      expect(
        '${hits.first.address}',
        '${subject.addressFor('.', 'demo/counter.dart#counter')}',
      );
    });

    test('search reaches past what the projection lists', () async {
      // Sorted by id, so `zebra` lands last — well past the cut-off, where the
      // default report walk would never see it. This is the shape the bug had
      // on a real catalog: 160 entries, twenty findable, all of them from files
      // beginning `a`–`c`.
      for (var i = 0; i < 40; i++) {
        write('demo/zebra_${i.toString().padLeft(2, '0')}.dart', '''
@Preview(name: 'Zebra $i')
Widget zebra$i() => const Placeholder();
''');
      }

      var subject = catalog();
      await subject.computeAll();

      expect(subject.report.view.toText(), isNot(contains('Zebra 39')));
      expect(
        subject.search('Zebra 39').map((h) => h.title),
        contains('Zebra 39'),
      );
    });

    test('the title is the one the projection shows', () async {
      var subject = catalog();
      await subject.computeAll();

      // Grouped entries read `group / name` in the panel — and the group is
      // the file's own stem, spelled the way the source spells it. A row found
      // in the palette has to read the same way or they look like two things.
      expect(
        subject.search('Members').map((h) => h.title),
        contains('avatar_tile / Members'),
      );
    });

    test('an entry is offered once, not once per surface', () async {
      var subject = catalog();
      await subject.computeAll();

      // `Counter` is inside the projection *and* found by the walk over the
      // scan. The dedupe is what keeps it from arriving twice.
      expect(
        subject.search('Counter').where((h) => h.title == 'Counter').length,
        1,
      );
    });

    test('the plugin row itself is still findable', () async {
      var subject = catalog();
      await subject.computeAll();

      expect(
        subject.search('Previews').map((h) => h.reason),
        contains(SearchReason.plugin),
      );
    });

    test('an empty query finds nothing', () async {
      var subject = catalog();
      await subject.computeAll();

      expect(subject.search('   '), isEmpty);
    });
  });
}
