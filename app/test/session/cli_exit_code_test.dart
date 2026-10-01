import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/assets_results.dart';
import 'package:flutterware_app/src/plugins/native/previews_results.dart';
import 'package:flutterware_app/src/plugins/plugin_core.dart';
import 'package:flutterware_app/src/session/cli.dart';
import 'package:flutterware_app/src/session/session.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';

/// Which actions a job can be gated on, and what a gate costs the report.
///
/// An audit that finds something and exits 0 is worse than an audit nobody
/// runs: the pipeline reports a check that cannot fail, and a green pipeline is
/// not something anyone goes and reads. So the verdict is a field on the result
/// — `ReportsFailure.ok` — and these tests hold both halves of what that means:
/// the exit code follows it, and the report is printed in full either way.
void main() {
  late StringBuffer out;
  late StringBuffer err;
  late Object? result;

  Future<int> run(List<String> arguments) => FwCli(
    openSession: () => _session(() => result),
    out: out,
    err: err,
  ).run(arguments);

  setUp(() {
    out = StringBuffer();
    err = StringBuffer();
    result = null;
  });

  group('previews audit', () {
    test('a clean catalog exits 0', () async {
      result = CatalogAuditResult(checked: 133, broken: 0, entries: []);
      expect(await run(['run', 'fake', 'audit']), 0);
      expect(jsonDecode(out.toString()), containsPair('ok', true));
    });

    test('a broken entry exits 1, with the report intact', () async {
      result = CatalogAuditResult(
        checked: 133,
        broken: 1,
        entries: [
          CatalogAuditEntry(
            id: 'demo/buttons.dart#buttons',
            address: 'fw:///worktrees/x/flutterware.previews/./buttons',
            compiles: true,
            errors: [
              CatalogRenderError(
                exception: 'A RenderFlex overflowed by 4100 pixels.',
              ),
            ],
          ),
        ],
      );
      expect(await run(['run', 'fake', 'audit']), 1);

      // The exit code decides what a shell does; it takes nothing away from
      // what a reader gets. Everything the action found is still on stdout.
      var report = jsonDecode(out.toString()) as Map<String, Object?>;
      expect(report['ok'], isFalse);
      expect(report['broken'], 1);
      expect('${report['entries']}', contains('RenderFlex'));
      expect(err.toString(), isEmpty);
    });

    test('a package it could not reach exits 1', () async {
      // The failure the flag exists to prevent: a package nobody looked at is
      // not a package with nothing wrong, so it may not read as green.
      result = CatalogAuditResult(
        checked: 0,
        broken: 0,
        entries: [],
        unreachable: [
          CatalogAuditFailure(package: 'packages/ui', error: 'no daemon'),
        ],
      );
      expect(await run(['run', 'fake', 'audit']), 1);
    });
  });

  group('assets audit', () {
    test('nothing wrong exits 0', () async {
      result = AssetAuditResult(checked: 10, bytes: 355519);
      expect(await run(['run', 'fake', 'assets']), 0);
    });

    test('a finding exits 1', () async {
      result = AssetAuditResult(
        checked: 10,
        bytes: 355519,
        findings: [
          AssetFinding(
            kind: 'oversized',
            summary: 'A raster larger than anything that will draw it.',
            detail: '4096 × 4096 at 347 kB, against a limit of 2048 px.',
          ),
        ],
      );
      expect(await run(['run', 'fake', 'assets']), 1);
    });

    test('a package it could not read exits 1', () async {
      result = AssetAuditResult(
        checked: 0,
        bytes: 0,
        unreadable: ['packages/ui'],
      );
      expect(await run(['run', 'fake', 'assets']), 1);
    });
  });

  group('previews check', () {
    test('every package servable exits 0', () async {
      result = CatalogCheckResult(
        packages: [
          CatalogPackageCheck(path: '.', ok: true, servable: ['a']),
        ],
      );
      expect(await run(['run', 'fake', 'check']), 0);
    });

    test('a quarantined entry exits 1', () async {
      result = CatalogCheckResult(
        packages: [
          CatalogPackageCheck(
            path: '.',
            broken: [CatalogBrokenEntry(id: 'a', error: 'nope')],
          ),
        ],
      );
      expect(await run(['run', 'fake', 'check']), 1);
    });

    test('a package the daemon could not be reached for exits 1', () async {
      result = CatalogCheckResult(
        packages: [CatalogPackageCheck(path: '.', error: 'no daemon')],
      );
      expect(await run(['run', 'fake', 'check']), 1);
    });
  });

  group('an artifact', () {
    Artifact picture({Map<String, Object?> meta = const {}}) => Artifact(
      kind: Artifact.png,
      address: Address(
        worktree: 'x',
        plugin: 'test.fake',
        segments: const ['a'],
      ),
      path: 'build/a.png',
      meta: meta,
    );

    test('prints its path alone', () async {
      result = picture();
      expect(await run(['run', 'fake', 'picture']), 0);
      expect(out.toString(), 'build/a.png\n');
      expect(err.toString(), isEmpty);
    });

    test("says its producer's note where a person reads it", () async {
      // A picture of an entry that complained while it rendered. The file
      // is still the answer, so it still exits 0 and stdout is still the
      // path and nothing else — `| xargs open` must not open a sentence.
      result = picture(meta: {'note': 'the entry reported an error'});
      expect(await run(['run', 'fake', 'picture']), 0);
      expect(out.toString(), 'build/a.png\n');
      expect(err.toString(), contains('the entry reported an error'));
    });
  });

  test('a result with no verdict exits 0, however it reads', () async {
    // Most actions answer a question rather than passing judgement. Nothing
    // here may invent a verdict for one of those.
    result = CatalogEntriesResult(packages: []);
    expect(await run(['run', 'fake', 'query']), 0);
  });

  test('--help says whether a job can gate on the action', () async {
    expect(await run(['run', 'fake', 'audit', '--help']), 0);
    expect(out.toString(), contains(gatingNote));
  });

  test('--help says nothing about gating on an action that does not', () async {
    expect(await run(['run', 'fake', 'query', '--help']), 0);
    expect(out.toString(), isNot(contains(gatingNote)));
  });
}

Future<Session> _session(Object? Function() result) async => Session.resolved(
  worktree: const Worktree(path: '/project'),
  workspace: Workspace(
    root: '/project',
    declared: const [Pkg('.')],
    discovered: const ['.'],
    appContext: AppContext(logger: LogClient.print()),
    flutterSdk: FlutterSdkPath('/flutter'),
  ),
  manifest: const PluginManifest([
    PluginDeclaration(id: 'test.fake', label: 'Fake'),
  ]),
  registry: PluginCoreRegistry({
    'test.fake': (host) => _FakeCore(host, result),
  }),
);

/// One action that hands back whatever the test set, so that what is under test
/// is the rule `fw` applies and not a plugin's own opinion of it.
class _FakeCore extends PluginCore {
  _FakeCore(super.host, this._result);

  final Object? Function() _result;

  @override
  PluginReport get report => PluginReport(
    id: host.id,
    label: host.label,
    // One per result class rather than one action reused, because an action
    // that returns something other than what it declared is refused before any
    // of this — the framework checks the type, and a test that tripped that
    // check would be measuring the wrong refusal.
    actions: const [
      PluginAction('audit', 'Audit', returns: CatalogAuditResult),
      PluginAction('assets', 'Assets', returns: AssetAuditResult),
      PluginAction('check', 'Check', returns: CatalogCheckResult),
      PluginAction('query', 'Query', returns: CatalogEntriesResult),
      PluginAction('picture', 'Picture', returns: Artifact),
    ],
  );

  @override
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) async => _result();
}
