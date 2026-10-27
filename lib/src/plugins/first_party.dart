/// The first-party plugins, as a project declares them in
/// `tool/flutterware.dart`:
///
/// ```dart
/// const app = Pkg('packages/app');
///
/// void main() => Flutterware.configure((fw) {
///   fw.use(Previews(packages: [.new(app, directory: 'demo')]));
/// });
/// ```
///
/// These carry identity and configuration only — the behaviour for each id is
/// compiled into the GUI. They live here, in the pure-Dart package, because the
/// config file runs under a plain `dart run` and cannot see the GUI.
library;

import '../../devices.dart';
import '../scenarios/time_mode.dart';
import 'manifest.dart' show foldersConfigKey;
import 'package.dart';
import 'plugin.dart';

/// Pub dependencies, per declared package.
class Dependencies extends Plugin {
  Dependencies({this.packages = const [], String? label})
    : super('flutterware.dependencies', label: label ?? 'Dependencies');

  final List<DependenciesPackage> packages;

  @override
  Map<String, Object?> get config => {
    'packages': [for (var p in packages) p.toJson()],
  };
}

class DependenciesPackage extends PluginPackage {
  const DependenciesPackage(super.pkg);

  /// Every package — for plugins where per-package options are genuinely
  /// optional. Offered per plugin, never as a framework rule.
  static List<DependenciesPackage> each(List<Pkg> packages) => [
    for (var pkg in packages) DependenciesPackage(pkg),
  ];
}

/// The app's render points — widgets and documents bound in a
/// `@RenderRegistry()` registrar, rendered as SVG, PNG or PDF in the studio
/// and from a server through `fw render bundle`.
class Renders extends Plugin {
  Renders({this.packages = const [], String? label})
    : super('flutterware.render', label: label ?? 'Render');

  final List<RendersPackage> packages;

  @override
  Map<String, Object?> get config => {
    'packages': [for (var p in packages) p.toJson()],
  };
}

class RendersPackage extends PluginPackage {
  const RendersPackage(super.pkg, {this.target = 'lib/renders.dart'});

  /// The file declaring the registrar, relative to the package root.
  final String target;

  @override
  Map<String, Object?> toJson() => {...super.toJson(), 'target': target};
}

/// Everything a package's bundle resolves to — declared assets, the density
/// variants beside them, the fonts, and whatever its dependencies contribute.
class Assets extends Plugin {
  Assets({this.packages = const [], String? label})
    : super('flutterware.assets', label: label ?? 'Assets');

  final List<AssetsPackage> packages;

  @override
  Map<String, Object?> get config => {
    'packages': [for (var p in packages) p.toJson()],
  };
}

class AssetsPackage extends PluginPackage {
  const AssetsPackage(super.pkg);

  /// Every package. Offered because there is nothing to configure per package
  /// here — the pubspec is the declaration — so naming them one at a time only
  /// creates a chance to forget one.
  static List<AssetsPackage> each(List<Pkg> packages) => [
    for (var pkg in packages) AssetsPackage(pkg),
  ];
}

/// Previews — your `@Preview`s, rendered in the embedded engine.
///
/// Wherever they are: the whole package is scanned, so a preview beside the
/// widget it shows is found without being declared.
/// [PreviewsPackage.directory] narrows that, and is the only reason to name a
/// directory at all.
class Previews extends Plugin {
  Previews({this.packages = const [], String? label})
    : super('flutterware.previews', label: label ?? 'Previews');

  final List<PreviewsPackage> packages;

  @override
  Map<String, Object?> get config {
    for (var package in packages) {
      if (package.duplicateCanvasPrefix case var prefix?) {
        throw StateError(
          'Package "${package.path}" declares the canvas '
          '"${prefix.isEmpty ? '<the whole package>' : prefix}" twice. '
          'Longest prefix wins, so two canvases with one prefix are the same '
          'rule written twice. Put its devices in a single PreviewCanvas.',
        );
      }
      if (package.unknownDevice case var device?) {
        throw StateError(
          'Package "${package.path}" frames previews on the device '
          '"${device.id}", which is not one of `Devices`. A preview names its '
          'device by id, so this one would be dropped and its entries drawn '
          'on the plain $previewPanelWidth × $previewPanelHeight rectangle. '
          'Pick a device from `Devices`. For a size no device has, leave the '
          'canvas without devices and give the screenshot a width and a '
          'height.',
        );
      }
    }
    return {
      'packages': [for (var p in packages) p.toJson()],
    };
  }
}

class PreviewsPackage extends PluginPackage {
  const PreviewsPackage(
    super.pkg, {
    this.directory,
    this.previewAnnotations,
    this.device,
    this.orientation,
    this.canvases = const [],
    this.setup,
  });

  /// A file whose `previewSetup()` runs once, before any preview in this
  /// package builds — relative to the package, e.g. `'lib/preview_setup.dart'`.
  ///
  /// ```dart
  /// // lib/preview_setup.dart
  /// Future<void> previewSetup() async {
  ///   GoogleFonts.config.allowRuntimeFetching = false;
  /// }
  /// ```
  ///
  /// The function is top-level, takes no arguments and returns `void` or a
  /// `Future<void>`, which is awaited. It runs after the binding exists and
  /// before the first entry is built, on every engine a preview renders on:
  /// the panel's guest, the `flutter_tester` lane that `screenshot`, `audit`
  /// and `compare` use, and the page `build-web` writes. Which makes it the
  /// place for what an app does once in `main` and every entry would
  /// otherwise need from its `wrapper:` — turning off a font package's
  /// downloads, registering fonts, installing `HttpOverrides`.
  ///
  /// Declared rather than found: a file named here that does not exist, or
  /// that declares no `previewSetup`, is reported and every render of the
  /// package refused, because rendering without it would draw every entry
  /// plausibly wrong.
  final String? setup;

  /// What the previews under each subtree are framed as. See [PreviewCanvas].
  ///
  /// [device] is one of these with no prefix, which is the whole relationship
  /// between the two: a project that is all phones says `device:` and is done,
  /// and a package holding two form factors says where each of them lives.
  ///
  /// ```dart
  /// PreviewsPackage(app, directory: 'demo', canvases: [
  ///   PreviewCanvas('demo/src/mobile', devices: [Devices.iphone16]),
  ///   PreviewCanvas('demo/src/desktop', devices: [Devices.wideWindow]),
  /// ])
  /// ```
  ///
  /// Here rather than one package declaration per form factor, which is the
  /// obvious shape to reach for and the one thing that cannot work: a
  /// package's path is the identity of its entry in the report, in `fw:///`
  /// addresses and in the previews compiler's own daemon address, so a second
  /// declaration of one package is not a second thing anything downstream could
  /// name. `Flutterware.configure` refuses it outright for that reason.
  ///
  /// Longest prefix wins, and two canvases with the same prefix are refused —
  /// they are one rule written twice, and either resolution drops a declared
  /// answer.
  final List<PreviewCanvas> canvases;

  /// What this package's previews are framed as when a caller names no device
  /// — the panel's canvas, every `screenshot`, `inspect` and `compare`, and the
  /// page `build-web` writes.
  ///
  /// Null is a rectangle, and for a phone app that is the wrong picture.
  /// Without a device a preview renders at 900 × 700, which is landscape and
  /// desktop-shaped: a phone screen laid out in it does not overflow, does not
  /// wrap and looks fine, so the default hides the bug you opened the preview
  /// to find. Nothing about it *looks* wrong either, which is why this is
  /// declared rather than left to be passed — an agent taking screenshots has
  /// no way to know it should have said `--device`.
  ///
  /// One line for the project instead of a `--device` on every call site,
  /// script and CI invocation, one of which will forget. A call that names a
  /// device still wins, and `--device=fit` is how one call asks for the plain
  /// rectangle back.
  final Device? device;

  /// Which way up [device] is. Ignored when nothing can turn — every desktop
  /// size, and the plain rectangle.
  final ScreenOrientation? orientation;

  /// Narrows the scan to one directory, relative to the package.
  ///
  /// Null scans the whole package, which is the default and what most
  /// projects want: previews are found wherever they are written, ignored files
  /// and `build/` excluded the way git excludes them. Naming a directory is for
  /// a package that wants the scan bounded — and it moves `new` there too, so
  /// the place files are written and the place they are looked for stay the
  /// same.
  final String? directory;

  /// The annotation names that mark an entry, without their `@`.
  ///
  /// `['Preview']` when null. A project that defines its own — e.g.
  /// `base class Tablet extends Preview` — registers it here, which is what makes
  /// recognition **by registration** rather than by resolving the class
  /// hierarchy: discovery parses, and a parser cannot know what a name extends.
  /// Naming a subclass here does not drop the defaults; list them if you want
  /// them.
  final List<String>? previewAnnotations;

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    if (directory != null) 'directory': directory,
    if (previewAnnotations != null) 'previewAnnotations': previewAnnotations,
    if (device != null) 'device': device!.id,
    if (orientation != null) 'orientation': orientation!.name,
    if (canvases.isNotEmpty) 'canvases': [for (var c in canvases) c.toJson()],
    if (setup != null) 'setup': setup,
  };

  /// The prefix this package names twice, or null when each is named once.
  ///
  /// Refused rather than resolved, for the reason a duplicate package is: one
  /// of the two answers is dropped, and nothing says which — least of all the
  /// output, where a rule that lost quietly looks exactly like a rule that
  /// never applied.
  String? get duplicateCanvasPrefix {
    var seen = <String>{};
    for (var canvas in canvases) {
      if (!seen.add(canvas.root)) return canvas.root;
    }
    return null;
  }

  /// The first device in [device] or [canvases] that is not in [Devices], or
  /// null when each of them is.
  ///
  /// Refused rather than dropped. A device crosses to the renderer as its id,
  /// and the far side looks the id up in the table: an id it does not have
  /// resolves to nothing, and one it does resolves to the table's screen, not
  /// this one. Either way the picture is taken on something nobody declared,
  /// and it looks like a preview rather than like a mistake.
  ///
  /// `const Device(...)` is public, and a size of one's own — store artwork is
  /// a fixed number of pixels — is exactly what reaches for it.
  Device? get unknownDevice {
    for (var candidate in [?device, for (var c in canvases) ...c.devices]) {
      if (!identical(deviceById(candidate.id), candidate)) return candidate;
    }
    return null;
  }

  static List<PreviewsPackage> each(List<Pkg> packages) => [
    for (var pkg in packages) PreviewsPackage(pkg),
  ];
}

/// Scenarios — app tests with per-step screenshots, run under FakeAsync in a
/// directly-spawned `flutter_tester`.
class Scenarios extends Plugin {
  Scenarios({this.packages = const [], String? label})
    : super('flutterware.scenarios', label: label ?? 'Scenarios');

  final List<ScenariosPackage> packages;

  @override
  Map<String, Object?> get config => {
    'packages': [for (var p in packages) p.toJson()],
    // A package may keep two suites — a fake-time folder and a real-time
    // one — and this plugin addresses the second by its directory.
    foldersConfigKey: true,
  };
}

class ScenariosPackage extends PluginPackage {
  const ScenariosPackage(
    super.pkg, {
    this.directory,
    this.languages,
    this.captureScale,
    this.time,
  });

