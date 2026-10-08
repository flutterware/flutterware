import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/worktrees/providers/git.dart';

/// The fixtures are **recorded from a real repository** (flutterware's own, 14
/// worktrees, 2026-08-10) rather than written from memory of the formats. The
/// parsers are the part that breaks when a git version changes, and a fixture
/// someone invented is a test of what we believed rather than of what git says.
void main() {
  group('for-each-ref', () {
    test('reads every branch tip from one call', () {
      var tips = parseForEachRef(
        'backup/pre-master-rebase\t1785404026\t582b70438e69ba3e2324264272de600ff4de7d55\n'
        'claude/address-space-segment-1702f9\t1786355269\ta74bccb987b5a64205e076295e60d0b2ace5d0a6\n'
        'master\t1786400000\tfac2371df25733026513240b2b3ca5a39e328984\n',
      );

      expect(tips, hasLength(3));
      expect(tips['master']!.sha, startsWith('fac2371'));
      expect(
        tips['claude/address-space-segment-1702f9']!.committedAt,
        DateTime.fromMillisecondsSinceEpoch(1786355269 * 1000),
      );
    });

    test('skips a malformed line rather than losing the list', () {
      var tips = parseForEachRef(
        'good\t1785404026\tabc\nrubbish\n\nalso\tnope\tdef\n',
      );
      expect(tips.keys, ['good']);
    });
  });

  group('status --porcelain=v2', () {
    test('counts every kind of dirt', () {
      // Recorded from a worktree mid-refactor: modified, deleted and untracked.
      var status = parseStatusV2(
        '# branch.oid 7357fe65bb929b95513f493495c7417f4e711534\n'
        '# branch.head claude/icons-launcher-plugin-eval-bf200f\n'
        '1 .M N... 100644 100644 100644 c6d75a0 c6d75a0 app/lib/src/address/address_scope.dart\n'
        '1 D. N... 100644 000000 000000 159d212 0000000 app/lib/src/icon/screen.dart\n'
        '2 R. N... 100644 100644 100644 aaa bbb R100 app/new.dart\tapp/old.dart\n'
        'u UU N... 100644 100644 100644 100644 ccc ddd eee app/conflict.dart\n'
        '? docs/notes.md\n',
      );

      expect(status.dirty, 5);
      expect(status.branch, 'claude/icons-launcher-plugin-eval-bf200f');
      expect(status.head, '7357fe65bb929b95513f493495c7417f4e711534');
    });

    test('a clean worktree is clean', () {
      var status = parseStatusV2(
        '# branch.oid 5603d51a225c2e7da7af96298587bbd18cb65e32\n'
        '# branch.head claude/worktree-explorer-brainstorm-e5efdc\n',
      );
      expect(status.dirty, 0);
    });

    test('no upstream means no ahead/behind — the common case here', () {
      // Not one of the 14 worktrees measured had an upstream configured, which
      // is why the explorer takes ahead/behind from rev-list instead.
      var status = parseStatusV2(
        '# branch.oid abc\n# branch.head claude/whatever\n',
      );
      expect(status.ahead, isNull);
      expect(status.behind, isNull);
    });

    test('reads ahead/behind when there is an upstream', () {
      var status = parseStatusV2(
        '# branch.oid abc\n'
        '# branch.head main\n'
        '# branch.upstream origin/main\n'
        '# branch.ab +3 -1\n',
      );
      expect(status.ahead, 3);
      expect(status.behind, 1);
    });

    test('a detached head has no branch, and an empty repo no oid', () {
      var status = parseStatusV2(
        '# branch.oid (initial)\n# branch.head (detached)\n',
      );
      expect(status.branch, isNull);
      expect(status.head, isNull);
    });
  });

  group('rev-list --left-right --count', () {
    test('left is behind, right is ahead', () {
      expect(parseRevListCounts('0\t2\n'), (0, 2));
      expect(parseRevListCounts('5\t13\n'), (5, 13));
    });

    test('survives output it cannot read', () {
      expect(parseRevListCounts(''), (0, 0));
      expect(parseRevListCounts('nonsense'), (0, 0));
    });
  });

  group('numstat', () {
    test('buckets by top-level directory', () {
      var shape = parseNumstat(
        '5\t5\tapp/lib/src/capture/capture_request.dart\n'
        '16\t9\tapp/lib/src/shell/address_bar.dart\n'
        '40\t2\tdocs/guide.md\n'
        '3\t1\tREADME.md\n',
      );

      expect(shape.files, 4);
      expect(shape.added, 64);
      expect(shape.removed, 17);
      // Ranked by lines touched, not by additions: `docs` moved 42 lines and
      // `app` 35, so docs leads however the two split into +/−. That is what
      // the bar's segment widths are proportional to.
      expect(shape.ranked.map((b) => b.name).take(2), ['docs', 'app']);
      expect(shape.ranked[1].added, 21);
      // A repository-root file gets a bucket it can be named by.
      expect(shape.buckets.map((b) => b.name), contains('·'));
    });

    test('a binary file counts as a file and no lines', () {
      var shape = parseNumstat('-\t-\tassets/logo.png\n2\t0\tlib/main.dart\n');
      expect(shape.files, 2);
      expect(shape.lines, 2);
    });

    test('a rename is bucketed by where the file landed', () {
      expect(bucketFor('lib/old.dart => app/new.dart'), 'app');
      // A move *inside* `app` stays in `app` — the braces carry the prefix, so
      // reading the text after the arrow would call this one `src`.
      expect(bucketFor('app/{lib => src}/thing.dart'), 'app');
      expect(bucketFor('{lib => app}/thing.dart'), 'app');
      // Moved to the repository root.
      expect(bucketFor('{lib => }/thing.dart'), '·');
      expect(bucketFor('pubspec.yaml'), '·');
    });

    test('an empty diff is an empty shape', () {
      expect(parseNumstat('').isEmpty, isTrue);
    });
  });

  group('GitProbe', () {
    test(
      'passes --no-optional-locks so we never fight the user’s git',
      () async {
        var seen = <List<String>>[];
        var probe = GitProbe(
          runProcess: (executable, arguments, {workingDirectory}) async {
            seen.add(arguments);
            return ProcessResult(0, 0, '', '');
          },
        );

        await probe.status('/tmp/wt');
        await probe.branchTips('/tmp/repo');

        expect(seen, hasLength(2));
        for (var arguments in seen) {
          expect(arguments.first, '--no-optional-locks');
        }
      },
    );

    test('a git that is not there yields nothing, not an exception', () async {
      var probe = GitProbe(
        runProcess: (executable, arguments, {workingDirectory}) =>
            throw const ProcessException('git', []),
      );
      expect(await probe.status('/tmp/wt'), isNull);
      expect(await probe.branchTips('/tmp/repo'), isEmpty);
    });

    test(
      'a non-zero exit yields nothing rather than parsing the error',
      () async {
        var probe = GitProbe(
          runProcess: (executable, arguments, {workingDirectory}) async =>
              ProcessResult(0, 128, '', 'fatal: not a git repository'),
        );
        expect(await probe.status('/tmp/wt'), isNull);
      },
    );

    test(
      'the branch diff runs on commits, so it takes the repo directory',
      () async {
        var directories = <String?>[];
        var probe = GitProbe(
          runProcess: (executable, arguments, {workingDirectory}) async {
            directories.add(workingDirectory);
            return ProcessResult(
              0,
              0,
              arguments.contains('rev-list') ? '0\t2\n' : '5\t5\tapp/a.dart\n',
              '',
            );
          },
        );

        var diff = await probe.branchDiff(
          '/tmp/repo',
          base: 'master',
          head: 'feature',
        );

        expect(diff!.ahead, 2);
        expect(diff.behind, 0);
        expect(diff.shape.files, 1);
        expect(directories, everyElement('/tmp/repo'));
      },
    );

    test('falls back through origin/HEAD, main, master', () async {
      var asked = <String>[];
      var probe = GitProbe(
        runProcess: (executable, arguments, {workingDirectory}) async {
          asked.add(arguments.join(' '));
          // No origin/HEAD, no main; master exists.
          if (arguments.contains('symbolic-ref')) {
            return ProcessResult(0, 128, '', '');
          }
          if (arguments.contains('main')) return ProcessResult(0, 1, '', '');
          return ProcessResult(0, 0, 'abc123\n', '');
        },
      );

      expect(await probe.defaultBranch('/tmp/repo'), 'master');
      expect(asked.last, contains('master'));
    });

    test('strips the remote from what origin/HEAD reports', () async {
      var probe = GitProbe(
        runProcess: (executable, arguments, {workingDirectory}) async =>
            ProcessResult(0, 0, 'origin/develop\n', ''),
      );
      expect(await probe.defaultBranch('/tmp/repo'), 'develop');
    });
  });
}
