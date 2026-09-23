import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutterware/plugins.dart';

import 'design/design.dart';

/// A grouped block of results, rendered under one section header.
class PaletteSection {
  const PaletteSection(this.title, this.hits);

  final String title;
  final List<SearchHit> hits;
}

/// Groups hits by [SearchHit.group], in the order the groups first appear.
///
/// Order comes from the hits rather than from a fixed list, so a plugin that
/// matched better sorts above one that did not, and a plugin added next year
/// needs no entry here.
List<PaletteSection> groupHits(List<SearchHit> hits) {
  var byGroup = <String, List<SearchHit>>{};
  for (var hit in hits) {
    (byGroup[hit.group] ??= []).add(hit);
  }
  return [
    for (var entry in byGroup.entries) PaletteSection(entry.key, entry.value),
  ];
}

/// The ⌘K surface: a query field, fuzzy-matched results grouped by section with
/// the matched characters lit, and full keyboard control.
///
/// A View. It is handed [sections] and hands back a [SearchHit] — it does
/// not know what a session is, never runs a search, and cannot open anything.
/// What it does own is interaction: the text field, the selection, and the
/// keys. Those are not business logic, and pushing them out would leave the
/// caller reimplementing arrow keys.
class CommandPalette extends StatefulWidget {
  const CommandPalette({
    super.key,
    required this.sections,
    required this.onQueryChanged,
    required this.onActivate,
    required this.onDismiss,
    this.initialQuery = '',
    this.initialSelected = 0,
    this.loading = false,
    this.placeholder = 'Search plugins, entries and actions…',
  });

  final List<PaletteSection> sections;

  /// Fires on every keystroke. The caller filters its warm index and hands back
  /// new [sections]; nothing here waits on it.
  final ValueChanged<String> onQueryChanged;

  /// The user picked one — open its address, or run its action.
  final ValueChanged<SearchHit> onActivate;

  final VoidCallback onDismiss;

  /// Seeds the field. For a demo, and for reopening on the last query.
  final String initialQuery;

  /// Which row starts selected. Only useful to show a particular row's
  /// selected state without driving the keyboard.
  final int initialSelected;

  /// Draws the progress line instead of the divider — a slower source has not
  /// reported yet, and the results below are incomplete rather than final.
  final bool loading;

