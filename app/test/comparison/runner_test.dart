import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutterware/comparison_report.dart';
import 'package:flutterware_app/src/comparison/cancel.dart';
import 'package:flutterware_app/src/comparison/phase_clock.dart';
import 'package:flutterware_app/src/comparison/runner.dart';
import 'package:flutterware_app/src/comparison/shot_cache.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';

/// The assembly: decide, render what is left, diff, report.
///
/// Driven through a fake side, because none of what can go wrong here — what
/// gets skipped, which side broke, what the index says — needs a compiler or a
/// guest to go wrong, and a real one would make these tests minutes long.
void main() {
  late Directory root;
  late _FakeSide side;
  late ShotCache cache;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fw_runner');
    side = _FakeSide();
    cache = ShotCache(p.join(root.path, 'shots'));
  });
  tearDown(() => root.deleteSync(recursive: true));

  /// A checkout holding [files].
  ///
  /// No SDK is seeded: the runner reads none from a checkout. It keys its cache
  /// on the SDK the session runs under, and both sides render with that one.
  String checkout(String name, Map<String, String> files) {
    var dir = Directory(p.join(root.path, name))..createSync(recursive: true);
    files.forEach((relative, content) {
      File(p.join(dir.path, relative))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    });
    return dir.path;
  }

  Future<ComparisonResult> compare({
    required String base,
    required String head,
    List<String>? only,
    int jobs = 1,
  }) => ComparisonRunner(
    sdk: 'test-sdk',
    headRoot: head,
    baseRoot: base,
    baseSha: 'abc123',
    side: side,
    cache: cache,
    only: only,
    jobs: jobs,
  ).run();

  ComparedItem itemFor(ComparisonResult result, String id) =>
      result.items.firstWhere((item) => item.id == id);

  // The id is the file and the function; the page and the comment are read by
  // people who know the preview by the name the panel shows.
  test('a row carries the name its entry was declared under', () async {
    side.declared['*'] = ['demo/shop.dart#shopMenu', 'demo/shop.dart#plain'];
    side.named['demo/shop.dart#shopMenu'] = 'Menu';

    var result = await compare(
      base: checkout('base', {'demo/shop.dart': '1'}),
      head: checkout('head', {'demo/shop.dart': '2'}),
    );

    expect(itemFor(result, 'demo/shop.dart#shopMenu').label, 'Menu');
    expect(itemFor(result, 'demo/shop.dart#plain').label, isNull);
  });

  // What a tab says before you click it. An estimate that had to render to
  // know would be the work rather than an estimate of it.
  group('the plan costs only hashing', () {
    ComparisonRunner runnerFor({required String base, required String head}) =>
        ComparisonRunner(
          sdk: 'test-sdk',
          headRoot: head,
          baseRoot: base,
          baseSha: 'abc123',
          side: side,
          cache: cache,
        );

    test('it counts what has to be rendered, and renders nothing', () async {
      side.declared['*'] = ['demo/card.dart#card', 'demo/list.dart#list'];

      var plan = await runnerFor(
        base: checkout('base', {
          'demo/card.dart': '1',
          'demo/list.dart': 'same',
        }),
        head: checkout('head', {
          'demo/card.dart': '2',
          'demo/list.dart': 'same',
        }),
      ).plan();

      expect(plan.toRender, ['demo/card.dart#card']);
      expect(plan.total, 2);
      expect(side.renderedFor, isEmpty);
    });

    // Every row that needs no picture is answered here, which is what lets a
    // list draw its full shape while the pictures are still arriving.
    test('added, removed and skipped are settled before any render', () async {
      side.declared[p.join(root.path, 'base')] = ['demo/gone.dart#gone'];
      side.declared[p.join(root.path, 'head')] = ['demo/new.dart#fresh'];

      var plan = await runnerFor(
        base: checkout('base', {'demo/gone.dart': '1'}),
        head: checkout('head', {'demo/new.dart': '1'}),
      ).plan();

      expect(plan.toRender, isEmpty);
      expect(plan.settled.map((i) => '${i.id}:${i.state.name}'), [
        'demo/new.dart#fresh:added',
        'demo/gone.dart#gone:removed',
      ]);
    });

    // The other half of `n rendered`. A branch that touched no widget and
    // rendered the whole catalog anyway is not a slow comparison — it is one
    // path the two checkouts disagree about, and until the plan carried the
    // reason out, nothing downstream could name it.
    test(
      'it says why each entry it could not answer has to be rendered',
      () async {
        side.declared['*'] = ['demo/card.dart#card', 'demo/list.dart#list'];

        // The consumer's case exactly: no source moved, and one file both
        // checkouts disagree about — a lockfile the base's own `pub get`
        // rewrote. It is a pixel input, so it is in every closure, so every
        // entry renders and the diff explains none of it.
        var plan = await runnerFor(
          base: checkout('base', {
            'demo/card.dart': 'same',
            'demo/list.dart': 'same',
            'pubspec.lock': 'one',
          }),
          head: checkout('head', {
            'demo/card.dart': 'same',
            'demo/list.dart': 'same',
            'pubspec.lock': 'two',
          }),
        ).plan();

        expect(plan.toRender, hasLength(2));
        // Folded: one cause is one line, however many entries carry it.
        expect(plan.because, {'pubspec.lock differs': 2});
      },
    );

    test('a reason survives into the half a reader gets', () async {
      side.declared['*'] = ['demo/card.dart#card'];

      var result = await compare(
        base: checkout('base', {'demo/card.dart': '1'}),
        head: checkout('head', {'demo/card.dart': '2'}),
      );

      expect(result.because, {'demo/card.dart differs': 1});
      expect(result.toJson()['because'], {'demo/card.dart differs': 1});
    });

    // Nothing to explain is nothing in the file: a reader that finds the key
    // knows the skip rule gave up on something.
    test('a comparison that skipped everything explains nothing', () async {
      var files = {'demo/card.dart': '1'};
      side.declared['*'] = ['demo/card.dart#card'];

      var result = await compare(
        base: checkout('base', files),
        head: checkout('head', files),
      );

      expect(result.because, isEmpty);
      expect(result.toJson().containsKey('because'), isFalse);
    });

    test('a plan already made is not made again', () async {
      side.declared['*'] = ['demo/card.dart#card'];
      var runner = runnerFor(
        base: checkout('base', {'demo/card.dart': '1'}),
        head: checkout('head', {'demo/card.dart': '2'}),
      );

      var plan = await runner.plan();
      var result = await runner.run(from: plan);

      expect(result.rendered, 2);
      expect(itemFor(result, 'demo/card.dart#card').state, isNot(isNull));
    });
  });

  group('the skip rule decides before anything renders', () {
    test('a branch that changed nothing renders nothing', () async {
      var files = {'demo/card.dart': 'const card = 1;'};
      side.declared['*'] = ['demo/card.dart#card'];

      var result = await compare(
        base: checkout('base', files),
        head: checkout('head', files),
      );

      expect(result.rendered, 0);
      expect(side.renderedFor, isEmpty);
      expect(
        itemFor(result, 'demo/card.dart#card').state,
        ComparedState.skipped,
      );
    });

    test('a touched entry is rendered on both sides', () async {
      side.declared['*'] = ['demo/card.dart#card'];

      var result = await compare(
        base: checkout('base', {'demo/card.dart': 'const card = 1;'}),
        head: checkout('head', {'demo/card.dart': 'const card = 2;'}),
      );

      expect(result.rendered, 2);
      expect(side.renderedFor, hasLength(2));
    });

    // The entry's own file is untouched; something three imports away moved.
    test('a change in the closure counts, not just in the entry', () async {
      side.declared['*'] = ['demo/card.dart#card'];
      var files = {'demo/card.dart': "import '../lib/theme.dart';"};

      var result = await compare(
        base: checkout('base', {...files, 'lib/theme.dart': 'blue'}),
        head: checkout('head', {...files, 'lib/theme.dart': 'green'}),
      );

      expect(result.rendered, 2);
    });

    // An entry id is relative to its *package*; a checkout can hold several.
    // Deriving the file from the id alone made every entry in a workspace look
    // like a missing file — which hashes the same on both sides, so a
    // genuinely changed preview was skipped and reported as no change at all.
    // Found by running it, not by testing it.
    test(
      'an entry inside a workspace package is found on both sides',
      () async {
        side = _FakeSide(packagePath: 'fixtures/probe_app');
        side.declared['*'] = ['demo/card.dart#card'];

        var result = await compare(
          base: checkout('base', {'fixtures/probe_app/demo/card.dart': '1'}),
          head: checkout('head', {'fixtures/probe_app/demo/card.dart': '2'}),
        );

        expect(result.rendered, 2);
        expect(
          itemFor(result, 'demo/card.dart#card').state,
          isNot(ComparedState.skipped),
        );
      },
    );

    test('only the named entries are looked at', () async {
      side.declared['*'] = ['demo/a.dart#a', 'demo/b.dart#b'];

      var result = await compare(
        base: checkout('base', {'demo/a.dart': '1', 'demo/b.dart': '1'}),
        head: checkout('head', {'demo/a.dart': '2', 'demo/b.dart': '2'}),
        only: ['demo/a.dart#a'],
      );

      expect(result.items.map((item) => item.id), ['demo/a.dart#a']);
    });
  });

  // A verdict and a picture are two different needs, and this row has only
  // one of them settled without work. The picture used to be skipped with the
  // verdict, so the page said "Neither side rendered" over a preview the
  // branch had just introduced — which is the row somebody opened the page
  // for, with its head side sitting in the checkout.
  group('an entry only one side has', () {
    // The files exist where the side declares them: an added entry's closure
    // is a file the base does not have, and that difference is what keeps its
    // two keys apart.
    late String base;
    late String head;

    setUp(() {
      side.declared[p.join(root.path, 'head')] = [
        'demo/a.dart#a',
        'demo/new.dart#fresh',
      ];
      side.declared[p.join(root.path, 'base')] = [
        'demo/a.dart#a',
        'demo/old.dart#gone',
      ];
      base = checkout('base', {'demo/a.dart': '1', 'demo/old.dart': '1'});
      head = checkout('head', {'demo/a.dart': '1', 'demo/new.dart': '1'});
    });

    test('is added or removed without being compared', () async {
      var result = await compare(base: base, head: head);

      expect(itemFor(result, 'demo/new.dart#fresh').state, ComparedState.added);
      expect(
        itemFor(result, 'demo/old.dart#gone').state,
        ComparedState.removed,
      );
    });

    test('is drawn on the side that has it, and only that side', () async {
      await compare(base: base, head: head);

      expect(side.renderedFor, [
        ('demo/old.dart#gone', base),
        ('demo/new.dart#fresh', head),
      ]);
    });

    test('carries the keys its picture lands under', () async {
      var result = await compare(base: base, head: head);

      var added = itemFor(result, 'demo/new.dart#fresh');
      expect(added.shots, isNotNull);
      // The head key has bytes; the base key is the one for a file that side
      // does not have, and nothing ever writes under it — which is what the
      // stage reads as "this side rendered nothing".
      expect(cache.has(added.shots!.head), isTrue);
      expect(cache.has(added.shots!.base), isFalse);
    });

    // Before these rows were given pictures, a side nothing needed to render
    // was never compiled — so a branch that only deleted an entry compared
    // cleanly against a base that could not be built. Drawing the deleted
    // entry must not be what refuses it.
    test(
      'whose side does not compile costs its picture, not the run',
      () async {
        side.declared[p.join(root.path, 'head')] = ['demo/a.dart#a'];
        side.uncompilable.add(base);

        var result = await compare(base: base, head: head);

        expect(
          itemFor(result, 'demo/old.dart#gone').state,
          ComparedState.removed,
        );
      },
    );

    test('still refuses when the side was needed for a comparison', () async {
      base = checkout('base', {'demo/a.dart': '2', 'demo/old.dart': '1'});
      side.uncompilable.add(base);

      expect(
        () => compare(base: base, head: head),
        throwsA(isA<ComparisonRefused>()),
      );
    });

    // The picture is a bonus; the verdict must not wait for it.
    test('is settled by the plan before anything renders', () async {
      var plan = await ComparisonRunner(
        sdk: 'test-sdk',
        headRoot: head,
        baseRoot: base,
        baseSha: 'abc123',
        side: side,
        cache: cache,
      ).plan();

      expect(plan.toRender, isEmpty);
      expect(plan.onlyOnHead, ['demo/new.dart#fresh']);
      expect(plan.onlyOnBase, ['demo/old.dart#gone']);
      expect(side.renderedFor, isEmpty);
    });
  });

  test('the run records where its time went, per side', () async {
    side.declared['*'] = ['demo/a.dart#a', 'demo/b.dart#b'];
    var clock = PhaseClock();

    await ComparisonRunner(
      sdk: 'test-sdk',
      headRoot: checkout('head', {'demo/a.dart': '2', 'demo/b.dart': '2'}),
      baseRoot: checkout('base', {'demo/a.dart': '1', 'demo/b.dart': '1'}),
      baseSha: 'abc123',
      side: side,
      cache: cache,
      clock: clock.within('app', qualify: false),
    ).run();

    var phases = clock.timings.phases;
    String where(ComparisonPhase phase) =>
        [phase.name, ?phase.side, ?phase.package].join(' ');
    expect(phases.map(where), [
      'previews.plan app',
      'previews.compile base app',
      'previews.render base app',
      'previews.compile head app',
      'previews.render head app',
      'previews.compare app',
    ]);
  });

  group('with jobs', () {
    Map<String, String> files(String value) => {
      for (var name in ['a', 'b', 'c']) 'demo/$name.dart': value,
    };
    var declared = [
      for (var name in ['a', 'b', 'c']) 'demo/$name.dart#$name',
    ];

    test('both sides render at once, each across that many guests', () async {
      side.declared['*'] = declared;
      var bothIn = Completer<void>();
      var asked = 0;
      // Neither side may start until both have been asked, which a base pass
      // followed by a head pass never does — hence the deadline.
      side.gate = (_) async {
        if (++asked == 2) bothIn.complete();
        await bothIn.future;
      };

      await compare(
        base: checkout('base', files('1')),
        head: checkout('head', files('2')),
        jobs: 3,
      ).timeout(const Duration(seconds: 5));

      expect(side.guestsAsked, [3, 3]);
    });

    test('the verdict is the one a serial run reaches', () async {
      side.declared['*'] = declared;
      side.frame = (entry, checkout) => _frame(
        entry,
        value: checkout.endsWith('head') && entry.startsWith('demo/a') ? 9 : 1,
      );
      side.fatal['demo/c.dart#c'] = 'threw while building';
      var base = checkout('base', files('1'));
      var head = checkout('head', files('2'));

      List<(String, ComparedState)> verdict(ComparisonResult result) => [
        for (var item in result.items) (item.id, item.state),
      ];

      var serial = await compare(base: base, head: head);
      cache = ShotCache(p.join(root.path, 'pooled'));
      var pooled = await compare(base: base, head: head, jobs: 2);

      expect(verdict(pooled), verdict(serial));
      expect(pooled.rendered, serial.rendered);
    });
  });

  group('the channels reach the verdict', () {
    test('two identical pictures of changed code are still the same', () async {
      side.declared['*'] = ['demo/card.dart#card'];
      side.frame = (entry, checkout) => _frame(entry, value: 10);

      var result = await compare(
        base: checkout('base', {'demo/card.dart': '1'}),
        head: checkout('head', {'demo/card.dart': '2'}),
      );

      expect(result.rendered, 2);
      expect(itemFor(result, 'demo/card.dart#card').state, ComparedState.same);
    });

    test('different pixels are a change, with the region named', () async {
      side.declared['*'] = ['demo/card.dart#card'];
      side.frame = (entry, checkout) =>
          _frame(entry, value: checkout.endsWith('head') ? 200 : 10);

      var result = await compare(
        base: checkout('base', {'demo/card.dart': '1'}),
        head: checkout('head', {'demo/card.dart': '2'}),
      );

      var item = itemFor(result, 'demo/card.dart#card');
      expect(item.state, ComparedState.changed);
      expect(item.pixels!.diff.clusters, isNotEmpty);
    });

    test('the tree explains the pixels', () async {
      side.declared['*'] = ['demo/card.dart#card'];
      side.frame = (entry, checkout) => _frame(
        entry,
        value: checkout.endsWith('head') ? 200 : 10,
        description: checkout.endsWith('head') ? 'Text("Pay")' : 'Text("Save")',
      );

      var result = await compare(
        base: checkout('base', {'demo/card.dart': '1'}),
        head: checkout('head', {'demo/card.dart': '2'}),
      );

      var deltas = itemFor(result, 'demo/card.dart#card').tree!.diff.deltas;
      expect(deltas.single.head, 'Text("Pay")');
    });
  });

  // A complaint about a frame is not the absence of one. This used to drop
  // any frame that reported anything, which threw away a perfectly comparable
  // screen because something overflowed by 1.5 pixels.
  group('a frame that was drawn anyway', () {
    test('an overflow is compared, and carried as the note', () async {
      side.declared['*'] = ['demo/card.dart#card'];
      side.complain = (entry, checkout) => checkout.endsWith('head')
          ? 'A RenderFlex overflowed by 1.5 pixels on the right.'
          : null;

      var result = await compare(
        base: checkout('base', {'demo/card.dart': '1'}),
        head: checkout('head', {'demo/card.dart': '2'}),
      );

      var item = itemFor(result, 'demo/card.dart#card');
      expect(item.state, isNot(ComparedState.failed));
      expect(item.pixels, isNotNull);
      expect(item.note, contains('overflowed'));
    });

    // A build that throws leaves an error screen where the entry was, and
    // comparing one of those against a working screen measures nothing.
    test('a build that threw is still not a frame', () async {
      side.declared['*'] = ['demo/card.dart#card'];
      side.fatal['demo/card.dart#card'] = 'Bad state: no';

      var result = await compare(
        base: checkout('base', {'demo/card.dart': '1'}),
        head: checkout('head', {'demo/card.dart': '2'}),
      );

      expect(
        itemFor(result, 'demo/card.dart#card').state,
        ComparedState.failed,
      );
    });

    // Both sides overflowing is the state of the world, not something this
    // branch did.
    test('a complaint both sides make is not a note', () async {
      side.declared['*'] = ['demo/card.dart#card'];
      side.complain = (entry, checkout) => 'overflowed by 1.5 pixels';

      var result = await compare(
        base: checkout('base', {'demo/card.dart': '1'}),
        head: checkout('head', {'demo/card.dart': '2'}),
      );

      expect(itemFor(result, 'demo/card.dart#card').note, isNull);
    });
  });

  group('the severity ladder', () {
    test('an entry that stopped rendering is the loudest row', () async {
      side.declared['*'] = ['demo/a.dart#a', 'demo/b.dart#b'];
      side.refuse = (entry, checkout) =>
          entry == 'demo/b.dart#b' && checkout.endsWith('head')
          ? 'threw while building'
          : null;

      var result = await compare(
        base: checkout('base', {'demo/a.dart': '1', 'demo/b.dart': '1'}),
        head: checkout('head', {'demo/a.dart': '2', 'demo/b.dart': '2'}),
      );

      expect(result.items.first.id, 'demo/b.dart#b');
      expect(result.items.first.state, ComparedState.broke);
      expect(result.items.first.note, contains('threw'));
    });

    test('an entry already broken on base says so quietly', () async {
      side.declared['*'] = ['demo/a.dart#a'];
      side.refuse = (entry, checkout) =>
          checkout.endsWith('base') ? 'was broken' : null;

      var result = await compare(
        base: checkout('base', {'demo/a.dart': '1'}),
        head: checkout('head', {'demo/a.dart': '2'}),
      );

      expect(result.items.single.state, ComparedState.wasBroken);
    });
  });

  test('a second run against the same base renders only the head', () async {
    side.declared['*'] = ['demo/card.dart#card'];
    var base = checkout('base', {'demo/card.dart': '1'});

    await compare(base: base, head: checkout('head', {'demo/card.dart': '2'}));
    side.renderedFor.clear();
    await compare(base: base, head: checkout('head2', {'demo/card.dart': '3'}));

    expect(side.renderedFor.map((r) => r.$2), everyElement(endsWith('head2')));
  });

  group('the run streams', () {
    // The design promise this repays: the interesting rows must not arrive in
    // one burst at the end. Once an entry's head frame lands, its verdict is
    // answerable — and said — while its neighbours are still rendering.
    test('a verdict lands before the next entry renders', () async {
      side.declared['*'] = ['demo/a.dart#a', 'demo/b.dart#b'];
      var events = <String>[];
      var inner = side.frame;
      side.frame = (entry, checkout) {
        events.add('render $entry ${p.basename(checkout)}');
        return inner(entry, checkout);
      };

      await ComparisonRunner(
        sdk: 'test-sdk',
        headRoot: checkout('head', {'demo/a.dart': '2', 'demo/b.dart': '2'}),
        baseRoot: checkout('base', {'demo/a.dart': '1', 'demo/b.dart': '1'}),
        baseSha: 'abc123',
        side: side,
        cache: cache,
        onItem: (item) => events.add('item ${item.id}'),
      ).run();

      expect(
        events.indexOf('item demo/a.dart#a'),
        lessThan(events.indexOf('render demo/b.dart#b head')),
      );
    });

    test('the plan is handed over before anything renders', () async {
      side.declared['*'] = ['demo/a.dart#a', 'demo/b.dart#b'];
      ComparisonPlan? seen;

      await ComparisonRunner(
        sdk: 'test-sdk',
        headRoot: checkout('head', {'demo/a.dart': '2', 'demo/b.dart': 'x'}),
        baseRoot: checkout('base', {'demo/a.dart': '1', 'demo/b.dart': 'x'}),
        baseSha: 'abc123',
        side: side,
        cache: cache,
        onPlan: (plan) {
          seen = plan;
          expect(side.renderedFor, isEmpty);
        },
      ).run();

      expect(seen!.total, 2);
      expect(seen!.toRender, ['demo/a.dart#a']);
    });

    test('progress counts each side as it renders', () async {
      side.declared['*'] = ['demo/a.dart#a'];
      var lines = <String>[];

      await ComparisonRunner(
        sdk: 'test-sdk',
        headRoot: checkout('head', {'demo/a.dart': '2'}),
        baseRoot: checkout('base', {'demo/a.dart': '1'}),
        baseSha: 'abc123',
        side: side,
        cache: cache,
        onProgress: lines.add,
      ).run();

      expect(lines, contains('rendering the base side · 1 of 1'));
      expect(lines, contains('rendering this side · 1 of 1'));
    });

    // Stopping is not an error: what was answered stays answered, and the
    // caller hears [ComparisonCancelled] rather than a refusal.
    test('a cancel stops at the next frame and keeps what landed', () async {
      side.declared['*'] = ['demo/a.dart#a', 'demo/b.dart#b'];
      var cancel = CancelToken();
      var reported = <String>[];

      var run = ComparisonRunner(
        sdk: 'test-sdk',
        headRoot: checkout('head', {'demo/a.dart': '2', 'demo/b.dart': '2'}),
        baseRoot: checkout('base', {'demo/a.dart': '1', 'demo/b.dart': '1'}),
        baseSha: 'abc123',
        side: side,
        cache: cache,
        cancel: cancel,
        onItem: (item) {
          reported.add(item.id);
          cancel.cancel();
        },
      ).run();

      await expectLater(run, throwsA(isA<ComparisonCancelled>()));
      expect(reported, isNotEmpty);
    });
  });

  test('the half reports what it did and did not do', () async {
    side.declared['*'] = ['demo/card.dart#card'];
    var result = await compare(
      base: checkout('base', {'demo/card.dart': '1'}),
      head: checkout('head', {'demo/card.dart': '1'}),
    );

    var json = result.toJson();

    expect(json['rendered'], 0);
    expect((json['counts']! as Map)['skipped'], 1);
    expect((json['items']! as List).single, containsPair('state', 'skipped'));
  });

  // Each side is read by its own checkout's `package:flutterware`, so a branch
  // that bumps it compares two walks. What they disagree about is how a widget
  // is described, and that is not the branch's doing.
  group('two walks', () {
    RenderedEntry read(String entry, {int? format, String? description}) {
      var frame = _frame(entry, description: description);
      return RenderedEntry(
        entryId: entry,
        rgba: frame.rgba,
        width: frame.width,
        height: frame.height,
        tree: frame.tree,
        treeFormat: format,
      );
    }

    test('a tree read differently does not make a finding', () async {
      side.declared['*'] = ['demo/card.dart#card'];
      var base = checkout('base', {'demo/card.dart': '1'});
      side.frame = (entry, at) => at == base
          ? read(entry)
          : read(entry, format: 1, description: 'Card("Pay")');

      var result = await compare(
        base: base,
        head: checkout('head', {'demo/card.dart': '2'}),
      );

      var card = itemFor(result, 'demo/card.dart#card');
      expect(card.state, ComparedState.same);
      expect(card.tree!.skewed, isTrue);
    });

    test('one walk on both sides still reports the tree', () async {
      side.declared['*'] = ['demo/card.dart#card'];
      var base = checkout('base', {'demo/card.dart': '1'});
      side.frame = (entry, at) => at == base
          ? read(entry, format: 1)
          : read(entry, format: 1, description: 'Card("Pay")');

      var result = await compare(
        base: base,
        head: checkout('head', {'demo/card.dart': '2'}),
      );

      expect(
        itemFor(result, 'demo/card.dart#card').state,
        ComparedState.changed,
      );
    });
  });
}

