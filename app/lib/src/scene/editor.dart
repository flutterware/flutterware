// The editor-state layer between the document and the widgets — the
// foundation milestone 2 of the graduation plan builds everything else on.
// The document stays pure domain; everything about *editing* it lives here:
// selection in two domains (node NAMES on the scene, key REFS on the
// timeline — both survive undo, because a name and a key id outlive the
// objects a restore touches), hover, and the command door every mutation
// passes through, which is what makes the undo stack a journal instead of
// a wish. Scene and motions are one document here: one journal, one undo.
//
// Pure Dart on purpose: a codemod or the fw CLI can drive the same doors
// the GUI does, and the purity wall (test/scene_pure_test.dart) holds it.
import 'package:flutterware/scene_authoring.dart';

/// One undo journal entry: what the file looked like before the door ran,
/// and the label the UI shows. Both planes ride together — a timeline edit
/// and a layout edit undo through the same journal, because they are one
/// document.
class _JournalEntry {
  _JournalEntry(
    this.label,
    this.scene,
    this.motions,
    this.motionClasses,
    this.mergeKey,
  );

  final String label;
  final SceneSnapshot scene;
  final Map<String, MotionSnapshot> motions;

  /// Which scene class each motion animates, so a motion undone out of
  /// existence can be redone into it.
  final Map<String, String> motionClasses;
  final String? mergeKey;
}

/// Where a key lives: which motion, which group, which track. The key
/// itself is held by [MotionKey.id], which survives sorting and undo.
class MotionKeyRef {
  const MotionKeyRef(this.motion, this.group, this.prop, this.keyId);

  final String motion;
  final String group;

  /// The track's property — an arg track is spelled `args.<name>`, the way
  /// the fx plane spells it.
  final String prop;

  final int keyId;

  @override
  bool operator ==(Object other) =>
      other is MotionKeyRef &&
      other.motion == motion &&
      other.group == group &&
      other.prop == prop &&
      other.keyId == keyId;

  @override
  int get hashCode => Object.hash(motion, group, prop, keyId);

  @override
  String toString() => '$motion.$group.$prop#$keyId';
}

/// What a press on the canvas does: pick, or draw one of the node kinds.
/// Drawing returns to [select] once the node exists.
/// The canvas tools. The drawing ones draw a box and place a node in it;
/// [orbit] draws nothing — it turns the camera of the 3D window under the
/// pointer, since a plain drag on the canvas moves a node.
enum SceneTool { select, frame, text, shape, view3d, orbit }

/// A thing the file declares that is not a node — a parameter, a motion —
/// named by the tree's outline and OPEN in the drawer under the canvas: a
/// motion as its timeline, a parameter as its pane or its table. One at a
/// time, and independent of the node selection: the drawer stays put while
/// nodes are clicked on the canvas, which is how a timeline gets its keys
/// and how a parameter is bound to them.
sealed class SceneAside {
  const SceneAside(this.name);

  final String name;

  @override
  bool operator ==(Object other) =>
      other is SceneAside &&
      other.runtimeType == runtimeType &&
      other.name == name;

  @override
  int get hashCode => Object.hash(runtimeType, name);
}

/// A parameter of the scene, by name.
class ParamAside extends SceneAside {
  const ParamAside(super.name);
}

/// A motion of the file, by name.
class MotionAside extends SceneAside {
  const MotionAside(super.name);
}

/// Where a clip block lives, held by [MotionClip.id] the way a key is.
class MotionClipRef {
  const MotionClipRef(this.motion, this.group, this.prop, this.clipId);

  final String motion;
  final String group;
  final String prop;
  final int clipId;

  @override
  bool operator ==(Object other) =>
      other is MotionClipRef &&
      other.motion == motion &&
      other.group == group &&
      other.prop == prop &&
      other.clipId == clipId;

  @override
  int get hashCode => Object.hash(motion, group, prop, clipId);

  @override
  String toString() => '$group.$prop#$clipId';
}

class SceneEditor extends SceneListenable {
  SceneEditor(this.doc, {Map<String, MotionDocument> motions = const {}})
    : motions = {...motions};

  final SceneDocument doc;

  /// The motions of the file, by class name — the same document as the
  /// scene, so they share this editor's selection, doors and journal.
  final Map<String, MotionDocument> motions;

  /// The motion the timeline is open on, or null: the scene is static first,
  /// and a motion is something you open.
  String? get activeMotion =>
      motions.containsKey(_activeMotion) ? _activeMotion : null;
  String? _activeMotion;

  set activeMotion(String? name) {
    if (_activeMotion == name) return;
    _activeMotion = name;
    if (name != null) _openParam = null;
    _drawerCollapsed = false;
    clearKeySelection();
    notifyListeners();
  }

  /// The parameter open in the drawer, or null — a list as its table, any
  /// other kind as its pane. The drawer holds one thing: opening a parameter
  /// closes the motion and the other way round.
  String? get openParam =>
      doc.paramNamed(_openParam ?? '') == null ? null : _openParam;
  String? _openParam;

  set openParam(String? name) {
    if (_openParam == name) return;
    _openParam = name;
    if (name != null) {
      _activeMotion = null;
      clearKeySelection();
    }
    _drawerCollapsed = false;
    notifyListeners();
  }

  /// What the drawer under the canvas is showing — a motion or a parameter
  /// — or null. The outline highlights exactly this row.
  ///
  /// A token is not among them: a library is the package's, and it opens on
  /// its own page rather than under one scene's artboard.
  SceneAside? get drawer => switch ((activeMotion, openParam)) {
    (var m?, _) => MotionAside(m),
    (_, var p?) => ParamAside(p),
    _ => null,
  };

  // ---------------------------------------------------------------------
  // Tokens are declared elsewhere — a library the editor owns, an export
  // the app owns — and this document only reads them. These are the doors
  // through which a change out there reaches the nodes here, and the two
  // moves between a scene's own parameter and the group's shared token.
  // ---------------------------------------------------------------------

  /// Takes a new declaration list — a library edited, a token added or
  /// gone — and moves every reader with it. Not a journal entry: the edit
  /// lives in the library, and is undone there. A value token's readers
  /// take its value; a style's readers take the new value on every property
  /// that was inherited from the old one; a reference to a token that is
  /// gone is dropped, as an edit would drop it.
  void retokenize(List<SceneTokenDecl> next) {
    var old = {for (var t in doc.tokens) t.name: t};
    doc.edit(() {
      doc.tokens
        ..clear()
        ..addAll(next);
      for (var (node, _) in doc.walk()) {
        for (var e in node.bindings.entries.toList()) {
          switch (e.value) {
            case TokenRef(:var name):
              var decl = doc.tokenNamed(name);
              if (decl != null && decl.hasValue && !decl.isStyle) {
                setSceneProperty(node, e.key, decl.value);
              }
            case StyleRef(:var name):
              var was = old[name]?.style;
              var now = doc.tokenNamed(name)?.style;
              if (now == null) continue;
              for (var f in now.values.entries) {
                // A property bound on its own follows its binding.
                if (node.bindings.containsKey(f.key)) continue;
                var current = getSceneProperty(node, f.key);
                // Inherited from the old style, or never set by it: follow.
                if (was == null ||
                    !was.sets(f.key) ||
                    sceneValuesEqual(current, was.values[f.key])) {
                  setSceneProperty(node, f.key, f.value);
                }
              }
            default:
              break;
          }
        }
      }
      reconcileBindings(doc);
    });
    notifyListeners();
  }