  /// Where this package keeps its scenarios, relative to the package. When
  /// null, discovery walks all of `test/` — a scenario is an ordinary widget
  /// test and may sit next to the rest of them — and `new` writes to
  /// `test/scenarios`. Declaring a directory narrows both to it.
  final String? directory;

  /// The locale tags this app supports — `['en', 'fr']` — offered by the
  /// language axis. Null means the axis offers no list and runs stay on the
  /// platform default.
  final List<String>? languages;

  /// Screenshot pixels per logical pixel for every run of this package —
  /// `3` renders retina captures, at roughly the device ratio's cost in
  /// time and bytes. Null means 1, the measured sweet spot; a run's own
  /// `capture-scale` argument still wins.
  final double? captureScale;

  /// The folder's clock. `ScenarioTime.real()` runs it on the wall clock with
  /// real sockets, one guest per scenario. Must agree with the folder's own
  /// `runScenarios(time: …)`; the harness refuses at probe when they differ.
  /// Null is [ScenarioTime.fake].
  final ScenarioTime? time;

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    if (directory != null) 'directory': directory,
    if (languages != null) 'languages': languages,
    if (captureScale != null) 'captureScale': captureScale,
    if (time case var time?) 'time': time.name,
    if (time case ScenarioTimeReal(:var animations)) 'animations': animations,
  };

  static List<ScenariosPackage> each(List<Pkg> packages) => [
    for (var pkg in packages) ScenariosPackage(pkg),
  ];
}

/// Translations — which key is on which screen, and a picture of it.
///
/// Two halves that have to agree on a name. In the app, a test hands
/// `indexTranslations('app')` to whatever the catalog funnels its reads
/// through; here, a catalog called `app` says where that catalog's files
/// live. Neither half can produce an export alone — the run knows where a key
/// appeared, only the files know which keys exist and what each locale says —
/// which is why the files are declared rather than discovered. Guessing at a
/// translations directory would be a claim about a project's layout that only
/// the project can make.
class Translations extends Plugin {
  Translations({this.packages = const [], String? label})
    : super('flutterware.translations', label: label ?? 'Translations');

  final List<TranslationsPackage> packages;

  @override
  Map<String, Object?> get config => {
    'packages': [for (var p in packages) p.toJson()],
  };
}

/// Lints — which analyzer rules this repo evaluated, and which it never did.
///
/// Repo-scoped rather than package-scoped, deliberately: `analysis_options.yaml`
/// files inherit across package boundaries (a member includes the root), so
/// "this rule is mentioned nowhere" is only a truthful sentence about the
/// union. The plugin discovers every options file itself; there is nothing to
/// declare.
class Lints extends Plugin {
  Lints({String? label}) : super('flutterware.lints', label: label ?? 'Lints');
}

class TranslationsPackage extends PluginPackage {
  const TranslationsPackage(super.pkg, {this.catalogs = const []});

  /// Where this package's translations live.
  ///
  /// A list, never a single catalog with a special case. Several in one
  /// UI is ordinary — a product's own strings beside a shared package's, or
  /// two halves of a migration — and a shape that makes the second one awkward
  /// is a shape that gets worked around.
  final List<TranslationCatalog> catalogs;

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    'catalogs': [for (var c in catalogs) c.toJson()],
  };
}

/// One catalog, as `tool/flutterware.dart` declares it.
///
/// Sealed, for the reason [StackRun] is: the variants do not carry the same
/// thing. A file per locale is found with a **glob**, because there is one
/// file for each of them; every locale under a key is **one file**, and
/// `files` naming it would be a plural that is never plural. The gap widens
/// with the next format rather than closing — an ARB carries its locale
/// inside the file and hides metadata under `@`-prefixed keys, a CSV needs to
/// be told its delimiter and which column holds the key. None of those are a
/// mode of one shape; each is its own set of questions, and a class per format
/// is where the answers go.
///
/// The alternative — one class with a `layout:` and the union of every
/// format's parameters on it — reads fine at two and stops reading at three,
/// because most of the fields on any one declaration would not apply to it.
sealed class TranslationCatalog {
  const TranslationCatalog._({required this.name, required this.template});

  /// One file per locale, named for it, each a flat object of key to string:
  /// `en.json` holding `{"save": "Save"}`.
  ///
  /// Unnamed because it is the shape every declaration had before there was a
  /// choice, so those go on compiling.
  ///
  /// [files] is a glob, package-relative like every other path in this file,
  /// and the locale is each file's base name: `en.json` is `en`. That is a
  /// convention rather than a parse, and a file whose name is not a locale tag
  /// is skipped rather than loaded as a locale called `schema`.
  const factory TranslationCatalog({
    required String name,
    required String files,
    String template,
  }) = FilePerLocaleCatalog;

  /// Every locale under each key, in one file: `strings.json` holding
  /// `{"save": {"en": "Save", "nl": "Opslaan"}}`.
  ///
  /// What a catalog looks like where a human or a translation service fills in
  /// languages a key at a time — the row is the unit of work, so the row holds
  /// every language.
  ///
  /// ```dart
  /// TranslationCatalog.localesPerKey(
  ///   name: 'server',
  ///   file: 'tool/translations/strings.json',
  /// )
  /// ```
  const factory TranslationCatalog.localesPerKey({
    required String name,
    required String file,
    String template,
  }) = LocalesPerKeyCatalog;

  /// What the seam calls it — `indexTranslations('app')` and this must agree.
  ///
  /// Free-form, and this is the only place the two names have to meet. A name
  /// the index reports and nothing declares is refused with the declared list,
  /// rather than quietly producing an export that attributes half its keys.
  final String name;

  /// The locale the source text is written in.
  ///
  /// It decides two of the three findings an export can make, which is why it
  /// is declared rather than assumed: a key the template has no text for is
  /// skipped entirely — there is nothing to fall back *to*, and a key only a
  /// target locale defines is usually stale — and a locale that *is* the
  /// template is never reported as falling back to itself or as disagreeing
  /// with itself. It is also the text shown beside a key as what a translator
  /// is working from.
  final String template;

  /// The value of [layoutKey] this variant writes, and what
  /// [TranslationCatalog.fromJson] reads it back by.
  String get layout;

  Map<String, Object?> toJson();

  /// Where a serialised catalog says which variant it is.
  static const layoutKey = 'layout';

  /// Reads back what [toJson] wrote, or **null for a layout this build does
  /// not know** — a project pinning a newer flutterware than the studio
  /// opening it, which is a thing to report rather than to guess at. Guessing
  /// would read a CSV as JSON and call the catalog empty.
  static TranslationCatalog? fromJson(Map<String, Object?> json) {
    var name = json['name'] as String? ?? '';
    var template = json['template'] as String? ?? 'en';
    switch (json[layoutKey]) {
      // Absent is not unknown: every declaration written before there was a
      // choice described a file per locale, because it was the only thing the
      // loader could read.
      case null:
      case FilePerLocaleCatalog._layout:
        return FilePerLocaleCatalog(
          name: name,
          files: json['files'] as String? ?? '',
          template: template,
        );
      case LocalesPerKeyCatalog._layout:
        return LocalesPerKeyCatalog(
          name: name,
          file: json['file'] as String? ?? '',
          template: template,
        );
    }
    return null;
  }
}

/// See [TranslationCatalog.new].
final class FilePerLocaleCatalog extends TranslationCatalog {
  const FilePerLocaleCatalog({
    required super.name,
    required this.files,
    super.template = 'en',
  }) : super._();

  static const _layout = 'filePerLocale';

  /// A glob of the catalog's files, one per locale and named for it.
  final String files;

  @override
  String get layout => _layout;

  @override
  Map<String, Object?> toJson() => {
    'name': name,
    'files': files,
    'template': template,
    TranslationCatalog.layoutKey: _layout,
  };
}

/// See [TranslationCatalog.localesPerKey].
final class LocalesPerKeyCatalog extends TranslationCatalog {
  const LocalesPerKeyCatalog({
    required super.name,
    required this.file,
    super.template = 'en',
  }) : super._();

  static const _layout = 'localesPerKey';

  /// The catalog's one file, package-relative. Singular and not a glob: every
  /// locale is already inside it, so there is nothing for a second file to be.
  final String file;

  @override
  String get layout => _layout;

  @override
  Map<String, Object?> toJson() => {
    'name': name,
    'file': file,
    'template': template,
    TranslationCatalog.layoutKey: _layout,
  };
}

/// The scene editor: WYSIWYG scenes and the motion that animates them, in
/// files this tool owns end to end (`*.scene.dart`).
///
/// A scene is rendered by the app itself — declare a `@Preview` entry named
/// `sceneCanvasHost` in the package whose theme and widgets the scenes use,
/// and the editor composites it.
class Scene extends Plugin {
  Scene({this.packages = const [], String? label})
    : super('flutterware.scene', label: label ?? 'Scene');

  final List<ScenePackage> packages;

  @override
  Map<String, Object?> get config => {
    'packages': [for (var p in packages) p.toJson()],
  };
}

class ScenePackage extends PluginPackage {
  const ScenePackage(super.pkg, {this.directory});

  /// Where the package is scanned for scene groups, relative to the package;
  /// the whole package when null. A group is a folder with a `scenes.dart`
  /// in it, found wherever it was written — this only narrows the walk for a
  /// package large enough to want that.
  final String? directory;

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    if (directory != null) 'directory': directory,
  };

  static List<ScenePackage> each(List<Pkg> packages) => [
    for (var pkg in packages) ScenePackage(pkg),
  ];
}

/// Worlds: several people on your real server, set up by a script.
///
/// A world is a Dart file whose `main` calls `World.run`, from
/// `package:flutterware/world.dart`, in the package that can start the server
/// and seed it: for a Dart server, the server's own package. Each is declared
/// here, by [WorldScript], the way Run's entry points are — a project has a
/// few worlds, each named on purpose, so nothing is scanned for:
///
/// ```dart
/// fw.use(Worlds(packages: [
///   .new(server, worlds: [
///     WorldScript('tool/worlds/pickup_order.dart', name: 'Pickup order'),
///   ]),
/// ]));
/// ```
///
/// Opening one runs it in its package; the people it declares get their
/// apps, each launched from one of Run's entry points.
class Worlds extends Plugin {
  Worlds({this.packages = const [], String? label})
    : super('flutterware.worlds', label: label ?? 'Worlds');

  final List<WorldsPackage> packages;

  @override
  Map<String, Object?> get config {
    // A world is opened by its file's name — `worlds open --world=…` — so two
    // of one name would be one world written twice.
    var seen = <String, String>{};
    for (var package in packages) {
      for (var world in package.worlds) {
        if (seen[world.id] case var other?) {
          throw StateError(
            'Two worlds are called "${world.id}": ${world.path} in '
            '"${package.path}" and one in "$other". A world is opened by its '
            "file's name, so rename one of the files.",
          );
        }
        seen[world.id] = package.path;
      }
    }
    return {
      'packages': [for (var p in packages) p.toJson()],
    };
  }
}

class WorldsPackage extends PluginPackage {
  const WorldsPackage(super.pkg, {this.worlds = const []});

  /// The package's worlds.
  final List<WorldScript> worlds;

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    'worlds': [for (var world in worlds) world.toJson()],
  };
}

/// One world: its file, and what to call it.
class WorldScript {
  const WorldScript(this.path, {this.name, this.description});

