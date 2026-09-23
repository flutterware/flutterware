import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/plugins.dart' show Tone;
import 'package:url_launcher/url_launcher.dart';

import '../../inspect/inspect_dock.dart';
import '../../lints/model/classification.dart';
import '../../lints/model/issue_counts.dart';
import '../../lints/model/options_scan.dart';
import '../../lints/model/rule_catalog.dart';
import '../../ui/action_button.dart';
import '../../ui/empty_state.dart';
import '../../ui/error_state.dart';
import '../../ui/loading_state.dart';
import '../../ui/menu.dart';
import '../../ui/panel_header.dart';
import '../../ui/tappable.dart';
import '../../ui/theme.dart';
import '../native_plugin.dart';
import 'lints_core.dart';

const _controlHeight = 32.0;
const _rowHeight = 48.0;
const _fixColumn = 44.0;
const _issuesColumn = 76.0;
const _whyColumn = 320.0;

class LintsPlugin extends NativePlugin<LintsCore> {
  LintsPlugin(super.core);

  @override
  String? get busyWith {
    if (core.isCounting) return 'counting lint issues';
    if (core.isScanning) return 'scanning lint options';
    return null;
  }

  @override
  Widget buildPanel(BuildContext context) => _LintsPanel(plugin: this);
}

class _LintsPanel extends StatefulWidget {
  const _LintsPanel({required this.plugin});

  final LintsPlugin plugin;

  @override
  State<_LintsPanel> createState() => _LintsPanelState();
}

class _LintsPanelState extends State<_LintsPanel> {
  var _tab = LintBucket.unevaluated;
  var _query = '';
  var _sort = _Sort.newest;

  /// Selected options file, or null for the whole-repo union.
  String? _scope;

  LintsCore get _core => widget.plugin.core;

  @override
  void initState() {
    super.initState();
    _core.track();
  }

