import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:path/path.dart' as p;

import '../../embedder/build_directory.dart';
import '../../previews/catalog_entry.dart';
import '../../previews/catalog_render.dart';
import '../../previews/devices.dart';
import '../../previews/discovery.dart';
import '../../previews/test_runner.dart';
import '../../previews/tester_renderer.dart';
import '../../scene/args_codegen.dart';
import '../../scene/args_generate.dart';
import '../../scene/discovery.dart';
import '../../scene/export/video.dart';
import '../../scene/group_file.dart';
import '../../scene/skeletons.dart';
import '../../scene/import/variables.dart';
import '../../scene/scene_file.dart';
import '../../scene/tokens_file.dart';
import '../../scene/tokens_library.dart';
import '../../scene/workspace.dart';
import '../../session/job.dart';
import '../../utils/string/plural.dart';
import '../plugin_core.dart';
import '../plugin_host.dart';
import '../scan_cache.dart';

/// The registered id — also what `tool/flutterware.dart` declares.
const scenePluginId = 'flutterware.scene';

/// What a package's scan covers when it declares no directory: the whole
/// package. A group is a folder with a `scenes.dart` in it, wherever that
/// folder is.
const defaultSceneDirectory = '.';

const _pluginDescription =
    'Scenes this project owns — a design and the motion animating it, in one '
    'tool-written file per scene, grouped by folder and rendered by the app '
    'itself.';

/// Scenes listed by name before the rest become a count.
const _projectedScenes = 12;

/// One property of one scene reading a token — what a delete names and a
/// rename follows.
class SceneTokenReader {
  SceneTokenReader(this.scenePath, this.sceneClass, this.node, this.prop);

  final String scenePath;
  final String sceneClass;
  final String node;
  final String prop;

  @override
  String toString() => '$sceneClass · $node.$prop';
}

/// What scene groups, scenes and token libraries a project has, and where.
///
/// Discovery is a directory walk and a first line: a group's `scenes.dart`,
/// a scene file and a library file each declare themselves with a marker,
/// so nothing here compiles, analyses or boots. Opening a scene — parsing
/// it in full, refusing it with line numbers — is the panel's job, over the
/// same door `fw` would use.
class SceneCore extends PluginCore {
  SceneCore(super.host);

  List<String> get packages => host.packagePaths;

  /// Where this package is scanned, per `tool/flutterware.dart` — the whole
  /// package unless it narrows the scope.
  String directoryFor(String path) {
    for (var config in host.packageConfigs) {
      if (config['path'] == path) {
        if (config['directory'] case String directory) return directory;
      }
    }
    return defaultSceneDirectory;
  }

  /// The package's own root — what a catalog entry's path is relative to.
  String projectRootFor(String package) =>
      host.workspace.packageFor(package).directory.path;

  /// The absolute directory scanned for [package].
  String rootFor(String package) =>
      p.normalize(p.join(projectRootFor(package), directoryFor(package)));

  late final _cache = ScanCache<String, ScenePackageScan>(
    scan: (package) async {
      // Declarations first, then the vocabulary they generate, then the
      // scene files that spell it. A scene file names `DrinkBadgeArgs`,
      // whose class is written from the group's declaration of that widget
      // — so a scan that listed scenes without regenerating would hand the
      // panel files naming classes that no longer exist.
      var scan = discoverPackage(rootFor(package));
      _argsFor[package] = generateSceneArgsIn(rootFor(package), scan: scan);
      return scan;
    },
    onChanged: notifyChanged,
  );

  final _argsFor = <String, Map<String, SceneArgsResult>>{};

  /// What the last generation run for [group] had to say — the refusals its
  /// declaration or a library earned, and whether the vocabulary was
  /// rewritten. Null before the first scan.
  SceneArgsResult? argsResultFor(String package, SceneGroupEntry group) =>
      _argsFor[package]?[group.directory];

  /// What [group] declares: its widgets, its exports, its libraries. Read
  /// at the last scan, or now when nothing has scanned yet; empty when the
  /// declaration is refused, in which case [argsResultFor] says why.
  GroupVocabulary vocabularyFor(String package, SceneGroupEntry group) {
    if (argsResultFor(package, group) case var result?) {
      return result.vocabulary;
    }
    var scan = scanFor(package) ?? discoverPackage(rootFor(package));
    return readGroup(group, scan).vocabulary ?? GroupVocabulary.empty;
  }

  /// Everything found under [package], or null when nothing has looked yet.
  ScenePackageScan? scanFor(String package) => _cache[package];

  /// The scenes of [package] across its groups, or null when nothing has
  /// looked yet.
  List<SceneEntry>? scenesFor(String package) => scanFor(package)?.scenes;

  /// The group a scene file belongs to.
  SceneGroupEntry? groupFor(String package, String scenePath) =>
      (scanFor(package) ?? discoverPackage(rootFor(package))).groupOf(
        scenePath,
      );

  /// A group's folder as the catalog names it: relative to the package.
  String groupPathFor(String package, SceneGroupEntry group) =>
      p.relative(group.directory, from: projectRootFor(package));

  bool isScanning(String package) => _cache.isScanning(package);

