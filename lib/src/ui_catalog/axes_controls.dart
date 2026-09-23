import 'package:material_ui/material_ui.dart';

import 'axes.dart';
import 'knob.dart';

/// The shell's axes, as controls, in the catalog's own toolbar.
///
/// The page and the demo are one isolate here, so there is no wire.
/// [CatalogAxes] already holds everything both halves need — `describe()` says
/// what the shell declared and what each is set to, `apply` records a selection
/// and bumps `revision`, and [PreviewShell] rebuilds on that notifier by
/// itself. The GUI reaches the same two methods over a service extension
/// because it is a different process. This one only had to call them.
///
/// Without it a `PreviewShell` on a generated page declares its axes and then
/// answers with the defaults written into the shell, forever — and shows no
/// sign of it, because a bar that is *absent* does not look broken the way a
/// bar that is dead would. A project whose catalog exists so the team can look
/// at every screen in a second language loses exactly that, silently.
///
/// Reads what was declared **after** the frame that declared it. An axis exists
/// because a shell asked for it while building, so during this build the
/// singleton still holds the last one's — the same one-frame lag [EditableKnobs]
/// handles with a post-frame pass, and handled the same way.
class AxesControls extends StatefulWidget {
  const AxesControls({super.key});

  @override
  State<AxesControls> createState() => _AxesControlsState();
}

class _AxesControlsState extends State<AxesControls> {
  List<KnobDescriptor> _axes = const [];
  String? _shellId;

  @override
  void initState() {
    super.initState();
    CatalogAxes.instance.revision.addListener(_scheduleSync);
    _scheduleSync();
  }

  @override
  void dispose() {
    CatalogAxes.instance.revision.removeListener(_scheduleSync);
    super.dispose();
  }

  void _scheduleSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      var report = CatalogAxes.instance.describe();
      if (report.shellId == _shellId && _sameAs(report.axes)) return;
      setState(() {
        _shellId = report.shellId;
        _axes = report.axes;
      });
    });
  }

  bool _sameAs(List<KnobDescriptor> axes) {
    if (axes.length != _axes.length) return false;
    for (var (index, axis) in axes.indexed) {
      var mine = _axes[index];
      if (axis.name != mine.name || axis.value != mine.value) return false;
    }
    return true;
  }

  /// The whole map for the shell, not the one that moved. `apply` replaces
  /// rather than merges — an absent name means "put it back to the default" —
  /// so sending one axis would reset every other one on the bar.
  void _select(String name, Object? value) {
    var shellId = _shellId;
    if (shellId == null) return;
    CatalogAxes.instance.apply({
      shellId: {for (var axis in _axes) axis.name: axis.value, name: value},
    });
    // No `setState`: `apply` bumps `revision`, the shell rebuilds and declares
    // its new values, and the post-frame pass reads those. Setting it here
    // would draw the value we asked for rather than the one the shell took.
  }

  @override
  Widget build(BuildContext context) {
    if (_axes.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var axis in _axes)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: _control(axis),
          ),
      ],
    );
  }

  Widget _control(KnobDescriptor axis) => switch (axis.kind) {
    KnobKind.boolean => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(axis.name),
        Transform.scale(
          scale: 0.7,
          child: Switch(
            value: axis.value == true,
            onChanged: (value) => _select(axis.name, value),
          ),
        ),
      ],
    ),
    // Everything else is a picker. An axis is a closed set by definition —
    // `PreviewAxes` offers exactly `picker` and `flag` — so there is no third
    // control to write and no free-text case to get wrong.
    _ => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(axis.name),
        const SizedBox(width: 6),
        DropdownButton<String>(
          value: axis.value as String?,
          underline: const SizedBox.shrink(),
          items: [
            for (var option in axis.options)
              DropdownMenuItem(value: option, child: Text(option)),
          ],
          onChanged: (value) => _select(axis.name, value),
        ),
      ],
    ),
  };
}