  /// Relative to the package, `/`-separated. `tool/worlds/` is the place to
  /// keep them: they are scripts the project runs, not code it ships.
  final String path;

  /// What the studio and `worlds list` call it; the file's name as words,
  /// `Pickup order`, when not given.
  final String? name;

  /// What it sets up, in a sentence or two — who is in it, and what state
  /// they start in.
  final String? description;

  /// What `worlds open` takes: the file's name without `.dart`.
  String get id {
    var file = path.split('/').last;
    return file.endsWith('.dart')
        ? file.substring(0, file.length - '.dart'.length)
        : file;
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'name': ?name,
    'description': ?description,
  };
}

/// The native splash screen: what `flutter_native_splash` will produce, on
/// every surface and in both themes.
///
/// Like [LauncherIcon] it offers no `each`: a splash config only means anything
/// in a package that is an app, and quietly declaring one for a pure Dart
/// library would report "no splash configured" forever.
class NativeSplash extends Plugin {
  NativeSplash({this.packages = const [], String? label})
    : super('flutterware.splash', label: label ?? 'Splash screen');

  final List<NativeSplashPackage> packages;

  @override
  Map<String, Object?> get config => {
    'packages': [for (var p in packages) p.toJson()],
  };
}

class NativeSplashPackage extends PluginPackage {
  const NativeSplashPackage(super.pkg);
}

/// Live inspection of the project's Dart servers: HTTP requests, SQL queries
/// and logs, reported from inside the running process by
/// `package:flutterware/server.dart`.
///
/// Deliberately declares no `packages:` — a server announces *itself* at
/// runtime with a handle under `~/.flutterware/run`, however it was launched,
/// so there is nothing to configure but the wish to see them.
class ServerInspection extends Plugin {
  ServerInspection({String? label})
    : super('flutterware.server', label: label ?? 'Server');
}

/// Running the app on a device: what is connected, what is free, what is
/// already running where — across every worktree of the repo, not just this
/// one — and launching an entry point onto it.
///
/// ```dart
/// fw.use(Run(packages: [
///   RunPackage(app, entrypoints: [
///     Entrypoint('lib/main.dart', name: 'App'),
///     Entrypoint('lib/main_staging.dart', name: 'Staging', knobs: [
///       Knob('apiHost', from: ValueSource.hostAddresses),
///       Knob('serverPort',
///           from: ValueSource.script('tool/local_env.dart',
///               args: ['port', 'server'])),
///     ]),
///   ]),
/// ]));
/// ```
///
/// The knobs are the entry point's own `main({String apiHost = 'localhost',
/// int serverPort = 8086})` — the config only annotates them. Changing one
/// costs a hot restart rather than a rebuild, which is the whole difference
/// from the `--dart-define`s this replaced.
///
/// [ValueSource] lists what a `from:` can work out for itself.
///
/// Offers no `each`, like [LauncherIcon] and for the same reason: only a
/// package that is an app can be run onto a phone.
class Run extends Plugin {
  Run({this.packages = const [], String? label})
    : super('flutterware.run', label: label ?? 'Run');

  final List<RunPackage> packages;

  @override
  Map<String, Object?> get config => {
    'packages': [for (var p in packages) p.toJson()],
  };
}

class RunPackage extends PluginPackage {
  const RunPackage(
    super.pkg, {
    this.entrypoints = const [],
    this.flavors = const {},
  });

  /// The `main()`s worth launching, named.
  ///
  /// Empty means "scan for them": every `lib/*.dart` with a `main()` is
  /// offered, under its file name. The scan is provisional and this list is
  /// authority — the rule discovery already has everywhere else.
  ///
  /// Naming them is worth more than it looks. An agent picks an entry point
  /// off a list, and `Staging` tells it what the thing is where
  /// `main_staging.dart` only tells it where the thing lives.
  final List<Entrypoint> entrypoints;

  /// The flavors this package has, per platform — the author's word, so the
  /// cockpit can offer a list instead of an empty box and a launch can refuse
  /// a name the build system was never going to accept.
  ///
  /// ```dart
  /// flavors: {
  ///   RunPlatform.mobile: ['local', 'kioskLocal', 'staging', 'prod'],
  ///   RunPlatform.macos: ['local', 'staging', 'prod'],
  ///   RunPlatform.linux: [], // this platform has no flavors
  /// },
  /// ```
  ///
  /// Declared rather than discovered, deliberately: the real authorities are
  /// Gradle and the Xcode schemes, which cost three parsers to read — see
  /// the note on the pubspec's `default-flavor` — and on Linux and Windows
  /// there is nothing to read at all, since `--flavor` there gates no build
  /// and merely sets `FLUTTER_APP_FLAVOR`.
  ///
  /// Four rules, one per shape:
  ///
  /// - **Not declared at all**: nothing changes — free text, no checking.
  /// - **A platform not in the map**: unknown vocabulary; a flavor there is
  ///   passed as written and unchecked. Omission means "I did not say",
  ///   never "there are none".
  /// - **A platform mapped to `[]`**: this platform has no flavors, and it
  ///   behaves the way web already does — the launch drops the flag instead
  ///   of handing Xcode a scheme that does not exist.
  /// - **A platform with a list**: the New run page offers a picker, and a
  ///   launch whose flavor is not on the list refuses before building — a
  ///   typo becomes a sentence naming the list instead of a Gradle failure
  ///   minutes later.
  ///
  /// Keys follow the same rules as [Entrypoint.flavorByPlatform]: shorthands
  /// allowed, a concrete key beats the shorthand containing it. The list
  /// carries **no default** — order means nothing. Which flavor an entry
  /// point builds with is [Entrypoint.flavor]'s job, and what a bare
  /// `flutter run` does is the pubspec's `default-flavor:` — a third answer
  /// here could only disagree with those two.
  final Map<RunPlatform, List<String>> flavors;

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    // As written, shorthand keys and all — the same author's-word rule as
    // `Entrypoint.platforms`.
    if (flavors.isNotEmpty)
      'flavors': {
        for (var entry in flavors.entries) entry.key.name: entry.value,
      },
    if (entrypoints.isNotEmpty)
      'entrypoints': [for (var e in entrypoints) e.toJson()],
  };
}

/// One `main()` a package can be launched from.
class Entrypoint {
  const Entrypoint(
    this.path, {
    this.name,
    this.description,
    this.flavor,
    this.flavorByPlatform = const {},
    this.platforms = const [],
    this.knobs = const [],
  });

  /// Package-relative, `/`-separated — `lib/main_staging.dart`.
  final String path;

  /// What a human and an agent call it. The file's name when null.
  final String? name;

  /// The knobs this entry point's `main` takes, annotated — see [Knob].
  ///
  /// Declaring none is the ordinary case: the signature is the list, and an
  /// unannotated parameter still gets a control with its own name, type
  /// and default. This is for the two things a signature cannot say — a
  /// computed value, and a human label.
  final List<Knob> knobs;

  /// What this entry point *is*, in a line.
  ///
  /// `Kiosk` and `Onboarding` are unguessable from their file names, and the
  /// picker is where that costs you. An agent choosing between entry points
  /// reads the same field, so it pays twice.
  final String? description;

  /// The `--flavor` this entry point is built with — `dev`, `staging`.
  ///
  /// A flavoured project cannot be run without one at all. Where a missing
  /// `--dart-define` merely gives you the fallback value, a missing `--flavor`
  /// on a project that declares product flavors is a hard failure before
  /// anything is compiled: Gradle has no such variant, and Xcode has no such
  /// scheme. So this is not a convenience — for those projects it is the
  /// difference between an entry point that launches and one that cannot.
  ///
  /// Declared per entry point because that is how the pairing actually works:
  /// `main_dev.dart` goes with `dev`, and it is the same fact twice. To run one
  /// entry point under several flavors, declare it several times with different
  /// [name]s, or pass `flavor` to the launch action. When the flavor varies by
  /// *platform* rather than by intent, that is [flavorByPlatform], not a second
  /// declaration.
  ///
  /// Every platform but web — `supportsFlavors` is true on Linux, macOS and
  /// Windows as well as Android and iOS, and web is the one that inherits the
  /// `false` default. Declaring one on an entry point that also runs in a
  /// browser is fine: the launch drops the flag there rather than refusing,
  /// which is what a project setting `flutter: default-flavor:` for its web
  /// build already expects.
  final String? flavor;

  /// [flavor], where it depends on the platform the launch targets.
  ///
  /// The case is real: an app split into two store identities builds the same
  /// entry point under `kioskLocal` on a phone — where the flavor decides
  /// the package id and the deep links, and the wrong one *installs over the
  /// other app* — and under plain `local` on a desktop, where none of that
  /// exists. One declaration:
  ///
  /// ```dart
  /// Entrypoint('lib/main_kiosk.dart', name: 'Kiosk',
  ///     flavor: 'local',
  ///     flavorByPlatform: {RunPlatform.mobile: 'kioskLocal'}),
  /// ```
  ///
  /// The launch resolves against the target device's platform: a concrete key
  /// ([RunPlatform.ios]) beats a shorthand ([RunPlatform.mobile]), a shorthand
  /// beats [flavor], and a platform in neither falls back to [flavor] and then
  /// to the pubspec's `default-flavor:` as always. The two shorthands cannot
  /// overlap each other, so there is no ambiguity to refuse. The launch
  /// action's `flavor` argument still beats all of it.
  ///
  /// Before this field the answer was two declarations of the same path with
  /// the platform spelled twice — once in each [name], once in [platforms] —
  /// and a picker showing two rows for one thing.
  final Map<RunPlatform, String> flavorByPlatform;

  /// What this entry point can actually run on. Everything, when empty.
  ///
  /// Some `main()`s are only meant for one kind of machine: a kiosk build for
  /// tablets, an operator console for the desktop, a web-only embed. Declaring
  /// it turns a wrong device from a build failure minutes later into a device
  /// the picker never offers.
  ///
  /// [RunPlatform.mobile] and [RunPlatform.desktop] are shorthands and expand,
  /// so the coarse case stays one word:
  ///
  /// ```dart
  /// Entrypoint('lib/main_kiosk.dart', name: 'Kiosk',
  ///     platforms: [RunPlatform.ios, RunPlatform.android]),
  /// Entrypoint('lib/main_admin.dart', name: 'Admin',
  ///     platforms: [RunPlatform.desktop]),
  /// ```
  ///
  /// This says what the *entry point* is for, not what the package can build.
  /// A package with no `web/` directory cannot run on Chrome either, and that
  /// is not declared here — it is a fact about the package, and one nothing
  /// should have to write down twice.
  final List<RunPlatform> platforms;

  Map<String, Object?> toJson() => {
    'path': path,
    'name': ?name,
    'description': ?description,
    'flavor': ?flavor,
    // As written, shorthands and all — same rule as `platforms` below.
    if (flavorByPlatform.isNotEmpty)
      'flavorByPlatform': {
        for (var entry in flavorByPlatform.entries) entry.key.name: entry.value,
      },
    // As written, shorthands and all. The tool expands them where it matches
    // devices; the manifest keeps the author's word so a picker can say
    // `desktop` rather than reciting three platforms back at them.
    if (platforms.isNotEmpty) 'platforms': [for (var p in platforms) p.name],
    if (knobs.isNotEmpty) 'knobs': [for (var k in knobs) k.toJson()],
  };
}