  String? failureFor(String package) => _cache.failureFor(package);

  /// Start (or reuse) the scan for [package] — what mounting the panel does.
  void track(String package) => _cache.track(package);

  /// Forget what was found, so the next look walks the directory again.
  ///
  /// Only forgets: something has to ask again afterwards, or a surface that
  /// reads the listing sits on its loading state forever. [reload] is the one
  /// to call when nobody else will ask.
  void rescan(String package) => _cache.invalidate(package);

  /// Walks the directory again now — what a file appearing on disk needs.
  Future<void> reload(String package) => _cache.reload(package);

  /// Discovery is a directory walk and a first line, so every surface that
  /// asks for status can afford it — which is what keeps `fw` and MCP from
  /// reporting "not computed" for a project that plainly has scenes.
  @override
  Future<void> computeAll() async {
    await Future.wait([for (var package in packages) _cache.load(package)]);
  }

  // --- Writing the folders -------------------------------------------------

  /// A new group: the folder, and the declaration skeleton in it. The
  /// folder is relative to the package. Refused, by message, when the
  /// folder already declares a group.
  Future<String> createGroup(String package, String folder) async {
    var directory = p.normalize(p.join(projectRootFor(package), folder));
    var declaration = File(p.join(directory, sceneGroupFileName));
    if (declaration.existsSync()) {
      throw ActionRefusal(
        '${p.relative(declaration.path, from: host.worktree.path)} '
        'already exists: that folder is already a group',
      );
    }
    if (!p.isWithin(rootFor(package), directory) &&
        p.canonicalize(rootFor(package)) != p.canonicalize(directory)) {
      throw ActionRefusal(
        '$folder is outside ${directoryFor(package)}/, where scenes are '
        'looked for, so they would not be found',
      );
    }
    Directory(directory).createSync(recursive: true);
    declaration.writeAsStringSync(emitGroupSkeleton());
    await reload(package);
    return declaration.path;
  }

  /// A scene in [folder], relative to the package — and the folder's
  /// declaration when it does not have one yet.
  ///
  /// That second clause is the whole of what making a group used to be. A
  /// folder holding a `$sceneGroupFileName` and nothing else is not a thing
  /// anybody wants; it was a first step you had to know about before the
  /// step you wanted was available at all.
  Future<String> createScene(
    String package,
    String folder,
    String className, {
    double width = 1024,
    double height = 500,
  }) async {
    if (!RegExp(r'^[A-Z][A-Za-z0-9]*$').hasMatch(className)) {
      throw ArgumentError.value(
        className,
        'name',
        'a Dart class name: a capital first, then letters and digits',
      );
    }
    var directory = p.normalize(p.join(projectRootFor(package), folder));
    var file = File(p.join(directory, sceneFileNameFor(className)));
    if (file.existsSync()) {
      throw ActionRefusal(
        '${p.relative(file.path, from: host.worktree.path)} already exists',
      );
    }
    if (!File(p.join(directory, sceneGroupFileName)).existsSync()) {
      // Refuses on its own terms when the folder is outside the scanned
      // scope, which is the check this needs too.
      await createGroup(package, folder);
    }
    Directory(directory).createSync(recursive: true);
    var root = FrameNode(name: 'root')
      ..width = width
      ..height = height
      ..fill = const SceneColor(0xFFFFFFFF);
    file.writeAsStringSync(
      emitSceneFile(SceneDocument(root), className: className),
    );
    await reload(package);
    return file.path;
  }

  /// A new library: `<name>.tokens.dart` in [folder], empty, the editor's
  /// own.
  ///
  /// Where it lands is the whole of who reads it, so the groups that read it
  /// are reconciled straight away — this is the tool's own write, and the
  /// only moment it can be certain what the folders mean.
  Future<String> createLibrary(
    String package,
    String folder,
    String name,
  ) async {
    var directory = p.normalize(p.join(projectRootFor(package), folder));
    var file = File(p.join(directory, tokensFileNameFor(name)));
    if (file.existsSync()) {
      throw ActionRefusal(
        '${p.relative(file.path, from: host.worktree.path)} already exists',
      );
    }
    Directory(directory).createSync(recursive: true);
    file.writeAsStringSync(emitTokensSkeleton(tokensSymbolFor(file.path)));
    var scan = discoverPackage(rootFor(package));
    for (var group in scan.groupsReading(file.path)) {
      _attach(group, file.path);
    }
    await reload(package);
    return file.path;
  }

  /// Writes [group]'s `libraries:` to say what its folder says: the ones
  /// below it that it does not list, listed; the ones it lists that are not
  /// below it, dropped.
  ///
  /// Called when the tool caused the change, and offered as one action when
  /// the human did — never run off a scan. A scan happens on every disk
  /// change, and `scenes.dart` is code somebody wrote: silently rewriting it
  /// under an editor is the thing this design exists to stop.
  Future<void> reconcileLibraries(String package, SceneGroupEntry group) async {
    var drift = driftFor(package, group);
    for (var library in drift.missing) {
      _attach(group, library.path);
    }
    for (var library in drift.stray) {
      _detach(group, library.path);
    }
    await reload(package);
  }