  /// Every binding of this document to [from] now reads [to] — a library
  /// renamed a token, and this is one of its readers. Journaled here too:
  /// the file's text changes, and undoing the rename in the library without
  /// undoing it here would leave a name nothing declares.
  void renameTokenRefs(String from, String to) {
    var readers = readersOfToken(from);
    if (readers.isEmpty) return;
    // The library renames after its readers do, so [to] is not declared
    // yet: an alias holds the references through the reconcile, and the
    // library's own notification replaces the whole list a moment later.
    var decl = doc.tokenNamed(from);
    if (decl != null && doc.tokenNamed(to) == null) {
      doc.tokens.add(
        decl.style != null
            ? SceneTokenDecl.style(to, decl.style!)
            : decl.isExport
            ? SceneTokenDecl.export(to, decl.type)
            : SceneTokenDecl(to, decl.kind!, decl.value!),
      );
    }
    perform('Rename token $from', () {
      for (var (node, prop) in readers) {
        node.bindings[prop] = switch (node.bindings[prop]) {
          StyleRef() => StyleRef(to),
          _ => TokenRef(to),
        };
        if (tokenMarkerName(getSceneProperty(node, prop)) == from) {
          setSceneProperty(node, prop, tokenMarker(to));
        }
      }
    });
  }

  /// SHARE: the parameter [name] becomes a token of [library], read by the
  /// group; every reader here follows and the parameter goes. The value is
  /// the parameter's default — the mockup, which is what a token is too.
  /// Refused for a list (a token is not data) and for a name the group
  /// already uses; the library's own journal holds the token, this one the
  /// rebinding, so undoing the move is two undos.
  void shareParam(
    String name,
    void Function(String name, SceneParamKind kind, Object value) declare,
  ) {
    var decl = doc.paramNamed(name);
    if (decl == null) throw ArgumentError('no parameter "$name"');
    if (decl.kind == SceneParamKind.list) {
      throw ArgumentError('"$name" is a list: a token is one value');
    }
    if (doc.tokenNamed(name) != null) {
      throw ArgumentError('the group already has a token "$name"');
    }
    for (var (node, prop) in readersOf(name)) {
      if (prop == 'repeat' || node.bindings[prop] is ItemRef) {
        throw ArgumentError('"$name" feeds a table, which a token cannot do');
      }
    }
    declare(name, decl.kind, decl.defaultValue);
    // The library's listeners have retokenized this document by now; a
    // caller with no workspace has not, and the reference must resolve.
    if (doc.tokenNamed(name) == null) {
      doc.tokens.add(SceneTokenDecl(name, decl.kind, decl.defaultValue));
    }
    // The parameter is gone; the drawer has nothing to show for it. Where
    // the token now lives is the library page, which the tree reaches.
    if (_openParam == name) _openParam = null;
    perform('Share $name', () {
      for (var (node, prop) in readersOf(name)) {
        node.bindings[prop] = TokenRef(name);
      }
      doc.params.removeWhere((p) => p.name == name);
    });
  }

  /// MAKE LOCAL: the token [name] becomes a parameter of this scene, with
  /// the token's value as its default; every reader here follows; the token
  /// stays in its library for the other scenes. Refused for a style
  /// (several properties) and an export (no value here).
  void localizeToken(String name) {
    var decl = doc.tokenNamed(name);
    if (decl == null) throw ArgumentError('no token "$name"');
    if (decl.isStyle) {
      throw ArgumentError('"$name" is a style: a parameter holds one value');
    }
    if (!decl.hasValue) {
      throw ArgumentError(
        '"$name" belongs to the app, so there is no value here',
      );
    }
    if (paramNameProblem(name) case var problem?) {
      throw ArgumentError(problem);
    }
    var kind = decl.kind!;
    var value = decl.value!;
    _openParam = name;
    perform('Make $name local', () {
      doc.params.add(SceneParamDecl(name, kind, value));
      for (var (node, prop) in readersOfToken(name)) {
        node.bindings[prop] = ParamRef(name);
      }
    });
  }

  /// Whether the drawer under the canvas is folded away while its motion
  /// stays open — the header keeps naming it, the motion stays on the
  /// picture. Not journaled: a view state, not a change. Opening anything
  /// unfolds it.
  bool get drawerCollapsed => _drawerCollapsed;
  bool _drawerCollapsed = false;

  set drawerCollapsed(bool value) {
    if (_drawerCollapsed == value) return;
    _drawerCollapsed = value;
    notifyListeners();
  }

  /// A new, empty motion on this scene, named after [sceneClassName] unless
  /// [name] says otherwise, opened as the active one. Its class name is a
  /// Dart identifier in the file, so it is checked as one.
  String addMotion(String sceneClassName, {String? name}) {
    var chosen = name ?? _freeMotionName(sceneClassName);
    if (!isValidNodeName(chosen) || motions.containsKey(chosen)) {
      throw ArgumentError('"$chosen" is not a free motion name');
    }
    perform('New motion $chosen', () {
      motions[chosen] = MotionDocument(sceneClassName: sceneClassName);
    });
    activeMotion = chosen;
    return chosen;
  }

  /// Replaces the whole document, scene and motions, with one read from
  /// somewhere else — the file changed on disk and this editor is taking
  /// that version.
  ///
  /// A journal entry like any other, so the version it replaced is one undo
  /// away. The document object itself is kept and transplanted into, because
  /// the guest, the playbacks and every mounted panel hold it by reference.
  void adopt(
    SceneDocument incoming,
    Map<String, MotionDocument> incomingMotions,
  ) {
    clearKeySelection();
    perform('Reload from disk', () {
      doc.restore(incoming.snapshot());
      motions
        ..clear()
        ..addAll(incomingMotions);
      // The incoming groups hold the INCOMING document's nodes, and what is
      // being drawn is this one, revived in place. Same names, other objects.
      for (var m in motions.values) {
        m.repoint(doc);
      }
    });
    // The motion that was open may not be in the version that arrived, and
    // a playback bound to a name the editor no longer has is a crash rather
    // than an empty timeline.
    if (_activeMotion != null && !motions.containsKey(_activeMotion)) {
      _activeMotion = null;
      notifyListeners();
    }
  }

  void removeMotion(String name) {
    if (!motions.containsKey(name)) return;
    perform('Delete motion $name', () => motions.remove(name));
    if (_activeMotion == name) activeMotion = null;
  }

  /// Renames a motion — the class it is in the file. The active motion
  /// follows; a playback bound under the old name is the owner's to drop.
  void renameMotion(String name, String wanted) {
    wanted = wanted.trim();
    var m = motions[name];
    if (m == null || wanted == name) return;
    if (!isValidNodeName(wanted)) {
      throw ArgumentError(
        '"$wanted" is not a valid name: letters and digits, '
        'starting with a letter',
      );
    }
    if (motions.containsKey(wanted)) {
      throw ArgumentError('"$wanted" is already taken');
    }
    perform('Rename motion $name', () {
      // Rebuilt rather than removed and re-added: the map's order is the
      // strip's order, and a rename must not move the chip.
      var renamed = {
        for (var e in motions.entries)
          (e.key == name ? wanted : e.key): e.value,
      };
      motions
        ..clear()
        ..addAll(renamed);
    });
    if (_activeMotion == name) {
      _activeMotion = wanted;
      notifyListeners();
    }
  }

  /// Renames a group of [motion] — the field it is in the motion class —
  /// and every reference the timeline holds to it, in one edit.
  void renameGroup(String motion, String name, String wanted) {
    wanted = wanted.trim();
    var m = motions[motion];
    var group = m?.groupNamed(name);
    if (m == null || group == null || wanted == name) return;
    if (!isValidNodeName(wanted)) {
      throw ArgumentError(
        '"$wanted" is not a valid name: letters, digits, '
        'starting with a lowercase letter',
      );
    }
    if (m.groupNamed(wanted) != null) {
      throw ArgumentError('"$wanted" is already taken');
    }
    // A key selection names its group; simpler to drop it than to follow.
    clearKeySelection();
    // The arrangement places the group ITSELF, so a rename is one field and
    // nothing to follow — which is the whole point of holding objects.
    perform('Rename $name', () => group.name = wanted);
  }

  String _freeMotionName(String sceneClassName) {
    var base = '${sceneClassName}Motion';
    var candidate = base;
    for (var i = 2; motions.containsKey(candidate); i++) {
      candidate = '$base$i';
    }
    return candidate;
  }

  // -------------------------------------------------------------------------
  // Selection — a set of node names, in selection order.
  // -------------------------------------------------------------------------

  final _selection = <String>{};

