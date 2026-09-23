import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/plugins/native/dev_stack_results.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/capture/settle.dart';
import 'package:flutterware_app/src/worktrees/facts.dart';
import 'package:flutterware_app/src/worktrees/facts_controller.dart';
import 'package:flutterware_app/src/worktrees/facts_probe.dart';
import 'package:flutterware_app/src/worktrees/facts_store.dart';
import 'package:flutterware_app/src/worktrees/facts_text.dart';
import 'package:flutterware_app/src/worktrees/explorer_row.dart';
import 'package:flutterware_app/src/worktrees/providers/stack.dart';
import 'package:flutterware_app/src/worktrees/watchers.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:path/path.dart' as p;

/// The explorer's stack column.
///
/// The screen answers "which of my checkouts is holding the port block".
/// That question is the whole reason per-worktree port allocation exists, and
/// until this column there was no way to ask it except to open eight checkouts
/// one at a time.
///
/// What is guarded here is the bargain that makes it affordable: it is a
/// **cache read and never a probe**, so the column can be wrong in one specific
/// way — a stack torn down from a terminal — and the design's answer is to dim
/// it and print its age rather than to spawn a subprocess per row.
void main() {
  late Directory runDir;
  late Directory project;

  setUp(() {
    runDir = Directory.systemTemp.createTempSync('fw-stack-col-run-');
    project = Directory.systemTemp.createTempSync('fw-stack-col-');
  });

  tearDown(() {
    for (var dir in [runDir, project]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  void writeCache(StackReading reading) =>
      File(stackCachePath(runDir.path, project.path))
          .writeAsStringSync(jsonEncode(reading.toJson()));

  group('the probe', () {
    test('reads back what a session left behind', () async {
      writeCache(
        StackReading(
          state: StackState.up,
          at: DateTime.now(),
          detail: 'localhost:8080',
          services: const [
            StackService(name: 'http', port: 8080, state: StackState.up),
          ],
        ),
      );
      var reading = await RunDirStackProbe(runDir: () => runDir.path)
          .probe(project.path);
      expect(reading!.state, StackState.up);
      expect(reading.services.single.port, 8080);
    });

    test('a checkout nobody has opened has nothing to say', () async {
      // Not a failure and not "down": no session has ever probed this one, and
      // finding out would mean running its config and its probe — which is the
      // cost this column exists to avoid.
      expect(
        await RunDirStackProbe(runDir: () => runDir.path).probe(project.path),
        isNull,
      );
    });

    test('a reading with no clock is no reading', () async {
      // It could never be aged, and an un-ageable reading is worse than none:
      // it would sit in the column looking current forever.
      File(stackCachePath(runDir.path, project.path))
          .writeAsStringSync('{"state":"up"}');
      expect(
        await RunDirStackProbe(runDir: () => runDir.path).probe(project.path),
        isNull,
      );
    });

    test('a half-written cache is no cache', () async {
      File(stackCachePath(runDir.path, project.path))
          .writeAsStringSync('{"state":"u');
      expect(
        await RunDirStackProbe(runDir: () => runDir.path).probe(project.path),
        isNull,
      );
    });
  });

  group('the cell', () {
    var now = DateTime(2026, 8, 11, 12);

    Future<void> pump(WidgetTester tester, WorktreeFacts facts) async {
      tester.view.physicalSize = const Size(1400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: Material(
            child: WorktreeRow(
              label: 'A worktree',
              branch: 'claude/thing',
              path: '/repo/thing',
              facts: facts,
              now: now,
              showStack: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    WorktreeFacts factsWith(
      StackReading reading, {
      Duration age = Duration.zero,
    }) {
      var at = now.subtract(age);
      var stamped = StackReading(
        state: reading.state,
        at: at,
        detail: reading.detail,
        services: reading.services,
        failure: reading.failure,
      );
      return WorktreeFacts(
        stack: age > stackFreshFor
            ? Fact.stale(stamped, computedAt: at)
            : Fact.fresh(stamped, computedAt: at),
      );
    }

    testWidgets('up carries the port, because that is what you look for', (
      tester,
    ) async {
      await pump(
        tester,
        factsWith(
          const StackReading(
            state: StackState.up,
            at: null,
            services: [
              StackService(name: 'http', port: 8080, state: StackState.up),
            ],
          ),
        ),
      );
      expect(find.text('up'), findsOneWidget);
      expect(find.text(':8080'), findsOneWidget);
      // Fresh readings do not announce their age. A column that says "now" on
      // every row has spent a line saying nothing.
      expect(find.textContaining('seen'), findsNothing);
    });

    testWidgets('a stale reading says when it was taken', (tester) async {
      await pump(
        tester,
        factsWith(
          const StackReading(state: StackState.up, at: null),
          age: const Duration(hours: 2),
        ),
      );
      expect(find.text('up'), findsOneWidget);
      expect(find.text('seen 2h'), findsOneWidget);
    });

    testWidgets('a probe that failed says so in one word', (tester) async {
      // The sentence explaining it is in the expanded detail — 116 pixels can
      // hold a state or an explanation, not both.
      await pump(
        tester,
        factsWith(
          const StackReading(
            state: StackState.unavailable,
            at: null,
            failure: 'Something else is listening on :8080.',
          ),
        ),
      );
      expect(find.text("can't tell"), findsOneWidget);
    });

    testWidgets('partly up is counted, not rounded to up', (tester) async {
      await pump(
        tester,
        factsWith(
          const StackReading(
            state: StackState.up,
            at: null,
            services: [
              StackService(name: 'db', port: 8200, state: StackState.up),
              StackService(
                name: 'sync',
                port: 8202,
                state: StackState.starting,
              ),
            ],
          ),
        ),
      );
      expect(find.text('up 1/2'), findsOneWidget);
    });

    testWidgets('a checkout with no stack draws nothing', (tester) async {
      await pump(tester, const WorktreeFacts());
      expect(find.byKey(stackCellKey), findsOneWidget);
      expect(find.text('up'), findsNothing);
      expect(find.text('down'), findsNothing);
    });

    testWidgets('the column is last to be dropped when the row is short', (
      tester,
    ) async {
      // Widest-first: at 116 it is the narrowest column here, so dropping it
      // is the smallest saving available and the worst trade on offer.
      var facts = factsWith(const StackReading(state: StackState.up, at: null));
      for (var width in [1400.0, 1000.0, 800.0]) {
        tester.view.physicalSize = Size(width, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme,
            home: Material(
              child: WorktreeRow(
                label: 'A worktree',
                facts: facts,
                now: now,
                showStack: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'overflowed at $width');
        expect(
          find.byKey(stackCellKey),
          findsOneWidget,
          reason: 'the stack column went at ${width}px',
        );
      }

      // Everything else has gone by 700, and it still holds.
      tester.view.physicalSize = const Size(700, 600);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: Material(
            child: WorktreeRow(
              label: 'A worktree',
              facts: facts,
              now: now,
              showStack: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(changesCellKey), findsNothing);
      expect(find.byKey(stackCellKey), findsOneWidget);
    });
  });

  group('the same words in a terminal', () {
    test('fw worktrees prints what the cell draws', () {
      var now = DateTime(2026, 8, 11, 12);
      var text = worktreeTable([
        (
          Worktree(path: '/repo/a', branch: 'a'),
          WorktreeFacts(
            stack: Fact.fresh(
              StackReading(
                state: StackState.up,
                at: now,
                services: const [
                  StackService(name: 'http', port: 8080, state: StackState.up),
                ],
              ),
            ),
          ),
        ),
        (
          Worktree(path: '/repo/b', branch: 'b'),
          WorktreeFacts(
            stack: Fact.stale(
              StackReading(
                state: StackState.unavailable,
                at: now.subtract(const Duration(hours: 3)),
              ),
            ),
          ),
        ),
      ], now: now).join('\n');
      expect(text, contains('up :8080'));
      expect(text, contains("can't tell (3h)"));
    });

    test('a repo with no stack anywhere loses the column', () {
      var now = DateTime(2026, 8, 11, 12);
      var text = worktreeTable([
        (Worktree(path: '/repo/a', branch: 'a'), const WorktreeFacts()),
      ], now: now).join('\n');
      expect(text, isNot(contains('up')));
    });
  });

  group('live, and holding nothing', () {
    /// A controller over a scripted stack probe and nothing else — no git, no
    /// forge, no agent, so nothing here spawns a process.
    WorktreeFactsController controllerOver(
      StackProbe stack, {
      SettleRegistry? settle,
    }) => WorktreeFactsController(
      repoRoot: project.path,
      settle: settle,
      probe: WorktreeFactsProbe(
        repoRoot: project.path,
        store: WorktreeFactsStore.open(project.path),
        stack: stack,
      ),
    );

    test('a run-dir event re-reads the stacks and nothing else', () async {
      // The point of the separate signal: this path must never reach git. It
      // is asserted by construction — the probe below is the only thing wired
      // in — and by the fact that `probeStacks` keeps every other fact as it
      // was rather than recomputing it.
      var reads = 0;
      var controller = controllerOver(
        _Scripted(() {
          reads++;
          return StackReading(state: StackState.up, at: DateTime.now());
        }),
      );
      addTearDown(controller.dispose);

      var worktrees = [Worktree(path: project.path)];
      await controller.refreshStacks(worktrees);
      expect(reads, 1);
      expect(
        controller.factsFor(worktrees.single).stack.value!.state,
        StackState.up,
      );

      // A fact that was already there survives a stack-only refresh.
      await controller.refreshStacks(worktrees);
      expect(reads, 2);
    });

    test('a cache written by anything else reaches the facts', () async {
      // **The whole chain, on the real filesystem**: a file appears under the
      // run dir — as `fw run dev_stack start` in a terminal makes it appear —
      // the watcher notices, the controller re-reads only the stacks, and the
      // fact the row draws has changed. Everything either side of this is unit
      // tested; this is the join.
      Directory(p.join(project.path, '.git')).createSync(recursive: true);
      var controller = controllerOver(
        RunDirStackProbe(runDir: () => runDir.path),
      );
      addTearDown(controller.dispose);
      var worktrees = [Worktree(path: project.path)];

      var watcher = WorktreeWatcher(
        repoRoot: project.path,
        agentRoot: p.join(project.path, 'no-agents'),
        runDir: runDir.path,
        debounce: const Duration(milliseconds: 10),
      )..start();
      addTearDown(watcher.dispose);

      var refreshed = Completer<void>();
      var events = watcher.changes.listen((change) async {
        if (change != WorktreeChange.stack) return;
        await controller.refreshStacks(worktrees);
        if (!refreshed.isCompleted) refreshed.complete();
      });
      addTearDown(events.cancel);

      expect(controller.factsFor(worktrees.single).stack.hasValue, isFalse);

      // Twice: the first event on a freshly registered watch can be swallowed.
      for (var i = 0; i < 2; i++) {
        writeCache(StackReading(state: StackState.up, at: DateTime.now()));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      await refreshed.future.timeout(const Duration(seconds: 15));
      expect(
        controller.factsFor(worktrees.single).stack.value!.state,
        StackState.up,
      );
    });

    test('disposing lets go of the settle registry', () {
      // The registry is a `Set` that lives for the process. A controller that
      // registered and never left would be asked whether it is busy forever —
      // invisible, and exactly the kind of leak nothing else would report.
      var settle = SettleRegistry();
      var controller = controllerOver(_Scripted(() => null), settle: settle);
      expect(settle.isIdle, isTrue);
      controller.dispose();

      // Nothing left holding it: adding a busy source is the only way to make
      // the registry speak, and this one is gone.
      expect(settle.waitingOn, isEmpty);
    });
  });
}

/// A stack probe that answers with whatever the test says, counting calls.
class _Scripted implements StackProbe {
  _Scripted(this.answer);

  final StackReading? Function() answer;

  @override
  Future<StackReading?> probe(String worktreePath) async => answer();
}
