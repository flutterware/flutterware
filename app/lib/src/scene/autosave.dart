import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'editor.dart';
import 'workspace.dart';

/// What the header says about the file on disk.
enum SceneSaveState {
  /// Everything the editor holds is on disk.
  saved,

  /// Edits are waiting out the quiet period.
  pending,

  /// The emitter refused its own output, so nothing was written. The work is
  /// still in the editor, which is why this is a state and not a dialog.
  refused,

  /// The file moved on disk under an editor that has edits of its own.
  /// Nothing is written until somebody says which version wins.
  conflicted,
}

/// Writes a [SceneSaveSource]'s files once its editor goes quiet, so there
/// is no save button to remember.
///
/// The two things that make writing without being asked safe are already in
/// [SceneFile.save]: it re-parses its own output before writing, and it writes
/// nothing when the bytes are the ones already there. So this decides only
/// *when*, which is the same division of labour the config watcher makes.
///
/// The one rule that is not about timing: an automatic write never overwrites
/// a change somebody else made to the file. A path that is [suspend]ed stays
/// unwritten until it is resumed, and only an explicit [flush] — a person
/// pressing save — is allowed to say that their version wins.
class SceneAutosave {
  SceneAutosave({
    required this.write,
    required this.onChanged,
    this.quiet = const Duration(milliseconds: 800),
  });

  final void Function(String path, String source) write;

  /// Called when [state] or [note] moved, so the header can redraw.
  final VoidCallback onChanged;

  /// How still the editor has to be before its work is written. Long enough
  /// that a drag is one write rather than sixty, short enough that walking
  /// away from the keyboard does not leave work only in memory.
  final Duration quiet;

  SceneSaveSource? _source;
  SceneEditor? _editor;
  int? _revision;
  Timer? _timer;
  var _disposed = false;

  /// Paths an external change is holding, by what happened to them.
  final _suspended = <String>{};

  var _state = SceneSaveState.saved;
  var _note = '';

  SceneSaveState get state => _state;

  /// What the state does not say by itself: which file, and why.
  String get note => _note;

  /// Whether a write is owed. Only true inside the quiet period.
  bool get isPending => _timer != null;

  /// Watches [source], flushing whatever the last one owed.
  void bind(SceneSaveSource? source) {
    if (identical(source, _source)) return;
    flush();
    _source?.removeListener(_onSource);
    _editor?.removeListener(_onEdit);
    _editor = null;
    _revision = null;
    _suspended.clear();
    _source = source;
    source?.addListener(_onSource);
    _onSource();
    // A source can arrive with work already in it — a hot reload rebinds
    // one mid-session — and saying "saved" over unwritten edits is the one
    // thing a status word must never do.
    if (source != null && source.anyDirty) {
      _timer = Timer(quiet, _fire);
      _set(SceneSaveState.pending, '');
    } else {
      _set(SceneSaveState.saved, '');
    }
  }

  /// The breadcrumb moved, or a library was edited: edits now arrive from a
  /// different file's editor, or something not on the breadcrumb owes a
  /// write.
  void _onSource() {
    var editor = _source?.saveEditor;
    if (!identical(editor, _editor)) {
      _editor?.removeListener(_onEdit);
      _editor = editor;
      _revision = editor?.revision;
      editor?.addListener(_onEdit);
    }
    if (_source?.anyDirty == true && _timer == null) {
      _timer = Timer(quiet, _fire);
      _set(SceneSaveState.pending, _note);
    }
  }

  /// Armed by a change to the document, never by a change to the selection.
  ///
  /// The editor notifies for hovering a row as much as for moving a node, and
  /// arming on those would let a moving mouse hold the write off for as long
  /// as it kept moving. The revision counter moves only for edits.
  void _onEdit() {
    var editor = _editor;
    if (editor == null) return;
    if (editor.revision == _revision) return;
    _revision = editor.revision;
    _timer?.cancel();
    _timer = Timer(quiet, _fire);
    _set(SceneSaveState.pending, _note);
  }

  /// Stops writing [path] until it is resolved: the file changed on disk and
  /// this editor has work of its own that a write would destroy.
  void suspend(String path, String note) {
    _suspended.add(p.canonicalize(path));
    _set(SceneSaveState.conflicted, note);
  }

  /// The file and the editor agree again.
  void resume(String path) {
    if (!_suspended.remove(p.canonicalize(path))) return;
    if (_suspended.isEmpty && _state == SceneSaveState.conflicted) {
      _set(SceneSaveState.saved, '');
    }
  }

  bool isSuspended(String path) => _suspended.contains(p.canonicalize(path));

  /// Writes now, including files an external change had suspended: an
  /// explicit save is a person saying their version wins.
  void flush() {
    _timer?.cancel();
    _timer = null;
    _write(includeSuspended: true);
  }

  void _fire() {
    _timer = null;
    _write(includeSuspended: false);
  }

  void _write({required bool includeSuspended}) {
    var source = _source;
    if (source == null || _disposed) return;
    var refused = <String>[];
    var held = <String>[];
    for (var file in source.dirtyFiles.toList()) {
      if (!includeSuspended && isSuspended(file.path)) {
        held.add(p.basename(file.path));
        continue;
      }
      var refusals = file.save(write);
      if (refusals.isEmpty) {
        resume(file.path);
      } else {
        refused.add('${p.basename(file.path)}: ${refusals.first}');
      }
    }
    if (refused.isNotEmpty) {
      _set(SceneSaveState.refused, 'not written: ${refused.join('; ')}');
    } else if (held.isNotEmpty) {
      _set(
        SceneSaveState.conflicted,
        '${held.join(', ')} changed on disk. Save to keep your version.',
      );
    } else {
      _set(SceneSaveState.saved, '');
    }
  }

  void _set(SceneSaveState state, String note) {
    if (_state == state && _note == note) return;
    _state = state;
    _note = note;
    onChanged();
  }

  void dispose() {
    flush();
    _disposed = true;
    _timer?.cancel();
    _source?.removeListener(_onSource);
    _editor?.removeListener(_onEdit);
  }
}