  /// What [group] lists against what its folder says it reads.
  ///
  /// The declaration is the fact — it is what compiles, and what the guest
  /// will have — and the walk is the intent. This is the gap between them,
  /// and it is worth showing rather than closing behind the human's back.
  SceneLibraryDrift driftFor(String package, SceneGroupEntry group) {
    var scan = scanFor(package) ?? discoverPackage(rootFor(package));
    // Parsed here rather than taken from the vocabulary, and by name rather
    // than by what the scan found: a library somebody moved out of the folder
    // leaves an import behind that resolves to nothing, which makes the whole
    // declaration refused — and a refused declaration has no vocabulary to
    // read the stray entry out of. The entry that has to go is exactly what
    // this needs to name.
    var parsed = parseGroupFile(
      File(group.declarationPath).readAsStringSync(),
      resolveImport: importResolverFor(group.declarationPath),
      librarySymbolAt: (path) =>
          path.endsWith(sceneTokensFileSuffix) ? tokensSymbolFor(path) : null,
    );
    var listed = <String>{};
    var stray = <SceneLibraryEntry>[];
    for (var ref in parsed.libraries) {
      if (ref.path case var path?) {
        // Readable from here means both: below this folder, and still there.
        if (readsLibrary(group.directory, path) && File(path).existsSync()) {
          listed.add(p.canonicalize(path));
        } else {
          stray.add(SceneLibraryEntry(path: path));
        }
      }
    }
    return SceneLibraryDrift(
      missing: [
        for (var library in scan.librariesFor(group))
          if (!listed.contains(p.canonicalize(library.path))) library,
      ],
      stray: stray,
    );
  }

  void _attach(SceneGroupEntry group, String libraryPath) {
    var declaration = File(group.declarationPath);
    var edited = attachLibraryIn(
      declaration.readAsStringSync(),
      group.declarationPath,
      libraryPath,
      refuse: (reason) => throw ActionRefusal(reason),
    );
    if (edited != null) declaration.writeAsStringSync(edited);
  }

  void _detach(SceneGroupEntry group, String libraryPath) {
    var declaration = File(group.declarationPath);
    var edited = detachLibraryIn(
      declaration.readAsStringSync(),
      group.declarationPath,
      libraryPath,
      refuse: (reason) => throw ActionRefusal(reason),
    );
    if (edited != null) declaration.writeAsStringSync(edited);
  }

  // --- Tokens across the group ---------------------------------------------

  /// The groups that read the library at [libraryPath] — its folder's, and
  /// every group below it.
  List<SceneGroupEntry> groupsReading(String package, String libraryPath) =>
      (scanFor(package) ?? discoverPackage(rootFor(package))).groupsReading(
        libraryPath,
      );

  /// Every property reading [token] in every scene of every group reading
  /// [libraryPath], except the scene files in [except] — the open ones,
  /// whose editors know their own readers. Parsed fresh from disk, so a
  /// rename or a delete is judged against what the files say now.
  List<SceneTokenReader> tokenReaders(
    String package,
    String libraryPath,
    String token, {
    Set<String> except = const {},
  }) {
    var skip = {for (var e in except) p.canonicalize(e)};
    var readers = <SceneTokenReader>[];
    for (var group in groupsReading(package, libraryPath)) {
      var tokens = vocabularyFor(package, group).tokens;
      for (var scene in group.scenes) {
        if (skip.contains(p.canonicalize(scene.path))) continue;
        var parsed = parseSceneFile(
          File(scene.path).readAsStringSync(),
          tokens: tokens,
        );
        var doc = parsed.doc;
        if (doc == null) continue;
        for (var (node, _) in doc.walk()) {
          for (var e in node.bindings.entries) {
            var name = switch (e.value) {
              TokenRef(:var name) || StyleRef(:var name) => name,
              _ => null,
            };
            if (name == token) {
              readers.add(
                SceneTokenReader(scene.path, scene.className, node.name, e.key),
              );
            }
          }
        }
      }
    }
    return readers;
  }

  /// Rewrites every closed scene file reading [from] so it reads [to] —
  /// the half of a rename the open editors cannot do. [vocabulary] is the
  /// group's tokens as they will be once the library is written, so the
  /// rewritten file parses against them. Returns the files touched.
  List<String> renameTokenInFiles(
    String package,
    String libraryPath,
    String from,
    String to, {
    Set<String> except = const {},
  }) {
    var touched = <String>[];
    var skip = {for (var e in except) p.canonicalize(e)};
    for (var group in groupsReading(package, libraryPath)) {
      var before = vocabularyFor(package, group).tokens;
      var after = [
        for (var t in before)
          if (t.name == from) _renamedDecl(t, to) else t,
      ];
      for (var scene in group.scenes) {
        if (skip.contains(p.canonicalize(scene.path))) continue;
        var source = File(scene.path).readAsStringSync();
        var opened = SceneFile.open(
          scene.path,
          source,
          declaredArgs: vocabularyFor(package, group).declaredArgs,
          tokens: before,
        );
        var file = opened.file;
        if (file == null) continue;
        if (file.editor.readersOfToken(from).isEmpty) continue;
        file.editor.renameTokenRefs(from, to);
        file.editor.retokenize(after);
        var refusals = file.save(
          (path, text) => File(path).writeAsStringSync(text),
        );
        if (refusals.isEmpty) touched.add(scene.path);
      }
    }
    return touched;
  }