  /// Names may outlive their nodes (undo, delete); reads resolve against
  /// the live document and silently drop the dead.
  Iterable<SceneNode> get selectedNodes =>
      _selection.map(doc.nodeNamed).whereType<SceneNode>();

  Iterable<String> get selectionNames =>
      selectedNodes.map((n) => n.name).toList();

  bool isSelected(SceneNode node) => _selection.contains(node.name);

  /// The node the inspector shows: the most recently selected live one.
  SceneNode? get primary {
    SceneNode? last;
    for (var node in selectedNodes) {
      last = node;
    }
    return last;
  }

  /// Exactly one live node selected, or null — what a resize handle needs.
  SceneNode? get single {
    var nodes = selectedNodes.toList();
    return nodes.length == 1 ? nodes.first : null;
  }

  /// Replace the selection ([toggle] false) or flip [node]'s membership.
  /// The root is the artboard, not a selectable node.
  void select(SceneNode? node, {bool toggle = false}) {
    if (node == null || node == doc.root) {
      if (toggle) return;
      clearSelection();
      return;
    }
    if (toggle) {
      if (!_selection.remove(node.name)) _selection.add(node.name);
    } else {
      _selection
        ..clear()
        ..add(node.name);
    }
    _keySelection.clear();
    _selectedClip = null;
    notifyListeners();
  }

  /// Marquee: the selection becomes the top-level nodes whose measured
  /// rect overlaps [rect] — geometry policy here, the gesture in the
  /// widget.
  void selectWithin(SceneRect rect) {
    setSelection([
      for (var node in doc.root.children)
        if (node.measured case var m? when m.overlaps(rect)) node.name,
    ]);
  }

  void setSelection(Iterable<String> names) {
    _selection
      ..clear()
      ..addAll(names);
    if (_selection.isNotEmpty) {
      _keySelection.clear();
      _selectedClip = null;
    }
    notifyListeners();
  }

  void clearSelection() {
    if (_selection.isEmpty) return;
    _selection.clear();
    notifyListeners();
  }

  /// Recording: while on, an edit made with a motion open becomes a key on
  /// that property at the playhead instead of a change to the node's own
  /// value — what "set the playhead, move things" means in every animation
  /// tool. Not journaled: a mode, not a change.
  bool get autoKey => _autoKey;
  bool _autoKey = false;

  set autoKey(bool value) {
    if (_autoKey == value) return;
    _autoKey = value;
    notifyListeners();
  }

  /// Where the open motion's playhead is, as the playback last reported it.
  /// Not a change of the editor: it moves sixty times a second while
  /// playing, and nothing rebuilds on it. What must follow it — a guest
  /// whose document a shader draws by the clock — listens to [playheadClock].
  Duration get playhead => playheadClock.value;
  set playhead(Duration value) => playheadClock.value = value;

  final playheadClock = SceneValue(Duration.zero);

  /// With no motion open the playhead is at zero, so a document drawn by the
  /// clock shows its authored moment rather than wherever playback left off.
  /// Closing by the chevron stops the playback, which zeroes it already; a
  /// motion deleted, reloaded away, undone out of the file or displaced by a
  /// parameter leaves with nothing stopping it, and every one of those
  /// notifies here.
  @override
  void notifyListeners() {
    if (activeMotion == null) playhead = Duration.zero;
    super.notifyListeners();
  }

  /// Whether an edit to [prop] of [node] would record a key right now.
  bool records(SceneNode node, String prop) =>
      autoKey && activeMotion != null && propSpecFor(node, prop) != null;

  /// What [prop] of [node] is worth at the playhead while recording: the
  /// key already there, if one is, else what the motion shows. The key
  /// first, because a drag records one on every sample and the picture
  /// catches up only when the motion is applied again.
  Object _recorded(SceneNode node, String prop) {
    var motion = activeMotion;
    if (motion != null) {
      for (var group in groupsTargeting(motion, node)) {
        var at =
            playhead -
            (motions[motion]!.placements[group.name] ?? Duration.zero);
        var track = trackOf(motion, group.name, prop);
        if (track == null) continue;
        for (var key in track.keys) {
          if ((key.at - at).inMilliseconds.abs() < 1) return key.value;
        }
      }
    }
    return node.fxRendered(prop);
  }

  /// Records [value] as a key on [prop] of [node] at the playhead, in the
  /// node's first group of the open motion — made and placed at zero when
  /// it has none. False when recording does not apply, so the caller edits
  /// the node's value instead.
  bool recordKey(
    SceneNode node,
    String prop,
    Object value, {
    String? mergeKey,
  }) {
    if (!records(node, prop)) return false;
    var motion = activeMotion!;
    var group =
        groupsTargeting(motion, node).firstOrNull ?? addGroup(motion, node);
    var at =
        playhead - (motions[motion]!.placements[group.name] ?? Duration.zero);
    addKey(
      motion,
      group.name,
      prop,
      at < Duration.zero ? Duration.zero : at,
      value: value,
      mergeKey: mergeKey,
      select: false,
    );
    return true;
  }

  /// The canvas tool. Not journaled: choosing a tool changes nothing in the
  /// document.
  SceneTool get tool => _tool;
  SceneTool _tool = SceneTool.select;

  set tool(SceneTool value) {
    if (_tool == value) return;
    _tool = value;
    notifyListeners();
  }

  /// The deepest frame whose measured box holds [point] (artboard space),
  /// the root when none does — where a node drawn at [point] belongs.
  FrameNode frameAt(double x, double y) {
    var best = doc.root;
    for (var (node, _) in doc.walk()) {
      if (node is! FrameNode || node == doc.root) continue;
      var rect = node.measured;
      if (rect == null) continue;
      if (x < rect.left || x > rect.right || y < rect.top || y > rect.bottom) {
        continue;
      }
      // Deeper wins: the walk is pre-order, so a child comes after its
      // parent and replaces it.
      best = node;
    }
    return best;
  }

  // ---------------------------------------------------------------------
  // Parameters
  //
  // A parameter is a typed hole in the scene's constructor whose default is
  // the mockup. These are the doors that declare, rename, retype and delete
  // one, set its mockup, and connect a node's property to it. Every one is
  // journaled through [perform] like any other edit, and every one refuses
  // rather than guessing — the file has to compile afterwards.
  // ---------------------------------------------------------------------

  /// Why [wanted] cannot be a parameter's name, or null when it can. Nodes
  /// and parameters share the class namespace, so a node's name is taken.
  String? paramNameProblem(String wanted, {String? renaming}) {
    if (!isValidNodeName(wanted)) {
      return '"$wanted" is not a valid name. A name is a Dart identifier: '
          'letters, digits and underscores, not starting with a digit';
    }
    if (wanted == renaming) return null;
    if (doc.nodeNamed(wanted) != null ||
        doc.params.any((p) => p.name == wanted)) {
      return '"$wanted" is already taken';
    }
    return null;
  }

  /// A free parameter name off [base]: `title`, `title2`, `title3`… A
  /// property key that is not itself a name — `args.label` — contributes
  /// its last segment.
  String freeParamName(String base) {
    base = base.split('.').last;
    if (!isValidNodeName(base)) base = 'value';
    if (paramNameProblem(base) == null) return base;
    for (var i = 2; ; i++) {
      if (paramNameProblem('$base$i') == null) return '$base$i';
    }
  }

  /// The properties reading [param], as (node, property) pairs — what a
  /// delete has to name, and what a rename has to follow.
  List<(SceneNode, String)> readersOf(String param) => [
    for (var (n, _) in doc.walk())
      for (var e in n.bindings.entries)
        if (switch (e.value) {
          ParamRef(:var name) => name == param,
          ItemRef(:var list) => list == param,
          TokenRef() || StyleRef() => false,
        })
          (n, e.key),
    for (var (n, _) in doc.walk())
      if (n is FrameNode && n.repeated?.source == param) (n, 'repeat'),
  ];

