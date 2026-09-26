import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart' show SearchReason, searchReport;
import 'package:flutterware_app/src/plugins/native/dependencies_core.dart';
import 'package:flutterware_app/src/plugins/native/dependencies_results.dart';
import 'package:flutterware_app/src/plugins/plugin_core.dart';
import 'package:flutterware_app/src/session/job.dart';
import 'package:flutterware_app/src/session/session.dart';
import 'package:flutterware_app/src/shell/repo_layout.dart';
import 'package:path/path.dart' as p;

import '../support/declared_dependencies.dart';

/// Drives the real repo, because the point of a session is that it resolves a
/// real `tool/flutterware.dart`. Nothing here computes anything: the laziness
/// rule is most of what is being asserted.
void main() {
  _appToolDirectoryTests();

  late Session session;

  setUp(() async {
    session = await Session.open(Directory(findRepoRoot('..')!));
  });

  tearDown(() => session.dispose());

  test('resolves the repo root by walking up', () {
    // Asserted by what a root *is*, not by its name: this test used to expect
    // the directory the branch was written in, which passed in one worktree
    // and failed everywhere else.
    expect(File('${session.root}/tool/flutterware.dart').existsSync(), isTrue);
    // Deliberately not asserting on `.git`: it is a directory in the main
    // checkout and a *file* in a linked worktree, so testing for either shape
    // just swaps one environment-specific failure for another.
    // Opened from `app/`, so the root has to be strictly above it.
    expect(Directory.current.path, startsWith(session.root));
    expect(Directory.current.path, isNot(session.root));
  });

  test('resolves a core per declared plugin, in declared order', () {
    expect(session.cores.map((c) => c.id), [
      'flutterware.dependencies',
      'flutterware.assets',
      'flutterware.render',
      'flutterware.previews',
      'flutterware.scene',
      'flutterware.splash',
      'flutterware.launcher_icon',
      'flutterware.store',
      'flutterware.server',
      'flutterware.lints',
      'flutterware.dev_stack',
      'flutterware.run',
      'flutterware.worlds',
      'flutterware.scenarios',
      'flutterware.translations',
    ]);
  });

  test('a plugin with no core registered is visible, not omitted', () async {
    // Every real plugin has a core, so this needs a build that lacks one.
    // The honest failure mode it guards: `fw` printing nothing for a declared
    // plugin would read as "this project has fewer plugins than it does".
    var bare = await Session.open(
      Directory(findRepoRoot('..')!),
      registry: PluginCoreRegistry(),
    );
    try {
      expect(bare.cores, everyElement(isA<MissingPluginCore>()));
      // One per declaration, same as a real build — a registry with nothing in
      // it must not shrink the list, which is the whole point.
      expect(bare.cores, hasLength(session.cores.length));
      for (var core in bare.cores) {
        expect(core.report.status.isEmpty, isFalse);
      }
      // A first-party plugin missing from a build means the build is older
      // than the project's flutterware — said, rather than "no actions".
      var result = await bare.invoke('run', 'devices').done;
      expect(
        '${result.error}',
        contains('older than the one the project declares'),
      );
    } finally {
      bare.dispose();
    }
  });

  test('opening a session computes nothing', () {
    var dependencies =
        session.coreById(dependenciesPluginId)! as DependenciesCore;
    expect(dependencies.packages, [
      '.',
      'app',
      'fixtures/probe_app',
      'examples/brewline',
    ]);
    for (var path in dependencies.packages) {
      expect(dependencies.isRealised(path), isFalse);
    }
    expect(dependencies.report.toText(), contains('not computed'));
  });

  test('reports are readable without any subscriber', () {
    // The rule that makes it safe for the sidebar, `fw` and an agent to call
    // this for every plugin: a pure read of cached state.
    expect(session.reports, hasLength(session.cores.length));
    expect(session.reports.first.id, dependenciesPluginId);
  });

  group('coreByShortName', () {
    test('resolves the last dotted segment', () {
      expect(session.coreByShortName('dependencies')?.id, dependenciesPluginId);
    });

    test('resolves a full id too', () {
      expect(
        session.coreByShortName(dependenciesPluginId)?.id,
        dependenciesPluginId,
      );
    });

    test('is null rather than a guess for an unknown name', () {
      expect(session.coreByShortName('nope'), isNull);
    });
  });

  test('an unknown action is refused loudly', () async {
    var dependencies = session.coreById(dependenciesPluginId)!;
    expect(
      () => dependencies.invoke('not-an-action'),
      throwsA(isA<ArgumentError>()),
    );
  });

  group('a parameter the action does not declare', () {
    /// Whatever the refusal said, from the surface both renderers read.
    Future<String> refusal(
      String plugin,
      String action,
      Map<String, Object?> arguments,
    ) async {
      var result = await session
          .invoke(plugin, action, arguments: arguments)
          .done;
      expect(result.ok, isFalse, reason: 'the call was meant to be refused');
      return describeJobError(result.error!);
    }

    test('is refused rather than dropped', () async {
      // The call that prompted this: the parameter is `with-axes`, and an
      // ignored `--axes` came back as a description with no `axes` field —
      // indistinguishable from the right answer for an entry that has no
      // shell.
      var message = await refusal('previews', 'describe', {
        'entry': 'demo/buttons.dart#buttons',
        'axes': 'true',
      });
      expect(message, contains('no such parameter'));
      expect(message, contains('(axes)'));
    });

    test('names the one it was probably meant to be', () async {
      var message = await refusal('previews', 'describe', {'axes': 'true'});
      expect(message, contains('did you mean `with-axes`'));
    });

    test('lists the ones the action does have', () async {
      var message = await refusal('previews', 'describe', {'nonsense': '1'});
      expect(message, contains('It takes: entry, with-knobs, with-axes'));
    });

    test('does not speak for an action that does not exist', () async {
      // The plugin owns everything past its own name, and an unknown action is
      // refused by listing the real ones. Answering "no such parameter" first
      // would describe the arguments of nothing.
      var message = await refusal('previews', 'not-an-action', {'axes': '1'});
      expect(message, contains('unknown action'));
      expect(message, isNot(contains('no such parameter')));
    });

    /// With no arguments at all there is nothing to coerce, and the check used
    /// to be skipped wholesale on that shortcut — see
    /// `undeclared_action_test.dart` for what that let through.
    test('an unknown action is refused even with no arguments', () async {
      var message = await refusal('previews', 'not-an-action', {});
      expect(message, contains('unknown action'));
    });
  });

  test('an action asked for by name loads what it needs', () async {
    var dependencies =
        session.coreById(dependenciesPluginId)! as DependenciesCore;
    var package = dependencies.packages.first;
    expect(dependencies.isRealised(package), isFalse);

    var result =
        (await dependencies.invoke('list', arguments: {'package': package}))!
            as DependencyListResult;

    // The inversion worth keeping: a *report* may never start work, because
    // everything reads it constantly. An action was asked for by name, and in
    // `fw` and MCP the process holds nothing — so a query that only read the
    // cache would answer "nothing" every time, which is what the plugin's two
    // deleted cache-invalidation actions did.
    expect(dependencies.isRealised(package), isTrue);
    expect(result.packages.single.path, package);
    expect(result.packages.single.direct, isA<int>());
  });

  test('the list reports where each package came from', () async {
    var dependencies =
        session.coreById(dependenciesPluginId)! as DependenciesCore;

    var result =
        (await dependencies.invoke(
              'list',
              arguments: {'package': 'fixtures/probe_app'},
            ))!
            as DependencyListResult;
    var entries = result.packages.single.dependencies;

    // Every one of these was null before: the source was read off a lockfile
    // entry that does not exist beside a member of a pub workspace.
    expect(entries, isNotEmpty);
    expect(entries.map((e) => e.source), everyElement(isNotEmpty));

    var flutterware = entries.firstWhere((e) => e.name == 'flutterware');
    expect(flutterware.source, 'root', reason: 'a sibling workspace member');
    expect(flutterware.direct, isTrue);

    var flutterTest = entries.firstWhere((e) => e.name == 'flutter_test');
    expect(flutterTest.source, 'sdk');
    expect(flutterTest.dev, isTrue, reason: 'declared in dev_dependencies');

    // The counts are per-member, not per-workspace — derived from the member's
    // own pubspec rather than written down here, so adding a dependency to the
    // sample project does not fail a test about where packages come from.
    var declared = DeclaredDependencies.of(
      '../fixtures/probe_app/pubspec.yaml',
    );
    expect(result.packages.single.direct, declared.dependencies.length);
    expect(result.packages.single.dev, declared.devs.length);
    expect(
      result.packages.single.transitive,
      greaterThan(declared.dependencies.length),
    );
  });

  test('a dependency is findable in the palette once computed', () async {
    var dependencies =
        session.coreById(dependenciesPluginId)! as DependenciesCore;
    await dependencies.invoke(
      'list',
      arguments: {'package': 'fixtures/probe_app'},
    );

    var hits = searchReport(dependencies.report, 'auto_size', worktree: 'wt');

    // The projection used to be a `ViewTable`, and `searchReport` skips tables
    // because a table row has nowhere to put an address. So the plugin's only
    // search hit was ever the plugin itself.
    var hit = hits.firstWhere((e) => e.title == 'auto_size_text');
    expect(hit.reason, SearchReason.item);
    expect(hit.address.plugin, dependenciesPluginId);
    expect(hit.address.segments, [
      'fixtures/probe_app',
      'packages',
      'auto_size_text',
    ]);
  });

  test('nothing is searchable before it is computed', () {
    // The laziness rule, from the search side: a report that started work just
    // because somebody typed would defeat the whole design.
    var dependencies = session.coreById(dependenciesPluginId)!;
    expect(
      searchReport(dependencies.report, 'auto_size', worktree: 'wt'),
      isEmpty,
    );
  });
}