  static SceneTokenDecl _renamedDecl(SceneTokenDecl t, String name) =>
      t.style != null
      ? SceneTokenDecl.style(name, t.style!)
      : t.isExport
      ? SceneTokenDecl.export(name, t.type)
      : SceneTokenDecl(name, t.kind!, t.value!);

  // --- Rendering -----------------------------------------------------------

  /// The preview entry that plays a scene from a file — generated beside
  /// every group's declaration, so a scene is exported with its own
  /// widgets and its own wrapper.
  static const playerEntrySymbol = scenePlayerSymbol;

  /// Renders a clip of [scene]'s motion.
  ///
  /// The harness lane, not the guest: a clip's frames must each be *of* the
  /// moment they claim, and only the tester can promise that — it parks the
  /// playhead and rasterises the tree that pump produced. The scene travels
  /// as a file because a walk asks for it once and a scene is kilobytes.
  Future<Artifact> exportVideo({
    required String package,
    required String scenePath,
    int fps = 30,
    Map<String, Object?> args = const {},
  }) async {
    var group = groupFor(package, scenePath);
    if (group == null) {
      throw ActionRefusal(
        '${p.basename(scenePath)} is not in a group: no folder above it has '
        'a $sceneGroupFileName, and a scene is rendered through its group',
      );
    }
    var opened = parseSceneFile(
      File(scenePath).readAsStringSync(),
      tokens: vocabularyFor(package, group).tokens,
    );
    if (!opened.ok) {
      throw ActionRefusal(
        'that scene does not parse, so there is nothing to render:\n'
        '${opened.refusals.take(3).join('\n')}',
      );
    }
    // The scene's own parameters, answered by the caller: the same door a
    // preview or an app uses when it writes `StoreHero(headline: …)`, which
    // is what lets ONE authored scene render every locale's clip. Applied to
    // the parsed document before it travels, so the walk sees the values and
    // nothing downstream has to know they were overridden.
    if (args.isNotEmpty) {
      var declared = {for (var param in opened.doc!.params) param.name};
      var unknown = args.keys.where((k) => !declared.contains(k)).toList();
      if (unknown.isNotEmpty) {
        throw ActionRefusal(
          '${p.basename(scenePath)} declares no parameter '
          '${unknown.join(', ')}. It takes '
          '${declared.isEmpty ? 'none' : declared.join(', ')}.',
        );
      }
      opened.doc!.applyArgs(args);
    }
    if (opened.motions.isEmpty) {
      throw ActionRefusal(
        '${p.basename(scenePath)} has no motion, so there is nothing to '
        'render as a video',
      );
    }
    var entry = _playerEntry(package, group);
    var pair =
        File(
          p.join(
            Directory.systemTemp.createTempSync('fw-scene').path,
            'pair.json',
          ),
        )..writeAsStringSync(
          jsonEncode(
            sceneFileToJson(
              opened.doc!,
              className: opened.className!,
              motions: opened.motions,
            ),
          ),
        );

    var output = p.join(
      host.workspace.appContext.appToolDirectory.path,
      'build',
      'scene',
      '${opened.className}${_argsSuffix(args)}.mp4',
    );
    // The whole motion at `fps`: only the running motion knows how long it
    // is, so the stops are not computed here.
    // The artboard's own size, not the panel's: a clip of a scene is the
    // scene, and rendering it in a viewport of another shape crops one edge
    // and letterboxes the other.
    var root = opened.doc!.root;
    MotionVideo video;
    try {
      var walk = await TesterRenderer(runner: _runnerFor(package, entry)).walk(
        CatalogWalk(
          entryId: entry.id,
          fps: fps,
          viewport: CaptureViewport(
            width: (root.width ?? 1024).round(),
            height: (root.height ?? 500).round(),
          ),
          knobs: {'pair': pair.path},
        ),
      );
      video = await encodeWalk(walk, output: output, fps: fps);
    } finally {
      pair.parent.deleteSync(recursive: true);
    }

    return Artifact(
      kind: Artifact.mp4,
      address: Address(
        worktree: host.worktree.name,
        plugin: host.id,
        segments: [package, p.basename(scenePath)],
      ),
      path: p.relative(video.file.path, from: host.worktree.path),
      meta: {
        'scene': opened.className,
        'group': group.name,
        'size': [root.width, root.height],
        'motion': opened.motions.keys.first,
        'file': p.relative(scenePath, from: host.worktree.path),
        'fps': video.fps,
        'frames': video.frames,
        'durationMs': video.durationMs,
        'renderMs': video.renderTime.inMilliseconds,
        'encodeMs': video.encodeTime.inMilliseconds,
        'bytes': video.file.lengthSync(),
      },
    );
  }

