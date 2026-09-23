import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';

import '../address/address_scope.dart';
import '../plugins/native/dependencies_address.dart';

import 'package:pub_scores/pub_scores.dart';

import '../ui/action_button.dart';
import '../ui/column_layout.dart';
import '../ui/empty_state.dart';
import '../ui/panel_header.dart';
import '../ui/table.dart';
import '../ui/theme.dart';
import '../utils/async_value.dart';
import '../utils/value_stream_builder.dart';
import 'detail.dart';
import 'model/package_origin.dart';
import 'model/service.dart';
import 'upgrades.dart';
import 'utils.dart';
import '../ui/error_state.dart';
import '../ui/tappable.dart';

class DependenciesScreen extends StatefulWidget {
  final DependenciesService dependencies;

  /// The package this panel is showing — the first plugin-level segment, and
  /// the head of every segment list written from here.
  final String package;

  const DependenciesScreen(
    this.dependencies, {
    required this.package,
    super.key,
  });

  @override
  State<DependenciesScreen> createState() => _DependenciesScreenState();
}

/// Holds the list's presentation state so it survives opening a dependency and
/// coming back — the detail page replaces the list widget entirely, so anything
/// kept down there would be lost on every round trip.
class _DependenciesScreenState extends State<DependenciesScreen> {
  final _searchController = TextEditingController();
  var _kinds = {DependencyKind.direct, DependencyKind.dev};
  var _sort = const FwTableSort(DependencySort.name);
  var _layout = const ColumnLayout();

  @override
  Widget build(BuildContext context) => _screen(context);

  /// Reading the segments subscribes to the segments, so an axis or a knob
  /// moving does not rebuild this.
  Widget _screen(BuildContext context) {
    var place = dependencyPlace(AddressScope.segments(context));
    if (place == null) return _DependencyListScreen(this);
    if (place.upgrade) return DependenciesUpgradeScreen();
    if (place.dependency case var dependency?) {
      return DependencyDetailScreen(widget.dependencies, dependency);
    }
    return _DependencyListScreen(this);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
}

/// The sort keys the table reports back through [FwTable.onSort]. Opaque to the
/// table, meaningful only to [visibleDependencies].
abstract final class DependencySort {
  static const name = 'name';
  static const kind = 'kind';
  static const origin = 'origin';
  static const version = 'version';
  static const pub = 'pub';
  static const github = 'github';
}

/// The rows the table should show: filtered by kind and query, then sorted.
///
/// Lives outside the widget because it is the only real logic on this screen —
/// the table itself is a pure view that renders whatever order it is handed,
/// which is what makes this worth testing on its own.
List<Dependency> visibleDependencies(
  Iterable<Dependency> all, {
  required Set<DependencyKind> kinds,
  required String query,
  required FwTableSort sort,
  PubScores? scores,
}) {
  var needle = query.trim().toLowerCase();
  var filtered = all.where((dependency) {
    if (!kinds.contains(dependency.kind)) return false;
    return needle.isEmpty || dependency.name.toLowerCase().contains(needle);
  });

  return filtered.sortedByCompare<Comparable>(
    (dependency) => _sortValue(dependency, sort.key, scores),
    sort.ascending ? (a, b) => a.compareTo(b) : (a, b) => b.compareTo(a),
  );
}

Comparable _sortValue(Dependency dependency, String key, PubScores? scores) {
  var score = scores?[dependency.name];
  return switch (key) {
    // By declaration order of the enum — direct, dev, transitive — which is
    // the order of decreasing "this is mine", not alphabetical.
    DependencySort.kind => dependency.kind.index,
    DependencySort.origin => dependency.origin.label,
    DependencySort.version => dependency.resolvedVersion,
    // Missing scores sort below zero rather than above everything, so an
    // unrated package does not top a descending sort by downloads.
    DependencySort.pub => score?.pub.downloadCount30Days ?? -1,
    DependencySort.github => score?.github?.starCount ?? -1,
    _ => dependency.name,
  };
}

class _DependencyListScreen extends StatefulWidget {
  final _DependenciesScreenState parent;

  const _DependencyListScreen(this.parent);

  @override
  State<_DependencyListScreen> createState() => _DependencyListScreenState();
}

class _DependencyListScreenState extends State<_DependencyListScreen> {
  DependenciesService get dependencies => widget.parent.widget.dependencies;

  TextEditingController get _searchController =>
      widget.parent._searchController;

  Set<DependencyKind> get _kinds => widget.parent._kinds;
  set _kinds(Set<DependencyKind> v) => widget.parent._kinds = v;

