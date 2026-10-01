import 'dart:convert';
import 'dart:developer' as developer;

import '../guest_extensions.dart';

import 'package:flutter/widgets.dart';

import '../inspect/guest_errors.dart';
import '../inspect/guest_logs.dart';
import '../inspect/guest_scrolls.dart';
import 'axes.dart';
import 'knob.dart';
import 'knobs.dart';
import 'ui_catalog.dart';

/// The catalog's side of a guest: the knobs a demo declares while it builds,
/// and the two service extensions a panel reads and writes them through.
///
/// The panel runs in another process and the guest has no platform channels —
/// there is nothing on the other end of one, the host is a few hundred lines
/// of C. What it does have is a VM service, already connected because that is
/// how a reload is pushed in. So the knobs travel as service extensions, which
/// is the one bidirectional channel a plain embedder guest has.
///
/// Values do **not** travel as a reload. Setting one rebuilds the demo in
/// place, which is the difference between turning a knob and recompiling: the
/// demo keeps its state, and the answer is on screen in a frame rather than in
/// a hundred milliseconds.
class CatalogKnobs {
  CatalogKnobs._();

  static final instance = CatalogKnobs._();

  /// Bumped when a *value* changes, so the widget providing these to the demo
  /// has something to rebuild on.
  final revision = ValueNotifier<int>(0);

  /// Bumped when a knob is *declared*, which happens while the demo builds —
  /// so this one must never mark anything dirty. Nothing on screen depends on
  /// it either: the demo already has the default it just asked for. It exists
  /// so a panel can tell that the set it is showing is out of date.
  int get declared => _declared;
  var _declared = 0;

  late final EditableKnobs editable = EditableKnobs(
    onRefresh: _bump,
    onAdded: () => _declared++,
  );

  /// What the entry that declared the current knobs was, so switching entries
  /// starts from nothing rather than from the last demo's controls.
  String? _entryId;

  /// Which entry the guest is currently showing.
  ///
  /// Public because anything else reporting on the live build has the same
  /// reason to name it that [describe] does: a read that landed before an
  /// entry switch describes the wrong demo, and only the id makes that
  /// detectable.
  String? get entryId => _entryId;

  void _bump() => revision.value++;

  /// Opens a declaration pass and closes it once the frame has been built.
  ///
  /// The frame is the right boundary because everything that reads a knob is a
  /// dependent of the provider [CatalogGuest] puts up, so one build of that
  /// widget rebuilds every reader there is. Whatever has not asked for a knob
  /// by the end of it is not asking any more — the demo was edited, or it took
  /// a different path through its own build.
  void _beginPass() {
    editable.beginPass();
    if (_sweeping) return;
    _sweeping = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sweeping = false;
      // Retiring changes the set as much as declaring does, so a panel holding
      // the old one has the same reason to ask again.
      if (editable.endPass() > 0) _declared++;
    });
  }

  var _sweeping = false;

  /// Forgets everything the previous entry declared.
  ///
  /// Knobs are discovered by *running* the demo, so the set is only ever as
  /// right as the last build. Carrying one entry's controls into the next
  /// would leave a panel offering knobs nothing reads.
  void resetFor(String entryId) {
    if (_entryId == entryId) return;
    _entryId = entryId;
    editable.dispose();
    editable.knobs.clear();
    _declared++;
    // No bump: this runs from the widget's own init or update, and the demo
    // below is about to build anyway.
  }

  /// Registers the extensions. Call once, before `runApp`.
  void registerExtensions() {
    GuestExtensions.register('ext.flutterware.knobs', (_, _) async {
      return developer.ServiceExtensionResponse.result(
        jsonEncode(describe().toJson()),
      );
    });
    GuestExtensions.register('ext.flutterware.setKnobs', (_, args) async {
      // A service extension's arguments are strings, so the payload is JSON in
      // one of them rather than a map of typed values.
      var payload = jsonDecode(args['payload'] ?? '{}') as Map<String, dynamic>;
      var applied = applyAll(payload.cast<String, Object?>());
      // Answered only once the demo has rebuilt on it. Turning a knob can
      // reveal or retire another, so a reply that came back before the frame
      // would leave the panel asking what to show and being told about the
      // build it had just replaced — intermittently, depending on whether the
      // frame beat the next request, which is worse than being wrong.
      //
      // Bounded because this is an RPC a panel waits on: a guest that has
      // stopped drawing should make the panel late, not stuck.
      if (applied) {
        await WidgetsBinding.instance.endOfFrame.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
      }
      return developer.ServiceExtensionResponse.result(
        jsonEncode({'applied': applied}),
      );
    });
  }

  /// Every knob the last build declared, in declaration order.
  KnobReport describe() => KnobReport(
    entryId: _entryId,
    declared: _declared,
    revision: revision.value,
    knobs: [
      for (var entry in editable.knobs.entries)
        ?_describe(entry.key, entry.value),
    ],
  );

  static KnobDescriptor? _describe(String name, Knob<Object?> p) => switch (p) {
    StringKnob() => KnobDescriptor(
      name: name,
      kind: KnobKind.string,
      value: p.requiredValue,
      defaultValue: p.defaultValue,
    ),
    BoolKnob() => KnobDescriptor(
      name: name,
      kind: KnobKind.boolean,
      value: p.requiredValue,
      defaultValue: p.defaultValue,
    ),
    NumKnob() => KnobDescriptor(
      name: name,
      kind: p.isInt ? KnobKind.integer : KnobKind.number,
      value: p.requiredValue,
      defaultValue: p.defaultValue,
      min: p.min,
      max: p.max,
    ),
    PickerKnob() => KnobDescriptor(
      name: name,
      kind: KnobKind.picker,
      options: p.options.keys.toList(),
      value: _labelOf(p, p.requiredValue),
      defaultValue: _labelOf(p, p.defaultValue),
      style: p.style,
    ),
    // Dates and buttons are left out rather than described wrong.
    _ => null,
  };

  static String? _labelOf(PickerKnob<Object?> p, Object? value) {
    for (var entry in p.options.entries) {
      if (entry.value == value) return entry.key;
    }
    return null;
  }

  /// Sets [name] to [value], or back to its default when [value] is null.
  ///
  /// Returns false for a knob the current build did not declare, which is what
  /// a panel showing a stale set looks like from in here.
  /// Takes the whole set at once, and it **is** the whole set: a knob the
  /// payload does not name goes back to the default the demo wrote.
  ///
  /// One call rather than one per knob, and replace rather than merge, because
  /// the host keeps knob values in the address and an address writes a default
  /// as *nothing at all*. A payload that only carried changes could never say
  /// "forget this one", which is exactly how the top bar's axes came to look
  /// stuck before they were moved to the same footing.
  ///
  /// It also collapses a queue: a slider drag used to be one round trip per
  /// value with a pending-map serialising them, where now the latest payload
  /// simply replaces whatever it caught up with.
  bool applyAll(Map<String, Object?> values) {
    var applied = false;
    for (var name in editable.knobs.keys.toList()) {
      if (apply(name, values[name])) applied = true;
    }
    return applied;
  }

  bool apply(String name, Object? value) {
    var parameter = editable.knobs[name];
    switch (parameter) {
      case StringKnob():
        parameter.value = value as String?;
      case BoolKnob():
        parameter.value = value as bool?;
      case NumKnob<int>():
        parameter.value = (value as num?)?.round();
      case NumKnob():
        parameter.value = (value as num?)?.toDouble();
      case PickerKnob():
        parameter.value = value == null ? null : parameter.options[value];
      case _:
        return false;
    }
    return true;
  }
}