  /// The group's scene-player entry, or a refusal naming what is missing.
  ///
  /// Scanned rather than asked of the previews plugin: an export must work
  /// whether or not that panel has ever been opened.
  CatalogEntry _playerEntry(String package, SceneGroupEntry group) {
    var scan = CatalogScanner(projectRoot: projectRootFor(package)).scan();
    var folder = groupPathFor(package, group);
    for (var entry in scan.entries) {
      if (entry.symbol == playerEntrySymbol &&
          isGroupHostEntry(entry.path, folder)) {
        return entry;
      }
    }
    throw ActionRefusal(
      'no scene player in $folder/. The generated $sceneArgsFileName '
      'declares it; rescan the group to write it.',
    );
  }

  /// The harness this plugin renders on, one per declared package — its own
  /// lane, because two hosts on one build directory are two
  /// `frontend_server`s writing one dill.
  PreviewTestRunner _runnerFor(String package, CatalogEntry entry) =>
      _runners.putIfAbsent(
        package,
        () => PreviewTestRunner(
          packageRoot: projectRootFor(package),
          flutterSdkRoot: host.workspace.flutterSdk.root,
          // One entry, not the catalog: the generated harness imports every
          // entry it is given, so a clip would otherwise pay a cold compile
          // of every demo in the project.
          read: () => (entries: [entry], canvases: const []),
          buildDirectory: sceneBuildRoot,
        ),
      );

  final _runners = <String, PreviewTestRunner>{};

  /// Ends the harnesses [exportVideo] started — a `frontend_server` and a
  /// `flutter_tester` per package.
  ///
  /// Without it `fw run scene video` printed its clip and never exited: the
  /// two processes, and the service socket to the tester, held the CLI's
  /// event loop open with nothing left to do.
  @override
  void dispose() {
    for (var runner in _runners.values) {
      unawaited(runner.dispose());
    }
    _runners.clear();
    super.dispose();
  }

  // --- Report --------------------------------------------------------------

  @override
  PluginReport get report => PluginReport(
    id: host.id,
    label: host.label,
    description: _pluginDescription,
    status: _status,
    badge: _badge,
    children: [
      for (var path in packages)
        PluginChild(
          id: path,
          label: path == '.' ? 'root' : path,
          status: _childStatus(path),
        ),
    ],
    actions: _actions,
    view: _view,
  );

  List<PluginAction> get _actions => [
    PluginAction(
      'list',
      'List',
      description:
          'The folders this project keeps scenes in — what is in each, what '
          'its scenes may use, and every library found with the scenes that '
          'read it. A folder holds scenes when it has a $sceneGroupFileName '
          'in it; nothing is listed in configuration.',
      parameters: [_packageParameter],
    ),
    PluginAction(
      'video',
      'Video',
      description:
          "Renders a scene's motion to an mp4, drawn by the app itself — "
          'its theme, the widgets its folder declares — one frame per '
          'moment on the harness lane, where a frame cannot be of a moment '
          'other than the one it was drawn for. Needs ffmpeg.',
      parameters: [
        _packageParameter,
        ActionParameter(
          'scene',
          'Scene',
          description: 'The scene file, by name or path.',
          required: true,
        ),
        ActionParameter(
          'fps',
          'Frames a second',
          required: false,
          defaultValue: '30',
          // What the default column cannot say: the range, and that this is
          // how finely the motion is sampled rather than how long the clip is
          // — the length is the motion's own either way.
          description: 'Between 1 and 120.',
        ),
        ActionParameter(
          'args',
          'Arguments',
          required: false,
          description:
              "A JSON object answering the scene's own parameters — "
              '{"headline": "Votre café", "shotFront": "…/01-welcome.png"}. '
              'One authored scene then renders every locale, and each '
              'setting is a file of its own rather than the same name '
              'written twice. A name the scene does not declare is refused, '
              'with the ones it does.',
        ),
      ],
    ),
    PluginAction(
      'newScene',
      'New scene',
      description:
          'Writes a scene file with an empty artboard — and the folder and '
          'its $sceneGroupFileName too, when that folder does not keep '
          'scenes yet. The one thing to reach for to start a scene.',
      parameters: [
        _packageParameter,
        ActionParameter(
          'name',
          'Name',
          description:
              'The scene class — PromoBadge. The file is named '
              'from it: promo_badge.scene.dart.',
          required: true,
        ),
        ActionParameter(
          'folder',
          'Folder',
          description:
              'Relative to the package. An existing folder of scenes, or a '
              'new one, which is written on the way. Default: the first '
              'folder that already keeps scenes, else lib/scenes.',
          required: false,
        ),
        ActionParameter(
          'width',
          'Artboard width',
          description: 'Default 1024.',
          required: false,
        ),
        ActionParameter(
          'height',
          'Artboard height',
          description: 'Default 500.',
          required: false,
        ),
      ],
    ),
    PluginAction(
      'newGroup',
      'New folder of scenes',
      description:
          "Writes a folder's $sceneGroupFileName on its own — the "
          'declaration saying what the scenes in it may use. `newScene` '
          'writes this as well when it has to, so reach for this only to '
          'prepare a folder before there is anything to put in it.',
      parameters: [
        _packageParameter,
        ActionParameter(
          'folder',
          'Folder',
          description: 'Relative to the package — lib/scenes/marketing.',
          required: true,
        ),
      ],
    ),
    PluginAction(
      'newLibrary',
      'New library',
      description:
          'Writes an empty token library — <name>$sceneTokensFileSuffix, '
          "the editor's own. Where it lands is who reads it: the scenes "
          'below its folder, and no others. A colour, a number or a text '
          'style — a library is a design system, not a bag of values.',
      parameters: [
        _packageParameter,
        ActionParameter(
          'name',
          'Name',
          description: 'The library — Brand, store front.',
          required: true,
        ),
        ActionParameter(
          'folder',
          'Folder',
          description:
              'Relative to the package, and the whole of who reads it — a '
              'folder of scenes for those scenes alone, a folder above '
              'several for all of them. Defaults to the folder named by '
              'group, else lib/.',
          required: false,
        ),
        ActionParameter(
          'group',
          'Group',
          description:
              'A folder of scenes, relative to the package — shorthand for '
              'that folder, so the library is read by its scenes.',
          required: false,
        ),
      ],
    ),
    PluginAction(
      'importTokens',
      'Import tokens',
      description:
          "Merges a design file's variables into a token library — the "
          'JSON its REST API answers for local variables, saved to a file. '
          "By name: a token the file knows takes the file's value, a new "
          'one is added, one the file does not have is kept and listed; a '
          'name held here as another kind is refused by name, as is a '
          'variable that cannot be a token. Only the default mode of a '
          'collection is read — a library holds one value per token — and '
          'every other mode is refused by name. The report is written into '
          'the library, where the panel shows it.',
      parameters: [
        _packageParameter,
        ActionParameter(
          'file',
          'Variables JSON',
          description: 'The saved response, by path.',
          required: true,
        ),
        ActionParameter(
          'library',
          'Library',
          description:
              'The library file to merge into, created when missing — '
              'relative to the package, lib/design/brand'
              '$sceneTokensFileSuffix. Default: imported'
              '$sceneTokensFileSuffix in the first folder of scenes.',
          required: false,
        ),
      ],
    ),
  ];