/// `Session.findAppToolDirectory()` has to answer however this process was
/// started, because the ways differ and none of them is exotic: the launcher
/// records `APP_TOOL_PATH`, a source run derives from `Platform.script`, and
/// `dart run flutterware_app:<bin>` — the form `.mcp.json` uses — gets a
/// snapshot path under `.dart_tool/pub/bin/` that derives to nothing.
///
/// That last case shipped broken: the MCP server resolved null and every
/// catalog action refused with a message about `appPackageRoot` that named the
/// symptom rather than the invocation. A test here rather than at the previews
/// daemon because this is the function that was wrong.
void _appToolDirectoryTests() {
  test('the app package root is recognised by name, not by having a '
      'pubspec', () {
    // This repo is a workspace whose *root* is also a package, so "a
    // pubspec.yaml is here" was satisfied by `flutterware` itself — and the
    // catalog daemon was then looked for one directory tree away from where it
    // lives. The name is the check.
    var app = Directory.current.path;
    var repoRoot = p.dirname(app);

    expect(Session.debugAppPackageRootAt(app)?.path, app);
    expect(
      Session.debugAppPackageRootAt(repoRoot),
      isNull,
      reason: 'the root package is `flutterware`, not `flutterware_app`',
    );
    expect(Session.debugAppPackageRootAt(p.join(app, 'lib')), isNull);
  });
}