/// Provides the catalog's state to the entry below it, and rebuilds it when a
/// knob moves.
///
/// The [PreviewState] a demo reads through `context.uiCatalog` is otherwise
/// the empty one, which answers every call with the default — which is exactly
/// what should happen when the same widget is built inside the real app.
class CatalogGuest extends StatefulWidget {
  const CatalogGuest({super.key, required this.entryId, required this.child});

  /// Marks where the demo starts, so inspection can report the demo rather
  /// than the catalog chrome standing above it.
  ///
  /// A [GlobalKey] rather than a held [Element]: the subtree is remounted on
  /// every entry switch, so anything holding an element would be holding the
  /// previous entry's. This one sits on the wrapper *around* the changing
  /// subtree and so survives the switch.
  static final demoKey = GlobalKey(debugLabel: 'flutterware.demo');

  /// The demo's root element, or null before the first build.
  static Element? get demoRoot => demoKey.currentContext as Element?;

  final String entryId;
  final Widget child;

  @override
  State<CatalogGuest> createState() => _CatalogGuestState();
}

class _CatalogGuestState extends State<CatalogGuest> {
  CatalogKnobs get _knobs => CatalogKnobs.instance;

  /// The entry and revision the last declaration pass was begun for.
  (String, int)? _passed;

  /// The axes are reset from here as well as the knobs, and it has to be from
  /// here: the shell is *below* this widget, so an entry whose wrapper is not a
  /// shell declares nothing at all, and without this the previous shell's axes
  /// would stay on the bar with no build ever coming to replace them.
  void _reset() {
    _knobs.resetFor(widget.entryId);
    CatalogAxes.instance.resetFor(widget.entryId);
    // The same boundary, for the same reason: carrying one entry's failures
    // into the next reports a demo as broken because the one before it was.
    GuestErrors.instance.resetFor(widget.entryId);
    // And what it printed, which is the same argument once more: every other
    // pane of the panel is scoped to the selected entry, and a console that was
    // not would be the one showing another demo's words under this demo's name.
    GuestLogs.instance.resetFor(widget.entryId);
  }

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(CatalogGuest old) {
    super.didUpdateWidget(old);
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    // Above the marker rather than below it, so that counting the demo's
    // scrolling adds nothing to the tree the panel reads — see [GuestScrolls]
    // for why the watch cannot see a scroll any other way.
    return GuestScrolls.instance.watching(
      child: ValueListenableBuilder<int>(
        valueListenable: _knobs.revision,
        builder: (context, revision, _) {
          // Everything below is about to re-declare what it reads, which is the
          // only chance there is to notice a knob nobody reads any more — but
          // only when it *is* about to: a new revision (the provider below
          // notifies its dependents) or a new entry (the subtree is
          // remounted). Any other rebuild of this widget — the window's
          // metrics moving on a resize or a device switch — leaves the demo's
          // element alone, and a pass with nothing declared in it retired
          // every knob. Measured on a switch followed by a pick.
          if (_passed != (widget.entryId, revision)) {
            _passed = (widget.entryId, revision);
            _knobs._beginPass();
          }
          return KnobsProvider(
            knobs: _knobs.editable,
            // One editable set for the life of the guest, so the revision is
            // what tells the provider anything happened: dependents are notified
            // by comparison, and the demo *is* a dependent — reading a knob is
            // what subscribed it.
            revision: revision,
            child: KeyedSubtree(key: CatalogGuest.demoKey, child: widget.child),
          );
        },
      ),
    );
  }
}