Uint8List _bytes(int value) =>
    Uint8List(8 * 8 * 4)..fillRange(0, 8 * 8 * 4, value);

RenderedEntry _frame(String entry, {int value = 0, String? description}) =>
    RenderedEntry(
      entryId: entry,
      rgba: _bytes(value),
      width: 8,
      height: 8,
      tree: InspectNode(
        id: '',
        type: 'Card',
        description: description,
        createdByLocalProject: true,
        children: const [],
      ),
    );

class _FakeSide implements ComparisonSide {
  _FakeSide({this.packagePath = '.'});

  /// Where the package sits inside each checkout — `.` for a single-package
  /// project, `fixtures/probe_app` in a workspace.
  @override
  final String packagePath;

  @override
  String fileOf(String entryId) {
    var hash = entryId.indexOf('#');
    var file = hash < 0 ? entryId : entryId.substring(0, hash);
    return p.normalize(p.join(packagePath, file));
  }

  /// Checkout path → entry ids, or `'*'` for both sides.
  final declared = <String, List<String>>{};

  /// (entry, checkout) pairs this was asked to render.
  final renderedFor = <(String, String)>[];

  RenderedEntry Function(String entry, String checkout) frame = (
    entry,
    checkout,
  ) => _frame(entry);

  String? Function(String entry, String checkout)? refuse;