  // A config reload swaps the core under a mounted panel; tracking only in
  // initState goes permanently cold.
  @override
  void didUpdateWidget(covariant _LintsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _core.track();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.plugin,
      builder: (context, _) {
        var classification = _core.classification;
        if (classification == null) {
          var error = _core.error;
          if (error != null) {
            return ErrorState(
              title: 'Could not scan the lint options',
              message: error,
              onRetry: () => _core.reload(),
            );
          }
          return const LoadingState(title: 'Scanning options files…');
        }
        return _body(context, classification);
      },
    );
  }

  Widget _body(BuildContext context, LintsClassification classification) {
    var scan = _core.scan!;
    var scope = scan.files.firstWhereOrNull((f) => f.path == _scope);
    var buckets = _Buckets.of(classification, scope);
    var rows = _visibleRows(buckets.inBucket(_tab));
    var colors = context.colors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FwPanelHeader(
          'Lints',
          subtitle: _subtitle(classification),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: FwSpacing.md,
            children: [
              TextButton(
                onPressed: () => _core.reload(),
                child: const Text('Rescan'),
              ),
              FwActionButton(
                label: 'Count issues',
                primary: true,
                tooltip:
                    'One dart analyze run with every rule that is off '
                    'enabled — counts what each would flag today',
                onPressed: classification.hasCatalog && !_core.isCounting
                    ? () async {
                        await _core.countIssues();
                      }
                    : null,
              ),
            ],
          ),
        ),
        if (_core.countError case var error?) _ErrorBar(message: error),
        if (!classification.hasCatalog)
          _Advisory(
            message:
                'No rule catalog for Dart ${_core.dartVersion ?? '?'} yet — '
                'the first fetch needs the network. Local buckets still '
                'stand; nothing can be called unevaluated without it.',
          ),
        _Stats(classification: classification, core: _core),
        _FilesStrip(
          files: scan.files,
          selected: _scope,
          onSelect: (path) => setState(() => _scope = path),
        ),
        if (scope != null) _FileDetailLine(file: scope),
        InspectTabStrip(
          tabs: [
            for (var bucket in LintBucket.values)
              InspectDockTab(
                id: bucket.name,
                label: _tabLabel(bucket),
                badge: buckets.inBucket(bucket).length,
                body: (_) => const SizedBox.shrink(),
              ),
          ],
          current: _tab.name,
          onSelect: (id) => setState(() => _tab = LintBucket.values.byName(id)),
        ),
        Container(
          decoration: BoxDecoration(
            color: colors.panel2,
            border: Border(bottom: BorderSide(color: colors.line)),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.xl,
            vertical: FwSpacing.md,
          ),
          child: Row(
            spacing: FwSpacing.md,
            children: [
              _SearchField(
                onChanged: (value) => setState(() => _query = value),
              ),
              const Spacer(),
              if (_tab == LintBucket.unevaluated)
                _SortMenu(
                  current: _sort,
                  onSelect: (sort) => setState(() => _sort = sort),
                ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? EmptyState(
                  title: _query.isEmpty
                      ? _emptyTitle(_tab)
                      : 'Nothing matches "$_query"',
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ColumnHeader(
                      bucket: _tab,
                      counted: _core.issueCounts != null,
                    ),
                    Expanded(
                      child: _RuleList(
                        rows: rows,
                        bucket: _tab,
                        counts: _core.issueCounts?.counts,
                        onOpen: (row) => _openDialog(context, row),
                      ),
                    ),
                  ],
                ),
        ),
        _CountsFoot(core: _core),
      ],
    );
  }

  List<String> _subtitle(LintsClassification classification) {
    var version = _core.dartVersion;
    return [
      if (version != null) 'Dart ${version.split('-').first}',
      if (classification.hasCatalog) '${classification.universe} rules known',
    ];
  }

  String _tabLabel(LintBucket bucket) => switch (bucket) {
    LintBucket.enabled => 'Enabled',
    LintBucket.dismissed => 'Dismissed',
    LintBucket.mentioned => 'Mentioned',
    LintBucket.unevaluated => 'Unevaluated',
  };

  String _emptyTitle(LintBucket bucket) => switch (bucket) {
    LintBucket.unevaluated => 'Every rule here has been evaluated',
    LintBucket.enabled => 'Nothing enabled',
    LintBucket.dismissed => 'Nothing dismissed',
    LintBucket.mentioned => 'No commented-out rules',
  };

  List<ClassifiedLint> _visibleRows(Iterable<ClassifiedLint> rows) {
    var query = _query.trim().toLowerCase();
    var visible = [
      for (var row in rows)
        if (query.isEmpty ||
            row.name.contains(query) ||
            (row.rule?.description.toLowerCase().contains(query) ?? false))
          row,
    ];
    if (_tab == LintBucket.unevaluated) {
      var counts = _core.issueCounts?.counts;
      switch (_sort) {
        case _Sort.newest:
          visible.sort(compareBySinceDesc);
        case _Sort.fewestIssues:
          visible.sort((a, b) {
            var issuesA = counts?[a.name];
            var issuesB = counts?[b.name];
            if (issuesA != issuesB) {
              if (issuesA == null) return 1;
              if (issuesB == null) return -1;
              return issuesA.compareTo(issuesB);
            }
            return compareBySinceDesc(a, b);
          });
        case _Sort.az:
          visible.sort((a, b) => a.name.compareTo(b.name));
      }
    } else {
      visible.sort((a, b) => a.name.compareTo(b.name));
    }
    return visible;
  }

  void _openDialog(BuildContext context, ClassifiedLint row) {
    showDialog<void>(
      context: context,
      builder: (context) => _RuleDialog(row: row, core: _core),
    );
  }
}

enum _Sort {
  newest('Newest first'),
  fewestIssues('Fewest issues'),
  az('A–Z');

  const _Sort(this.label);

  final String label;
}

/// The classification restricted to one options file, or the union when
/// [scope] is null.
///
/// Per-file semantics reuse the union objects (they carry the catalog info)
/// but re-bucket them: a rule dismissed at the root and unmentioned in a
/// severed vendored file is *unevaluated there*.
class _Buckets {
  final Map<LintBucket, List<ClassifiedLint>> _byBucket;

  _Buckets._(this._byBucket);

  List<ClassifiedLint> inBucket(LintBucket bucket) =>
      _byBucket[bucket] ?? const [];

