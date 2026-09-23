import 'package:material_ui/material_ui.dart';

import '../../ui/filter_bar.dart';
import '../../ui/tappable.dart';
import '../../ui/theme.dart';

/// What either index lists: the changes, or everything that was compared.
///
/// Two scopes, not four. The states inside a scope keep their sections — a
/// pill per state would spend the 300px column restating what the section
/// headers already say, and the one question a reader actually toggles is
/// *just the changes* against *prove you looked at the rest*.
enum IndexScope { changes, all }

/// The index's filter: a scope and a typed query.
class IndexFilter {
  const IndexFilter({this.scope = IndexScope.changes, this.query = ''});

  final IndexScope scope;
  final String query;

  IndexFilter withScope(IndexScope scope) =>
      IndexFilter(scope: scope, query: query);
  IndexFilter withQuery(String query) =>
      IndexFilter(scope: scope, query: query);

  bool matches(String id) =>
      query.isEmpty || id.toLowerCase().contains(query.toLowerCase());
}

/// The bar over either index: a search field, then the two scope pills.
///
/// The field-above-pills anatomy is the files tab's, three hundred pixels to
/// the left of this — a 280px column cannot seat pills and a search box on
/// one line (the test font proves it by overflowing), and a reader who has
/// learned one narrow index should not meet a second layout in the next.
class IndexFilterBar extends StatelessWidget {
  const IndexFilterBar({
    super.key,
    required this.filter,
    required this.onFilter,
    required this.changes,
    required this.all,
  });

  final IndexFilter filter;
  final ValueChanged<IndexFilter> onFilter;

  /// How many rows carry a finding, and how many were compared at all — the
  /// counts live on the pills so the scope says what it hides before it is
  /// chosen.
  final int changes;
  final int all;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      FwSpacing.lg,
      FwSpacing.sm,
      FwSpacing.lg,
      FwSpacing.sm,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FwSearchBox(
          hint: 'Filter…',
          onChanged: (query) => onFilter(filter.withQuery(query)),
        ),
        const Gap(FwSpacing.sm),
        Wrap(
          spacing: FwSpacing.xs,
          runSpacing: FwSpacing.xs,
          children: [
            FwPill(
              label: 'Changes $changes',
              selected: filter.scope == IndexScope.changes,
              onTap: () => onFilter(filter.withScope(IndexScope.changes)),
            ),
            FwPill(
              label: 'All $all',
              selected: filter.scope == IndexScope.all,
              onTap: () => onFilter(filter.withScope(IndexScope.all)),
            ),
          ],
        ),
      ],
    ),
  );
}

/// The rows a rule removed, folded to one line.
///
/// Demoted, not deleted — but demoted used to mean *fully drawn under a
/// header*, and a reader who had just hidden two rows met the same two rows
/// with a caption over them: the list never got shorter, which was the whole
/// point of the rule. The fact of the hiding is what must stay visible, and
/// one line carries it; the rows themselves are one click away.
class HiddenRows extends StatefulWidget {
  const HiddenRows({super.key, required this.count, required this.children});

  final int count;
  final List<Widget> children;

  @override
  State<HiddenRows> createState() => _HiddenRowsState();
}

class _HiddenRowsState extends State<HiddenRows> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var count = widget.count;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FwSpacing.xl,
            FwSpacing.lg,
            FwSpacing.xl,
            FwSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$count hidden by rules',
                  style: context.type.micro.copyWith(color: colors.mut),
                ),
              ),
              Tappable(
                onTap: () => setState(() => _open = !_open),
                child: Text(
                  _open ? 'Hide' : 'Show',
                  style: context.type.micro.copyWith(color: colors.accentDark),
                ),
              ),
            ],
          ),
        ),
        if (_open) ...widget.children,
      ],
    );
  }
}