/// What an [Entrypoint] can run on — one of Flutter's platforms, or a
/// shorthand for a group of them.
///
/// The concrete members are `flutter run`'s own platform names, which is what
/// makes them checkable: the device list reports the same vocabulary, so a
/// declaration and a device either match or visibly do not. The two shorthands
/// are the daemon's device *categories*, and exist because "this is a phone
/// thing" is the restriction people actually mean most of the time.
enum RunPlatform {
  ios,
  android,
  macos,
  linux,
  windows,
  web,

  /// [ios] and [android].
  mobile,

  /// [macos], [linux] and [windows].
  desktop;

  /// The concrete platforms this stands for — itself, unless it is a shorthand.
  Set<RunPlatform> get expanded => switch (this) {
    mobile => const {ios, android},
    desktop => const {macos, linux, windows},
    _ => {this},
  };

  static RunPlatform? byName(String name) {
    for (var value in values) {
      if (value.name == name) return value;
    }
    return null;
  }

  /// Every concrete platform [platforms] allows, shorthands expanded.
  ///
  /// Empty in and empty out, and the caller has to read that as "no
  /// restriction" rather than "nothing is allowed" — the difference between an
  /// entry point that runs anywhere and one that runs nowhere.
  static Set<RunPlatform> expandAll(Iterable<RunPlatform> platforms) => {
    for (var platform in platforms) ...platform.expanded,
  };
}

/// One knob an entry point's `main` takes, annotated.
///
/// The signature is the declaration; this only annotates it. `main`'s
/// parameter list already says what exists, with what type and what default,
/// and it cannot be wrong about its own function — so nothing here repeats any
/// of that. Only [name] appears twice, and it is the join key.
///
/// ```dart
/// // tool/flutterware.dart — declared once, shared by being a variable
/// final devKnobs = [
///   Knob('serverPort',
///       from: ValueSource.script('tool/local_env.dart', args: ['port'])),
///   Knob('apiHost', from: ValueSource.hostAddresses),
/// ];
///
/// Entrypoint('lib/main.dart', name: 'App', knobs: devKnobs),
/// Entrypoint('lib/main_staging.dart', name: 'Staging', knobs: devKnobs),
/// ```
///
/// ```dart
/// // lib/main.dart — just the socket
/// void main({int serverPort = 8086, String apiHost = 'localhost'}) => …
/// ```
///
/// Sharing across entry points needs no API: `tool/flutterware.dart` is Dart,
/// so a variable does it. A per-package list was proposed and rejected for
/// exactly that reason.
///
/// Changing a knob's value rewrites the generated wrapper and hot restarts —
/// 262ms on desktop, 3s on an Android emulator, against a rebuild.
///
/// The word is back because the cost is. This was `LaunchKnob`, renamed to
/// `DartDefine` on the grounds that a preview's knob costs a frame while a
/// define costs a rebuild, so one word for both would hide the difference. The
/// mechanism underneath has changed: a restart is not a frame, but it is the
/// same order of thing, and a value read off a parameter list is what
/// `KnobDescriptor` already models for previews and devbar variables. One
/// vocabulary, one wire shape.
class Knob {
  const Knob(
    this.name, {
    this.label,
    this.description,
    this.options = const [],
    this.from,
    this.required = false,
  });

  /// The parameter's name, exactly — `serverPort`. A knob naming a parameter
  /// `main` does not take is reported rather than silently ignored: the control
  /// would appear and do nothing, which looks like a broken feature.
  final String name;

  /// What a human sees; [name] when absent.
  final String? label;

  final String? description;

  /// Values worth offering for a knob whose type cannot enumerate itself.
  ///
  /// An `enum` parameter needs none — its constants are read off the
  /// declaration, so a list here would be the same facts twice and free to
  /// drift. That reading is bounded, and the bound is worth knowing: the entry
  /// point's own file, the files it imports directly, and the packages of the
  /// same checkout — a shared config package included. An enum outside all
  /// three is reported by name rather than drawn, and a list here does not
  /// rescue it: the values would be offered for a control that is not there.
  final List<String> options;

  /// A value the tool works out for itself, rather than one to type.
  ///
  /// The only thing in this class a signature could not have said: a default is
  /// a constant, and "whichever port this worktree was allocated" is not.
  final ValueSource? from;

  /// Whether a launch that sets no value for this knob is refused.
  ///
  /// The second thing a signature cannot say, and for a harder reason than
  /// [from]. A knob *is* an optional named parameter, and
  /// `void main({required String x})` is not an entry point at all: Flutter's
  /// bootstrap calls `main()` with no arguments, so the word `required` in the
  /// signature stops the file running under plain `flutter run`. That is why a
  /// parameter genuinely declared `required` is reported as unlaunchable rather
  /// than as a knob to fill in — there is no way to satisfy it and keep the
  /// entry point.
  ///
  /// So the parameter keeps a default, because it has to, and this says the
  /// default is a placeholder rather than a value anybody meant to run against:
  ///
  /// ```dart
  /// // lib/main_dev.dart — still launchable by hand
  /// void main({String apiToken = const String.fromEnvironment('API_TOKEN')})
  ///
  /// // tool/flutterware.dart — but not by flutterware without one
  /// Knob('apiToken', required: true),
  /// ```
  ///
  /// A [from] that answers satisfies it. The point is that *some* value was
  /// chosen for this launch, not that a human typed it — which is what makes
  /// `required` with a working source a declaration rather than a chore.
  ///
  /// The refusal comes before anything is built, which is the whole value.
  /// Left to the app, forgetting one costs a compile, an install, a boot and
  /// whatever the code does about a placeholder — usually throwing somewhere
  /// that names neither the knob nor the launch, minutes after the mistake.
  final bool required;

  Map<String, Object?> toJson() => {
    'knob': name,
    if (label != null) 'label': label,
    if (description != null) 'description': description,
    if (options.isNotEmpty) 'options': options,
    if (from != null) 'from': from!.toJson(),
    if (required) 'required': true,
  };
}

/// The new name for [DefineSource], which no longer only feeds defines.
///
/// An alias rather than a rename, because `DefineSource` is published. Both
/// spell the same class until defines go.
typedef ValueSource = DefineSource;

/// Where a [Knob]'s value or offered values are found.
///
/// Two of them, and they are not the same kind of thing: [hostAddresses] is
/// something the tool knows, while [DefineSource.script] is something the
/// project knows and the tool goes and asks. Only the second can answer "what
/// port did this worktree get", because only the project allocated it.
///
/// There was a third, `servers`, offering the base URLs of dev servers
/// announcing themselves through `package:flutterware/server.dart`. It was
/// deleted: the offered values are a `List<String>`, so two servers arrived as
/// two bare URLs with nothing to tell them apart — and the scan was not even
/// scoped to this worktree, so they came from every project on the machine.
/// A source whose answer you cannot identify is worse than no source.
sealed class DefineSource {
  const DefineSource();

  /// This machine's addresses on the local network. What a phone has to be
  /// told, since `localhost` on a phone is the phone.
  static const DefineSource hostAddresses = HostAddressesSource();

  /// The root of the Flutter SDK this launch is being built with.
  ///
  /// A value flutterware is holding while the app it launches cannot see
  /// it. `flutter run` hands its child a stripped environment, so nothing
  /// inside the process can tell which `flutter` started it — and an app that
  /// has to spawn Flutter itself, a dev tool or a codegen harness or this GUI,
  /// must not fall back to the one on PATH: that is routinely a different
  /// version from the one the project pinned.
  ///
  /// Which makes it the same kind of fact as [hostAddresses] — something the
  /// machine knows, the app cannot reach, and no constant can be written down
  /// for. The difference is only that there is exactly one answer, so it fills
  /// the knob in rather than offering a list.
  ///
  /// ```dart
  /// // main({String flutterSdkRoot = const String.fromEnvironment(…)})
  /// Knob('flutterSdkRoot', from: ValueSource.flutterSdk, required: true),
  /// ```
  ///
  /// Pairs naturally with [Knob.required]: the source answers for every launch
  /// flutterware makes, and the flag is what refuses the one where it could
  /// not.
  static const DefineSource flutterSdk = FlutterSdkSource();

  /// A Dart script in this worktree that prints the value, or a JSON array of
  /// values to choose from.
  ///
  /// ```dart
  /// Knob('serverPort',
  ///     from: ValueSource.script('tool/local_env.dart',
  ///         args: ['port', 'server'])),
  /// ```
  ///
  /// A script, not a command, because a command would have to name an
  /// executable and no config file can know which one. A `dart` on PATH is
  /// routinely older than the SDK the project pins — this repo's own is — so a
  /// config saying `dart` would be saying "whichever SDK happens to be first",
  /// which is not a thing anybody means. Run with the same `dart` that compiles
  /// and runs this config file, from the worktree root.
  ///
  /// Selection belongs in [args], not here. An earlier draft had a `pick:`
  /// naming a key in a JSON object the script printed; it would have grown a
  /// path syntax the first time somebody's output was nested. Passing the
  /// selection as an argument puts it in the tool that owns the data, where it
  /// can be a real function of that tool's model.
  ///
  /// Run when the values are needed, not when the config is read: the answer to
  /// "which port is this worktree on" changes when the stack goes up or down,
  /// which is not a moment the config file knows about.
  const factory DefineSource.script(String path, {List<String> args}) =
      ScriptSource;

  Map<String, Object?> toJson();

  /// Reads back what [toJson] wrote, or null for a shape this build has no
  /// member for.
  ///
  /// Null rather than a throw, for the reason `_platformsOf` gives on the app
  /// side: the config imports the `flutterware` version the *project* pins,
  /// which can run ahead of the GUI reading its manifest. A source we cannot
  /// resolve has to mean a knob with fewer suggestions, never a knob that
  /// disappears.
  static DefineSource? fromJson(Object? raw) {
    if (raw is! Map) return null;
    if (raw['source'] == 'hostAddresses') return hostAddresses;
    if (raw['source'] == 'flutterSdk') return flutterSdk;
    if (raw['script'] case String path) {
      return ScriptSource(
        path,
        args: [
          for (var arg in (raw['args'] as List? ?? const []))
            if (arg is String) arg,
        ],
      );
    }
    return null;
  }
}

/// See [DefineSource.hostAddresses].
final class HostAddressesSource extends DefineSource {
  const HostAddressesSource();

  @override
  Map<String, Object?> toJson() => {'source': 'hostAddresses'};
}

/// See [DefineSource.flutterSdk].
final class FlutterSdkSource extends DefineSource {
  const FlutterSdkSource();

  @override
  Map<String, Object?> toJson() => {'source': 'flutterSdk'};
}

/// See [DefineSource.script].
final class ScriptSource extends DefineSource {
  const ScriptSource(this.path, {this.args = const []});

  /// Worktree-relative, `/`-separated — `tool/local_env.dart`.
  final String path;

  final List<String> args;

  @override
  Map<String, Object?> toJson() => {
    'script': path,
    if (args.isNotEmpty) 'args': args,
  };
}

/// The launcher-icon editor. Only meaningful for packages that are apps, so it
/// deliberately offers no `each` — naming them is the point.
class LauncherIcon extends Plugin {
  LauncherIcon({this.packages = const [], String? label})
    : super('flutterware.launcher_icon', label: label ?? 'Launcher icon');