  static _Buckets of(
    LintsClassification classification,
    LintOptionsFile? scope,
  ) {
    if (scope == null) {
      return _Buckets._({
        for (var bucket in LintBucket.values)
          bucket: classification.inBucket(bucket).toList(),
      });
    }
    var buckets = <LintBucket, List<ClassifiedLint>>{
      for (var bucket in LintBucket.values) bucket: [],
    };
    var enabled = scope.enabled;
    var ignored = {
      for (var entry in scope.severityOverrides.entries)
        if (entry.value == 'ignore') entry.key,
    };
    for (var rule in classification.rules) {
      LintBucket bucket;
      if (enabled.contains(rule.name)) {
        bucket = LintBucket.enabled;
      } else if (scope.effective.containsKey(rule.name) ||
          ignored.contains(rule.name)) {
        bucket = LintBucket.dismissed;
      } else if (scope.commentedOut.contains(rule.name)) {
        bucket = LintBucket.mentioned;
      } else if (rule.rule?.isActive ?? false) {
        bucket = LintBucket.unevaluated;
      } else {
        continue;
      }
      buckets[bucket]!.add(rule);
    }
    return _Buckets._(buckets);
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.classification, required this.core});

  final LintsClassification classification;
  final LintsCore core;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.xl,
        FwSpacing.lg,
        FwSpacing.xl,
        0,
      ),
      child: Wrap(
        spacing: FwSpacing.md,
        runSpacing: FwSpacing.md,
        children: [
          _StatTile(
            label: 'Unevaluated',
            value: '${classification.count(LintBucket.unevaluated)}',
            hero: true,
          ),
          _StatTile(
            label: 'Enabled',
            value: '${classification.count(LintBucket.enabled)}',
          ),
          _StatTile(
            label: 'Dismissed',
            value: '${classification.count(LintBucket.dismissed)}',
          ),
          _StatTile(
            label: 'Mentioned',
            value: '${classification.count(LintBucket.mentioned)}',
          ),
          if (core.issueCounts != null)
            _StatTile(
              label: 'No issues',
              value: '${core.unevaluatedWithoutIssues}',
            ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    this.hero = false,
  });

  final String label;
  final String value;
  final bool hero;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      width: 120,
      padding: const EdgeInsets.all(FwSpacing.lg),
      decoration: BoxDecoration(
        color: hero ? colors.accentSoft : colors.bg,
        border: Border.all(color: hero ? Colors.transparent : colors.line),
        borderRadius: BorderRadius.circular(context.radii.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: context.type.heading.copyWith(
              color: hero ? colors.accent : null,
            ),
          ),
          Text(
            label.toUpperCase(),
            style: context.type.micro.copyWith(
              color: hero ? colors.accent : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _FilesStrip extends StatelessWidget {
  const _FilesStrip({
    required this.files,
    required this.selected,
    required this.onSelect,
  });

  final List<LintOptionsFile> files;
  final String? selected;
  final void Function(String? path) onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.xl,
        FwSpacing.lg,
        FwSpacing.xl,
        FwSpacing.sm,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          spacing: FwSpacing.sm,
          children: [
            _FileCard(
              title: 'Whole repo',
              detail: '${files.length} options files · union view',
              selected: selected == null,
              onTap: () => onSelect(null),
            ),
            for (var file in files)
              _FileCard(
                title: file.path,
                mono: true,
                detail: file.hasInclude
                    ? '→ ${file.includeChain.join(' → ')}'
                    : 'no include',
                tooltip: file.hasInclude
                    ? 'includes ${file.includeChain.join(' → ')}'
                    : 'No include: this file inherits nothing — every rule an '
                          'ancestor enabled is off underneath it.',
                warn: !file.hasInclude ? 'inherits nothing' : null,
                error: file.includeErrors.isNotEmpty
                    ? 'unresolved include'
                    : null,
                selected: selected == file.path,
                onTap: () => onSelect(file.path),
              ),
          ],
        ),
      ),
    );
  }
}

/// The selected file's chain, whole — the cards truncate it, and a chain that
/// is only ever visible truncated cannot be read.
class _FileDetailLine extends StatelessWidget {
  const _FileDetailLine({required this.file});

