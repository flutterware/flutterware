import 'dart:io';
import 'dart:typed_data';

import 'package:flutterware/comparison_report.dart';
import 'package:flutterware_app/src/comparison/replay_store.dart';
import 'package:flutterware_app/src/comparison/scenario_alignment.dart';
import 'package:flutterware_app/src/comparison/scenario_diff.dart';
import 'package:flutterware_app/src/comparison/shot_cache.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// One side's replay of one scenario, filed so a push whose inputs did not
/// move replays nothing.
void main() {
  // A key is a sha1, and the store fans out on its first four characters.
  const key = 'a94a8fe5ccb19ba61c4c0873d391e987982fbbd3';
  late Directory root;
  late ShotCache cache;
  late ReplayStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fw_replay_store');
    cache = ShotCache(p.join(root.path, 'shots'));
    store = ReplayStore(cache);
  });
  tearDown(() => root.deleteSync(recursive: true));

  /// A step as a replay leaves it: its frame written by the harness under
  /// the run's own directory.
  ScenarioStepShot replayed(int index, {int value = 7}) {
    var rgba = Uint8List(2 * 2 * 4)..fillRange(0, 16, value);
    var frame = File(p.join(root.path, 'run', '$index.raw'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(rgba);
    return ScenarioStepShot(
      step: AlignableStep(
        index: index,
        position: '#$index',
        parent: index == 1 ? null : index - 1,
        name: 'step $index',
        verb: 'tap',
        target: '"Pay"',
      ),
      rgba: rgba,
      width: 2,
      height: 2,
      tree: InspectNode(
        id: '',
        type: 'Text',
        description: 'Text("Pay")',
        createdByLocalProject: true,
        children: const [],
      ),
      treeFormat: 1,
      texts: const ['Pay'],
      events: const [
        {'channel': 'db', 'title': 'select * from cart'},
      ],
      frame: FrameRef(path: frame.path, width: 2, height: 2),
    );
  }

  test('a filed replay reads back as it was replayed', () {
    store.write(key, [replayed(1), replayed(2, value: 9)]);

    var read = store.read(key)!;

    expect(read.map((s) => s.step.index), [1, 2]);
    var second = read[1];
    expect(second.step.parent, 1);
    expect(second.step.target, '"Pay"');
    expect(second.rgba, Uint8List(16)..fillRange(0, 16, 9));
    expect(second.tree!.description, 'Text("Pay")');
    expect(second.treeFormat, 1);
    expect(second.texts, ['Pay']);
    expect(second.events.single['channel'], 'db');
    expect(File(second.frame!.path).existsSync(), isTrue);
  });

  // A replay's frames are megabytes each, and they are about to be deleted
  // from the run directory anyway.
  test('the frames are moved in, not copied', () {
    var step = replayed(1);

    var filed = store.write(key, [step]).single;

    expect(File(step.frame!.path).existsSync(), isFalse);
    expect(p.isWithin(cache.root, filed.frame!.path), isTrue);
    expect(File(filed.frame!.path).readAsBytesSync(), step.rgba);
  });

  // Most of a scenario's frames are copies of one another, and raw frames are
  // megabytes: filed per step, one suite outgrew the whole store's budget.
  test('a frame filed once is not filed again', () {
    var first = store.write(key, [replayed(1), replayed(2)]);
    const other = '62cdb7020ff920e5aa642c3d4066950dd1f01f4d';
    var second = store.write(other, [replayed(1)]);

    expect(first[0].frame!.path, first[1].frame!.path);
    expect(second.single.frame!.path, first[0].frame!.path);
    expect(
      File(p.join(root.path, 'run', '1.raw')).existsSync(),
      isFalse,
      reason: "the run's own copy of a frame already filed is litter",
    );
    var raw = [
      for (var file in Directory(cache.root).listSync(recursive: true))
        if (file is File && !file.path.endsWith('.json')) file,
    ];
    expect(raw, hasLength(1));
  });

  test('nothing is filed under a key nobody wrote', () {
    expect(store.has(key), isFalse);
    expect(store.read(key), isNull);
  });

  // The frames are shots of their own and are swept on their own. A list
  // naming frames that are gone is a replay that is not there.
  test('a replay with a frame swept away reads as absent', () {
    var filed = store.write(key, [replayed(1), replayed(2)]);
    File(filed.last.frame!.path).deleteSync();

    expect(store.has(key), isTrue);
    expect(store.read(key), isNull);
  });

  // Trees are entries of their own too. Served without one, a step is diffed
  // against no tree at all, and every node on the other side reads as added —
  // measured on a consumer's CI: 1,084 unchanged steps each reported as
  // `added` at the root, from replays whose trees the sweep had taken.
  test('a replay with a tree swept away reads as absent', () {
    store.write(key, [replayed(1), replayed(2)]);
    var trees = [
      for (var file in Directory(cache.root).listSync(recursive: true))
        if (file is File && file.path.endsWith('.tree.json')) file,
    ];
    expect(trees, hasLength(2));
    trees.last.deleteSync();

    expect(store.has(key), isTrue);
    expect(store.read(key), isNull);
  });

  // Reading a replay refreshes the list and the frames; the trees have to be
  // refreshed with them, or they are the first thing a sweep takes.
  test('reading a replay keeps its trees as fresh as its frames', () {
    store.write(key, [replayed(1)]);
    var old = DateTime.now().subtract(const Duration(days: 30));
    for (var file in Directory(cache.root).listSync(recursive: true)) {
      if (file is File) file.setLastModifiedSync(old);
    }

    expect(store.read(key), isNotNull);
    cache.sweep();

    var read = store.read(key);
    expect(read, isNotNull);
    expect(read!.single.tree, isNotNull);
  });

  test('a step with no frame is filed without one', () {
    store.write(key, [
      ScenarioStepShot(
        step: const AlignableStep(index: 1, position: '#1'),
        failure: 'nothing matches "Pay"',
      ),
    ]);

    var read = store.read(key)!.single;

    expect(read.rgba, isNull);
    expect(read.frame, isNull);
    expect(read.failure, 'nothing matches "Pay"');
  });

  // The sweep groups an entry's files by stripping what it knows: a list it
  // did not know would be its own group, and age out apart from nothing.
  test('the list is swept as an entry of its own, by age', () {
    store.write(key, [replayed(1)]);
    var old = DateTime.now().subtract(const Duration(days: 30));
    for (var file in Directory(cache.root).listSync(recursive: true)) {
      if (file is File) file.setLastModifiedSync(old);
    }

    cache.sweep();

    expect(store.has(key), isFalse);
  });
}