  /// Declares a parameter. With no [defaultValue] the mockup is the kind's
  /// zero — an empty string, 0, black, no items.
  void addParam(String name, SceneParamKind kind, {Object? defaultValue}) {
    if (paramNameProblem(name) case var problem?) {
      throw ArgumentError(problem);
    }
    var value = defaultValue ?? zeroOf(kind);
    perform('Add parameter $name', () {
      doc.params.add(SceneParamDecl(name, kind, value));
    });
  }

  /// Renames a parameter; every binding and repeat reading it follows, so
  /// the file still compiles.
  void renameParam(String name, String wanted) {
    wanted = wanted.trim();
    if (wanted == name) return;
    var i = doc.params.indexWhere((p) => p.name == name);
    if (i < 0) throw ArgumentError('no parameter "$name"');
    if (paramNameProblem(wanted) case var problem?) {
      throw ArgumentError(problem);
    }
    if (_openParam == name) _openParam = wanted;
    perform('Rename parameter $name', () {
      var decl = doc.params[i];
      doc.params[i] = SceneParamDecl(wanted, decl.kind, decl.defaultValue);
      for (var (n, _) in doc.walk()) {
        for (var e in n.bindings.entries.toList()) {
          n.bindings[e.key] = switch (e.value) {
            ParamRef(name: var p) when p == name => ParamRef(wanted),
            ItemRef(:var list, :var field) when list == name => ItemRef(
              wanted,
              field,
            ),
            var other => other,
          };
        }
        if (n is FrameNode && n.repeated?.source == name) {
          recordRepeat(n, wanted);
        }
      }
      bindRepeats(doc);
    });
  }

  /// Sets a parameter's mockup. Every property reading it takes the value —
  /// the other direction of [reconcileBindings], which moves the default
  /// when a reader moves.
  void setParamDefault(String name, Object value, {String? mergeKey}) {
    var i = doc.params.indexWhere((p) => p.name == name);
    if (i < 0) throw ArgumentError('no parameter "$name"');
    var decl = doc.params[i];
    if (!_holds(decl.kind, value)) {
      throw ArgumentError(
        '"$name" is a ${decl.typeName} parameter: '
        'a ${value.runtimeType} is not one',
      );
    }
    perform('Edit parameter $name', mergeKey: mergeKey, () {
      doc.params[i] = decl.withDefault(value);
      if (decl.kind == SceneParamKind.list) {
        bindRepeats(doc);
        return;
      }
      for (var (n, _) in doc.walk()) {
        for (var e in n.bindings.entries) {
          if (e.value case ParamRef(name: var p) when p == name) {
            setSceneProperty(n, e.key, value);
          }
        }
      }
    });
  }

  /// Changes a parameter's kind. Refused while anything reads it: a text
  /// cannot start reading a colour, and choosing which reader to drop is
  /// not this door's call.
  void retypeParam(String name, SceneParamKind kind) {
    var i = doc.params.indexWhere((p) => p.name == name);
    if (i < 0) throw ArgumentError('no parameter "$name"');
    if (doc.params[i].kind == kind) return;
    var readers = readersOf(name);
    if (readers.isNotEmpty) {
      throw ArgumentError(
        '"$name" is read by ${_readerList(readers)}: unbind them first',
      );
    }
    perform('Retype parameter $name', () {
      doc.params[i] = SceneParamDecl(name, kind, zeroOf(kind));
    });
  }

  /// Deletes a parameter. Refused while anything reads it, naming the
  /// readers, so nothing is silently unbound.
  void deleteParam(String name) {
    var i = doc.params.indexWhere((p) => p.name == name);
    if (i < 0) throw ArgumentError('no parameter "$name"');
    var readers = readersOf(name);
    if (readers.isNotEmpty) {
      throw ArgumentError(
        '"$name" is read by ${_readerList(readers)}: unbind them first',
      );
    }
    perform('Delete parameter $name', () => doc.params.removeAt(i));
  }

  /// Moves a parameter in the declaration order — the order of the
  /// constructor's formals, and of the panel.
  void moveParam(String name, int to) {
    var i = doc.params.indexWhere((p) => p.name == name);
    if (i < 0) throw ArgumentError('no parameter "$name"');
    to = to.clamp(0, doc.params.length - 1);
    if (to == i) return;
    perform('Move parameter $name', () {
      var decl = doc.params.removeAt(i);
      doc.params.insert(to, decl);
    });
  }

  /// Connects [prop] of [node] to the parameter [param]. The property takes
  /// the parameter's default — the binding is the stronger of the two.
  void bind(SceneNode node, String prop, String param) {
    var decl = doc.paramNamed(param);
    if (decl == null) throw ArgumentError('no parameter "$param"');
    var kind = bindableKind(node, prop);
    if (kind == null) {
      throw ArgumentError('"$prop" cannot read a parameter');
    }
    if (decl.kind != kind) {
      throw ArgumentError(
        '"$param" is a ${decl.typeName} parameter: "$prop" takes a '
        '${SceneParamDecl(param, kind, zeroOf(kind)).typeName}',
      );
    }
    perform('Bind $prop to $param', () {
      node.bindings[prop] = ParamRef(param);
      setSceneProperty(node, prop, decl.defaultValue);
    });
  }

  /// Connects [prop] of [node] to the package's token [token]. The property
  /// takes the token's value. Unlike a parameter, a token is not moved by a
  /// later edit — the property detaches instead ([reconcileBindings]),
  /// because the declaration is the app's own file.
  ///
  /// An OPAQUE token — the app's own object — can only fill an external
  /// widget's argument; the property carries the token's name for the guest
  /// to resolve. Whether the widget's argument is of that type is the
  /// declaration's to say, and the compiler's: this door checks the shape.
  void bindToken(SceneNode node, String prop, String token) {
    var decl = doc.tokenNamed(token);
    if (decl == null) throw ArgumentError('no token "$token"');
    if (decl.isStyle) {
      throw ArgumentError(
        '"$token" is a text style: apply it to a text, not to a property',
      );
    }
    // An export on an external widget's argument: the argument carries the
    // NAME, whatever the export's type, and the widget takes the object.
    if (decl.isExport && node is ExternalNode && sceneArgName(prop) != null) {
      perform('Bind $prop to tokens.$token', () {
        node.bindings[prop] = TokenRef(token);
        setSceneProperty(node, prop, tokenMarker(token));
      });
      return;
    }
    if (decl.isOpaque) {
      if (node is! ExternalNode || sceneArgName(prop) == null) {
        throw ArgumentError(
          '"$token" is a ${decl.typeName}: the app\'s own object, which '
          "only an external widget's argument can take",
        );
      }
      perform('Bind $prop to tokens.$token', () {
        node.bindings[prop] = TokenRef(token);
        setSceneProperty(node, prop, tokenMarker(token));
      });
      return;
    }
    var kind = bindableKind(node, prop);
    if (kind == null) {
      throw ArgumentError('"$prop" cannot read a token');
    }
    if (decl.kind != kind) {
      throw ArgumentError(
        '"$token" is a ${decl.typeName} token: "$prop" takes a '
        '${SceneTokenDecl(token, kind, '').typeName}',
      );
    }
    perform('Bind $prop to tokens.$token', () {
      node.bindings[prop] = TokenRef(token);
      // An export has no value here: the property keeps what it shows and
      // the guest draws the app's own over it.
      if (decl.hasValue) {
        setSceneProperty(node, prop, decl.value);
      }
    });
  }

  /// The properties reading [token], as (node, property) pairs — a style's
  /// readers under [styleBindingKey].
  List<(SceneNode, String)> readersOfToken(String token) => [
    for (var (n, _) in doc.walk())
      for (var e in n.bindings.entries)
        if (switch (e.value) {
          TokenRef(:var name) || StyleRef(:var name) => name == token,
          _ => false,
        })
          (n, e.key),
  ];

  /// Gives [node] the shared text style [token]: every property the style
  /// sets takes its value, and stays the node's to override afterwards.
  void applyStyle(SceneNode node, String token) {
    var decl = doc.tokenNamed(token);
    if (decl == null) throw ArgumentError('no token "$token"');
    if (!decl.isStyle) {
      throw ArgumentError('"$token" is a ${decl.typeName}, not a text style');
    }
    if (node is! TextNode) {
      throw ArgumentError(
        '"${node.name}" is not a text, and only a text takes a style',
      );
    }
    var style = decl.style;
    perform('Apply style $token', () {
      node.bindings[styleBindingKey] = StyleRef(token);
      // An export's style is the app's: the guest lays it under the values
      // here, and nothing is written into them.
      if (style != null) writeStyle(node, style);
    });
  }