  final String placeholder;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initialQuery,
  );
  final _scroll = ScrollController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);
  final _rowKeys = <int, GlobalKey>{};

  late int _selected = widget.initialSelected;

  List<SearchHit> get _flat => [for (var s in widget.sections) ...s.hits];

  @override
  void didUpdateWidget(CommandPalette old) {
    super.didUpdateWidget(old);
    // Results changed under the selection — keep it in range rather than
    // letting Enter fire on a row that is no longer there.
    var count = _flat.length;
    if (_selected >= count) _selected = count == 0 ? 0 : count - 1;
  }

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        _activate();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        widget.onDismiss();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _move(int delta) {
    var count = _flat.length;
    if (count == 0) return;
    setState(() => _selected = (_selected + delta).clamp(0, count - 1));
    // After layout, so the row we are scrolling to exists.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      var context = _rowKeys[_selected]?.currentContext;
      if (context != null && context.mounted) {
        unawaited(
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 80),
          ),
        );
      }
    });
  }

  void _activate() {
    var flat = _flat;
    if (_selected < 0 || _selected >= flat.length) return;
    widget.onActivate(flat[_selected]);
  }

  @override
  Widget build(BuildContext context) {
    var flat = _flat;

    // Shadow on the outer box, clip on the inner Material: a Material that
    // clips crops its own shadow into a grey edge.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(context.radii.radiusLarge),
        boxShadow: context.elevation.lg,
      ),
      child: Material(
        color: context.colors.bg,
        elevation: 0,
        borderRadius: BorderRadius.circular(context.radii.radiusLarge),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _field(context),
            SizedBox(
              height: 2,
              child: widget.loading
                  ? LinearProgressIndicator(
                      minHeight: 2,
                      backgroundColor: context.colors.line2,
                      color: context.colors.accent,
                    )
                  : Divider(
                      height: 2,
                      thickness: 1,
                      color: context.colors.line2,
                    ),
            ),
            Flexible(
              child: flat.isEmpty ? _empty(context) : _list(context, flat),
            ),
            Divider(height: 1, thickness: 1, color: context.colors.line2),
            _footer(context),
          ],
        ),
      ),
    );
  }

  Widget _field(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(
            Icons.search_rounded,
            size: FwIconSize.lg,
            color: context.colors.mut,
          ),
          const Gap(FwSpacing.md),
          Expanded(
            child: TextField(
              controller: _text,
              focusNode: _focus,
              autofocus: true,
              onChanged: (value) {
                // Selection returns to the top: the old index pointed into a
                // list that no longer exists.
                setState(() => _selected = 0);
                widget.onQueryChanged(value);
              },
              onSubmitted: (_) => _activate(),
              style: context.type.body.copyWith(fontSize: 16),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: widget.placeholder,
                hintStyle: context.type.body.copyWith(
                  fontSize: 16,
                  color: context.colors.mut2,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  vertical: FwSpacing.lg,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context, List<SearchHit> flat) {
    var index = 0;
    var children = <Widget>[];
    for (var section in widget.sections) {
      children.add(_header(context, section.title));
      for (var hit in section.hits) {
        children.add(_row(context, hit, index));
        index++;
      }
    }
    return ListView(
      controller: _scroll,
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: FwSpacing.sm),
      children: children,
    );
  }

  Widget _header(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.xl,
        FwSpacing.md,
        FwSpacing.xl,
        FwSpacing.xs,
      ),
      child: Text(
        title.toUpperCase(),
        style: context.type.micro.copyWith(
          color: context.colors.mut2,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  Widget _row(BuildContext context, SearchHit hit, int index) {
    var selected = index == _selected;
    var key = _rowKeys[index] ??= GlobalKey();

    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.sm),
      child: MouseRegion(
        onEnter: (_) => setState(() => _selected = index),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() => _selected = index);
            widget.onActivate(hit);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.lg,
              vertical: FwSpacing.md,
            ),
            decoration: BoxDecoration(
              color: selected ? context.colors.accentSoft : null,
              borderRadius: BorderRadius.circular(context.radii.radius),
            ),
            child: Row(
              children: [
                Icon(
                  _iconFor(hit.reason),
                  size: FwIconSize.lg,
                  color: selected ? context.colors.accent : context.colors.mut,
                ),
                const Gap(FwSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _title(context, hit),
                      if (hit.subtitle != null) ...[
                        const SizedBox(height: 1),
                        Text(
                          hit.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.type.caption,
                        ),
                      ],
                    ],
                  ),
                ),
                const Gap(FwSpacing.md),
                _ReasonChip(hit.reason),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The title with the matched characters lit, so it is visible *why* a row is
  /// in the list — which is what separates a fuzzy result from a random one.
  Widget _title(BuildContext context, SearchHit hit) {
    var base = context.type.body.copyWith(
      color: context.colors.ink,
      fontWeight: FontWeight.w500,
    );
    if (hit.matched.isEmpty) {
      return Text(
        hit.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }
    var hot = hit.matched.toSet();
    var accent = base.copyWith(
      color: context.colors.accent,
      fontWeight: FontWeight.w700,
    );
    return Text.rich(
      TextSpan(
        children: [
          for (var i = 0; i < hit.title.length; i++)
            TextSpan(
              text: hit.title[i],
              style: hot.contains(i) ? accent : base,
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _empty(BuildContext context) {
    // Fixed height so an empty result neither collapses the panel nor lets it
    // jump as the user types past the last match.
    return SizedBox(
      height: 180,
      child: Center(
        child: widget.loading
            ? SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: context.colors.mut,
                ),
              )
            : Text(
                _text.text.trim().isEmpty
                    ? 'Type to search'
                    : 'No results for “${_text.text}”',
                style: context.type.bodyMuted,
              ),
      ),
    );
  }

  Widget _footer(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.md,
      ),
      child: Row(
        children: [
          _hint(context, '↑↓', 'navigate'),
          const Gap(FwSpacing.xl),
          _hint(context, '↵', 'open'),
          const Gap(FwSpacing.xl),
          _hint(context, 'esc', 'close'),
        ],
      ),
    );
  }

  Widget _hint(BuildContext context, String key, String label) {
    return Row(
      children: [
        _Kbd(key),
        const Gap(FwSpacing.sm),
        Text(label, style: context.type.caption),
      ],
    );
  }
}

IconData _iconFor(SearchReason reason) => switch (reason) {
  SearchReason.plugin => Icons.extension_outlined,
  SearchReason.package => Icons.inventory_2_outlined,
  SearchReason.item => Icons.crop_square_outlined,
};

/// A small keycap chip.
class _Kbd extends StatelessWidget {
  const _Kbd(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: context.colors.panel2,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        border: Border.all(color: context.colors.line2),
      ),
      child: Text(
        label,
        style: context.type.micro.copyWith(
          color: context.colors.mut,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Why the row matched, on the trailing edge. It answers "what am I looking
/// at?" for a list that mixes a plugin, a package, a demo and a table row.
class _ReasonChip extends StatelessWidget {
  const _ReasonChip(this.reason);

  final SearchReason reason;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: context.colors.panel,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        border: Border.all(color: context.colors.line2),
      ),
      child: Text(
        reason.label,
        style: context.type.micro.copyWith(
          color: context.colors.mut,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