  final List<LauncherIconPackage> packages;

  @override
  Map<String, Object?> get config => {
    'packages': [for (var p in packages) p.toJson()],
  };
}

class LauncherIconPackage extends PluginPackage {
  const LauncherIconPackage(super.pkg);
}

/// Everything that has to be up for this project's app to work locally.
///
/// A list, because a project has more than one: the docker stack *and* the API
/// server *and* the worker that reads its queue. Each entry is a
/// [StackService] with its own state, its own control and its own commands,
/// and the panel is the list of them.
///
/// Two kinds, and the discriminator is **who owns the process** — a question a
/// config author can answer without knowing anything about flutterware. A
/// [StackService.delegated] is one the project's own CLI owns: `up` returns and
/// leaves something running, `status` answers, `down` exists. A
/// [StackService.owned] is one flutterware spawns and holds the pid of, which
/// is what a process you would otherwise keep in a terminal tab and stop with
/// Ctrl-C has to be.
///
/// ```dart
/// fw.use(DevStack(services: [
///   StackService.delegated('stack',
///     name: 'Local stack',
///     workingDirectory: 'packages/server',
///     probe: Probe.json(StackRun.script('tool/local_env.dart',
///         args: ['status', '--json'])),
///     start: StackRun.script('tool/local_env.dart', args: ['up']),
///     stop: StackRun.script('tool/local_env.dart', args: ['down']),
///     stopIsDestructive: true),
///   StackService.owned('server',
///     name: 'API server',
///     workingDirectory: 'packages/server',
///     start: StackRun.script('bin/server_local.dart'),
///     ready: Ready.http(8100, path: '/health',
///         timeout: Duration(seconds: 30))),
/// ]));
/// ```
///
/// **Ids are how everything else names a service.** `fw run dev_stack
/// server.start` and an agent's `flutterware_invoke` both address one entry by
/// its [StackService.id], and a teardown step carries it too. With a single
/// service declared the prefix is dropped and the actions are the bare
/// `start` / `stop` / `status` they have always been, so a project that
/// declares one thing sees exactly what it saw before.
///
/// `Dev` is a safety word and the reason this is not called `Services`: the
/// plugin can run a `stop` that drops a database, and a name that scopes it to
/// local development is the cheapest guard against someone pointing it at
/// something real.
class DevStack extends Plugin {
  DevStack({required this.services, String? label})
    : super('flutterware.dev_stack', label: label ?? 'Dev stack') {
    var seen = <String>{};
    for (var service in services) {
      if (!seen.add(service.id)) {
        throw StateError(
          'Duplicate service id "${service.id}" in DevStack. Every service '
          'needs its own — the id is what an action, a teardown step and a '
          'cached reading are keyed on.',
        );
      }
    }
    for (var service in services) {
      for (var need in service.needs) {
        if (!seen.contains(need)) {
          throw StateError(
            'Service "${service.id}" needs "$need", but no service in this '
            'DevStack has that id. The ids are: ${seen.join(', ')}.',
          );
        }
      }
    }
    if (_circleIn(services) case var circle?) {
      throw StateError(
        'Services in this DevStack need each other in a circle: '
        '${circle.join(' → ')}. None of them could be started first.',
      );
    }
  }

  /// The first circle [StackService.needs] makes, as the ids around it with
  /// the first one repeated at the end, or null when there is none.
  static List<String>? _circleIn(List<StackService> services) {
    var byId = {for (var service in services) service.id: service};
    var done = <String>{};
    var path = <String>[];
    List<String>? visit(String id) {
      if (done.contains(id)) return null;
      if (path.contains(id)) return [...path.sublist(path.indexOf(id)), id];
      path.add(id);
      for (var need in byId[id]?.needs ?? const <String>[]) {
        if (visit(need) case var circle?) return circle;
      }
      path.removeLast();
      done.add(id);
      return null;
    }

    for (var service in services) {
      if (visit(service.id) case var circle?) return circle;
    }
    return null;
  }

  /// The one-service shorthand, and what this plugin took before it took a
  /// list. Declares a single [StackService.delegated] with the id `stack`.
  ///
  /// Kept because it is what every config pinning an older flutterware already
  /// says, and because one delegated stack remains the common case. It is a
  /// spelling of the list, not a different plugin: the panel, the actions and
  /// the cache are the same either way.
  DevStack.background({
    required Probe probe,
    StackRun? start,
    StackRun? stop,
    String? workingDirectory,
    Duration poll = const Duration(seconds: 10),
    Duration commandTimeout = const Duration(minutes: 10),
    bool stopIsDestructive = false,
    List<StackCommand> commands = const [],
    String? label,
  }) : this(
         label: label,
         services: [
           StackService.delegated(
             'stack',
             name: label ?? 'Dev stack',
             probe: probe,
             start: start,
             stop: stop,
             workingDirectory: workingDirectory,
             poll: poll,
             commandTimeout: commandTimeout,
             stopIsDestructive: stopIsDestructive,
             commands: commands,
           ),
         ],
       );

  final List<StackService> services;

  @override
  Map<String, Object?> get config => {
    'services': [for (var service in services) service.toJson()],
  };
}

/// One thing in the [DevStack] with a lifecycle of its own.
///
/// The discriminator between the kinds is **who owns the process** — which is
/// a question a config author can answer without knowing anything about
/// flutterware. A [StackService.delegated] is one the project's own CLI owns:
/// `up` returns and leaves something running, `status` answers, `down` exists.
sealed class StackService {
  const StackService(
    this.id, {
    this.name,
    this.workingDirectory,
    this.needs = const [],
    this.poll = const Duration(seconds: 10),
    this.commandTimeout = const Duration(minutes: 10),
    this.commands = const [],
  });

  /// A lifecycle the project's own commands own. flutterware polls [probe] and
  /// runs [start] / [stop] when told to; it holds no process and no pid.
  const factory StackService.delegated(
    String id, {
    String? name,
    required Probe probe,
    StackRun? start,
    StackRun? stop,
    String? workingDirectory,
    List<String> needs,
    Duration poll,
    Duration commandTimeout,
    bool stopIsDestructive,
    List<StackCommand> commands,
  }) = DelegatedStackService;

  /// A process flutterware spawns and holds itself: it has the pid, it owns
  /// the log, and stopping it is a signal rather than someone else's command.
  const factory StackService.owned(
    String id, {
    String? name,
    required StackRun start,
    required Ready ready,
    String? workingDirectory,
    List<String> needs,
    Map<String, String> env,
    Map<String, ValueSource> envFrom,
    Duration stopGrace,
    Duration poll,
    Duration commandTimeout,
    List<StackCommand> commands,
  }) = OwnedStackService;

  /// Stable within the plugin — what an action, a teardown step and a cached
  /// reading are keyed on. `stack`, `server`, `worker`.
  final String id;

  /// What a human and an agent call it. [id] when null.
  final String? name;

  /// Where this service's commands run, relative to the worktree root. The
  /// worktree root itself when null.
  final String? workingDirectory;

  /// The services that have to be up before this one starts, by [id].
  ///
  /// ```dart
  /// StackService.owned('server', needs: ['db'], …)
  /// ```
  ///
  /// `ensure` reads it: asked for the server, it brings up the database
  /// first, waits until it is up, then starts the server. A service that does
  /// not come up stops everything that needs it. `start` on its own starts
  /// only the one service.
  ///
  /// Every id must be another service in the same [DevStack], and the needs
  /// must not go round in a circle. Both are checked when the config loads.
  final List<String> needs;

  /// How often to re-read this service's state while something is watching.
  ///
  /// The declaration says the timescale; the shell decides whether to look at
  /// all. Only this declaration knows how fast the subject changes — a docker
  /// stack does not come up twice a minute — and only the shell knows about
  /// window focus and which panel is on screen. So the shell scales this rather
  /// than replacing it, and a service that is nowhere on screen is not polled.
  ///
  /// The defaults differ by kind because the reading costs differ by two orders
  /// of magnitude: a delegated service spawns its probe, and an owned one asks
  /// whether a pid is alive and whether a socket accepts.
  ///
  /// Only the studio polls. `fw` and the MCP server never do: they report the
  /// reading the last check left in the shared cache, from whichever process
  /// ran it, and on a worktree nothing has checked yet that reading is
  /// `unknown`. The `status` action is what goes and looks, and every surface
  /// reads its answer afterwards.
  final Duration poll;

  /// How long to wait for `start`, `stop` or a [StackCommand] before giving up
  /// on it. [StackCommand.timeout] overrides this per command.
  ///
  /// It bounds the wait, not the process. Nothing is killed when this expires:
  /// a `docker compose up` interrupted half way through leaves the stack in an
  /// indeterminate state, and flutterware does not own a delegated command well
  /// enough to make that call. What it does end is flutterware's *claim* on the
  /// service — without which one command that never returns takes every later
  /// one with it, because a transition in flight is what refuses the next.
  ///
  /// So the default is generous rather than tight: ten minutes is longer than
  /// any bring-up that is actually working and short enough that a session
  /// recovers on its own. A command that is *meant* to run forever — `logs
  /// --follow` — wants a [StackCommand.timeout] of a few seconds instead, and
  /// really wants a streaming kind, which does not exist yet.
  final Duration commandTimeout;

  /// Everything else this service can be asked to do: logs, restart, recreate,
  /// prune.
  ///
  /// Each spawns a **new process**. There is deliberately no way to write to a
  /// running service's stdin: a service that outlives the GUI has no stdin to
  /// write to, and every tool that offers real control offers it over a socket
  /// or an HTTP port, which is another command.
  final List<StackCommand> commands;

  Map<String, Object?> toJson();

  /// The fields every kind carries, so a reader can pick the kind apart from
  /// the rest and the two do not drift.
  Map<String, Object?> baseJson(String kind) => {
    'id': id,
    'kind': kind,
    if (name != null) 'name': name,
    if (workingDirectory != null) 'workingDirectory': workingDirectory,
    if (needs.isNotEmpty) 'needs': needs,
    'poll': poll.inMilliseconds,
    'commandTimeout': commandTimeout.inMilliseconds,
    if (commands.isNotEmpty) 'commands': [for (var c in commands) c.toJson()],
  };

  /// Every service a `config` map declares, in declaration order.
  ///
  /// Reads the flat shape too — `probe`/`start`/`stop` at the top level, with
  /// no `services` list — because that is what a project pinning an older
  /// flutterware writes, and a config that stops being read is a panel that
  /// stops knowing anything. It becomes one delegated service with the id
  /// `stack`, which is exactly what [DevStack.background] declares today.
  static List<StackService> listFromConfig(Map<String, Object?> config) {
    if (config['services'] case List raw) {
      return [
        for (var entry in raw)
          if (entry is Map) ?fromJson(entry.cast<String, Object?>()),
      ];
    }
    if (config['probe'] == null) return const [];
    return [
      ?fromJson({...config, 'id': 'stack'}),
    ];
  }

