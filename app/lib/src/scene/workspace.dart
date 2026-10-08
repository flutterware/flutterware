// The workspace: what the editor has open, and how you move through it.
//
// A scene FILE is one document — a scene class and the motions animating it
// (grammar 0.5) — so [SceneFile] holds the parsed pair, the editor state
// over it, and the save door. A [SceneWorkspace] holds the file you opened
// and the stack you drilled into: entering a nested scene switches the whole
// surface and leaves a breadcrumb, because an instance's internals are not
// addressable from its parent (the nesting law).
//
// Pure Dart, like the editor beside it: the fw CLI and a codemod open files
// through the same door the GUI does.
import 'package:flutterware/scene_authoring.dart';

import 'editor.dart';
import 'scene_file.dart';
import 'tokens_library.dart';

/// What the autosave writes: a scene file or a token library, each with a
/// path, a dirty flag and a save door that refuses what it cannot re-read.
abstract interface class SceneSavable {
  String get path;
  bool get isDirty;
  bool matchesDisk(String source);
  List<SceneRefusal> save(void Function(String path, String source) write);
}

/// What the autosave watches: something holding savables that announces
/// when what they owe changes.
///
/// Two of them. A [SceneWorkspace] is the usual one — a scene, the scenes
/// it entered, and the libraries its group lists. A [SceneLibraryDesk] is a
/// library open on its own page with no scene in the editor at all, which
/// is what the index's Libraries row opens; without this the page would
/// have needed a save button, and the studio has none.
abstract interface class SceneSaveSource {
  void addListener(void Function() listener);
  void removeListener(void Function() listener);

  Iterable<SceneSavable> get dirtyFiles;
  bool get anyDirty;

  /// The editor whose revision arms a write, or null. An editor notifies
  /// for a hover as much as for an edit, so the autosave arms on its
  /// revision rather than on the notification; a library notifies only when
  /// it changes, so it needs none.
  SceneEditor? get saveEditor;
}

/// One library, open by itself. Everything the autosave asks of a
/// workspace, answered by one document.
class SceneLibraryDesk extends SceneListenable implements SceneSaveSource {
  SceneLibraryDesk(this.library) {
    library.addListener(notifyListeners);
  }

  final TokensLibrary library;

  @override
  Iterable<SceneSavable> get dirtyFiles =>
      library.isDirty ? [library] : const [];

  @override
  bool get anyDirty => library.isDirty;

  @override
  SceneEditor? get saveEditor => null;

  void dispose() => library.removeListener(notifyListeners);
}

/// One open file: the pair, its editor, and where it came from.
class SceneFile implements SceneSavable {
  SceneFile({
    required this.path,
    required this.className,
    required SceneDocument scene,
    Map<String, MotionDocument> motions = const {},
    List<String> imports = const [],
    String? source,
  }) : editor = SceneEditor(scene, motions: motions),
       imports = [...imports],
       _disk = source;

  /// Read a file through the parse door. Refusals are the collecting kind,
  /// so a rejected file yields no document and every reason is listed.
  static SceneFileOpen open(
    String path,
    String source, {
    Map<String, Set<String>> declaredArgs = const {},
    List<SceneTokenDecl> tokens = const [],
  }) {
    var parsed = parseSceneFile(
      source,
      declaredArgs: declaredArgs,
      tokens: tokens,
    );
    if (!parsed.ok) return SceneFileOpen._(null, parsed.refusals);
    return SceneFileOpen._(
      SceneFile(
        path: path,
        className: parsed.className!,
        scene: parsed.doc!,
        motions: parsed.motions,
        imports: parsed.imports,
        source: source,
      ),
      const [],
    );
  }

  /// Where it lives — the identity a workspace dedupes on.
  @override
  final String path;

  /// The scene class, which is also the file's name in the UI. Follows the
  /// file when a version written elsewhere renamed it.
  String className;

  /// The file's own imports, verbatim — everything but the authoring one.
  /// Kept because the tool rewrites the whole file and cannot invent them:
  /// an Ext names an app widget, and only the author knows where it lives.
  final List<String> imports;

  /// The bytes this file last had on disk, as read or as written.
  ///
  /// What an external change is compared against, so our own write does not
  /// come back looking like somebody else's edit, and what a save compares
  /// against so it writes nothing when there is nothing to change.
  String? _disk;

  /// Whether [source] is the text this file last read or wrote.
  @override
  bool matchesDisk(String source) => source == _disk;

  final SceneEditor editor;

  SceneDocument get scene => editor.doc;
  Map<String, MotionDocument> get motions => editor.motions;