  final LintOptionsFile file;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var parts = <InlineSpan>[
      TextSpan(
        text: file.path,
        style: context.type.mono.copyWith(fontWeight: FontWeight.w600),
      ),
      TextSpan(
        text: file.hasInclude
            ? '  →  ${file.includeChain.join('  →  ')}'
            : '  ·  no include — inherits nothing',
        style: context.type.caption,
      ),
      TextSpan(
        text:
            '  ·  ${file.mentions.length} configured here · '
            '${file.enabled.length} effectively on',
        style: context.type.caption.copyWith(color: colors.mut2),
      ),
      for (var error in file.includeErrors)
        TextSpan(
          text: '  ·  could not resolve $error',
          style: context.type.caption.copyWith(color: colors.red),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.xl,
        0,
        FwSpacing.xl,
        FwSpacing.md,
      ),
      child: SelectableText.rich(TextSpan(children: parts)),
    );
  }
}

class _FileCard extends StatelessWidget {
  const _FileCard({
    required this.title,
    required this.detail,
    required this.selected,
    required this.onTap,
    this.mono = false,
    this.tooltip,
    this.warn,
    this.error,
  });

  final String title;
  final String detail;
  final bool selected;
  final VoidCallback onTap;
  final bool mono;
  final String? tooltip;
  final String? warn;
  final String? error;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var card = Tappable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.radii.radius),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.lg,
          vertical: FwSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: selected ? colors.accentSoft2 : colors.panel2,
          border: Border.all(color: selected ? colors.accent : colors.line),
          borderRadius: BorderRadius.circular(context.radii.radius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: FwSpacing.sm,
              children: [
                Flexible(
                  child: Text(
                    title,
                    style: mono
                        ? context.type.mono.copyWith(
                            fontWeight: FontWeight.w600,
                          )
                        : context.type.bodySmall.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (warn case var warn?) _WarnChip(label: warn),
                if (error case var error?)
                  _WarnChip(label: error, tone: Tone.error),
              ],
            ),
            Text(
              detail,
              style: context.type.caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
    if (tooltip == null) return card;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: card,
    );
  }
}

class _WarnChip extends StatelessWidget {
  const _WarnChip({required this.label, this.tone = Tone.warn});

  final String label;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var color = tone == Tone.error ? colors.red : colors.warningText;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.xs),
      decoration: BoxDecoration(
        color: colors.statusFill(color),
        borderRadius: BorderRadius.circular(context.radii.micro),
      ),
      child: Text(label, style: context.type.micro.copyWith(color: color)),
    );
  }
}

/// The list's column captions — which columns exist depends on the bucket,
/// and the fixed widths here are the same constants the rows use, which is
/// what keeps a caption over its column.
class _ColumnHeader extends StatelessWidget {
  const _ColumnHeader({required this.bucket, required this.counted});

  final LintBucket bucket;
  final bool counted;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var style = context.type.micro.copyWith(color: colors.mut2);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.xs,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Row(
        spacing: FwSpacing.lg,
        children: [
          SizedBox(width: 36, child: Text('SINCE', style: style)),
          Expanded(child: Text('RULE', style: style)),
          ...switch (bucket) {
            LintBucket.unevaluated => [
              SizedBox(
                width: _fixColumn,
                child: Text('FIX', style: style),
              ),
              if (counted)
                SizedBox(
                  width: _issuesColumn,
                  child: Text(
                    'ISSUES',
                    style: style,
                    textAlign: TextAlign.right,
                  ),
                ),
            ],
            LintBucket.enabled => [Text('FROM', style: style)],
            LintBucket.dismissed => [
              SizedBox(
                width: _whyColumn,
                child: Text('WHY', style: style),
              ),
              if (counted)
                SizedBox(
                  width: _issuesColumn,
                  child: Text(
                    'HIDING',
                    style: style,
                    textAlign: TextAlign.right,
                  ),
                ),
            ],
            LintBucket.mentioned => [
              if (counted)
                SizedBox(
                  width: _issuesColumn,
                  child: Text(
                    'ISSUES',
                    style: style,
                    textAlign: TextAlign.right,
                  ),
                ),
            ],
          },
        ],
      ),
    );
  }
}

class _RuleList extends StatelessWidget {
  const _RuleList({
    required this.rows,
    required this.bucket,
    required this.counts,
    required this.onOpen,
  });