  /// The import door: read, merge into the library (opened from disk, or
  /// new), write, and rescan so the generated vocabulary follows. Returns
  /// the report — what was added, updated, kept and refused.
  Future<Map<String, Object?>> importTokens({
    required String package,
    required String jsonPath,
    String? library,
  }) async {
    var file = File(jsonPath);
    if (!file.existsSync()) {
      throw ArgumentError.value(jsonPath, 'file', 'no such file');
    }
    var imported = importVariables(file.readAsStringSync());
    if (imported.tokens.isEmpty) {
      throw ArgumentError.value(
        jsonPath,
        'file',
        'nothing to import: ${imported.refusals.join('; ')}',
      );
    }
    File target;
    if (library != null && library.isNotEmpty) {
      var path = p.isAbsolute(library)
          ? library
          : p.join(projectRootFor(package), library);
      if (!path.endsWith(sceneTokensFileSuffix)) {
        throw ArgumentError.value(
          library,
          'library',
          'a library file ends in $sceneTokensFileSuffix',
        );
      }
      target = File(p.normalize(path));
    } else {
      var scan = scanFor(package) ?? discoverPackage(rootFor(package));
      var folder = scan.groups.firstOrNull?.directory ?? rootFor(package);
      target = File(p.join(folder, 'imported$sceneTokensFileSuffix'));
    }
    var symbol = tokensSymbolFor(target.path);
    TokensLibrary document;
    if (target.existsSync()) {
      var opened = TokensLibrary.open(target.path, target.readAsStringSync());
      if (!opened.ok) {
        throw ActionRefusal(
          '${p.relative(target.path, from: host.worktree.path)} cannot be '
          'read as a token library. Fix it first: '
          '${opened.refusals.join('; ')}',
        );
      }
      document = opened.library!;
    } else {
      document = TokensLibrary(path: target.path);
    }
    var note = document.merge(imported, from: p.basename(jsonPath));
    var source = document.emit();
    // The file the tool writes has to be one the tool reads: the parser is
    // the grader, before anything lands on disk.
    var check = parseTokensFile(source, symbol: symbol);
    if (!check.ok) {
      throw StateError(
        'the import produced a file its own reader refuses: '
        '${check.refusals.join('; ')}',
      );
    }
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(source);
    await reload(package);
    // The tool wrote the file, so the tool says who reads it — otherwise an
    // import lands as a file nobody names, which is a step nobody would
    // guess is missing.
    for (var group in groupsReading(package, target.path)) {
      await reconcileLibraries(package, group);
    }
    return {
      'path': p.relative(target.path, from: host.worktree.path),
      'symbol': symbol,
      'tokens': [
        for (var t in imported.tokens)
          {'name': t.name, 'type': t.decl.typeName, 'from': t.source},
      ],
      'added': note.added,
      'updated': note.updated,
      'unchanged': note.unchanged,
      'kept': note.kept,
      'refusals': note.notImported,
      'readBy': [
        for (var group in groupsReading(package, target.path))
          groupPathFor(package, group),
      ],
    };
  }