  /// Reads back what [toJson] wrote.
  ///
  /// An entry with no `kind` is delegated, which is what every config written
  /// before there was a second kind means. An entry this build cannot read
  /// comes back as an [UnreadableStackService] rather than as null, so it is
  /// still named on the panel with the reason — *the config declared
  /// something and this build cannot read it* and *the config declared
  /// nothing* are different sentences with different fixes, and silently
  /// dropping the row tells you neither.
  ///
  /// Null only when there is no id, which is the one thing nothing can be
  /// reported under.
  static StackService? fromJson(Map<String, Object?> json) {
    var id = json['id'];
    if (id is! String || id.isEmpty) return null;
    var name = json['name'] as String?;
    switch (json['kind']) {
      case 'owned':
        var read = OwnedStackService.fromJson(json);
        if (read != null) return read;
        return UnreadableStackService(
          id,
          name: name,
          reason: json['start'] == null
              ? 'No start command is declared, so there is nothing to run.'
              : 'The config declares a start command or a readiness check this '
                    'version of flutterware cannot read, perhaps one written '
                    'for a newer version. Run `dart run flutterware` again, or '
                    'simplify the declaration.',
        );
      case null || 'delegated':
        var read = DelegatedStackService.fromJson(json);
        if (read != null) return read;
        // Two sentences, because they have different fixes — and the pair was
        // reported from the field, where a working config was told "No probe
        // is declared" by a build that simply could not read the one it had.
        return UnreadableStackService(
          id,
          name: name,
          reason: json['probe'] == null
              ? 'No probe is declared, so flutterware cannot tell what state '
                    'this service is in.'
              : 'The config declares a probe this version of flutterware '
                    'cannot read, perhaps one written for a newer version. '
                    'Run `dart run flutterware` again, or simplify the '
                    'declaration.',
        );
      case 'unreadable':
        return UnreadableStackService(
          id,
          name: name,
          reason: json['reason'] as String? ?? 'It could not be read.',
        );
      case var kind:
        return UnreadableStackService(
          id,
          name: name,
          reason:
              'This version of flutterware does not know the service kind '
              '"$kind", perhaps one written for a newer version. Upgrade the '
              'flutterware running here.',
        );
    }
  }
}

/// A service the config declared and this build cannot read.
///
/// It has no lifecycle and no actions — it exists so the row is still on the
/// panel, named, saying why. A future kind read by an older flutterware lands
/// here rather than disappearing, which is the difference between a confusing
/// panel and a wrong one.
final class UnreadableStackService extends StackService {
  const UnreadableStackService(super.id, {super.name, required this.reason});

  /// What to say instead of a state.
  final String reason;

  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': 'unreadable',
    if (name != null) 'name': name,
    'reason': reason,
  };
}

/// See [StackService.delegated].
///
/// It owns nothing. flutterware runs [probe] to find out what is going on
/// and runs [start] / [stop] when told to; the project's own CLI stays the
/// authority on what those mean. That is the whole difference from a
/// supervisor, and it is why a stack brought up in a terminal, by a teammate's
/// script or by this plugin all read identically.
///
/// ```dart
/// fw.use(DevStack.background(
///   workingDirectory: 'packages/server',
///   // Not `docker compose ps --quiet` on its own: that exits 0 whether or
///   // not anything is up. And in a worktree, even this answers about
///   // whichever compose project the working directory resolves to — which
///   // is the checkout next door if this one has never come up. See
///   // [Probe.exitCode], and prefer a [Probe.json] script in a monorepo.
///   probe: Probe.exitCode(StackRun.command([
///     'sh',
///     '-c',
///     'test -n "$(docker compose ps --quiet --status running)"',
///   ])),
///   start: StackRun.command(['docker', 'compose', 'up', '--wait']),
///   stop:  StackRun.command(['docker', 'compose', 'down', '--volumes']),
///   stopIsDestructive: true,
/// ));
/// ```
///
/// A project whose stack is behind its own CLI declares the same thing as
/// scripts, and then nothing here names an executable at all:
///
/// ```dart
/// fw.use(DevStack.background(
///   workingDirectory: 'packages/server',
///   probe: Probe.json(StackRun.script('tool/local_env.dart',
///       args: ['status', '--json'])),
///   start: StackRun.script('tool/local_env.dart', args: ['up']),
///   stop:  StackRun.script('tool/local_env.dart', args: ['down']),
///   stopIsDestructive: true,
/// ));
/// ```
///
/// Delegated is a requirement on the tool, not a description of how this is
/// implemented: the command must return, leaving something running behind it.
/// A tool you stop with Ctrl-C — `firebase emulators:start`, `tilt up`,
/// `ngrok http`, a plain `dart bin/server.dart` — cannot be declared this way,
/// because there is no `stop` to name and nothing to ask whether it is up.
/// That is `StackService.owned`, where flutterware holds the process itself
/// — and with it a pid to check, a log to keep and a stop to get right.
///
final class DelegatedStackService extends StackService {
  const DelegatedStackService(
    super.id, {
    super.name,
    required this.probe,
    this.start,
    this.stop,
    super.workingDirectory,
    super.needs,
    super.poll,
    super.commandTimeout,
    this.stopIsDestructive = false,
    super.commands,
  });

  /// How to find out what state the stack is in.
  final Probe probe;

  /// Brings it up. Null for a stack this machine only observes — a shared
  /// server, a system postgres — which is a complete declaration and gets a
  /// panel with a status and no controls.
  final StackRun? start;

  /// Takes it down. Null has the same meaning as a null [start].
  final StackRun? stop;

  /// [stop] destroys data — `down --volumes` drops the database. Renderers make
  /// the control distinct and ask first.
  final bool stopIsDestructive;

  @override
  Map<String, Object?> toJson() => {
    ...baseJson('delegated'),
    'probe': probe.toJson(),
    if (start != null) 'start': start!.toJson(),
    if (stop != null) 'stop': stop!.toJson(),
    if (stopIsDestructive) 'stopIsDestructive': true,
  };

  /// Null when there is no probe to read, which is the one field without which
  /// nothing here can say anything at all.
  static DelegatedStackService? fromJson(Map<String, Object?> json) {
    var id = json['id'];
    if (id is! String || id.isEmpty) return null;
    var probe = json['probe'];
    if (probe is! Map) return null;
    var read = Probe.fromJson(probe.cast<String, Object?>());
    if (read == null) return null;
    return DelegatedStackService(
      id,
      name: json['name'] as String?,
      probe: read,
      start: StackRun.fromJson(json['start']),
      stop: StackRun.fromJson(json['stop']),
      workingDirectory: json['workingDirectory'] as String?,
      needs: _needs(json['needs']),
      poll: _millis(json['poll']) ?? const Duration(seconds: 10),
      commandTimeout:
          _millis(json['commandTimeout']) ?? const Duration(minutes: 10),
      stopIsDestructive: json['stopIsDestructive'] == true,
      commands: [
        for (var entry in (json['commands'] as List? ?? const []))
          if (entry is Map)
            ?StackCommand.fromJson(entry.cast<String, Object?>()),
      ],
    );
  }
}

Duration? _millis(Object? raw) =>
    raw is int && raw > 0 ? Duration(milliseconds: raw) : null;

List<String> _needs(Object? raw) => [
  for (var id in raw is List ? raw : const []) ?(id is String ? id : null),
];

/// See [StackService.owned].
///
/// flutterware spawns it, holds the pid, and owns the file its output goes to.
/// That is the whole difference from [DelegatedStackService], and everything
/// else follows from it: there is no `stop` to declare because stopping is a
/// signal, no `logs` to declare because the log is ours, and no probe to
/// declare because the pid answers whether it is running — [ready] answers the
/// harder question of whether it is *usable*.
///
/// The kind exists for the process you would otherwise keep in a terminal tab
/// and stop with Ctrl-C: `dart bin/server.dart`, a uvicorn, a queue worker,
/// `firebase emulators:start`, `ngrok http`. None of those can be declared
/// delegated — there is no command that returns leaving them running, and
/// nothing to ask whether they are up.
///
/// ```dart
/// StackService.owned('server',
///   name: 'API server',
///   workingDirectory: 'packages/server',
///   start: StackRun.script('bin/server_local.dart'),
///   ready: Ready.http(8100, path: '/health', timeout: Duration(seconds: 30))),
/// ```
///
/// **Nothing here is Dart-specific.** A [StackRun.command] names its own
/// interpreter, so a Python server is the same declaration with a different
/// runner — which is the point, since the language a dependency is written in
/// is not a fact about the app that depends on it.
///
/// ```dart
/// StackService.owned('ml',
///   workingDirectory: 'packages/ml_backend',
///   start: StackRun.command(['uv', 'run', 'uvicorn', 'app:api', '--port', '8099']),
///   ready: Ready.port(8099, timeout: Duration(seconds: 60))),
/// ```
///
/// **It is spawned detached, on purpose.** The process is not a child of the
/// GUI, so closing the window does not take the server with it and reopening
/// it finds the same process again rather than starting a second one. The
/// price is the orphan: a service left running by a session that crashed. That
/// is what the handle file under `~/.flutterware/run/` is for — it is how the
/// next session knows the pid, and it is checked before every start, so a
/// second bring-up adopts what is running instead of colliding with it.
final class OwnedStackService extends StackService {
  const OwnedStackService(
    super.id, {
    super.name,
    required this.start,
    required this.ready,
    super.workingDirectory,
    super.needs,
    this.env = const {},
    this.envFrom = const {},
    this.stopGrace = const Duration(seconds: 5),
    super.poll = const Duration(seconds: 3),
    super.commandTimeout,
    super.commands,
  });

  /// What to spawn. It is expected **not** to return — that is what makes this
  /// kind the right one.
  final StackRun start;

  /// When the spawned process counts as usable.
  ///
  /// Required, because the honest answers differ and none of them is a safe
  /// default. A server has a port or a health URL; a worker that talks to
  /// nothing but a queue has neither, and [Ready.processAlive] says so out
  /// loud rather than pretending to a check it cannot make.
  final Ready ready;

  /// Environment the process is started with, on top of the one a new
  /// terminal window has.
  ///
  /// For what a config file can state as a fact — the name of a binary the
  /// service should call, a flag that only means anything in development.
  /// Anything whose value is a property of *this machine* or *this worktree*
  /// belongs in [envFrom]: a home directory written into a committed file is
  /// wrong on the next machine, and quietly.
  ///
  /// ```dart
  /// env: {'FFMPEG_BIN': 'ffmpeg', 'CONVERT_BIN': 'convert'},
  /// ```
  final Map<String, String> env;

  /// Environment the project computes, resolved once per start.
  ///
  /// Two fields rather than one union, because the two are different kinds of
  /// thing and reading them together should say so. A [ValueSource] is a
  /// *question* — something flutterware goes and asks — and wrapping a literal
  /// in one to fit a single map would make every ordinary value look like a
  /// question that happens to have a constant answer.
  ///
  /// ```dart
  /// envFrom: {'MODEL_TOOLS_DIR': ValueSource.script('tool/model_tools_dir.dart')},
  /// ```
  ///
  /// Same contract as [Ready.portFrom]: asked before anything is spawned, and
  /// a source that cannot answer **refuses the start** quoting what it said.
  /// A service started with a variable silently missing is a service that
  /// fails somewhere else, later, for a reason nothing on screen explains.
  ///
  /// It is also the answer to a start command that needs a per-worktree value
  /// on its *argv*. There is no `args:` here and deliberately no template
  /// syntax; where a tool takes its port as a flag, name a shell and read the
  /// variable:
  ///
  /// ```dart
  /// start: StackRun.command([
  ///   'sh', '-c', r'exec uvicorn app:api --port "$SERVICE_PORT"',
  /// ]),
  /// envFrom: {'SERVICE_PORT': localEnvSource(['port', 'ml'])},
  /// ```
  final Map<String, ValueSource> envFrom;