  final List<ClassifiedLint> rows;
  final LintBucket bucket;
  final Map<String, int>? counts;
  final void Function(ClassifiedLint row) onOpen;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemExtent: _rowHeight,
      itemCount: rows.length,
      itemBuilder: (context, index) => _RuleRow(
        row: rows[index],
        bucket: bucket,
        counts: counts,
        onOpen: onOpen,
      ),
    );
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({
    required this.row,
    required this.bucket,
    required this.counts,
    required this.onOpen,
  });

  final ClassifiedLint row;
  final LintBucket bucket;
  final Map<String, int>? counts;
  final void Function(ClassifiedLint row) onOpen;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var rule = row.rule;
    return Tappable(
      onTap: () => onOpen(row),
      child: Container(
        height: _rowHeight,
        padding: const EdgeInsets.symmetric(horizontal: FwSpacing.xl),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.line2)),
        ),
        child: Row(
          spacing: FwSpacing.lg,
          children: [
            SizedBox(
              width: 36,
              child: Text(
                rule?.sinceDartSdk ?? '',
                style: context.type.caption.copyWith(
                  color: colors.mut2,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: FwSpacing.sm,
                    children: [
                      Flexible(
                        child: Text(
                          row.name,
                          style: context.type.mono.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (rule?.state == 'experimental')
                        const _WarnChip(label: 'EXP'),
                      if (rule != null &&
                          (rule.state == 'deprecated' ||
                              rule.state == 'removed'))
                        _WarnChip(label: rule.state, tone: Tone.error),
                    ],
                  ),
                  if (rule?.description case var description?)
                    Text(
                      description,
                      style: context.type.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            ..._trailing(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _trailing(BuildContext context) {
    var colors = context.colors;
    var counted = counts != null;
    var issues = counts?[row.name];
    var issuesCell = counted
        ? SizedBox(
            width: _issuesColumn,
            child: Align(
              alignment: Alignment.centerRight,
              child: issues == null
                  ? Text(
                      '—',
                      style: context.type.caption.copyWith(color: colors.mut3),
                    )
                  : _IssuesPill(issues: issues),
            ),
          )
        : null;
    switch (bucket) {
      case LintBucket.unevaluated:
        return [
          SizedBox(
            width: _fixColumn,
            child: row.rule?.fixStatus == 'hasFix'
                ? Text(
                    'fix',
                    style: context.type.caption.copyWith(color: colors.grn),
                  )
                : const SizedBox.shrink(),
          ),
          ?issuesCell,
        ];
      case LintBucket.enabled:
        return [
          Text(
            row.enabledVia ?? '',
            style: context.type.caption,
            overflow: TextOverflow.ellipsis,
          ),
        ];
      case LintBucket.dismissed:
        return [
          SizedBox(
            width: _whyColumn,
            child: Text(
              row.comment != null
                  ? '# ${row.comment}'
                  : 'no comment — dismissed without a why',
              style: context.type.caption.copyWith(fontStyle: FontStyle.italic),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ?issuesCell,
        ];
      case LintBucket.mentioned:
        return [?issuesCell];
    }
  }
}

class _IssuesPill extends StatelessWidget {
  const _IssuesPill({required this.issues});

  final int issues;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var color = issues == 0 ? colors.grn : colors.warningText;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.md),
      decoration: BoxDecoration(
        color: colors.statusFill(color),
        borderRadius: BorderRadius.circular(context.radii.pill),
      ),
      child: Text(
        '$issues',
        style: context.type.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _CountsFoot extends StatelessWidget {
  const _CountsFoot({required this.core});

  final LintsCore core;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var counts = core.issueCounts;
    String text;
    if (core.isCounting) {
      text = 'Counting — one dart analyze run over the repo…';
    } else if (counts == null) {
      text =
          'Not counted yet — "Count issues" reports what every rule that is '
          'off would flag today, in one analyzer run.';
    } else {
      var elapsed = (counts.elapsed.inMilliseconds / 1000).toStringAsFixed(1);
      text =
          'Counted ${_ago(counts.at)} · ${elapsed}s · '
          '${core.unevaluatedWithoutIssues} unevaluated rules report nothing '
          'today'
          '${core.countsAreStale ? ' · stale — the rule set changed' : ''}';
    }
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.panel2,
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: Row(
        spacing: FwSpacing.sm,
        children: [
          if (core.isCounting)
            SizedBox(
              width: FwIconSize.xs,
              height: FwIconSize.xs,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.accent,
              ),
            ),
          Expanded(child: Text(text, style: context.type.caption)),
        ],
      ),
    );
  }

  String _ago(DateTime at) {
    var delta = DateTime.now().difference(at);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inHours < 1) return '${delta.inMinutes}m ago';
    if (delta.inDays < 1) return '${delta.inHours}h ago';
    return '${delta.inDays}d ago';
  }
}

class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.sm,
      ),
      color: colors.red.withValues(alpha: .12),
      child: SelectableText(
        message,
        style: context.type.bodySmall.copyWith(color: colors.red),
      ),
    );
  }
}

class _Advisory extends StatelessWidget {
  const _Advisory({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.sm,
      ),
      color: colors.amber.withValues(alpha: .10),
      child: Row(
        spacing: FwSpacing.sm,
        children: [
          Icon(
            Icons.info_outline,
            size: FwIconSize.sm,
            color: colors.warningText,
          ),
          Expanded(
            child: Text(
              message,
              style: context.type.bodySmall.copyWith(color: colors.warningText),
            ),
          ),
        ],
      ),
    );
  }
}

/// Kills every `InputDecoration` border state: the app's
/// `inputDecorationTheme` sets `enabledBorder`/`focusedBorder`, which beat
/// `border`, so the wrapping container owns the whole look.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.onChanged});

  final void Function(String value) onChanged;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      width: 260,
      height: _controlHeight,
      decoration: BoxDecoration(
        color: colors.bg,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.md),
      child: Row(
        spacing: FwSpacing.sm,
        children: [
          Icon(Icons.search, size: FwIconSize.sm, color: colors.mut2),
          Expanded(
            child: TextField(
              onChanged: onChanged,
              style: context.type.bodySmall,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Filter rules…',
                hintStyle: context.type.bodySmall.copyWith(color: colors.mut2),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One dropdown, not a row of chips — a chip row beside a filter field reads
/// as more filters.
class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.current, required this.onSelect});

  final _Sort current;
  final void Function(_Sort sort) onSelect;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Menu(
      entries: [
        for (var sort in _Sort.values)
          MenuItem(sort.label, onSelected: () => onSelect(sort)),
      ],
      builder: (context, controller) => Tappable(
        onTap: controller.toggle,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        child: Container(
          height: _controlHeight,
          padding: const EdgeInsets.only(
            left: FwSpacing.lg,
            right: FwSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: colors.bg,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(context.radii.radiusSmall),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Sort: ${current.label}',
                style: context.type.bodySmall.copyWith(color: colors.ink2),
              ),
              Icon(
                Icons.arrow_drop_down,
                size: FwIconSize.lg,
                color: colors.mut,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RuleDialog extends StatelessWidget {
  const _RuleDialog({required this.row, required this.core});

  final ClassifiedLint row;
  final LintsCore core;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var rule = row.rule;
    var issues = row.bucket == LintBucket.enabled
        ? null
        : core.issueCounts?.counts[row.name];
    var samples = core.issueCounts?.samples[row.name] ?? const [];
    return Dialog(
      backgroundColor: colors.bg,
      insetPadding: const EdgeInsets.all(FwSpacing.xxxl),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            FwSpacing.xxl,
            FwSpacing.xxl,
            FwSpacing.xxl,
            FwSpacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      row.name,
                      style: context.type.mono.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        launchUrl(Uri.https('dart.dev', '/lints/${row.name}')),
                    icon: Icon(Icons.open_in_new, size: FwIconSize.sm),
                    label: const Text('dart.dev'),
                  ),
                  const Gap(FwSpacing.md),
                  Tappable(
                    onTap: () => Navigator.of(context).pop(),
                    child: Icon(
                      Icons.close,
                      size: FwIconSize.md,
                      color: colors.mut,
                    ),
                  ),
                ],
              ),
              const Gap(FwSpacing.md),
              Wrap(
                spacing: FwSpacing.sm,
                runSpacing: FwSpacing.xs,
                children: [
                  _Chip(label: row.bucket.name),
                  if (rule != null) ...[
                    _Chip(label: 'since Dart ${rule.sinceDartSdk}'),
                    if (rule.state != 'stable') _Chip(label: rule.state),
                    _Chip(label: _fixLabel(rule.fixStatus)),
                    for (var category in rule.categories)
                      _Chip(label: category),
                  ],
                  if (issues != null)
                    _Chip(
                      label: issues == 0
                          ? 'no issues in this repo today'
                          : issues == 1
                          ? 'flags 1 issue today'
                          : 'flags $issues issues today',
                      tone: issues == 0 ? Tone.good : Tone.warn,
                    ),
                ],
              ),
              const Gap(FwSpacing.xl),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (rule != null && rule.details.isNotEmpty)
                        ..._LintDoc.render(context, rule.details)
                      else if (rule != null)
                        Text(rule.description, style: context.type.body),
                      if (samples.isNotEmpty) ...[
                        const Gap(FwSpacing.xl),
                        _sectionLabel(context, 'Seen in this repo'),
                        const Gap(FwSpacing.sm),
                        _Samples(samples: samples, issues: issues ?? 0),
                      ],
                      if (rule != null && rule.incompatible.isNotEmpty) ...[
                        const Gap(FwSpacing.xl),
                        _sectionLabel(context, 'Incompatible with'),
                        const Gap(FwSpacing.sm),
                        _Incompatible(rule: rule, core: core),
                      ],
                      const Gap(FwSpacing.xl),
                      _sectionLabel(context, 'Where it stands'),
                      const Gap(FwSpacing.sm),
                      _WhereItStands(row: row, core: core),
                      const Gap(FwSpacing.lg),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fixLabel(String fixStatus) => switch (fixStatus) {
    'hasFix' => 'has quick fix',
    'needsFix' => 'fix planned',
    'noFix' => 'no quick fix',
    _ => fixStatus,
  };

  Widget _sectionLabel(BuildContext context, String label) => Text(
    label.toUpperCase(),
    style: context.type.micro.copyWith(color: context.colors.mut2),
  );
}

/// Renders a rule's `details` — markdown with fenced code examples — into the
/// shapes that matter: headings, paragraphs with inline `code` and **bold**,
/// and code fences. Links keep their text and lose their URL; the dialog's
/// dart.dev button is the way out.
abstract final class _LintDoc {
  static final _fence = RegExp(r'```\w*\n([\s\S]*?)```');
  static final _inline = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
  static final _link = RegExp(r'\[([^\]]+)\]\([^)]*\)');

  static List<Widget> render(BuildContext context, String details) {
    var colors = context.colors;
    var widgets = <Widget>[];

    void addText(String text) {
      var trimmed = text.trim();
      if (trimmed.isEmpty) return;
      for (var paragraph in trimmed.split(RegExp(r'\n{2,}'))) {
        var flat = _link.hasMatch(paragraph)
            ? paragraph.replaceAllMapped(_link, (m) => m.group(1)!)
            : paragraph;
        if (flat.startsWith('#')) {
          widgets.add(
            Padding(
              padding: const EdgeInsets.only(bottom: FwSpacing.md),
              child: Text(
                flat.replaceFirst(RegExp(r'^#+\s*'), ''),
                style: context.type.bodyStrong,
              ),
            ),
          );
          continue;
        }
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: FwSpacing.md),
            child: Text.rich(
              TextSpan(children: _spans(context, flat)),
              style: context.type.body,
            ),
          ),
        );
      }
    }

    var cursor = 0;
    for (var match in _fence.allMatches(details)) {
      addText(details.substring(cursor, match.start));
      widgets.add(
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: FwSpacing.md),
          padding: const EdgeInsets.all(FwSpacing.lg),
          decoration: BoxDecoration(
            color: colors.panel,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(context.radii.radiusSmall),
          ),
          child: SelectableText(
            match.group(1)!.trimRight(),
            style: context.type.mono,
          ),
        ),
      );
      cursor = match.end;
    }
    addText(details.substring(cursor));
    return widgets;
  }

  static List<InlineSpan> _spans(BuildContext context, String text) {
    var colors = context.colors;
    var spans = <InlineSpan>[];
    var cursor = 0;
    for (var match in _inline.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      if (match.group(1) case var bold?) {
        spans.add(
          TextSpan(
            text: bold,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        );
      } else if (match.group(2) case var code?) {
        spans.add(
          TextSpan(
            text: code,
            style: context.type.mono.copyWith(backgroundColor: colors.panel2),
          ),
        );
      }
      cursor = match.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return spans;
  }
}

/// Concrete findings from the last counting run — what the rule is actually
/// about in this repo's own code.
class _Samples extends StatelessWidget {
  const _Samples({required this.samples, required this.issues});

  final List<LintIssueSample> samples;
  final int issues;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var sample in samples)
          Padding(
            padding: const EdgeInsets.only(bottom: FwSpacing.xs),
            child: SelectableText.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${sample.file}:${sample.line}',
                    style: context.type.mono.copyWith(color: colors.accent),
                  ),
                  TextSpan(
                    text: '  ${sample.message}',
                    style: context.type.caption,
                  ),
                ],
              ),
              style: context.type.bodySmall,
            ),
          ),
        if (issues > samples.length)
          Text(
            'and ${issues - samples.length} more',
            style: context.type.caption.copyWith(color: colors.mut2),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.tone});

  final String label;
  final Tone? tone;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var color = switch (tone) {
      Tone.good => colors.grn,
      Tone.warn => colors.warningText,
      Tone.error => colors.red,
      _ => colors.mut,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.md),
      decoration: BoxDecoration(
        color: tone == null ? colors.panel : colors.statusFill(color),
        border: Border.all(
          color: tone == null ? colors.line : Colors.transparent,
        ),
        borderRadius: BorderRadius.circular(context.radii.pill),
      ),
      child: Text(
        label,
        style: context.type.caption.copyWith(
          color: color,
          fontWeight: tone == null ? null : FontWeight.w600,
        ),
      ),
    );
  }
}

