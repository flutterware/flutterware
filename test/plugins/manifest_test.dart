import 'package:flutterware/plugins.dart';
import 'package:test/test.dart';

/// The packages a manifest reports come off the plugins that name them.
///
/// This used to be a separate `fw.packages([...])` call, and the host filtered
/// each plugin's packages against it. A package the list forgot was dropped
/// from the plugin that had been configured with it, without a word — so the
/// list's only observable effect was to contradict the config below it.
void main() {
  const root = Pkg('.');
  const app = Pkg('app');

  /// A config, emitted and parsed back — the host reads this off a
  /// subprocess's stdout and never sees the objects.
  PluginManifest manifestOf(List<Plugin> plugins) {
    late String emitted;
    Flutterware.configure((fw) {
      for (var plugin in plugins) {
        fw.use(plugin);
      }
    }, emit: (line) => emitted = line);
    return PluginManifest.parse(emitted);
  }

  test('every package a plugin names is reported', () {
    var manifest = manifestOf([
      Dependencies(packages: DependenciesPackage.each([root, app])),
    ]);
    expect(manifest.packages.map((p) => p.path), ['.', 'app']);
  });

  test('a package named by several plugins is reported once', () {
    var manifest = manifestOf([
      Dependencies(packages: DependenciesPackage.each([root, app])),
      Assets(packages: AssetsPackage.each([app, root])),
    ]);
    expect(manifest.packages.map((p) => p.path), ['.', 'app']);
  });

  test('order follows the plugins, not the alphabet', () {
    var manifest = manifestOf([
      Assets(packages: AssetsPackage.each([app, root])),
    ]);
    expect(manifest.packages.map((p) => p.path), ['app', '.']);
  });

  test('a plugin with no packages contributes none', () {
    expect(manifestOf([Dependencies()]).packages, isEmpty);
    expect(manifestOf([]).packages, isEmpty);
  });

  /// The shell owns two ids in the plugin slot, and a plugin that took one
  /// would be silently unreachable — shadowed by the screen, with nothing said.
  /// So the refusal is enforced on **both doors**: the config a project writes,
  /// and the manifest the host parses back. A manifest does not have to have
  /// come from `Flutterware.configure`, and a reservation enforced on one side
  /// only is a convention rather than a fact.
  group('a package declared twice', () {
    test('is refused when the entries are one folder', () {
      expect(
        () => Flutterware.configure((fw) {
          fw.use(
            Scenarios(
              packages: [
                ScenariosPackage(Pkg('app')),
                ScenariosPackage(Pkg('app')),
              ],
            ),
          );
        }, emit: (_) {}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('"app" twice'),
          ),
        ),
      );
      expect(
        () => Flutterware.configure((fw) {
          fw.use(
            Scenarios(
              packages: [
                ScenariosPackage(Pkg('app'), directory: 'test/scenarios'),
                ScenariosPackage(Pkg('app')),
              ],
            ),
          );
        }, emit: (_) {}),
        throwsA(isA<StateError>()),
      );
    });

    test('is two folders when each entry names its own directory', () {
      String? emitted;
      Flutterware.configure((fw) {
        fw.use(
          Scenarios(
            packages: [
              ScenariosPackage(Pkg('app'), directory: 'test/scenarios'),
              ScenariosPackage(
                Pkg('app'),
                directory: 'test/integration',
                time: ScenarioTime.real(),
              ),
            ],
          ),
        );
      }, emit: (json) => emitted = json);
      var manifest = PluginManifest.parse(emitted!);
      var packages = manifest.plugins.single.config['packages']! as List;
      expect(packages, hasLength(2));
      expect((packages[1] as Map)['time'], 'real');
    });
  });

  group('the shell reserves its own ids', () {
    for (var id in Address.shellOwned) {
      test('`$id` is refused by the config', () {
        expect(
          () => Flutterware.configure(
            (fw) => fw.use(_Squatter(id)),
            emit: (_) {},
          ),
          throwsA(isA<StateError>()),
        );
      });

      test('`$id` is refused by the parser too', () {
        expect(
          () => PluginManifest.fromJson({
            'version': 1,
            'plugins': [
              {'id': id, 'label': 'Squatter'},
            ],
          }),
          throwsA(isA<FormatException>()),
        );
      });
    }

    test('both ids are named, so a third screen cannot be forgotten', () {
      expect(Address.shellOwned, contains(Address.shellConfig));
      expect(Address.shellOwned, contains(Address.shellChanges));
      // The sessionless set is a subset: `config` is about the session, so it
      // needs one; `changes` reads git and does not.
      expect(Address.shellSessionless, {Address.shellChanges});
    });
  });

  group('the changes config rides the manifest', () {
    /// The whole point of the round trip: the GUI never sees the objects a
    /// config built, only what a subprocess printed.
    PluginManifest emitted(void Function(FlutterwareConfig fw) build) {
      late String line;
      Flutterware.configure(build, emit: (it) => line = it);
      return PluginManifest.parse(line);
    }

    test('survives being printed and parsed back', () {
      var manifest = emitted(
        (fw) => fw.changes(
          const ChangesConfig(attention: ['**/migrations/**'], base: 'develop'),
        ),
      );
      expect(manifest.changes?.attention, ['**/migrations/**']);
      expect(manifest.changes?.base, 'develop');
    });

    test('a config that declares none reports none', () {
      expect(emitted((fw) {}).changes, isNull);
      // Distinct from an empty one, which is a project that said something.
      expect(
        emitted((fw) => fw.changes(const ChangesConfig())).changes?.isEmpty,
        isTrue,
      );
    });

    test('declaring it twice is refused rather than silently merged', () {
      // Either resolution loses one of the two answers without a word — the
      // failure that killed the standalone package list.
      expect(
        () => Flutterware.configure((fw) {
          fw
            ..changes(const ChangesConfig(attention: ['a']))
            ..changes(const ChangesConfig(attention: ['b']));
        }, emit: (_) {}),
        throwsA(isA<StateError>()),
      );
    });

    test('a manifest written by an older flutterware still parses', () {
      // No `changes` key at all, which is every manifest before this landed.
      var manifest = PluginManifest.parse('{"version":1,"plugins":[]}');
      expect(manifest.changes, isNull);
    });

    test('a list with a non-string in it drops the entry, never throws', () {
      // Read back from a cache a future version wrote. Refusing to rank
      // because one list had a number in it would be strictly worse.
      expect(
        ChangesConfig.fromJson(const {
          'attention': ['a', 1, 'b'],
        }).attention,
        ['a', 'b'],
      );
      // Not a list at all, which is the same class of surprise.
      expect(
        ChangesConfig.fromJson(const {'attention': 'everything'}).attention,
        isEmpty,
      );
    });
  });

  group('the project clock rides the manifest', () {
    PluginManifest emitted(void Function(FlutterwareConfig fw) build) {
      late String line;
      Flutterware.configure(build, emit: (it) => line = it);
      return PluginManifest.parse(line);
    }

    test('survives being printed and parsed back, seconds and all', () {
      // Seconds and a non-round minute, because the previews entrypoint used
      // to spell the pin out as `DateTime(y, m, d, h, min)` and would have
      // dropped both without a word.
      var manifest = emitted((fw) => fw.clock(DateTime(2031, 3, 4, 5, 6, 7)));
      expect(manifest.clock, DateTime(2031, 3, 4, 5, 6, 7));
      expect(manifest.clock!.isUtc, isFalse);
    });

    test('a UTC declaration stays UTC', () {
      var manifest = emitted((fw) => fw.clock(DateTime.utc(2031, 3, 4, 5)));
      expect(manifest.clock, DateTime.utc(2031, 3, 4, 5));
      expect(manifest.clock!.isUtc, isTrue);
    });

    test('a config that declares none reports none — the default applies', () {
      expect(emitted((fw) {}).clock, isNull);
    });

    test('declaring it twice is refused rather than silently merged', () {
      expect(
        () => Flutterware.configure((fw) {
          fw
            ..clock(DateTime(2031))
            ..clock(DateTime(2032));
        }, emit: (_) {}),
        throwsA(isA<StateError>()),
      );
    });

    test('a manifest written by an older flutterware still parses', () {
      expect(PluginManifest.parse('{"version":1,"plugins":[]}').clock, isNull);
    });

    test('a wrong shape is no clock, never a throw', () {
      // Same reasoning as the identity below: a project whose config cannot be
      // read is a project that cannot be opened, over one optional field.
      expect(
        PluginManifest.parse('{"version":1,"plugins":[],"clock":42}').clock,
        isNull,
      );
      expect(
        PluginManifest.parse(
          '{"version":1,"plugins":[],"clock":"half past ten"}',
        ).clock,
        isNull,
      );
    });
  });

  group('the project identity rides the manifest', () {
    PluginManifest emitted(void Function(FlutterwareConfig fw) build) {
      late String line;
      Flutterware.configure(build, emit: (it) => line = it);
      return PluginManifest.parse(line);
    }

    test('survives being printed and parsed back', () {
      var manifest = emitted(
        (fw) => fw.identity(
          const ProjectIdentity(package: Pkg('app'), icon: 'logo.png'),
        ),
      );
      expect(manifest.identity?.package, const Pkg('app'));
      expect(manifest.identity?.icon, 'logo.png');
    });

    test('a config that declares none reports none', () {
      expect(emitted((fw) {}).identity, isNull);
    });

    test('declaring it twice is refused rather than silently merged', () {
      expect(
        () => Flutterware.configure((fw) {
          fw
            ..identity(const ProjectIdentity(package: Pkg('a'), icon: 'a.png'))
            ..identity(const ProjectIdentity(package: Pkg('b'), icon: 'b.png'));
        }, emit: (_) {}),
        throwsA(isA<StateError>()),
      );
    });

    test('a manifest written by an older flutterware still parses', () {
      // No `identity` key at all, which is every manifest before this landed.
      var manifest = PluginManifest.parse('{"version":1,"plugins":[]}');
      expect(manifest.identity, isNull);
    });

    test('a wrong shape is no identity, never a throw', () {
      // A window that looks like every other window is where the project
      // started; refusing to open it would be the worse answer.
      expect(ProjectIdentity.fromJson(const {}), isNull);
      expect(ProjectIdentity.fromJson(const {'package': 42}), isNull);
      expect(ProjectIdentity.fromJson(const {'package': ''}), isNull);
      // A package with no icon is half a declaration, and half of this one
      // shows nothing — so it is no identity rather than a package on its own.
      expect(ProjectIdentity.fromJson(const {'package': 'app'}), isNull);
      expect(
        ProjectIdentity.fromJson(const {'package': 'app', 'icon': ''}),
        isNull,
      );
      expect(
        PluginManifest.parse(
          '{"version":1,"plugins":[],"identity":"packages/web_app"}',
        ).identity,
        isNull,
      );
    });

    test('it names a package no plugin has to mention', () {
      // Identity is about the repository, not about what is mounted in it, so
      // it does not have to appear in the derived package list.
      var manifest = emitted((fw) {
        fw
          ..identity(
            const ProjectIdentity(
              package: Pkg('packages/web_app'),
              icon: 'logo.png',
            ),
          )
          ..use(Dependencies(packages: DependenciesPackage.each([app])));
      });
      expect(manifest.identity?.package.path, 'packages/web_app');
      expect(manifest.packages.map((p) => p.path), ['app']);
    });
  });

  /// Declaring one package twice is the first thing anybody tries when they
  /// want two configurations of it — two preview directories, two canvases —
  /// and it used to look like it had worked. The path is the identity of a
  /// per-package entry all the way down (report children, `fw:///` addresses,
  /// the previews daemon's own address), so the first entry won and its result
  /// was emitted once per declaration: two blocks, byte-identical, with the
  /// second declaration's options nowhere.
  ///
  /// Refused on **both doors**, like a duplicate plugin id and for the same
  /// reason — the manifest does not have to have come from
  /// `Flutterware.configure`.
  group('a package may be named once per plugin', () {
    test('the config refuses a second entry for one package', () {
      expect(
        () => manifestOf([
          Previews(
            packages: [
              PreviewsPackage(app, directory: 'demo/mobile'),
              PreviewsPackage(app, directory: 'demo/desktop'),
            ],
          ),
        ]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('flutterware.previews'), contains('"app"')),
          ),
        ),
      );
    });

    test('the parser refuses it too', () {
      expect(
        () => PluginManifest.fromJson({
          'version': 1,
          'plugins': [
            {
              'id': 'flutterware.previews',
              'label': 'Previews',
              'config': {
                'packages': [
                  {'path': 'app', 'directory': 'demo/mobile'},
                  {'path': 'app', 'directory': 'demo/desktop'},
                ],
              },
            },
          ],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('two plugins naming the same package is not that', () {
      // The join key is (plugin, path). Previews and Assets both operating on
      // one package is the ordinary case and always was.
      var manifest = manifestOf([
        Previews(packages: [PreviewsPackage(app)]),
        Assets(packages: AssetsPackage.each([app])),
      ]);
      expect(manifest.packages.map((p) => p.path), ['app']);
    });
  });

  test("a plugin's own per-package options are untouched", () {
    var manifest = manifestOf([
      Previews(packages: [PreviewsPackage(app, directory: 'tool/catalog')]),
    ]);
    expect(manifest.packages.map((p) => p.path), ['app']);
    expect(manifest.plugins.single.config['packages'], [
      {'path': 'app', 'directory': 'tool/catalog'},
    ]);
  });
}

/// A plugin that tries to take an id the shell owns.
class _Squatter extends Plugin {
  _Squatter(super.id);
}