  FwTableSort get _sort => widget.parent._sort;
  set _sort(FwTableSort v) => widget.parent._sort = v;

  ColumnLayout get _layout => widget.parent._layout;
  set _layout(ColumnLayout v) => widget.parent._layout = v;

  @override
  Widget build(BuildContext context) {
    return ValueStreamBuilder<Snapshot<Dependencies>>(
      stream: dependencies.dependencies.snapshots,
      builder: (context, snapshot, child) {
        return ValueStreamBuilder<Snapshot<PubScores>>(
          stream: dependencies.pubScores.snapshots,
          builder: (context, scores, child) =>
              _screen(context, snapshot, scores.data),
        );
      },
    );
  }

  /// A column, not a `ListView`.
  ///
  /// The table virtualizes, which it cannot do inside a scrollable that offers
  /// it unbounded height — and the old screen did exactly that, wrapping a
  /// `DataTable` in a `SizedBox` whose height was `rowCount * rowHeight`. So the
  /// page owns the viewport and the table scrolls within it.
  Widget _screen(
    BuildContext context,
    Snapshot<Dependencies> snapshot,
    PubScores? scores,
  ) {
    var package = widget.parent.widget.package;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The package, not "Dependencies" — the rail says that already, and
        // this panel exists once per package.
        FwPanelHeader(
          package == '.' ? 'root' : package,
          // `refreshOrThrow`, not `refresh`: the button reports what it is
          // handed, and `refresh` resolves to a Snapshot carrying its own error
          // rather than throwing — which would show a tick for a resolve that
          // failed.
          trailing: FwActionButton(
            label: 'Reload',
            tooltip: 'Resolve the package graph again',
            onPressed: dependencies.dependencies.refreshOrThrow,
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              panelGutter,
              0,
              panelGutter,
              FwSpacing.lg,
            ),
            child: _card(snapshot, scores),
          ),
        ),
      ],
    );
  }

  Widget _card(Snapshot<Dependencies> snapshot, PubScores? scores) {
    var data = snapshot.data;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _toolbar(data),
          Expanded(child: _table(snapshot, scores)),
        ],
      ),
    );
  }

  Widget _table(Snapshot<Dependencies> snapshot, PubScores? scores) {
    var data = snapshot.data;
    var rows = data == null
        ? <Dependency>[]
        : visibleDependencies(
            data.dependencies,
            kinds: _kinds,
            query: _searchController.text,
            sort: _sort,
            scores: scores,
          );

    return FwTable<Dependency>(
      rows: rows,
      columns: _layout.apply(_columns(scores)),
      sort: _sort,
      columnWidths: _layout.widths,
      loading: snapshot.isLoading,
      onSort: (key, ascending) => setState(() {
        _sort = FwTableSort(key, ascending: ascending);
      }),
      onHideColumn: (key) =>
          setState(() => _layout = _layout.withVisible(key, false)),
      onColumnResize: (key, width) =>
          setState(() => _layout = _layout.withWidth(key, width)),
      onRowTap: (dependency) {
        AddressScope.write(context).setSegments(
          dependencySegments(
            widget.parent.widget.package,
            dependency: dependency.name,
          ),
        );
      },
      error: snapshot.error == null
          ? null
          : ErrorState(
              title: 'Could not load dependencies',
              message: '${snapshot.error}',
              onRetry: dependencies.dependencies.refresh,
            ),
      empty: EmptyState(
        icon: Icons.inventory_2_outlined,
        title: _searchController.text.isNotEmpty
            ? 'No package matches "${_searchController.text}"'
            : 'Nothing to show',
        message: _kinds.isEmpty
            ? 'Every kind is filtered out.'
            : 'Try a different filter.',
      ),
    );
  }

  List<FwTableColumn<Dependency>> _columns(PubScores? scores) => [
    FwTableColumn(
      label: 'PACKAGE',
      sortKey: DependencySort.name,
      flex: 3,
      minWidth: 160,
      pinned: true,
      hideable: false,
      cell: (dependency) => Text(
        dependency.name,
        style: context.type.bodyStrong,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    FwTableColumn(
      label: 'TYPE',
      sortKey: DependencySort.kind,
      fixed: 110,
      cell: (dependency) => _KindBadge(dependency.kind),
    ),
    FwTableColumn(
      label: 'ORIGIN',
      sortKey: DependencySort.origin,
      flex: 2,
      minWidth: 120,
      cell: (dependency) => _OriginCell(dependency.origin),
    ),
    FwTableColumn(
      label: 'CONSTRAINT',
      fixed: 120,
      cell: (dependency) => Text(
        // A transitive package was declared by nobody here, so there is no
        // constraint to show — as opposed to one declared as `any`.
        dependency.constraint ?? '',
        style: context.type.bodyMuted,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    FwTableColumn(
      label: 'RESOLVED',
      sortKey: DependencySort.version,
      fixed: 110,
      cell: (dependency) => Text(
        dependency.hasMeaningfulVersion ? dependency.resolvedVersion : '—',
        style: context.type.bodyMuted,
      ),
    ),
    FwTableColumn(
      label: 'PUB',
      sortKey: DependencySort.pub,
      fixed: 90,
      cell: (dependency) => _PubCell(dependency, scores),
    ),
    FwTableColumn(
      label: 'GITHUB',
      sortKey: DependencySort.github,
      fixed: 90,
      cell: (dependency) => _GithubCell(dependency, scores),
    ),
  ];

  Widget _toolbar(Dependencies? data) {
    var colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.tableHeader,
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      padding: const EdgeInsets.all(FwSpacing.md),
      // The search box gives up width before the filters do, and the filters
      // scroll rather than overflow. A fixed 300 plus a `Spacer` blew past the
      // right edge by 107px at a 700pt window — narrow, but a window this app
      // can absolutely be dragged to.
      child: Row(
        children: [
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: _searchField(),
            ),
          ),
          const Gap(FwSpacing.lg),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  // Three counts, three toggles. The old control was a single
                  // "Show all" checkbox, which could not express "dev only" — a
                  // distinction the model only started making once it read the
                  // real resolution.
                  for (var kind in DependencyKind.values) ...[
                    _KindFilter(
                      kind: kind,
                      count: data == null ? null : _countOf(data, kind),
                      selected: _kinds.contains(kind),
                      onChanged: (selected) => setState(() {
                        _kinds = {
                          for (var k in DependencyKind.values)
                            if (k == kind ? selected : _kinds.contains(k)) k,
                        };
                      }),
                    ),
                    const Gap(FwSpacing.xs),
                  ],
                  if (_layout.hidden.isNotEmpty)
                    TextButton(
                      onPressed: () => setState(
                        () => _layout = ColumnLayout(widths: _layout.widths),
                      ),
                      child: Text(
                        'Show ${_layout.hidden.length} hidden column'
                        '${_layout.hidden.length > 1 ? 's' : ''}',
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static int _countOf(Dependencies data, DependencyKind kind) => switch (kind) {
    DependencyKind.direct => data.directs.length,
    DependencyKind.dev => data.devs.length,
    DependencyKind.transitive => data.transitives.length,
  };

  Widget _searchField() {
    return TextFormField(
      controller: _searchController,
      decoration: InputDecoration(
        hintText: 'Search by name',
        prefixIcon: Icon(Icons.search),
        suffixIconConstraints: BoxConstraints(minHeight: 30),
        suffixIcon: _searchController.text.isNotEmpty
            ? IconButton(
                constraints: BoxConstraints(minHeight: 30, minWidth: 48),
                padding: EdgeInsets.zero,
                onPressed: () => setState(() => _searchController.text = ''),
                icon: Icon(Icons.clear),
              )
            : null,
      ),
      onChanged: (_) => setState(() {}),
    );
  }
}

/// One kind, its count, and whether it is showing.
class _KindFilter extends StatelessWidget {
  final DependencyKind kind;
  final int? count;
  final bool selected;
  final ValueChanged<bool> onChanged;

  const _KindFilter({
    required this.kind,
    required this.count,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var tone = _kindColor(context, kind);
    // [Tappable], not [InkWell]: the chip fills itself opaquely (`panel` when
    // it is off, a status tint when it is on), and a [Material] paints its ink
    // *below* its child — so the wash was drawn and then covered, and this
    // chip answered a pointer with nothing at all. [Tappable] paints inside
    // its own subtree, over the fill.
    return Tappable(
      borderRadius: BorderRadius.circular(context.radii.radiusLarge),
      onTap: () => onChanged(!selected),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.md,
          vertical: FwSpacing.sm,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(context.radii.radiusLarge),
          color: selected ? colors.statusFill(tone) : colors.panel,
          border: Border.all(
            color: selected ? colors.statusBorder(tone) : colors.line,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? Icons.check_box : Icons.check_box_outline_blank,
              size: FwIconSize.sm,
              color: selected ? tone : colors.mut2,
            ),
            const Gap(FwSpacing.xs),
            Text(
              count == null ? _kindLabel(kind) : '${_kindLabel(kind)} $count',
              style: context.type.caption.copyWith(
                color: selected ? colors.ink : colors.mut,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _kindLabel(DependencyKind kind) => switch (kind) {
  DependencyKind.direct => 'Direct',
  DependencyKind.dev => 'Dev',
  DependencyKind.transitive => 'Transitive',
};

Color _kindColor(BuildContext context, DependencyKind kind) => switch (kind) {
  DependencyKind.direct => context.colors.grn,
  DependencyKind.dev => context.colors.amber,
  DependencyKind.transitive => context.colors.mut,
};

class _KindBadge extends StatelessWidget {
  final DependencyKind kind;

  const _KindBadge(this.kind);

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var tone = _kindColor(context, kind);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.md,
        vertical: FwSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: colors.statusFill(tone),
        border: Border.all(color: colors.statusBorder(tone)),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      child: Text(
        _kindLabel(kind),
        style: context.type.micro.copyWith(color: tone),
      ),
    );
  }
}

/// Where the package came from.
///
/// An ordinary pub.dev package is the boring case and reads as plain muted
/// text; anything else — a git repo, a path, the SDK — gets a chip, because
/// noticing those is most of the reason to look at this column at all.
class _OriginCell extends StatelessWidget {
  final PackageOrigin origin;

  const _OriginCell(this.origin);

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var detail = origin.detail;

    if (origin is HostedOrigin && (origin as HostedOrigin).isPubDev) {
      return Text('pub.dev', style: context.type.bodyMuted);
    }

    var label = detail == null ? origin.label : '${origin.label} · $detail';
    return Tooltip(
      message: _tooltip(),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.md,
          vertical: FwSpacing.xxs,
        ),
        decoration: BoxDecoration(
          color: colors.panel2,
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        ),
        child: Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: context.type.micro,
        ),
      ),
    );
  }

  String _tooltip() => switch (origin) {
    GitOrigin git => [
      git.url,
      ?git.shortRef,
      if (git.subPath case var path?) 'in $path',
    ].join('\n'),
    PathOrigin path =>
      path.relative
          ? path.path
          : '${path.path}\n(absolute — this will not resolve elsewhere)',
    HostedOrigin hosted => hosted.server,
    SdkOrigin sdk => 'Ships with the ${sdk.sdk} SDK',
    WorkspaceOrigin() => 'A member of this workspace',
    UnknownOrigin unknown => 'Unrecognised source: ${unknown.source}',
  };
}

class _PubCell extends StatelessWidget {
  final Dependency dependency;
  final PubScores? pubScores;

  const _PubCell(this.dependency, this.pubScores);

  @override
  Widget build(BuildContext context) {
    var pub = pubScores?[dependency.name]?.pub;
    if (pub == null) return const SizedBox();

    var number = NumberFormat.compact(locale: 'en_US');
    var downloads = pub.downloadCount30Days;
    var likeCount = pub.likeCount;
    var points = pub.grantedPoints;
    var message = [
      if (downloads != null)
        '${NumberFormat.decimalPattern('en_US').format(downloads)} downloads / 30d',
      '$likeCount like${likeCount > 1 ? 's' : ''}',
      if (points != null) '$points point${points > 1 ? 's' : ''}',
    ];

    return InkWell(
      onTap: () => openPub(dependency),
      child: Tooltip(
        message: message.join(' / '),
        child: Text(
          downloads == null ? '' : number.format(downloads),
          style: context.type.bodyMuted,
        ),
      ),
    );
  }
}

class _GithubCell extends StatelessWidget {
  final Dependency dependency;
  final PubScores? pubScores;

  const _GithubCell(this.dependency, this.pubScores);

  @override
  Widget build(BuildContext context) {
    var github = pubScores?[dependency.name]?.github;
    if (github == null) return const SizedBox();

    var starCount = github.starCount;
    var forkCount = github.forkCount;
    return InkWell(
      onTap: () => openGithub(github),
      child: Tooltip(
        message:
            '$starCount star${starCount > 1 ? 's' : ''}, '
            '$forkCount fork${forkCount > 1 ? 's' : ''}\n${github.slug}',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$starCount', style: context.type.bodyMuted),
            const Gap(FwSpacing.xxs),
            Icon(
              Icons.star_outline,
              size: FwIconSize.md,
              color: context.colors.mut,
            ),
          ],
        ),
      ),
    );
  }
}