  /// Takes the style off [node]; every value stays where it is.
  void detachStyle(SceneNode node) => unbind(node, styleBindingKey);

  /// Puts the style's own value back on [prop] — the end of an override.
  void resetToStyle(SceneNode node, String prop) {
    var style = styleOf(doc, node);
    if (style == null || !style.sets(prop)) return;
    perform('Reset $prop to style', () {
      setSceneProperty(node, prop, style.values[prop]);
    });
  }

  /// Declares a parameter whose default is what [prop] of [node] holds now,
  /// and binds the property to it — one edit, one undo entry. Returns the
  /// name it took.
  String promote(SceneNode node, String prop, {String? name}) {
    var kind = bindableKind(node, prop);
    if (kind == null) {
      throw ArgumentError('"$prop" cannot become a parameter');
    }
    var value = getSceneProperty(node, prop);
    if (value == null || !_holds(kind, value)) {
      throw ArgumentError('"$prop" holds nothing a parameter can carry');
    }
    var chosen = name?.trim() ?? freeParamName(prop);
    if (paramNameProblem(chosen) case var problem?) {
      throw ArgumentError(problem);
    }
    perform('Make parameter $chosen', () {
      doc.params.add(SceneParamDecl(chosen, kind, value));
      node.bindings[prop] = ParamRef(chosen);
      // A nested argument at its child's default is not written anywhere
      // yet; bound, it has to be, so the file can spell the reference.
      setSceneProperty(node, prop, value);
    });
    return chosen;
  }

  /// Disconnects [prop] of [node]; the value stays where it is. An opaque
  /// token's argument has no value of its own to keep, so it is cleared.
  void unbind(SceneNode node, String prop) {
    if (!node.bindings.containsKey(prop)) return;
    perform('Unbind $prop', () {
      node.bindings.remove(prop);
      if (tokenMarkerName(getSceneProperty(node, prop)) != null) {
        setSceneProperty(node, prop, null);
      }
    });
  }

  static String _readerList(List<(SceneNode, String)> readers) =>
      readers.map((r) => '${r.$1.name}.${r.$2}').join(', ');

  static bool _holds(SceneParamKind kind, Object value) => switch (kind) {
    SceneParamKind.string => value is String,
    SceneParamKind.number => value is double,
    SceneParamKind.color => value is SceneColor,
    SceneParamKind.bool => value is bool,
    SceneParamKind.list => value is List,
  };

  /// The kind's zero — the mockup a fresh parameter starts with.
  static Object zeroOf(SceneParamKind kind) => switch (kind) {
    SceneParamKind.string => '',
    SceneParamKind.number => 0.0,
    SceneParamKind.color => const SceneColor(0xFF000000),
    SceneParamKind.bool => false,
    SceneParamKind.list => const <SceneItem>[],
  };

  /// Shows or hides every selected node — one entry, whatever the count.
  void setVisible(bool visible) {
    var nodes = selectedNodes.where((n) => n != doc.root).toList();
    if (nodes.isEmpty) return;
    var what = nodes.length == 1 ? nodes.single.name : '${nodes.length} nodes';
    perform(visible ? 'Show $what' : 'Hide $what', () {
      for (var n in nodes) {
        n.visible = visible;
      }
    });
  }

  /// Renames [node]. A name is a Dart identifier and the field name in the
  /// file, so it must be free among the scene's nodes and parameters; every
  /// group animating the node follows. Refuses rather than guessing.
  void rename(SceneNode node, String name) {
    var wanted = name.trim();
    if (wanted == node.name) return;
    if (!isValidNodeName(wanted)) {
      throw ArgumentError(
        '"$wanted" is not a valid name: letters, digits, '
        'starting with a lowercase letter',
      );
    }
    if (doc.nodeNamed(wanted) != null ||
        doc.params.any((p) => p.name == wanted)) {
      throw ArgumentError('"$wanted" is already taken');
    }
    var was = node.name;
    var selected = isSelected(node);
    perform('Rename $was', () {
      // Nothing else to re-point: a group holds the node, not its name.
      node.name = wanted;
    });
    if (selected) {
      _selection
        ..remove(was)
        ..add(wanted);
      notifyListeners();
    }
  }

  /// Whether [node] may go into [into]: not the root, not into itself or a
  /// descendant of itself.
  bool canReparent(SceneNode node, FrameNode into) {
    if (node == doc.root) return false;
    for (SceneNode? p = into; p != null; p = doc.parentOf(p)) {
      if (p == node) return false;
    }
    return true;
  }

  /// Moves [nodes] into [into], at [index] (appended when null). Under a
  /// free-layout parent the node keeps its place on the canvas — its
  /// position is re-expressed against the new parent's measured box; under a
  /// row or a column its position is its order.
  void reparent(Iterable<SceneNode> nodes, FrameNode into, {int? index}) {
    var moving = [
      for (var (n, _) in doc.walk())
        if (nodes.contains(n) && canReparent(n, into)) n,
    ];
    if (moving.isEmpty) return;
    perform(
      moving.length == 1
          ? 'Move ${moving.single.name}'
          : 'Move ${moving.length} nodes',
      () {
        var at = index ?? into.children.length;
        for (var node in moving) {
          var parent = doc.parentOf(node)!;
          var from = parent.children.indexOf(node);
          parent.children.removeAt(from);
          if (parent == into && from < at) at--;
          if (into.layout == NodeLayout.absolute) {
            var was = node.measured;
            var origin = into.measured;
            if (was != null && origin != null) {
              node
                ..x = _half(was.left - origin.left)
                ..y = _half(was.top - origin.top);
            }
          } else {
            node
              ..x = 0
              ..y = 0;
          }
          into.children.insert(at.clamp(0, into.children.length), node);
          at++;
        }
      },
    );
  }

  /// Puts [node] where it was drawn: under the frame at that point, at a
  /// position relative to it when the frame lays out freely, appended when
  /// the frame is a row or a column (position is order there). Selected
  /// afterwards, and the tool goes back to select.
  void insertNode(SceneNode node, {required double x, required double y}) {
    var parent = frameAt(x, y);
    if (parent.layout == NodeLayout.absolute) {
      var origin = parent.measured;
      node
        ..x = _half(x - (origin?.left ?? 0))
        ..y = _half(y - (origin?.top ?? 0));
    }
    perform('Add ${node.name}', () => parent.children.add(node));
    select(node);
    tool = SceneTool.select;
  }

  /// Puts [child] under [parent] — a model or a screen under a 3D window,
  /// which the canvas cannot draw since a placement has no box on the
  /// artboard. Selected afterwards.
  void addChild(SceneNode parent, SceneNode child) {
    perform('Add ${child.name}', () => parent.children.add(child));
    select(child);
  }

  static double _half(double v) => (v * 2).round() / 2;

  /// The frame a drop would move the dragged node into — drawn on the
  /// canvas while the reparent modifier is held, and nothing more than
  /// drawn. Null whenever the pointer is over the node's own parent or the
  /// modifier is not down.
  FrameNode? _dropTarget;

  /// Every frame the dragged node COULD go into, while the modifier is
  /// held. Drawn faintly, because the rule they answer is invisible
  /// otherwise: only a frame takes children, so a scene of shapes and texts
  /// has almost nowhere to drop and nothing said so.
  var _dropCandidates = <FrameNode>{};

  Set<FrameNode> get dropCandidates => _dropCandidates;

  set dropCandidates(Set<FrameNode> frames) {
    if (_dropCandidates.length == frames.length &&
        _dropCandidates.containsAll(frames)) {
      return;
    }
    _dropCandidates = frames;
    notifyListeners();
  }

  FrameNode? get dropTarget => _dropTarget;

