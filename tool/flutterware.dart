import 'package:flutterware/plugins.dart';

/// flutterware's own repo — a three-member pub workspace, and the monorepo
/// test case for the shell.
///
/// There is exactly one config, here at the repo root: `fixtures/probe_app` is a
/// workspace *member*, so it is a package below, not a project of its own.
/// `.new(...)` is the dot shorthand for a package entry, and needs an SDK
/// constraint of 3.10+; the explicit `PreviewsPackage(...)` form is identical
/// otherwise. It only works inside a list literal, where the context type is
/// the entry — `.each(...)` is handed a `List`, so it stays spelled out.
const root = Pkg('.');
const app = Pkg('app');
const fixture = Pkg('fixtures/probe_app');
const brewline = Pkg('examples/brewline');
const webDemo = Pkg('web_demo');
const worldLab = Pkg('fixtures/world_lab/app');
const worldLabServer = Pkg('fixtures/world_lab/server');

void main() => Flutterware.configure((fw) {
  // **What to surface first on the changes screen, for this repository.**
  //
  // There are no built-in attention rules and there must not be: flutterware
  // cannot know whether a project has migrations, and putting a file under a
  // heading that says *look here first* is a claim only the person reading it
  // can make. So every entry below is a statement about *this* repo.
  fw.changes(
    ChangesConfig(
      attention: [
        // The file you are reading. A change here changes what every other
        // screen in the app is looking at.
        'tool/flutterware.dart',
        // Instructions to whoever — or whatever — is working in this checkout.
        // An agent quietly rewriting its own brief is the single thing most
        // worth seeing.
        'CLAUDE.md',
        // The published package's public surface. One added `export` in
        // `lib/plugins.dart` reads as a one-line change and *is* the API.
        'lib/*.dart',
        // The two versions CLAUDE.md says must stay in sync, and the SDK pin
        // that decides whether anything builds at all.
        'pubspec.yaml',
        'app/pubspec.yaml',
        '.fvmrc',
        // What CI will actually run, and the lint rules it runs with.
        '.github/workflows/**',
        'analysis_options.yaml',
        // The design docs. Every screen in this app was argued in one of
        // these first, and a spec moving is usually the reason the code did.
        'docs/superpowers/specs/**',
      ],
    ),
  );

  // **Which of the three packages is this repository, and its picture.** `app`
  // — the desktop GUI — because that is the thing a window of flutterware is
  // showing you. `.` is the published library, `fixtures/probe_app` is a
  // fixture and `examples/brewline` is the demo app; none of them is what you
  // point at to say "that project".
  //
  // The icon is the macOS art rather than a source file because that is where
  // `app/tool/icon/generate.dart` writes the largest version of it.
  fw.identity(
    const ProjectIdentity(
      package: app,
      icon: 'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png',
    ),
  );

  fw.use(
    Dependencies(
      packages: DependenciesPackage.each([root, app, fixture, brewline]),
    ),
  );
  fw.use(Assets(packages: AssetsPackage.each([root, app, fixture, brewline])));
  // The fixture app's render points — `lib/renders.dart` binds a chart
  // widget and a report document; the panel renders them on the same guest
  // a server would get from `fw render bundle`.
  fw.use(Renders(packages: const [RendersPackage(fixture)]));
  fw.use(
    Previews(
      packages: [
        // flutterware's own demos sit beside the harness that renders them
        // rather than in `demo/`, because they exist to exercise the catalog.
        //
        // **Declared desktop, because this app is a desktop app.** Almost
        // everything here is a piece of the studio's own chrome — a panel, a
        // bar, a row of a table — and undeclared they opened on the plain
        // rectangle, which offers no window size and reads as no opinion. It
        // is the same trap `PreviewsPackage.device` names in the other
        // direction: nothing about the wrong canvas looks wrong, and whoever
        // renders one of these has no way to know they should have said
        // `--device`. Measured 2026-08-17: an agent asked for a picture of a
        // 24pt control and got it on an iPad, because nothing said otherwise.
        .new(
          app,
          directory: 'tool/catalog',
          canvases: [
            // The head is the default and the list is what the picker offers,
            // so: open at the size the studio is usually run at, with the
            // narrow one beside it — the width most of these panels break at.
            PreviewCanvas(
              '',
              devices: [
                Devices.window,
                Devices.smallWindow,
                Devices.wideWindow,
              ],
            ),
          ],
        ),
        // The fixture is a phone app: its previews open on a phone, and the
        // web demo's do the same (see `app/lib/src/demo/recorded_project.dart`).
        // One file opts out, which is the point of the pair in `demo/`:
        // `home_page_mobile.dart` opens framed like everything else and
        // `home_page.dart` opens on the plain rectangle beside it. Declared
        // here rather than on the annotation because a device is a property of
        // where a preview is looked at, not of the widget — and a file is a
        // legal prefix precisely so one entry can differ from its neighbours.
        .new(
          fixture,
          canvases: [
            PreviewCanvas('', devices: [Devices.iphone16]),
            PreviewCanvas('demo/home_page.dart'),
          ],
        ),
        // The demo app, as its own `tool/flutterware.dart` declares it: the
        // shop's screens and its icon, on the two phones it ships on.
        .new(
          brewline,
          directory: 'demo',
          canvases: [
            PreviewCanvas('', devices: [Devices.iphone16, Devices.androidTall]),
          ],
        ),
      ],
    ),
  );
  // `example` only: a scene is rendered by the app whose theme and widgets
  // it uses. No `directory:` — a scene group is a folder with a `scenes.dart`
  // in it, found wherever it was written; `demo/` holds the one this
  // project has.
  fw.use(Scene(packages: [.new(fixture)]));
  // The two apps. `root` is a library and `app` is this GUI — neither has a
  // native splash to resolve, which is why `NativeSplash` offers no `each`.
  fw.use(NativeSplash(packages: [.new(fixture), .new(brewline)]));
  // The same two, and for the same reason: only a package that is an app has
  // launcher icons to look at. The fixture's are the wrong cases the viewer
  // is tested on; the demo app's are one clean set.
  fw.use(LauncherIcon(packages: [.new(fixture), .new(brewline)]));

  // **The demo shop's store listing.** `examples/brewline` is the app with a
  // listing; the fixture has screens nobody would put in a store.
  //
  // Both stores are declared even though Google Play's phone cannot be
  // exported yet: its canvas is 1080×2160 and an `android-tall` renders
  // 1082×2402, so that set is a *composition* and the frame that composes it
  // is not built. It is declared rather than commented out because that gap is
  // the thing to keep visible — the export names the set it deferred and why,
  // where a missing declaration would look like a listing nobody wanted.
  //
  // Nothing here pins a clock. A store run renders at the date every scenario
  // renders at — `pinnedClockOrigin` unless `fw.clock(...)` says otherwise —
  // which is what a listing needs and what a debugging run needs equally: a
  // capture carrying today's date changes every time anybody regenerates it,
  // and then nobody can tell a real change from a re-run.
  fw.use(
    StoreShots(
      apps: [
        StoreShotsApp(
          brewline,
          file: 'test/scenarios/mobile/shop_test.dart',
          // The listing's own composition — a panorama with tilted devices
          // that lean across the joins. See the file; it is the demo the
          // store design's §10i argues for.
          frame: 'lib/store_frame.dart',
          listings: [
            Listing.appStore(locales: {'en': 'en-US', 'fr': 'fr-FR'}),
            Listing.play(locales: {'en': 'en-US', 'fr': 'fr-FR'}),
          ],
        ),
      ],
    ),
  );
  fw.use(ServerInspection());
  // Repo-scoped, nothing to declare: the plugin discovers every
  // analysis_options.yaml itself, because "this rule is evaluated nowhere" is
  // only a truthful sentence about all of them at once.
  fw.use(Lints());
  // The same stack `fixtures/probe_app/tool/flutterware.dart` declares, from the
  // root of the monorepo it lives in — which is the whole job of
  // `workingDirectory:`. The commands are written as that package writes them
  // and run where it runs them, so one script serves both configs and neither
  // has to know where the other opened.
  //
  // `StackRun.script` rather than a command naming an interpreter: flutterware
  // supplies the SDK it is running under, which is the one the project pinned.
  // The `dart` on PATH is a different question with a frequently different
  // answer — in this repo, a two-versions-old one. This used to be
  // `Platform.resolvedExecutable` prepended to all six commands.
  fw.use(
    DevStack.background(
      label: 'Example server',
      workingDirectory: 'fixtures/probe_app',
      probe: Probe.json(
        StackRun.script('tool/stack.dart', args: ['status', '--json']),
      ),
      start: StackRun.script('tool/stack.dart', args: ['up']),
      stop: StackRun.script('tool/stack.dart', args: ['down']),
      poll: const Duration(seconds: 15),
      commands: [
        StackCommand(
          'logs',
          'Logs',
          StackRun.script('tool/stack.dart', args: ['logs']),
          description:
              'The last 40 lines the server logged. A background process has '
              'no terminal, so it appends to a file instead.',
        ),
        StackCommand(
          'hit',
          'Send a request',
          StackRun.script('tool/stack.dart', args: ['hit']),
          argument: 'path',
          description:
              'Requests a path — /users, /slow, /error — so the Server panel '
              'has traffic to show. Defaults to /users.',
        ),
      ],
    ),
  );
  // `example` only: it is the one package here that is an app you would put on
  // a phone. `app` is this GUI and `root` is a library.
  //
  // Named rather than left to the scan, which would find four `main()`s under
  // `lib/` and offer them by file name. `fwMarker` is a real parameter of that
  // app's `main` — see `fixtures/probe_app/lib/main.dart`; the entry below only
  // labels it, because the signature already says everything else.
  fw.use(
    Run(
      packages: [
        // The GUI itself, on the worktree shell. Launching it through Run is
        // what makes it *driveable* — the launch wraps the entry point in the
        // run guest — and driving the GUI with its own drive verbs is this
        // repo's dogfood loop.
        .new(
          app,
          entrypoints: [
            Entrypoint(
              'lib/main_dev.dart',
              name: 'Studio (dev)',
              description:
                  'The flutterware GUI on the worktree shell — the '
                  'edit-reload-drive inner loop for GUI work',
              platforms: [RunPlatform.desktop],
              // **The studio is a Flutter tool, so it needs a Flutter SDK, and
              // it is the one thing a launched app cannot find out.** A
              // `flutter run` hands its child a stripped environment: this
              // process cannot see which `flutter` started it, and guessing
              // from PATH would pick a different version from the one `.fvmrc`
              // pins. So flutterware says it out loud — `from:` is the launcher
              // handing over the SDK it is building with, and `required:` is
              // what refuses a launch that somehow arrives without one.
              //
              // It was neither before, and the cost was paid on every session:
              // the launch succeeded, ~40s of build went by, and `main` threw
              // on an empty string. Three equal-looking knobs with no defaults
              // said nothing about which of them was load-bearing.
              knobs: [
                Knob(
                  'flutterSdkRoot',
                  label: 'Flutter SDK',
                  description:
                      'The SDK the studio runs projects with. Supplied by '
                      'whichever flutterware launched this one',
                  from: ValueSource.flutterSdk,
                  required: true,
                ),
                Knob(
                  'appRoot',
                  label: 'App root',
                  description:
                      'The flutterware_app package root — where tool/catalog/ '
                      'lives. Only the catalog panel reads it, and only when '
                      'it is opened',
                ),
              ],
            ),
            Entrypoint(
              'lib/canvas_toy/main.dart',
              name: 'Canvas toy',
              description:
                  'Disposable scene-canvas experiment — uniform-node model, '
                  'selection, drag, inspector',
              platforms: [RunPlatform.desktop],
            ),
          ],
        ),
        .new(
          fixture,
          // The sample declares Android product flavors — fixtures for the
          // launcher-icon viewer, see `fixtures/probe_app/README.md` — but its
          // pubspec deliberately has no `default-flavor`: the flutter tool
          // applies that field on every platform, and on macOS and iOS it
          // then demands an Xcode scheme named after a flavor only Android
          // has, underneath any flag the cockpit drops. So the pairing is
          // said per entry point (`flavorByPlatform` below), and the empty
          // lists here stay truthful: those platforms have no flavors, and
          // nothing re-adds one after the vocabulary drops the flag.
          flavors: {
            RunPlatform.android: [
              'free',
              'beta',
              'kiosk',
              'partner',
              'proMonthly',
              'proYearly',
            ],
            RunPlatform.desktop: [],
            RunPlatform.ios: [],
            RunPlatform.web: [],
          },
          entrypoints: [
            Entrypoint(
              'lib/main.dart',
              name: 'App',
              description: 'The fixture app, with the devbar mounted',
              flavorByPlatform: {RunPlatform.android: 'free'},
              knobs: [
                Knob(
                  'fwMarker',
                  label: 'Marker',
                  description:
                      'Shown on the home page, to prove which launch is on '
                      'the device',
                ),
              ],
            ),
            Entrypoint(
              'lib/devbar_example.dart',
              name: 'Devbar',
              description: 'Every devbar plugin, on a demo screen',
              flavorByPlatform: {RunPlatform.android: 'free'},
            ),
            // Outside `lib/`, which is the reason it is declared: the wrapper
            // that installs the run guest names this file by path and the enum
            // beside it by path, so a launch of it is the live check that a
            // dev-only entry point kept out of what ships is still driveable.
            Entrypoint(
              'demo/main_dev.dart',
              name: 'Dev entry point',
              description:
                  'A dev-only entry point in demo/ — the non-package: case '
                  'for the run guest wrapper',
              platforms: [RunPlatform.desktop],
              knobs: [
                Knob('seed', description: 'What to put in the app at startup'),
                Knob('marker', label: 'Marker'),
              ],
            ),
            Entrypoint(
              'lib/ui_book.dart',
              name: 'UI book',
              description: 'The component gallery, no backend',
              // Not a restriction the gallery needs — it runs anywhere — but
              // the one entry point here that is worth reading a device list
              // through, and this repo is the monorepo test case.
              platforms: [RunPlatform.desktop, RunPlatform.web],
            ),
          ],
        ),
        // The demo app: no flavors, so nothing to pair, and the same two
        // entry points its own config declares.
        .new(
          brewline,
          entrypoints: [
            Entrypoint(
              'lib/main.dart',
              name: 'Brewline',
              description: 'The coffee shop',
            ),
            Entrypoint(
              'lib/shop_devbar.dart',
              name: 'Brewline (devbar)',
              description:
                  'The shop, with a plugin that pushes a notification into '
                  'it — the sample for driving an app from the cockpit, '
                  '`fw` or an agent',
            ),
          ],
        ),
        // The worlds lab's customer app — what the lab's worlds launch for
        // each person, with their server, session and name as knobs. See
        // `fixtures/world_lab/README.md`.
        .new(
          worldLab,
          entrypoints: [
            Entrypoint(
              'lib/main.dart',
              name: 'Lab',
              description:
                  'The pickup app, against the lab server on :8090 unless '
                  'told otherwise',
              knobs: [
                Knob(
                  'person',
                  label: 'Person',
                  description: 'Whose app this is, shown in its title',
                ),
                Knob(
                  'session',
                  label: 'Session',
                  description:
                      'A session token from the server, which signs the app '
                      'in without a code',
                ),
                Knob('server', label: 'Server'),
              ],
            ),
          ],
        ),
      ],
    ),
  );
  // The lab's worlds, run in the lab server's package: it hosts the server
  // and seeds it through its own API.
  fw.use(Worlds(packages: [.new(worldLabServer)]));
  // The fixture's scenarios pin the runner; the demo app's are the sample.
  fw.use(
    Scenarios(
      packages: [
        .new(fixture, languages: ['en', 'fr']),
        .new(brewline, languages: ['en', 'fr']),
        // The studio itself, over a recording of the demo app — see
        // `app/lib/src/demo/`. Narrowed to its own folder: `app/test/` is
        // hundreds of widget tests, and only these are scenarios. The folder
        // carries the profile that frames them as a window, which is also
        // what `flutter test` runs them at.
        .new(app, directory: 'test/scenarios/studio'),
        // The web demo itself, walked under the harness: the same shell,
        // recording and compiled-in previews the page is built from.
        .new(webDemo, directory: 'test/scenarios'),
      ],
    ),
  );

  // **The demo shop's copy, and where it lives.** `examples/brewline` funnels
  // every string through one function, and its scenario config hands that
  // funnel `indexTranslations('shop')` — so a run can say which key is on
  // which screen. This declares the other half: where the words themselves
  // are, which is the only thing a run cannot work out for itself.
  fw.use(
    Translations(
      packages: [
        TranslationsPackage(
          brewline,
          catalogs: [
            TranslationCatalog(name: 'shop', files: 'assets/i18n/*.json'),
            // The listing's headlines. A second catalog rather than more keys
            // in the first: marketing copy is not UI, and a translator sent
            // the shop's strings should not find `Tap. Pay. Collect.` among
            // them. Store design, decision 9.
            TranslationCatalog(name: 'store', files: 'assets/store/*.json'),
          ],
        ),
      ],
    ),
  );
});
