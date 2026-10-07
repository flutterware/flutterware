import 'dart:io';

import 'package:flutterware/comparison_report.dart';
import 'package:flutterware_app/src/comparison/artifact.dart';
import 'package:flutterware_app/src/comparison/runner.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// What comparisons leave behind, and what they say about how they measured.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('fw_leftovers'));
  tearDown(() => root.deleteSync(recursive: true));

  // A CI host runs nothing but `fw compare`, and only the studio's panel ever
  // swept — so a host restoring its cache between jobs grew without bound.
  group('the comparison directories', () {
    Directory dir(String name, {required DateTime written}) {
      var directory = Directory(p.join(root.path, 'comparisons', name))
        ..createSync(recursive: true);
      File(p.join(directory.path, 'index.json'))
        ..writeAsStringSync('{}')
        ..setLastModifiedSync(written);
      File(p.join(directory.path, 'scenarios', 'shop', 'head', '1.raw'))
        ..createSync(recursive: true)
        ..setLastModifiedSync(written);
      return directory;
    }

    test('one nothing has written in a fortnight is dropped', () {
      var now = DateTime(2026, 9, 11);
      var stale = dir(
        'job-41',
        written: now.subtract(const Duration(days: 20)),
      );
      var fresh = dir('job-42', written: now.subtract(const Duration(days: 2)));

      var swept = sweepComparisonDirs(root.path, now: now);

      expect(swept, 1);
      expect(stale.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
    });

    // A run rewrites `index.json` in place, which moves the file's mtime and
    // not the directory's.
    test('it is judged by what the last run wrote, not by the directory', () {
      var now = DateTime(2026, 9, 11);
      var kept = dir('mine', written: now);

      expect(
        sweepComparisonDirs(root.path, now: now.add(const Duration(days: 1))),
        0,
      );
      expect(kept.existsSync(), isTrue);
    });

    // Frames were written under the worktree's directory by every run and
    // cleared by none; they go to the store now, and the tree an earlier
    // version left is reclaimed the first time a sweep meets it.
    test('a frames tree an earlier version left is dropped', () {
      var now = DateTime(2026, 9, 11);
      var kept = dir('mine', written: now.subtract(const Duration(days: 2)));

      sweepComparisonDirs(root.path, now: now);

      expect(kept.existsSync(), isTrue);
      expect(Directory(p.join(kept.path, 'scenarios')).existsSync(), isFalse);
    });

    test('one an older flutterware is writing this moment is left', () {
      var now = DateTime(2026, 9, 11);
      var kept = dir('mine', written: now.subtract(const Duration(hours: 1)));

      sweepComparisonDirs(root.path, now: now);

      expect(Directory(p.join(kept.path, 'scenarios')).existsSync(), isTrue);
    });

    test('a cache with no comparisons in it is nothing to sweep', () {
      expect(sweepComparisonDirs(root.path), 0);
    });
  });

  group('the caveats', () {
    InspectNode node(String? description) => InspectNode(
      id: '',
      type: 'Text',
      description: description,
      createdByLocalProject: true,
      children: const [],
    );

    ComparisonResult previews(List<ComparedItem> items) => ComparisonResult(
      items: items,
      baseSha: 'abc',
      headRoot: '/head',
      elapsed: Duration.zero,
      rendered: 0,
    );

    test('say how many rows had tree differences left out', () {
      var skewed = ComparedItem.of(
        id: 'a#b',
        tree: TreeDiff.of(node(null), node('Text("Pay")')),
        treeSkewed: true,
      );

      var caveats = comparisonCaveats(previews: previews([skewed, skewed]));

      expect(caveats.single, contains('2 rows'));
    });

    test('say nothing when both sides were read the same way', () {
      var item = ComparedItem.of(
        id: 'a#b',
        tree: TreeDiff.of(node(null), node('Text("Pay")')),
      );

      expect(comparisonCaveats(previews: previews([item])), isEmpty);
    });

    test('carry the SDK sentence they were handed', () {
      expect(comparisonCaveats(previews: previews(const []), sdk: 'two SDKs'), [
        'two SDKs',
      ]);
    });

    test('ride the artifact into the published reader', () {
      var artifact = ComparisonArtifact(
        previews: previews(const []),
        caveats: const ['two SDKs'],
      );

      expect(ComparisonIndex.fromJson(artifact.toJson()).caveats, ['two SDKs']);
      expect(
        ComparisonIndex.fromJson(
          ComparisonArtifact(previews: previews(const [])).toJson(),
        ).caveats,
        isEmpty,
      );
    });
  });
}