  var _savedRevision = 0;

  /// Whether the file differs from what was last written. Counted off the
  /// editor's revision, so undoing back to the saved state still reads
  /// dirty — the safe direction to be wrong in.
  @override
  bool get isDirty => editor.revision != _savedRevision;

  /// The text to write. Emitting through the door and parsing the result
  /// back is the caller's job — [save] does it.
  String emit() => emitSceneFile(
    scene,
    className: className,
    motions: motions,
    imports: imports,
  );

  /// Emit, refuse to write anything the parser would reject, and hand the
  /// text to [write]. Returns the refusals — empty on success.
  @override
  List<SceneRefusal> save(void Function(String path, String source) write) {
    var source = emit();
    // The check parses against the tokens the document was read with: the
    // emitted file spells `tokens.brand`, and only that list says what it
    // names.
    var check = parseSceneFile(source, tokens: scene.tokens);
    if (!check.ok) return check.refusals;
    // Nothing to write when the bytes are already there. This is what keeps
    // an editor that saves by itself out of your diff: opening a canonical
    // file costs nothing, and undoing back to where you started leaves the
    // file alone and reads clean again.
    if (source != _disk) {
      write(path, source);
      _disk = source;
    }
    _savedRevision = editor.revision;
    return const [];
  }

  /// Takes the version [source] on disk, as one undoable step.
  ///
  /// Undoable is the whole point: a change that arrives while you are working
  /// — an agent finishing a file, a branch switching under you — can be taken
  /// without anyone having to answer a dialog about whose version wins,
  /// because yours is one undo away afterwards.
  List<SceneRefusal> adopt(
    String source, {
    Map<String, Set<String>> declaredArgs = const {},
    List<SceneTokenDecl> tokens = const [],
  }) {
    var parsed = parseSceneFile(
      source,
      declaredArgs: declaredArgs,
      tokens: tokens,
    );
    if (!parsed.ok) return parsed.refusals;
    className = parsed.className!;
    imports
      ..clear()
      ..addAll(parsed.imports);
    editor.adopt(parsed.doc!, parsed.motions);
    _disk = source;
    _savedRevision = editor.revision;
    return const [];
  }
}

/// The result of opening a file: the document, or why there is none.
class SceneFileOpen {
  SceneFileOpen._(this.file, this.refusals);

  final SceneFile? file;
  final List<SceneRefusal> refusals;

  bool get ok => file != null;
}

/// One step of the breadcrumb: a file, and the node in its parent that
/// stands for it (null for the file you opened).
class SceneCrumb {
  SceneCrumb(this.file, this.viaNode);

  final SceneFile file;

  /// The nested node's name in the parent — what the breadcrumb labels the
  /// step with, and what an exit selects on the way back.
  final String? viaNode;
}

/// Resolves the file a nested node stands for. Nesting is not in the grammar
/// yet (milestone 6), so the workspace takes this as a hook: the plugin will
/// pass one that finds the pair by scene class, and a test passes a fake.
typedef NestedSceneResolver = SceneFile? Function(SceneNode node);

class SceneWorkspace extends SceneListenable implements SceneSaveSource {
  SceneWorkspace(
    SceneFile root, {
    this.resolveNested,
    List<TokensLibrary> libraries = const [],
    this.tokensFor,
  }) : _stack = [SceneCrumb(root, null)],
       _opened = {root.path: root},
       libraries = [...libraries] {
    for (var library in this.libraries) {
      library.addListener(_onLibrary);
    }
    resolveInstances(root);
  }

  final List<SceneCrumb> _stack;

  /// The token libraries the open file's group lists — shared documents,
  /// held by whoever opened them and listened to here: an edit in one
  /// moves every reader in every open file.
  final List<TokensLibrary> libraries;

  /// The group's whole vocabulary as it is now — the libraries' tokens,
  /// then the exports — which is what every open document is retokenized
  /// with. Given the live list, so a library added later counts. Null when
  /// the workspace was built without libraries.
  final List<SceneTokenDecl> Function(List<TokensLibrary> libraries)? tokensFor;

  /// Lists one more library — created from here — and retokenizes.
  void addLibrary(TokensLibrary library) {
    if (libraryAt(library.path) != null) return;
    libraries.add(library);
    library.addListener(_onLibrary);
    _onLibrary();
  }

  void _onLibrary() {
    var tokens = tokensFor?.call(libraries);
    if (tokens == null) return;
    for (var file in _opened.values) {
      file.editor.retokenize(tokens);
    }
    // A nested instance carries its own copy of the child's document.
    resolveInstances(active);
    notifyListeners();
  }