  /// How long each rung of the stop ladder gets before the next one.
  ///
  /// Stopping is `SIGINT`, then `SIGTERM`, then `SIGKILL`, each sent to the
  /// process *group* so a tool's own children go with it — a `uv run` is a
  /// launcher wrapping the interpreter that holds the port, and signalling only
  /// the pid we spawned leaves the port held by a process nothing is tracking.
  ///
  /// The ladder is fixed and only the grace is declared, because the ladder is
  /// not a preference: `SIGINT` is what Ctrl-C sends and is the signal every
  /// one of these tools already handles, and the two below it are the answer
  /// to a tool that ignores it. What varies per service is only how long a
  /// clean shutdown legitimately takes.
  final Duration stopGrace;

  @override
  Map<String, Object?> toJson() => {
    ...baseJson('owned'),
    'start': start.toJson(),
    'ready': ready.toJson(),
    if (env.isNotEmpty) 'env': env,
    if (envFrom.isNotEmpty)
      'envFrom': {
        for (var entry in envFrom.entries) entry.key: entry.value.toJson(),
      },
    'stopGrace': stopGrace.inMilliseconds,
  };

  /// Null when there is no start command or no readable readiness check —
  /// the two fields without which nothing here can run or be believed.
  static OwnedStackService? fromJson(Map<String, Object?> json) {
    var id = json['id'];
    if (id is! String || id.isEmpty) return null;
    var start = StackRun.fromJson(json['start']);
    if (start == null) return null;
    var ready = Ready.fromJson(json['ready']);
    if (ready == null) return null;
    return OwnedStackService(
      id,
      name: json['name'] as String?,
      start: start,
      ready: ready,
      workingDirectory: json['workingDirectory'] as String?,
      needs: _needs(json['needs']),
      env: {
        for (var entry in (json['env'] as Map? ?? const {}).entries)
          if (entry.value is String) '${entry.key}': entry.value! as String,
      },
      envFrom: {
        for (var entry in (json['envFrom'] as Map? ?? const {}).entries)
          '${entry.key}': ?ValueSource.fromJson(entry.value),
      },
      stopGrace: _millis(json['stopGrace']) ?? const Duration(seconds: 5),
      poll: _millis(json['poll']) ?? const Duration(seconds: 3),
      commandTimeout:
          _millis(json['commandTimeout']) ?? const Duration(minutes: 10),
      commands: [
        for (var entry in (json['commands'] as List? ?? const []))
          if (entry is Map)
            ?StackCommand.fromJson(entry.cast<String, Object?>()),
      ],
    );
  }
}

/// When an [StackService.owned] process counts as usable.
///
/// *Started* and *usable* are different moments, and the gap between them is
/// where a dev loop actually loses its time: an app launched against a server
/// that is three seconds from binding its port fails in a way that looks like
/// a bug in the app. So this is required rather than defaulted — the
/// declaration has to say which moment it means.
///
/// Three shapes, and the list is deliberately short. There is no
/// `Ready.logLine(RegExp(…))`: matching a tool's startup banner is a check
/// that breaks when the tool rewords a sentence, and the wording of a log line
/// is the least stable thing a program has. It was left out because no service
/// in evidence needs it — every one that has a readiness signal at all has a
/// port or a URL, and the one that has neither is honestly served by
/// [processAlive].
sealed class Ready {
  const Ready();

  /// The pid is alive, and that is all anyone can say.
  ///
  /// The honest answer for a process that serves nothing — a queue worker, a
  /// file watcher, a codegen loop. It is ready the moment it is running, and a
  /// crash on startup still reports as down, because a process that exited is
  /// not alive.
  const factory Ready.processAlive() = ProcessAliveReady;

  /// Something accepts a TCP connection on `localhost:`[port].
  ///
  /// The right check for a server whose protocol is not HTTP, and for one
  /// whose HTTP surface has no endpoint that is cheap and safe to call in a
  /// loop.
  const factory Ready.port(int port, {required Duration timeout}) = PortReady;

  /// The same check, on a port the *project* computes.
  ///
  /// **This is the one a monorepo needs**, and the reason a port is not simply
  /// a number here. Where every worktree gets its own slot, a literal in a
  /// committed file is right for exactly one checkout and silently wrong for
  /// the rest — and "silently" is the operative word, because the number that
  /// gets written down is usually the *main* checkout's, so the service that
  /// answers is the one next door.
  ///
  /// ```dart
  /// Ready.portFrom(
  ///   ValueSource.script('tool/local_env.dart', args: ['port', 'server']),
  ///   timeout: Duration(seconds: 30)),
  /// ```
  ///
  /// Asked **once per start**, before anything is spawned, and remembered for
  /// that run — the socket poll after it costs nothing. A source that cannot
  /// answer **refuses the start** and quotes what it said, rather than falling
  /// back to a number nobody chose.
  ///
  /// Which puts one requirement on the script, and it is worth stating
  /// plainly: **it has to fail when it does not know.** A `port` command that
  /// answers with a canonical default when this worktree has no allocation is
  /// not answering — it is guessing, with an exit code that says otherwise,
  /// and nothing downstream can tell the difference. That is the trap
  /// [Probe.exitCode] documents for a lister, arrived at from the other side.
  const factory Ready.portFrom(ValueSource port, {required Duration timeout}) =
      PortReady.from;

  /// `GET localhost:`[port][path] answers 2xx or 3xx.
  ///
  /// Stronger than [port] and worth it where the endpoint exists: a server
  /// binds its socket before it has connected to its database, so a port that
  /// accepts is a promise about the socket rather than about the service. Any
  /// other status — a 503 from a health check that knows it is not ready yet —
  /// counts as not ready, and the last one seen is what the timeout reports.
  const factory Ready.http(int port, {String path, required Duration timeout}) =
      HttpReady;

  /// The same check, on a port the project computes. See [Ready.portFrom].
  const factory Ready.httpFrom(
    ValueSource port, {
    String path,
    required Duration timeout,
  }) = HttpReady.from;

  /// How long after the spawn to keep waiting before saying so.
  ///
  /// Required on the checks that wait, because there is no number that is
  /// right for both a Dart server that binds in 200ms and a JVM that takes
  /// forty seconds — and an unbounded wait is a spinner that never resolves,
  /// which is the failure this is here to avoid. When it expires the process
  /// is reported as running and not answering, with its log: that is a real
  /// state, and it is one you want to be told about rather than left watching.
  Duration? get timeout;

  Map<String, Object?> toJson();

  /// Reads back what [toJson] wrote, or null for a shape this build cannot
  /// read — which makes the whole service unreadable rather than silently
  /// ready, because "we could not read the check" must never render as "it is
  /// up".
  static Ready? fromJson(Object? raw) {
    if (raw is! Map) return null;
    var json = raw.cast<String, Object?>();
    // Zero is a real declaration — *do not wait, tell me now* — so this reads
    // its own number rather than borrowing [_millis], which treats zero as
    // absent because a zero poll interval means nothing.
    var declared = json['timeout'];
    var timeout = declared is int && declared >= 0
        ? Duration(milliseconds: declared)
        : null;
    switch (json['ready']) {
      case 'processAlive':
        return const ProcessAliveReady();
      case 'port':
        if (timeout == null) return null;
        if (json['port'] case int port) {
          return PortReady(port, timeout: timeout);
        }
        if (ValueSource.fromJson(json['from']) case var from?) {
          return PortReady.from(from, timeout: timeout);
        }
        return null;
      case 'http':
        if (timeout == null) return null;
        var path = json['path'] as String? ?? '/';
        if (json['port'] case int port) {
          return HttpReady(port, path: path, timeout: timeout);
        }
        if (ValueSource.fromJson(json['from']) case var from?) {
          return HttpReady.from(from, path: path, timeout: timeout);
        }
        return null;
    }
    return null;
  }
}

/// See [Ready.processAlive].
final class ProcessAliveReady extends Ready {
  const ProcessAliveReady();

  @override
  Duration? get timeout => null;

  @override
  Map<String, Object?> toJson() => {'ready': 'processAlive'};
}

/// See [Ready.port] and [Ready.portFrom].
final class PortReady extends Ready {
  const PortReady(int this.port, {required this.timeout}) : from = null;

  const PortReady.from(ValueSource this.from, {required this.timeout})
    : port = null;

  /// The port as declared, or null when [from] computes it.
  ///
  /// Exactly one of the two is set, which is what the two constructors are
  /// for: a port that is *both* written down and computed would have to say
  /// which wins, and there is no answer to that a config author would enjoy
  /// discovering.
  final int? port;

  /// Where the port comes from, or null when [port] is written down.
  final ValueSource? from;

  @override
  final Duration timeout;

  @override
  Map<String, Object?> toJson() => {
    'ready': 'port',
    if (port != null) 'port': port,
    if (from != null) 'from': from!.toJson(),
    'timeout': timeout.inMilliseconds,
  };
}

/// See [Ready.http] and [Ready.httpFrom].
final class HttpReady extends Ready {
  const HttpReady(int this.port, {this.path = '/', required this.timeout})
    : from = null;

  const HttpReady.from(
    ValueSource this.from, {
    this.path = '/',
    required this.timeout,
  }) : port = null;

  /// See [PortReady.port].
  final int? port;

  /// See [PortReady.from].
  final ValueSource? from;

  /// Absolute, starting with `/`.
  final String path;

  @override
  final Duration timeout;

  @override
  Map<String, Object?> toJson() => {
    'ready': 'http',
    if (port != null) 'port': port,
    if (from != null) 'from': from!.toJson(),
    'path': path,
    'timeout': timeout.inMilliseconds,
  };
}

/// Something a [DevStack] runs: the probe, `start`, `stop`, a [StackCommand].
///
/// Two kinds, because "which executable" is a question a config file cannot
/// answer and does not have to. A [StackRun.command] names an executable and
/// is right for one the machine is expected to have — `docker`, `kubectl`, `sh`.
/// A [StackRun.script] names a Dart file in this project and lets flutterware
/// supply the interpreter, which is the only way to be sure it is the SDK the
/// project pins.
///
/// This is the same argument [DefineSource.script] makes, and it is here
/// because the sibling API making it was not enough: both configs in this
/// repository open by computing `Platform.resolvedExecutable` into a `dart`
/// variable and prepending it to six commands, under ten lines of comment
/// explaining why. A consumer reached for `['fvm', 'dart', 'run', …]` instead —
/// a committed file naming a version manager, which then only works on the
/// machines that have it.
///
/// The third kind, [StackRun.tool], names an executable that is genuinely not
/// ours to supply — `uv`, `node`, a vendor CLI — and checks it is there before
/// anything runs, so a missing one is reported by name.
///
/// Every kind runs in the environment a new terminal window has, whether the
/// studio was opened from the Dock, from a terminal or by an agent. A command
/// that works when you type it works here, and a `dart run` finds its build
/// hooks as your terminal left them instead of rebuilding them. On CI and on
/// Windows it is the environment flutterware itself was started with.
sealed class StackRun {
  const StackRun();