  set dropTarget(FrameNode? frame) {
    if (identical(_dropTarget, frame)) return;
    _dropTarget = frame;
    notifyListeners();
  }

  String? _hover;

  String? get hover => _hover;

  set hover(String? name) {
    if (_hover == name) return;
    _hover = name;
    notifyListeners();
  }

  /// Nodes the canvas exposes to the pointer, bottom-to-top: top-level
  /// children always, plus the children of every selected node's frame
  /// chain. Selection determines hit-test structure — the click ladder is
  /// plain z-order, no coordinate math in the editor.
  Iterable<SceneNode> addressable() {
    var seen = <SceneNode>{};
    var out = <SceneNode>[];
    void addAll(Iterable<SceneNode> nodes) {
      for (var n in nodes) {
        if (seen.add(n)) out.add(n);
      }
    }

    addAll(doc.root.children);
    for (var sel in selectedNodes) {
      var chain = <FrameNode>[];
      var p = doc.parentOf(sel);
      while (p != null && p != doc.root) {
        chain.insert(0, p);
        p = doc.parentOf(p);
      }
      if (sel is FrameNode) chain.add(sel);
      for (var f in chain) {
        addAll(f.children);
      }
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // Selection, second domain: keys on the timeline.
  // -------------------------------------------------------------------------

  final _keySelection = <MotionKeyRef>{};

  /// The two domains do not mix: selecting a node clears the key selection
  /// and vice versa, because every verb (nudge, delete, duplicate) means a
  /// different thing in each, and a verb must never be ambiguous about what
  /// it acts on.
  Iterable<MotionKeyRef> get selectedKeys =>
      _keySelection.where((ref) => keyOf(ref) != null);

  bool isKeySelected(MotionKeyRef ref) => _keySelection.contains(ref);

  /// Resolve a ref against the live model, or null if it no longer exists
  /// (deleted, or undone away) — the same lazy-prune rule node names get.
  MotionKey? keyOf(MotionKeyRef ref) {
    var track = trackOf(ref.motion, ref.group, ref.prop);
    if (track == null) return null;
    for (var key in track.keys) {
      if (key.id == ref.keyId) return key;
    }
    return null;
  }

  MotionTrack? trackOf(String motion, String group, String prop) {
    var g = motions[motion]?.groupNamed(group);
    if (g == null) return null;
    return g.tracks[prop];
  }

  void selectKey(MotionKeyRef? ref, {bool toggle = false}) {
    if (ref == null) {
      if (!toggle) clearKeySelection();
      return;
    }
    if (toggle) {
      if (!_keySelection.remove(ref)) _keySelection.add(ref);
    } else {
      _keySelection
        ..clear()
        ..add(ref);
    }
    _selection.clear();
    _selectedClip = null;
    notifyListeners();
  }

  void setKeySelection(Iterable<MotionKeyRef> refs) {
    _keySelection
      ..clear()
      ..addAll(refs);
    if (_keySelection.isNotEmpty) {
      _selection.clear();
      _selectedClip = null;
    }
    notifyListeners();
  }

  /// Clears the timeline's selection — keys and block both, since they are
  /// one domain: a thing on a lane.
  void clearKeySelection() {
    if (_keySelection.isEmpty && _selectedClip == null) return;
    _keySelection.clear();
    _selectedClip = null;
    notifyListeners();
  }

  MotionClipRef? _selectedClip;

  /// The selected clip block, if it still exists. One at a time: a block
  /// is edited in the inspector, and two blocks have nothing to share.
  MotionClipRef? get selectedClip =>
      _selectedClip != null && clipOf(_selectedClip!) != null
      ? _selectedClip
      : null;

  bool isClipSelected(MotionClipRef ref) => selectedClip == ref;

  MotionClip? clipOf(MotionClipRef ref) {
    var index = clipIndexOf(ref);
    return index == null
        ? null
        : trackOf(ref.motion, ref.group, ref.prop)!.clips[index];
  }

  /// The block's place in its track right now — good until the next move,
  /// which is why the doors below take it fresh each time.
  int? clipIndexOf(MotionClipRef ref) {
    var track = trackOf(ref.motion, ref.group, ref.prop);
    if (track == null) return null;
    for (var (i, c) in track.clips.indexed) {
      if (c.id == ref.clipId) return i;
    }
    return null;
  }

  void selectClip(MotionClipRef? ref) {
    if (ref == null) {
      clearKeySelection();
      return;
    }
    _keySelection.clear();
    _selectedClip = ref;
    _selection.clear();
    notifyListeners();
  }

  /// Backspace on the timeline: whichever is selected, keys or the block.
  void deleteSelected() {
    if (selectedClip case var ref?) {
      deleteClip(ref.motion, ref.group, ref.prop, clipIndexOf(ref)!);
      return;
    }
    deleteKeys();
  }

  /// Move every selected key in time, through the track's sorting door so a
  /// key dragged past a neighbour cannot break the hold rule. One gesture is
  /// one undo entry: pass the gesture's [mergeKey].
  void nudgeKeys(Duration by, {String? mergeKey}) {
    var refs = selectedKeys.toList();
    if (refs.isEmpty) return;
    perform('Move ${_keyCount(refs)}', mergeKey: mergeKey, () {
      for (var ref in refs) {
        var track = trackOf(ref.motion, ref.group, ref.prop)!;
        var key = keyOf(ref)!;
        var at = key.at + by;
        track.moveKey(key, at < Duration.zero ? Duration.zero : at);
      }
    });
  }

  void deleteKeys() {
    var refs = selectedKeys.toList();
    if (refs.isEmpty) return;
    perform('Delete ${_keyCount(refs)}', () {
      for (var ref in refs) {
        trackOf(ref.motion, ref.group, ref.prop)!.removeKey(keyOf(ref)!);
      }
    });
    clearKeySelection();
  }

  String _keyCount(List<MotionKeyRef> refs) =>
      refs.length == 1 ? '1 key' : '${refs.length} keys';

  // -------------------------------------------------------------------------
  // Authoring keys and groups.
  // -------------------------------------------------------------------------

  /// The groups of [motion] that animate [node], in document order.
  Iterable<AnimateGroup> groupsTargeting(String motion, SceneNode node) =>
      motions[motion]?.groups.where((g) => identical(g.node, node)) ?? const [];

  /// Puts a key on [prop] of [group] at [at] — the time *within the group* —
  /// and selects it. The value is what the track already evaluates to there,
  /// so a fresh key changes nothing until it is edited; a track that does not
  /// exist yet starts from what the node shows now.
  ///
  /// A key within 1ms of an existing one moves that one instead: two keys
  /// at one instant have no order and no meaning.
  MotionKeyRef addKey(
    String motion,
    String groupName,
    String prop,
    Duration at, {
    Object? value,
    String? mergeKey,
    bool select = true,
  }) {
    var group = motions[motion]!.groupNamed(groupName)!;
    var node = group.node;
    var existing = trackOf(motion, groupName, prop);
    var spec = propSpecFor(node, prop);
    var kind = spec?.kind ?? TrackKind.number;
    var seed =
        value ??
        (existing != null && existing.keys.isNotEmpty
            ? existing.evaluate(at)
            : _currentValue(node, prop, kind));
    late MotionKey key;
    perform(
      mergeKey == null ? 'Add key' : 'Record key',
      mergeKey: mergeKey,
      () {
        var track = existing;
        if (track == null) {
          track = MotionTrack([], kind: kind);
          group.tracks[prop] = track;
        }
        // A key on a block track replaces the block: a track has one or
        // the other, and a key is the more particular ask.
        track.clips.clear();
        var near = track.keys.where(
          (k) => (k.at - at).inMilliseconds.abs() < 1,
        );
        if (near.isNotEmpty) {
          key = near.first..value = seed;
        } else {
          key = MotionKey(at: at, value: seed);
          track.insertKey(key);
        }
      },
    );
    var ref = MotionKeyRef(motion, groupName, prop, key.id);
    // Selecting the key drops the node selection, which a recording edit
    // is in the middle of using — a drag keeps its nodes.
    if (select) selectKey(ref);
    return ref;
  }

  /// A new group on [node], placed at [at] on the timeline (appended to the
  /// top-level `Par`, or wrapped in one), so it plays with the rest.
  AnimateGroup addGroup(String motion, SceneNode node, {Duration? at}) {
    var m = motions[motion]!;
    var base = '${node.name}Motion';
    var name = base;
    for (var i = 2; m.groupNamed(name) != null; i++) {
      name = '$base$i';
    }
    var group = AnimateGroup(node, name: name);
    perform('Animate ${node.name}', () {
      m.groups.add(group);
      var child = at == null || at == Duration.zero ? group : AtExpr(at, group);
      m.timeline = switch (m.timeline) {
        ParExpr p => ParExpr([...p.children, child]),
        var other => ParExpr([other, child]),
      };
    });
    return group;
  }

  /// What a fresh track on [prop] starts from: the node's value as shown,
  /// or the property's identity when the node has no such slot.
  Object _currentValue(SceneNode node, String prop, TrackKind kind) {
    if (sceneArgName(prop) case var arg?) {
      var raw = switch (node) {
        ExternalNode e => e.args[arg],
        SceneRefNode r =>
          r.args[arg] ??
              r.instance?.params
                  .where((p) => p.name == arg)
                  .firstOrNull
                  ?.defaultValue,
        _ => null,
      };
      if (raw is num) return raw.toDouble();
      if (raw is SceneColor) return raw;
      return kind == TrackKind.color ? const SceneColor(0xFF000000) : 0.0;
    }
    try {
      var v = node.fxRendered(prop);
      return v is num ? v.toDouble() : v;
    } on ArgumentError {
      return kind == TrackKind.color ? const SceneColor(0xFF000000) : 0.0;
    }
  }

  /// Removes [groupName] from [motion] and from its timeline, keys and all.
  void deleteGroup(String motion, String groupName) {
    var m = motions[motion];
    var group = m?.groupNamed(groupName);
    if (m == null || group == null) return;
    perform('Delete $groupName', () {
      m.groups.remove(group);
      m.timeline = _without(m.timeline, groupName);
    });
    clearKeySelection();
  }

  /// Removes one track of a group; the group stays, even empty, since it is
  /// the node's place on the timeline.
  /// Adds a clip block on [prop] of [group] — see [MotionClip]. [at] is
  /// the time within the group; [clip] names the clip, or is empty for the
  /// placement's own row. Keys on the track go: a track has keys or
  /// blocks. Blocks may overlap; the overlap is a crossfade.
  void addClip(
    String motion,
    String groupName,
    String prop, {
    required Duration at,
    required Duration length,
    String clip = '',
  }) {
    var group = motions[motion]!.groupNamed(groupName)!;
    MotionClip? born;
    perform('Clip block on ${_propLabel(prop)}', () {
      var track = trackOf(motion, groupName, prop);
      if (track == null) {
        track = MotionTrack([], kind: TrackKind.number);
        group.tracks[prop] = track;
      }
      track.keys.clear();
      var block = MotionClip(at: at, length: length, clip: clip);
      track.clips.add(block);
      track.sortClips();
      born = block;
    });
    selectClip(MotionClipRef(motion, groupName, prop, born!.id));
  }

  /// Moves the block at [index] by [by], or one of its edges when [edge] is
  /// `start` or `end` — a trim. A block keeps at least 50ms and never
  /// starts before its group. The blocks stay sorted, so an index is only
  /// good until the next move.
  void nudgeClip(
    String motion,
    String groupName,
    String prop,
    int index,
    Duration by, {
    String edge = 'move',
    String? mergeKey,
  }) {
    var track = trackOf(motion, groupName, prop);
    if (track == null || index < 0 || index >= track.clips.length) return;
    var clip = track.clips[index];
    const least = Duration(milliseconds: 50);
    perform(
      edge == 'move' ? 'Move clip block' : 'Trim clip block',
      mergeKey: mergeKey,
      () {
        switch (edge) {
          case 'start':
            var start = clip.at + by;
            if (start < Duration.zero) start = Duration.zero;
            if (clip.end - start < least) start = clip.end - least;
            clip.length = clip.end - start;
            clip.at = start;
          case 'end':
            var length = clip.length + by;
            clip.length = length < least ? least : length;
          default:
            var start = clip.at + by;
            clip.at = start < Duration.zero ? Duration.zero : start;
        }
        track.sortClips();
      },
    );
  }

  /// The block's clip, start, length, speed, offset or direction — the
  /// inspector's fields. A start before the group's, a length under 50ms,
  /// a speed at or below zero and a negative offset are all held at their
  /// limit rather than refused: a field being typed into passes through
  /// them on the way to a number.
  void setClip(
    String motion,
    String groupName,
    String prop,
    int index, {
    String? clip,
    Duration? at,
    Duration? length,
    double? speed,
    Duration? offset,
    bool? reverse,
    String? mergeKey,
  }) {
    var track = trackOf(motion, groupName, prop);
    if (track == null || index < 0 || index >= track.clips.length) return;
    var block = track.clips[index];
    const least = Duration(milliseconds: 50);
    perform('Clip block', mergeKey: mergeKey, () {
      if (clip != null) block.clip = clip;
      if (at != null) block.at = at < Duration.zero ? Duration.zero : at;
      if (length != null) block.length = length < least ? least : length;
      if (speed != null) block.speed = speed <= 0 ? 0.01 : speed;
      if (offset != null) {
        block.offset = offset < Duration.zero ? Duration.zero : offset;
      }
      if (reverse != null) block.reverse = reverse;
      track.sortClips();
    });
  }

  /// Removes one block; the last one takes the track with it.
  void deleteClip(String motion, String groupName, String prop, int index) {
    var track = trackOf(motion, groupName, prop);
    if (track == null || index < 0 || index >= track.clips.length) return;
    if (track.clips.length == 1) {
      deleteTrack(motion, groupName, prop);
      return;
    }
    perform('Delete clip block', () => track.clips.removeAt(index));
    clearKeySelection();
  }

  void deleteTrack(String motion, String groupName, String prop) {
    var group = motions[motion]?.groupNamed(groupName);
    if (group == null) return;
    perform('Delete ${_propLabel(prop)}', () {
      group.tracks.remove(prop);
    });
    clearKeySelection();
  }

  static String _propLabel(String prop) => sceneArgName(prop) ?? prop;

  /// [expr] with every placement of [name] gone, and any combinator left
  /// empty by that collapsed.
  static TimelineExpr _without(TimelineExpr expr, String name) {
    TimelineExpr? strip(TimelineExpr e) => switch (e) {
      AnimateGroup g => g.name == name ? null : g,
      ParExpr p => ParExpr([for (var c in p.children) ?strip(c)]),
      SeqExpr s => SeqExpr([for (var c in s.children) ?strip(c)]),
      AtExpr a => switch (strip(a.child)) {
        null => null,
        var child => AtExpr(a.offset, child),
      },
      SpeedExpr s => switch (strip(s.child)) {
        null => null,
        var child => SpeedExpr(s.factor, child),
      },
      RepeatExpr r => switch (strip(r.child)) {
        null => null,
        var child => RepeatExpr(r.times, child),
      },
    };
    return strip(expr) ?? ParExpr([]);
  }

  void setKeyValue(MotionKeyRef ref, Object value, {String? mergeKey}) {
    var key = keyOf(ref);
    if (key == null || key.value == value) return;
    perform('Edit key', mergeKey: mergeKey, () => key.value = value);
  }

  void setKeyCurve(Iterable<MotionKeyRef> refs, SceneCurve? curve) {
    var keys = [for (var ref in refs) ?keyOf(ref)];
    if (keys.isEmpty) return;
    perform('Ease ${_keyCount(refs.toList())}', () {
      for (var key in keys) {
        key.curve = curve;
      }
    });
  }

  void setKeyTime(MotionKeyRef ref, Duration at, {String? mergeKey}) {
    var key = keyOf(ref);
    var track = trackOf(ref.motion, ref.group, ref.prop);
    if (key == null || track == null || key.at == at) return;
    perform('Move 1 key', mergeKey: mergeKey, () {
      track.moveKey(key, at < Duration.zero ? Duration.zero : at);
    });
  }

  /// Where [group] starts on the timeline, moved to [to]. Only a group
  /// placed directly under the top-level `Par` (bare, or wrapped in one
  /// `At`) can be moved this way; one inside a `Seq` or a `Speed` has its
  /// start decided by its neighbours and is refused.
  void moveGroup(
    String motion,
    String groupName,
    Duration to, {
    String? mergeKey,
  }) {
    var m = motions[motion]!;
    var at = to < Duration.zero ? Duration.zero : to;
    var group = m.groupNamed(groupName)!;
    TimelineExpr place(TimelineExpr e) =>
        at == Duration.zero ? group : AtExpr(at, group);

    bool isRef(TimelineExpr e) =>
        identical(e, group) || (e is AtExpr && identical(e.child, group));
    var timeline = m.timeline;
    var children = switch (timeline) {
      ParExpr p => p.children,
      _ => [timeline],
    };
    var index = children.indexWhere(isRef);
    if (index < 0 && m.placements.containsKey(groupName)) {
      throw ArgumentError(
        '"$groupName" is not placed directly on the timeline: a group inside '
        'a Seq or a Speed starts where its neighbours put it',
      );
    }
    perform('Move $groupName', mergeKey: mergeKey, () {
      var next = [...children];
      // A declared group the timeline never placed joins it here.
      if (index < 0) {
        next.add(place(group));
      } else {
        next[index] = place(next[index]);
      }
      m.timeline = ParExpr(next);
    });
  }

  // -------------------------------------------------------------------------
  // The command door and its journal.
  // -------------------------------------------------------------------------

  static const _journalCap = 100;

  final _undo = <_JournalEntry>[];
  final _redo = <_JournalEntry>[];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;

  /// Every mutation of the document goes through here: snapshot, mutate
  /// inside one [SceneDocument.edit], journal. A [mergeKey] coalesces a
  /// burst of consecutive same-key doors (a drag's move deltas, a field's
  /// live keystrokes) into ONE undo entry — the first snapshot of the burst
  /// is the one undo restores.
  void perform(String label, void Function() mutate, {String? mergeKey}) {
    var merge =
        mergeKey != null &&
        _redo.isEmpty &&
        _undo.isNotEmpty &&
        _openMerge == mergeKey;
    _openMerge = mergeKey;
    if (!merge) {
      _undo.add(
        _JournalEntry(
          label,
          doc.snapshot(),
          _motionSnapshots(),
          _motionClasses(),
          mergeKey,
        ),
      );
      if (_undo.length > _journalCap) _undo.removeAt(0);
      _redo.clear();
    }
    doc.edit(() {
      mutate();
      // A bound property that moved has moved its parameter's default, and
      // every other reader of it follows — inside the same edit, so one
      // notification and one undo entry cover both. The motions' keys obey
      // the same rule against their own parameters.
      reconcileBindings(doc);
      for (var m in motions.values) {
        reconcileMotionBindings(m);
      }
    });
    _revision++;
    notifyListeners();
  }

  /// The merge key still open, if a gesture is running. Held rather than read
  /// off the last journal entry so that TWO drags of the same property are
  /// two entries: the first ends when [endMerge] is called, and the second
  /// starts fresh even though it carries the same key.
  String? _openMerge;

  /// Close the current merge run — what a gesture calls on release.
  void endMerge() => _openMerge = null;

  void undo() {
    if (_undo.isEmpty) return;
    var entry = _undo.removeLast();
    _redo.add(
      _JournalEntry(
        entry.label,
        doc.snapshot(),
        _motionSnapshots(),
        _motionClasses(),
        null,
      ),
    );
    _restore(entry);
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty) return;
    var entry = _redo.removeLast();
    _undo.add(
      _JournalEntry(
        entry.label,
        doc.snapshot(),
        _motionSnapshots(),
        _motionClasses(),
        null,
      ),
    );
    _restore(entry);
    notifyListeners();
  }

  Map<String, MotionSnapshot> _motionSnapshots() => {
    for (var e in motions.entries) e.key: e.value.snapshot(),
  };

  Map<String, String> _motionClasses() => {
    for (var e in motions.entries) e.key: e.value.sceneClassName,
  };

  void _restore(_JournalEntry entry) {
    _openMerge = null;
    doc.restore(entry.scene);
    // The set of motions is part of the state: one added since is dropped,
    // one removed since comes back — revived into a fresh document, since
    // the old object is gone with whoever held it.
    // Rebuilt in the snapshot's order, which is the strip's: a motion
    // revived by undo goes back where it was, not to the end.
    var restored = <String, MotionDocument>{};
    for (var e in entry.motions.entries) {
      var existing = motions[e.key];
      if (existing != null) {
        existing.restore(e.value, scene: doc);
        restored[e.key] = existing;
      } else {
        restored[e.key] = MotionDocument(
          sceneClassName: entry.motionClasses[e.key]!,
        )..restore(e.value, scene: doc);
      }
    }
    motions
      ..clear()
      ..addAll(restored);
    _revision++;
  }

  /// Bumped by every door, undo and redo — what a file's dirty flag counts.
  /// Deliberately not content-comparing: undoing back to the saved state
  /// still reads as dirty, which is the safe direction to be wrong in.
  var _revision = 0;

  int get revision => _revision;

  // -------------------------------------------------------------------------
  // Editing verbs, all doors.
  // -------------------------------------------------------------------------

  void deleteSelection() {
    var nodes = selectedNodes.toList();
    if (nodes.isEmpty) return;
    perform('Delete ${_count(nodes)}', () {
      for (var node in nodes) {
        doc.parentOf(node)?.children.remove(node);
      }
    });
    clearSelection();
  }

  /// Move every selected node under an absolute parent by (dx, dy). One
  /// gesture is one entry: pass the gesture's [mergeKey].
  void nudgeSelection(double dx, double dy, {String? mergeKey}) {
    // Recording: the node stays where it is authored and *travels* — the
    // move becomes translate keys, from wherever the motion has it now.
    if (autoKey && activeMotion != null) {
      var nodes = selectedNodes.toList();
      if (nodes.isEmpty) return;
      for (var node in nodes) {
        var tx = _recorded(node, 'translateX') as double;
        var ty = _recorded(node, 'translateY') as double;
        recordKey(node, 'translateX', _half(tx + dx), mergeKey: mergeKey);
        recordKey(node, 'translateY', _half(ty + dy), mergeKey: mergeKey);
      }
      return;
    }
    var nodes = [
      for (var node in selectedNodes)
        if (doc.parentOf(node)?.layout == NodeLayout.absolute) node,
    ];
    if (nodes.isEmpty) return;
    perform('Move ${_count(nodes)}', mergeKey: mergeKey, () {
      for (var node in nodes) {
        node.x += dx;
        node.y += dy;
      }
    });
  }

  /// Copy every selected node beside its original, offset a hair so the
  /// copy is visible. The whole subtree gets fresh names — names are field
  /// identity, unique per scene.
  void duplicateSelection() {
    var nodes = selectedNodes.toList();
    if (nodes.isEmpty) return;
    var copies = <SceneNode>[];
    perform('Duplicate ${_count(nodes)}', () {
      var taken = {for (var (n, _) in doc.walk()) n.name};
      String fresh(String base) {
        var i = 1;
        while (taken.contains('$base$i')) {
          i++;
        }
        var name = '$base$i';
        taken.add(name);
        return name;
      }

      for (var node in nodes) {
        var parent = doc.parentOf(node);
        if (parent == null) continue;
        var copy = deepCopyNode(node, rename: fresh)
          ..x += 10
          ..y += 10;
        parent.children.insert(parent.children.indexOf(node) + 1, copy);
        copies.add(copy);
      }
    });
    setSelection([for (var c in copies) c.name]);
  }

  String _count(List<SceneNode> nodes) =>
      nodes.length == 1 ? nodes.first.name : '${nodes.length} nodes';
}