  /// A library the open file's group lists, by path.
  TokensLibrary? libraryAt(String path) {
    for (var library in libraries) {
      if (library.path == path) return library;
    }
    return null;
  }

  /// The library declaring [token], or null for an export or a stranger.
  TokensLibrary? libraryOf(String token) {
    for (var library in libraries) {
      if (library.named(token) != null) return library;
    }
    return null;
  }

  /// Every token name the group already uses, for a library refusing a
  /// duplicate.
  Set<String> get tokenNames => {
    for (var t in tokensFor?.call(libraries) ?? editor.doc.tokens) t.name,
  };

  void dispose() {
    for (var library in libraries) {
      library.removeListener(_onLibrary);
    }
  }

  /// Every file this workspace has opened, by path — NOT just the ones on
  /// the breadcrumb. Leaving a nested scene must not lose sight of edits
  /// made inside it; they are unsaved work either way.
  final Map<String, SceneFile> _opened;

  final NestedSceneResolver? resolveNested;

  /// The breadcrumb, outermost first — the file you opened, then every
  /// nested scene entered since.
  List<SceneCrumb> get crumbs => List.unmodifiable(_stack);

  /// The file being edited: the deepest crumb. Everything on screen —
  /// canvas, tree, inspector, timeline — reads this one.
  SceneFile get active => _stack.last.file;

  SceneEditor get editor => active.editor;

  bool get isNested => _stack.length > 1;

  /// Every file this workspace has opened, in the order it opened them.
  Iterable<SceneFile> get openFiles => _opened.values;

  /// The files with unsaved work — what a save-all button writes and what an
  /// exit guard warns about. Includes nested scenes already left behind,
  /// and the libraries edited from here.
  @override
  Iterable<SceneSavable> get dirtyFiles => [
    ..._opened.values.where((f) => f.isDirty),
    ...libraries.where((l) => l.isDirty),
  ];

  @override
  bool get anyDirty => dirtyFiles.isNotEmpty;

  @override
  SceneEditor? get saveEditor => editor;

  /// The file a node stands for, through the resolver — and if that file is
  /// already open here, the open one, so edits made inside it are what the
  /// parent draws and what a second visit finds.
  SceneFile? _fileFor(SceneNode node) {
    var file = resolveNested?.call(node);
    if (file == null) return null;
    return _opened.putIfAbsent(file.path, () => file);
  }

  /// Instantiates every nested scene [file] references, from the files as
  /// they are now. Called on open, and again on the way back out of a nested
  /// scene, because that is when the child may have changed.
  void resolveInstances(SceneFile file) {
    if (resolveNested == null) return;
    var parent = file.scene;
    for (var (node, _) in parent.walk()) {
      if (node is! SceneRefNode) continue;
      var child = _fileFor(node);
      node.instance = child == null
          ? null
          : instantiateScene(child.scene, node.args);
      // A child that takes a set receives the parent's, threaded here and
      // never by the author: the parent grows a formal on its next save if
      // it had none, and the child's formal name is what the file spells.
      node.tokensArg = child?.scene.tokensFormal;
    }
  }

  /// Drills into the scene [node] stands for. The surface switches to that
  /// file; a crumb remembers the way back.
  void enter(SceneNode node) {
    if (resolveNested == null) {
      throw StateError(
        'this workspace cannot enter nested scenes: it was built without a '
        'resolver, so nothing can say which file "${node.name}" stands for',
      );
    }
    var file = _fileFor(node);
    if (file == null) {
      throw ArgumentError(
        '"${node.name}" is not a nested scene: only a node standing for '
        'another scene file can be entered',
      );
    }
    _stack.add(SceneCrumb(file, node.name));
    resolveInstances(file);
    notifyListeners();
  }

  /// Back one level; the node entered through is selected on the way out,
  /// and its instance redrawn from the child as it is now.
  void exit() {
    if (_stack.length < 2) return;
    var leaving = _stack.removeLast();
    resolveInstances(active);
    var via = leaving.viaNode;
    if (via != null) {
      var node = active.scene.nodeNamed(via);
      if (node != null) editor.select(node);
    }
    notifyListeners();
  }

  /// Back to crumb [index]; the last crumb is where you already are.
  void goTo(int index) {
    if (index < 0 || index >= _stack.length - 1) return;
    _stack.removeRange(index + 1, _stack.length);
    resolveInstances(active);
    notifyListeners();
  }
}
