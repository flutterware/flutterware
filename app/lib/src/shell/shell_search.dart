import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/plugins.dart';

import '../plugins/plugin_core.dart';
import '../ui/command_palette.dart';
import '../ui/design/design.dart';
import '../ui/tappable.dart';
import 'shell_controller.dart';

/// Opens the palette over the shell.
///
/// Top-anchored: the field never moves, so the panel grows downward and the
/// query stays where the eye already is.
Future<void> showShellSearch(BuildContext context, ShellController shell) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.25),
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        top: (MediaQuery.sizeOf(context).height * 0.12).clamp(24.0, 140.0),
        left: FwSpacing.xl,
        right: FwSpacing.xl,
        bottom: FwSpacing.xl,
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600, maxHeight: 520),
          child: ShellSearch(shell, onDismiss: Navigator.of(context).pop),
        ),
      ),
    ),
  );
}

/// The Screen behind [CommandPalette]: it warms the index, runs the query
/// for the selected worktree, and turns the chosen hit into navigation.
///
/// Opening the palette is what triggers loading. Every keystroke after that
/// filters what is already in memory — not because a rule forbids more, but
/// because the scans are cached and idempotent, so redoing them per character
/// would be work with no result.
class ShellSearch extends StatefulWidget {
  const ShellSearch(this.shell, {super.key, required this.onDismiss});

  final ShellController shell;
  final VoidCallback onDismiss;

  @override
  State<ShellSearch> createState() => _ShellSearchState();
}

class _ShellSearchState extends State<ShellSearch> {
  var _query = '';
  var _loading = false;

  /// The selected worktree's cores, and only those.
  ///
  /// Searching every open worktree sounds better than it is: a hit in another
  /// checkout switches the whole shell out from under you, and warming them all
  /// pays for worktrees the query was never about. Whatever is on screen is
  /// what the search is about.
  List<PluginCore> get _cores =>
      widget.shell.selectedSession?.session.cores ?? const [];

  @override
  void initState() {
    super.initState();
    unawaited(_warm());
  }

  /// Loads what nothing has looked at yet, then lets the results in as each
  /// core lands rather than waiting for the slowest.
  Future<void> _warm() async {
    var pending = [
      for (var core in _cores)
        core.computeAll().then((_) {
          if (mounted) setState(() {});
        }),
    ];
    if (pending.isEmpty) return;
    setState(() => _loading = true);
    try {
      await Future.wait(pending);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<PaletteSection> get _sections {
    if (_query.trim().isEmpty) return const [];
    var hits = [for (var core in _cores) ...core.search(_query)]
      ..sort((a, b) => b.score - a.score);
    return groupHits(hits);
  }

  /// Hands the hit's address to the shell, and nothing more.
  ///
  /// Not a branch per kind of result, and no longer a translation into
  /// `select…` calls: the address *is* the instruction, and the shell's state
  /// is an address, so opening a hit is one write. Segments the shell does not
  /// understand ride along rather than being dropped — it reads the first as a
  /// child and leaves the rest for whatever owns them.
  void _open(SearchHit hit) {
    widget.onDismiss();
    widget.shell.go(hit.address);
  }

  @override
  Widget build(BuildContext context) {
    return CommandPalette(
      sections: _sections,
      loading: _loading,
      onQueryChanged: (value) => setState(() => _query = value),
      onActivate: _open,
      onDismiss: widget.onDismiss,
    );
  }
}

/// A search-shaped button for the band. It is a button, not a field — the
/// palette owns the real one — but it looks like a field because that is what
/// it opens, and it carries the shortcut so the binding is discoverable
/// without a menu.
class SearchTrigger extends StatefulWidget {
  const SearchTrigger({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  State<SearchTrigger> createState() => _SearchTriggerState();
}

class _SearchTriggerState extends State<SearchTrigger> {
  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable.builder(
      onTap: widget.onTap,
      builder: (context, hovered) => Container(
        height: 26,
        width: 220,
        padding: const EdgeInsets.symmetric(horizontal: FwSpacing.md),
        decoration: BoxDecoration(
          color: hovered ? colors.panel2 : colors.bg,
          borderRadius: BorderRadius.circular(context.radii.radius),
          border: Border.all(color: colors.line),
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded, size: FwIconSize.sm, color: colors.mut2),
            const Gap(FwSpacing.sm),
            Expanded(
              child: Text(
                'Search',
                style: context.type.caption.copyWith(color: colors.mut2),
              ),
            ),
            Text(
              _shortcutLabel(context),
              style: context.type.micro.copyWith(color: colors.mut2),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the platform actually calls the modifier. A macOS user reading `Ctrl K`
/// would try the wrong key.
String _shortcutLabel(BuildContext context) =>
    Theme.of(context).platform == TargetPlatform.macOS ? '⌘K' : 'Ctrl K';
