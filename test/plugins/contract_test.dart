import 'dart:convert';
import 'dart:io';

import 'package:flutterware/plugins.dart';
import 'package:test/test.dart';

class _Docker extends Plugin {
  _Docker({required this.compose, super.label}) : super('acme.docker');

  final String compose;

  @override
  Map<String, Object?> get config => {'compose': compose};
}

void main() {
  group('the contract stays pure data', () {
    // If any of this reaches for package:flutter, then the CLI, the file
    // projection and any agent lose it permanently.
    test('no file under lib/src/plugins imports flutter', () {
      var offenders = <String>[];
      for (var entity in Directory(
        'lib/src/plugins',
      ).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.readAsStringSync().contains('package:flutter/')) {
          offenders.add(entity.path);
        }
      }
      expect(offenders, isEmpty);
    });
  });

  group('view projection', () {
    test('renders an indented text tree', () {
      var view = PluginView([
        ViewField('Guest', 'warm · 118ms'),
        ViewSection('Entries', [
          ViewItems([
            ViewItem('Button / primary', detail: 'ok'),
            ViewItem('Card / with image', detail: 'changed', tone: Tone.warn),
          ], truncated: 46),
        ]),
      ]);

      expect(view.toText(), '''
Guest: warm · 118ms
Entries
  - Button / primary   ok
  - Card / with image  changed
  … 46 more''');
    });

    test('aligns table columns', () {
      var view = PluginView([
        ViewTable(
          ['PACKAGE', 'VERSION'],
          [
            ['analyzer', '13.3.0'],
            ['args', '2.7.0'],
          ],
        ),
      ]);

      expect(view.toText(), '''
PACKAGE   VERSION
analyzer  13.3.0
args      2.7.0''');
    });

    test('records truncation rather than dropping rows silently', () {
      var table = ViewTable(
        ['A'],
        [
          ['1'],
        ],
        truncated: 9,
      );
      expect(table.toJson()['truncated'], 9);
      expect(table.toJson()['rows'], [
        ['1'],
      ]);
    });
  });

  group('report', () {
    var report = PluginReport(
      id: 'flutterware.tests',
      label: 'Tests',
      status: Status.error('3 failing'),
      badge: StatusBadge.dot(Tone.error),
      actions: [PluginAction('run', 'Run all')],
      teardown: [
        TeardownStep(
          'clear-screenshots',
          'Clear screenshot cache',
          phase: TeardownPhase.cleanup,
        ),
      ],
      guards: [Guard.warn('a run is still in flight')],
      view: PluginView([ViewField('Failing', '3 of 128')]),
    );

    test('projects to text', () {
      expect(report.toText(), '''
Tests  3 failing
  Failing: 3 of 128''');
    });

    test('a package named by both a child and a section prints once', () {
      var scoped = PluginReport(
        id: 'flutterware.scenarios',
        label: 'Scenarios',
        children: [
          PluginChild(id: 'fixtures/probe_app', label: 'fixtures/probe_app'),
          PluginChild(
            id: 'app',
            label: 'app',
            status: Status.warn('no config'),
          ),
          PluginChild(id: '.', label: 'root', status: Status.info('4 assets')),
          PluginChild(id: 'tools', label: 'tools'),
        ],
        view: PluginView([
          ViewSection('fixtures/probe_app', [ViewField('Scenarios', '8')]),
          ViewSection('app', [ViewField('Scenarios', '0')]),
          // Titled by id where the child spells it `root` — one package, and
          // the child's spelling is the one worth keeping.
          ViewSection('.', [ViewField('Scenarios', '2')]),
        ]),
      );

      expect(scoped.toText(), '''
Scenarios
  tools
  fixtures/probe_app
    Scenarios: 8
  app  no config
    Scenarios: 0
  root  4 assets
    Scenarios: 2''');

      // `--brief` renders no projection, so nothing folds and every child is
      // still its own line.
      expect(scoped.toText(includeView: false), '''
Scenarios
  fixtures/probe_app
  app  no config
  root  4 assets
  tools''');
    });

    test('serialises the whole contract', () {
      var json = report.toJson();
      expect(json['status'], {'tone': 'error', 'message': '3 failing'});
      expect(json['badge'], {'kind': 'dot', 'tone': 'error'});
      expect((json['actions']! as List).single, {
        'id': 'run',
        'label': 'Run all',
      });
      expect(json['view'], isA<List<Object?>>());
    });

    test('omits empty parts', () {
      var bare = PluginReport(id: 'x', label: 'X');
      expect(bare.toJson().keys, ['id', 'label', 'status']);
    });
  });

  group('manifest', () {
    test('round-trips a configured project', () {
      String? emitted;
      Flutterware.configure(
        (fw) => fw
          ..use(_Docker(compose: 'docker/dev.yml', label: 'dev'))
          ..use(_BarePlugin('flutterware.previews')),
        emit: (line) => emitted = line,
      );

      var manifest = PluginManifest.parse(emitted!);
      expect(manifest.version, manifestVersion);
      expect(manifest.plugins.map((p) => p.id), [
        'acme.docker',
        'flutterware.previews',
      ]);
      expect(manifest.plugins.first.label, 'dev');
      expect(manifest.plugins.first.config, {'compose': 'docker/dev.yml'});
      // Label falls back to the last dotted segment of the id.
      expect(manifest.plugins.last.label, 'previews');
    });

    test('rejects duplicate ids', () {
      expect(
        () => Flutterware.configure(
          (fw) => fw
            ..use(_BarePlugin('same'))
            ..use(_BarePlugin('same')),
          emit: (_) {},
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('refuses the id the shell reserves for its own config screen', () {
      // `fw:///worktrees/<worktree>/config` is the one place that explains why
      // this file did not load. A plugin able to take that address could hide
      // it — so the reservation is enforced here rather than documented and
      // hoped for.
      expect(
        () => Flutterware.configure(
          (fw) => fw.use(_BarePlugin(Address.shellConfig)),
          emit: (_) {},
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('refuses a manifest from a future version', () {
      var future = jsonEncode({'version': manifestVersion + 1, 'plugins': []});
      expect(() => PluginManifest.parse(future), throwsFormatException);
    });
  });
}

class _BarePlugin extends Plugin {
  _BarePlugin(super.id);
}