class _Incompatible extends StatelessWidget {
  const _Incompatible({required this.rule, required this.core});

  final LintRule rule;
  final LintsCore core;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var classification = core.classification;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var name in rule.incompatible)
          Builder(
            builder: (context) {
              var other = classification?.rules.firstWhereOrNull(
                (r) => r.name == name,
              );
              var conflicts = other?.bucket == LintBucket.enabled;
              return Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: name, style: context.type.mono),
                    if (conflicts)
                      TextSpan(
                        text:
                            '  — enabled in this repo: turning this rule on '
                            'means turning that one off',
                        style: context.type.caption.copyWith(color: colors.red),
                      ),
                  ],
                ),
                style: context.type.bodySmall,
              );
            },
          ),
      ],
    );
  }
}

class _WhereItStands extends StatelessWidget {
  const _WhereItStands({required this.row, required this.core});

  final ClassifiedLint row;
  final LintsCore core;

  @override
  Widget build(BuildContext context) {
    var scan = core.scan;
    if (scan == null) return const SizedBox.shrink();
    var lines = <Widget>[];
    for (var file in scan.files) {
      var parts = <String>[];
      var mention = file.mentions[row.name];
      var decision = file.effective[row.name];
      if (mention != null) {
        parts.add(mention.enabled ? 'enabled here' : 'disabled here');
        if (mention.comment != null) parts.add('# ${mention.comment}');
      } else if (decision != null) {
        parts.add('${decision.enabled ? 'on' : 'off'} via ${decision.via}');
      }
      if (file.severityOverrides[row.name] == 'ignore') {
        parts.add('severity: ignore');
      }
      if (file.commentedOut.contains(row.name)) parts.add('commented out');
      if (parts.isEmpty) continue;
      lines.add(
        Padding(
          padding: const EdgeInsets.only(bottom: FwSpacing.xs),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: file.path, style: context.type.mono),
                TextSpan(
                  text: '  ${parts.join(' · ')}',
                  style: context.type.caption,
                ),
              ],
            ),
            style: context.type.bodySmall,
          ),
        ),
      );
    }
    if (lines.isEmpty) {
      return Text(
        'Mentioned in none of the ${scan.files.length} options files.',
        style: context.type.bodyMuted,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines,
    );
  }
}
