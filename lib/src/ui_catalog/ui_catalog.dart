import 'package:material_ui/material_ui.dart';

import 'knobs.dart';

export 'app.dart' show UICatalog;

/// The controls this entry asks for while it builds — `context.knobs.bool(…)`.
///
/// One accessor, for a preview and for an in-app catalog page alike. There were
/// two — `previews` and `uiCatalog` — because the state they returned was named
/// after a tool rather than after what it holds; naming it [Knobs] left nothing
/// for the second one to disambiguate.
///
/// App-wide switches — a flavour, a locale, a theme — are **not** knobs. They
/// are declared by the project's `PreviewShell` through `PreviewAxes`, and they
/// persist across entries because they belong to the shell rather than to
/// whatever it is wrapping. That they are not reachable from a context is
/// deliberate; see `PreviewAxes`.
extension KnobsExtension on BuildContext {
  Knobs get knobs => KnobsProvider.maybeOf(this)?.knobs ?? Knobs.unanswered;
}

/// What answers [KnobsExtension.knobs] below it.
///
/// Absent — in the real app, in a test, in Flutter's own previewer — every knob
/// answers with the default written at the call site, which is what makes a
/// knob safe to write in a widget that ships.
class KnobsProvider extends InheritedWidget {
  const KnobsProvider({
    super.key,
    required super.child,
    required this.knobs,
    this.revision = 0,
  });

  final Knobs knobs;

  /// Bumped by a host that re-answers *through the same [Knobs] object*.
  ///
  /// Reading a knob is what subscribes a widget to this, and dependents are
  /// notified by comparison — so a host holding one editable set for the life of
  /// a session would never notify anything. The guest bumps this per build pass;
  /// a host that hands over a fresh object each time can leave it alone.
  final int revision;

  static KnobsProvider? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<KnobsProvider>();
  }

  @override
  bool updateShouldNotify(KnobsProvider oldWidget) {
    return oldWidget.knobs != knobs || oldWidget.revision != revision;
  }
}