  ActionParameter get _packageParameter => ActionParameter(
    'package',
    'Package',
    required: false,
    description: 'Which declared package; the first when omitted.',
    options: [for (var path in packages) ActionOption(path)],
  );

  @override
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) async {
    var package = switch (arguments['package']) {
      String named when packages.contains(named) => named,
      String named => throw ArgumentError.value(
        named,
        'package',
        'no such declared package. Declared: ${packages.join(', ')}',
      ),
      _ => packages.firstOrNull,
    };
    if (package == null) {
      throw ActionRefusal('this plugin is not declared for any package');
    }
    switch (actionId) {
      case 'list':
        await _cache.load(package);
        var scan = scanFor(package)!;
        return {
          'package': package,
          'scope': directoryFor(package),
          'groups': [
            for (var group in scan.groups)
              {
                'name': group.name,
                'folder': groupPathFor(package, group),
                'libraries': [
                  for (var l in vocabularyFor(package, group).libraries)
                    p.relative(l.entry.path, from: host.worktree.path),
                ],
                'widgets': [
                  for (var w in vocabularyFor(package, group).widgets) w.entry,
                ],
                'exports': [
                  for (var t in vocabularyFor(package, group).exports) t.name,
                ],
                'refusals': [
                  for (var r
                      in argsResultFor(package, group)?.refusals ??
                          const <SceneRefusal>[])
                    '$r',
                ],
                'scenes': [
                  for (var scene in group.scenes)
                    {
                      'class': scene.className,
                      'path': p.relative(scene.path, from: host.worktree.path),
                    },
                ],
              },
          ],
          'libraries': [
            for (var library in scan.libraries)
              {
                'symbol': library.symbol,
                'path': p.relative(library.path, from: host.worktree.path),
                'readBy': [
                  for (var g in scan.groupsReading(library.path))
                    groupPathFor(package, g),
                ],
              },
          ],
          'strayScenes': scan.strayScenes,
        };
      case 'newScene':
        var name = _text(arguments['name'], 'name', 'a scene class name');
        var scan = scanFor(package) ?? discoverPackage(rootFor(package));
        // The folder you did not name is the one you would have named: the
        // first that already keeps scenes, and only failing that a new one.
        var folder = switch (arguments['folder']) {
          String f when f.isNotEmpty => f,
          _ =>
            scan.groups.isEmpty
                ? 'lib/scenes'
                : groupPathFor(package, scan.groups.first),
        };
        var wroteFolder = !File(
          p.join(
            p.normalize(p.join(projectRootFor(package), folder)),
            sceneGroupFileName,
          ),
        ).existsSync();
        var path = await createScene(
          package,
          folder,
          name,
          width: _number(arguments['width']) ?? 1024,
          height: _number(arguments['height']) ?? 500,
        );
        return {
          'path': p.relative(path, from: host.worktree.path),
          'class': name,
          'folder': folder,
          if (wroteFolder) 'alsoWrote': p.join(folder, sceneGroupFileName),
        };
      case 'newGroup':
        var folder = _text(arguments['folder'], 'folder', 'a folder path');
        var path = await createGroup(package, folder);
        return {'path': p.relative(path, from: host.worktree.path)};
      case 'newLibrary':
        var name = _text(arguments['name'], 'name', 'a library name');
        var scan = scanFor(package) ?? discoverPackage(rootFor(package));
        SceneGroupEntry? group;
        if (arguments['group'] case String folder when folder.isNotEmpty) {
          var wanted = p.normalize(p.join(projectRootFor(package), folder));
          group = scan.groups
              .where(
                (g) => p.canonicalize(g.directory) == p.canonicalize(wanted),
              )
              .firstOrNull;
          if (group == null) {
            throw ArgumentError.value(
              folder,
              'group',
              scan.groups.isEmpty
                  ? 'this package has no groups'
                  : 'no such group. Found: '
                        '${scan.groups.map((g) => groupPathFor(package, g)).join(', ')}',
            );
          }
        }
        var folder = switch (arguments['folder']) {
          String f when f.isNotEmpty => f,
          _ => group == null ? 'lib' : groupPathFor(package, group),
        };
        var path = await createLibrary(package, folder, name);
        return {
          'path': p.relative(path, from: host.worktree.path),
          'symbol': tokensSymbolFor(path),
          'readBy': [
            for (var g in groupsReading(package, path))
              groupPathFor(package, g),
          ],
        };
      case 'importTokens':
        return importTokens(
          package: package,
          jsonPath: switch (arguments['file']) {
            String path when path.isNotEmpty =>
              p.isAbsolute(path) ? path : p.join(host.worktree.path, path),
            _ => throw ArgumentError.value(
              arguments['file'],
              'file',
              'the saved variables JSON, by path',
            ),
          },
          library: arguments['library'] as String?,
        );
      case 'video':
        return exportVideo(
          package: package,
          scenePath: _resolveScene(package, arguments['scene']),
          fps: switch (arguments['fps']) {
            int value => value,
            String text when int.tryParse(text) != null => int.parse(text),
            _ => 30,
          }.clamp(1, 120),
          args: _argsObject(arguments['args']),
        );
      default:
        return super.invoke(actionId, arguments: arguments);
    }
  }

  /// The `args` argument, from a JSON object or a map that already is one.
  static Map<String, Object?> _argsObject(Object? value) => switch (value) {
    null => const {},
    Map<String, Object?> map => map,
    String text when text.trim().isEmpty => const {},
    String text => switch (_decodeOrNull(text)) {
      Map<String, Object?> map => map,
      _ => throw ArgumentError.value(text, 'args', 'must be a JSON object'),
    },
    _ => throw ArgumentError.value(value, 'args', 'must be a JSON object'),
  };

  static Object? _decodeOrNull(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  /// What tells two settings of one scene apart on disk.
  ///
  /// A digest rather than the values: a headline is a sentence and a shot is
  /// an absolute path, and neither belongs in a file name. Empty for the
  /// unparameterised call, so the plain `Scene.mp4` keeps its name.
  static String _argsSuffix(Map<String, Object?> args) {
    if (args.isEmpty) return '';
    var keys = args.keys.toList()..sort();
    var canonical = jsonEncode({for (var k in keys) k: args[k]});
    return '-${sha1.convert(utf8.encode(canonical)).toString().substring(0, 8)}';
  }

  static String _text(Object? value, String name, String what) =>
      switch (value) {
        String s when s.trim().isNotEmpty => s.trim(),
        _ => throw ArgumentError.value(value, name, what),
      };

  /// A number an argument carries, however the transport spelled it — the
  /// CLI hands over strings, MCP hands over JSON numbers, and both mean the
  /// same 1024. Null when it was not given.
  static double? _number(Object? value) => switch (value) {
    num n => n.toDouble(),
    String s when s.trim().isNotEmpty => double.tryParse(s.trim()),
    _ => null,
  };

  /// A scene named by class, file name or path — refused by listing what
  /// this package actually has, which is the only useful answer to a typo.
  String _resolveScene(String package, Object? wanted) {
    var scenes = scenesFor(package) ?? discoverPackage(rootFor(package)).scenes;
    if (wanted is String) {
      for (var scene in scenes) {
        if (scene.className == wanted ||
            scene.fileName == wanted ||
            scene.path == wanted ||
            p.relative(scene.path, from: host.worktree.path) == wanted) {
          return scene.path;
        }
      }
    }
    throw ArgumentError.value(
      wanted,
      'scene',
      scenes.isEmpty
          ? 'this package has no scenes'
          : 'no such scene. Found: ${scenes.map((s) => s.className).join(', ')}',
    );
  }

  Status get _status {
    var scanned = packages.where((p) => scanFor(p) != null).toList();
    if (scanned.isEmpty) {
      return const Status.neutral('not computed');
    }
    var total = scanned.fold(0, (n, p) => n + scanFor(p)!.scenes.length);
    var groups = scanned.fold(0, (n, p) => n + scanFor(p)!.groups.length);
    if (groups == 0) return const Status.neutral('no scene groups');
    return Status.neutral(
      '${plural(total, 'scene')} · ${plural(groups, 'group')}',
    );
  }

  StatusBadge get _badge {
    var total = 0;
    for (var package in packages) {
      total += scanFor(package)?.scenes.length ?? 0;
    }
    return total == 0 ? StatusBadge.none : StatusBadge.count(total);
  }

  Status _childStatus(String package) {
    if (failureFor(package) case var failure?) return Status.error(failure);
    var scan = scanFor(package);
    if (scan == null) {
      return Status.neutral(isScanning(package) ? 'scanning…' : 'not computed');
    }
    if (scan.groups.isEmpty) {
      return Status.neutral(
        scan.strayScenes == 0
            ? 'no scene groups'
            : '${plural(scan.strayScenes, 'scene file')} in no group',
      );
    }
    return Status.neutral(
      '${plural(scan.scenes.length, 'scene')} · '
      '${plural(scan.groups.length, 'group')}',
    );
  }

  /// The inventory: every group found, by package, with its scenes — the
  /// same listing the panel draws, so `fw` and an agent read what the human
  /// reads.
  PluginView get _view {
    var sections = <ViewNode>[];
    for (var package in packages) {
      var scan = scanFor(package);
      if (scan == null) continue;
      for (var group in scan.groups) {
        var scenes = group.scenes;
        sections.add(
          ViewSection('${package == '.' ? '' : '$package · '}${group.name}', [
            ViewItems([
              for (var scene in scenes.take(_projectedScenes))
                ViewItem(
                  scene.className,
                  detail: p.relative(scene.path, from: host.worktree.path),
                ),
            ], truncated: (scenes.length - _projectedScenes).clamp(0, 1 << 30)),
          ]),
        );
      }
      if (scan.libraries.isNotEmpty) {
        sections.add(
          ViewSection('${package == '.' ? '' : '$package · '}libraries', [
            ViewItems([
              for (var library in scan.libraries)
                ViewItem(
                  library.symbol,
                  detail: p.relative(library.path, from: host.worktree.path),
                ),
            ]),
          ]),
        );
      }
    }
    return PluginView(sections);
  }
}

PluginCore sceneCoreFactory(PluginHost host) => SceneCore(host);