  /// An executable and its arguments, spawned directly — so `$(…)`, pipes and
  /// `&&` exist only if `sh -c` is part of what you declared.
  const factory StackRun.command(List<String> command) = CommandRun;

  /// A Dart script in this project, run with the SDK flutterware is running
  /// under.
  ///
  /// ```dart
  /// StackRun.script('tool/local_env.dart', args: ['status', '--json'])
  /// ```
  ///
  /// [path] is relative to the stack's `workingDirectory`, and the script runs
  /// there — so it is written exactly as you would type it, having cd'd to the
  /// directory the stack's other commands already run in. That differs from
  /// [DefineSource.script], which is relative to the worktree root, and the
  /// difference is the `workingDirectory` this plugin has and that one does not.
  ///
  /// Run with `dart run`, so build hooks run and a server that depends on a
  /// package with native code finds its native assets. The first start after
  /// a dependency changes builds them, which can take a minute for a large
  /// native package: give [Ready] a timeout that allows for it.
  ///
  /// The one exception is a delegated service's status check, which runs on a
  /// timer and so runs as `dart <path>`, skipping the hooks. A status script
  /// that imports native code will not work there.
  const factory StackRun.script(String path, {List<String> args}) = ScriptRun;

  /// An executable looked up on the PATH a new terminal window has.
  ///
  /// ```dart
  /// StackRun.tool('uv', args: ['run', 'uvicorn', 'app:api'])
  /// ```
  ///
  /// A [StackRun.command] naming `uv` runs with that PATH too. What this adds
  /// is the check: the executable is looked up before anything is spawned, the
  /// command shown is its full path, and when it is not there the service
  /// **refuses to start and says which executable is missing**, instead of
  /// spawning it and reporting whatever `ENOENT` looks like from inside a
  /// health check.
  ///
  /// For a Dart script in this project, prefer [StackRun.script]: flutterware
  /// supplies the SDK and there is nothing to find.
  const factory StackRun.tool(String name, {List<String> args}) = ToolRun;

  Map<String, Object?> toJson();

  /// Reads back what [toJson] wrote, or null for a shape this build cannot read.
  ///
  /// A bare list is accepted too: that is what `start`, `stop` and a command
  /// were before this class existed, and a project pinning an older
  /// `flutterware` still writes one.
  static StackRun? fromJson(Object? raw) {
    if (raw is List) {
      var command = [for (var arg in raw) '$arg'];
      return command.isEmpty ? null : CommandRun(command);
    }
    if (raw is! Map) return null;
    if (raw['tool'] case String name) {
      return ToolRun(
        name,
        args: [
          for (var arg in (raw['args'] as List? ?? const []))
            if (arg is String) arg,
        ],
      );
    }
    if (raw['script'] case String path) {
      return ScriptRun(
        path,
        args: [
          for (var arg in (raw['args'] as List? ?? const []))
            if (arg is String) arg,
        ],
      );
    }
    if (raw['command'] case List raw) {
      var command = [for (var arg in raw) '$arg'];
      return command.isEmpty ? null : CommandRun(command);
    }
    return null;
  }
}

/// See [StackRun.command].
final class CommandRun extends StackRun {
  const CommandRun(this.command);

  final List<String> command;

  @override
  Map<String, Object?> toJson() => {'command': command};
}

/// See [StackRun.tool].
final class ToolRun extends StackRun {
  const ToolRun(this.name, {this.args = const []});

  /// The executable's name, as you would type it — `uv`, `node`, `docker`.
  /// Not a path: a path is a [StackRun.command] and needs no looking up.
  final String name;

  final List<String> args;

  @override
  Map<String, Object?> toJson() => {
    'tool': name,
    if (args.isNotEmpty) 'args': args,
  };
}

/// See [StackRun.script].
final class ScriptRun extends StackRun {
  const ScriptRun(this.path, {this.args = const []});

  /// Relative to the stack's `workingDirectory`, `/`-separated.
  final String path;

  final List<String> args;

  @override
  Map<String, Object?> toJson() => {
    'script': path,
    if (args.isNotEmpty) 'args': args,
  };
}

/// How a [DevStack] finds out what state it is in.
///
/// Two shapes, because the minimum and the useful maximum are different
/// commands. [Probe.exitCode] works against any health check that already
/// exists; [Probe.json] needs the tool to say more, and gives more back.
class Probe {
  /// Zero is up, anything else is down. The command's last non-empty output
  /// line becomes the detail shown beside the status.
  ///
  /// The floor, and it works today against `minikube status`,
  /// `supabase status` and any health check a project already has, without
  /// asking anyone to change anything.
  ///
  /// The command has to say no when the stack is down, and a lister does
  /// not. `docker compose ps --quiet` exits 0 and prints nothing for a
  /// stopped project — it succeeded at listing zero containers — so a probe
  /// declared that way reads `up` forever, and the panel is confidently green
  /// with no Bring-up button on it. The same goes for anything whose exit code
  /// is about whether the *tool* ran rather than what it found: `docker ps`,
  /// `kubectl get pods`, `ls`. The question to ask of a candidate is not "does
  /// this tell me about the stack" but "does this fail when there is nothing
  /// there".
  ///
  /// Where the answer is only in the output, the emptiness has to be turned
  /// into an exit code, and that needs a shell — a [StackRun.command] is
  /// spawned directly, so `$(…)`, pipes and `&&` exist only if `sh -c` is part
  /// of what you declared:
  ///
  /// ```dart
  /// Probe.exitCode(StackRun.command([
  ///   'sh',
  ///   '-c',
  ///   'test -n "$(docker compose ps --quiet --status running)"',
  /// ]))
  /// ```
  ///
  /// That names a Unix shell and is as portable as one. A project that needs
  /// more than one platform is better off putting the check in a
  /// [StackRun.script] of its own — which is most of the work of earning a
  /// [Probe.json], and gets the service list and the *broken* state with it.
  ///
  /// And a lister exits 0 over someone else's stack, too. The example above
  /// is right about zero containers and still wrong in a worktree: `docker
  /// compose` resolves its project from the working directory, so a checkout
  /// that has never brought its own stack up reports `up` — describing the
  /// containers of the *main* checkout next door. Measured in exactly that
  /// shape: exit 0, eight containers, none of them the worktree's. This is the
  /// monorepo the plugin is aimed at, and the failure is silent and confident.
  ///
  /// The reliable order is to answer from what identifies *this* checkout
  /// before asking the tool anything — no `.env`, no compose project name, no
  /// stack, answer `down` without spawning docker at all. That is a
  /// [StackRun.script] again, and one more reason the useful ceiling is
  /// [Probe.json].
  ///
  /// What it cannot do is tell *down* from *broken*: a health check that fails
  /// because Docker Desktop is asleep exits non-zero exactly like one that
  /// fails because nothing is up, and reporting "down" there offers a Bring-up
  /// button that cannot work. Use [Probe.json] where that distinction matters.
  const Probe.exitCode(this.run) : shape = ProbeShape.exitCode;

  /// The command prints one JSON object on stdout:
  ///
  /// ```json
  /// {
  ///   "state": "up",
  ///   "detail": "slot 8200-8208 · 4 containers",
  ///   "services": [{"name": "postgres", "port": 8200, "state": "up"}]
  /// }
  /// ```
  ///
  /// `state` is one of `down`, `starting`, `up`, `stopping`, `unavailable`;
  /// everything else is optional. `failure` is read too, and is where the
  /// reason goes when the state is `unavailable` — though a `detail` is taken
  /// as the reason there as well, because one sentence explaining what is wrong
  /// is one sentence whichever key it arrives under.
  ///
  /// A partly-up stack is `up`, with `services` saying which parts are
  /// not. Four of five services serving fits no single word above, and the
  /// word is not asked to carry it: report each service's own state and the
  /// surfaces render the fraction — `up 3/4`, washed amber rather than
  /// green. A probe that answers `down` there paints a working stack red and
  /// buries the whole truth in `detail`; `unavailable` is wrong twice, since
  /// it means the *probe* failed and this one just delivered its most useful
  /// answer.
  ///
  /// Read from **stdout only**. Almost nothing that prints structured output
  /// has stderr to itself — `dart` announces `Running build hooks...` there,
  /// docker writes deprecation warnings, a wrapper's `set -x` writes every line
  /// it runs — so folding it in would make a probe that works for a fortnight
  /// and then fails because a tool started mentioning something.
  ///
  /// Output that does not parse is reported as `unavailable` quoting whatever
  /// the command did say, because a probe that cannot be read is a probe that
  /// failed — not a stack that is down.
  const Probe.json(this.run) : shape = ProbeShape.json;

  final StackRun run;
  final ProbeShape shape;

  Map<String, Object?> toJson() => {'run': run.toJson(), 'shape': shape.name};

  static Probe? fromJson(Map<String, Object?> json) {
    // `command` as the fallback key: that is where a config pinning an older
    // `flutterware` puts its argv, and a probe that stops being read is a panel
    // that stops knowing anything.
    var run = StackRun.fromJson(json['run'] ?? json['command']);
    if (run == null) return null;
    return ProbeShape.byName(json['shape'] as String?) == ProbeShape.json
        ? Probe.json(run)
        : Probe.exitCode(run);
  }
}

/// How a [Probe]'s output is read.
enum ProbeShape {
  exitCode,
  json;

  static ProbeShape byName(String? name) =>
      values.firstWhere((v) => v.name == name, orElse: () => exitCode);
}

/// One more thing a [DevStack]'s CLI can be asked to do.
class StackCommand {
  const StackCommand(
    this.id,
    this.label,
    this.run, {
    this.description,
    this.danger = false,
    this.argument,
    this.timeout,
  });

  /// Stable within the plugin — what `fw run dev_stack <id>` names.
  final String id;

  final String label;
  final String? description;

  /// Run as declared, with [argument]'s value appended when one is given.
  final StackRun run;

  /// Destroys data. Renderers make it distinct and ask first.
  final bool danger;

  /// A free-text argument this command takes — `service` for `restart`,
  /// `surface` for `open`. Appended to [command]. Null for a command that takes
  /// nothing.
  final String? argument;

  /// How long to wait for this one, overriding [DevStack.commandTimeout].
  ///
  /// The command that needs it is the one that does not intend to finish:
  /// a `logs` that tails, a `watch`. Give it a few seconds — the wait ends,
  /// the output collected so far is what comes back, and the process is left
  /// alone. See [DevStack.commandTimeout] for why nothing is killed.
  final Duration? timeout;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'run': run.toJson(),
    if (description != null) 'description': description,
    if (danger) 'danger': true,
    if (argument != null) 'argument': argument,
    if (timeout != null) 'timeout': timeout!.inMilliseconds,
  };

  static StackCommand? fromJson(Map<String, Object?> json) {
    var id = json['id'];
    var label = json['label'];
    var run = StackRun.fromJson(json['run'] ?? json['command']);
    if (id is! String || label is! String || run == null) return null;
    return StackCommand(
      id,
      label,
      run,
      description: json['description'] as String?,
      danger: json['danger'] == true,
      argument: json['argument'] as String?,
      timeout: json['timeout'] is int
          ? Duration(milliseconds: json['timeout']! as int)
          : null,
    );
  }
}