  /// What the framework said while drawing it anyway, per side — a complaint
  /// about a frame rather than the absence of one.
  String? Function(String entry, String checkout)? complain;

  /// Entry id → a build that threw, leaving no frame.
  final fatal = <String, String>{};

  /// Checkouts whose whole catalog does not compile.
  final uncompilable = <String>{};

  @override
  Future<List<String>> entries(String checkout) async =>
      declared[checkout] ?? declared['*'] ?? const [];

  /// Entry id → its declared name, for both sides.
  final named = <String, String>{};

  @override
  Future<Map<String, String>> names(String checkout) async => named;

  /// How many guests each render was allowed, in the order asked.
  final guestsAsked = <int>[];

  /// Held open at the start of a render, so a test can prove two are in
  /// flight at once rather than infer it from an order.
  Future<void> Function(String checkout)? gate;

  @override
  Future<Map<String, String>> render({
    required String checkout,
    required List<String> entryIds,
    required Future<void> Function(RenderedEntry frame) onFrame,
    int guests = 1,
    void Function(Duration elapsed)? onCompiled,
  }) async {
    guestsAsked.add(guests);
    await gate?.call(checkout);
    onCompiled?.call(Duration.zero);
    if (uncompilable.contains(checkout)) {
      throw SideDidNotCompile('lib/a.dart:1:1: Error: not found');
    }
    var failed = <String, String>{};
    for (var entry in entryIds) {
      renderedFor.add((entry, checkout));
      if (refuse?.call(entry, checkout) case var why?) {
        failed[entry] = why;
        continue;
      }
      if (fatal[entry] case var why?) {
        failed[entry] = why;
        continue;
      }
      var drawn = frame(entry, checkout);
      await onFrame(
        RenderedEntry(
          entryId: drawn.entryId,
          rgba: drawn.rgba,
          width: drawn.width,
          height: drawn.height,
          tree: drawn.tree,
          treeFormat: drawn.treeFormat,
          complaint: complain?.call(entry, checkout),
        ),
      );
    }
    return failed;
  }
}
