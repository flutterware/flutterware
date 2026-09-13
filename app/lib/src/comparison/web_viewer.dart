import 'dart:async';
import 'dart:convert';

import 'package:flutterware/comparison_report.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../capture/settle.dart';
import '../ui/empty_state.dart';
import '../ui/age.dart';
import '../ui/theme.dart';
import '../utils/url_fragment.dart';
import 'comparison_controller.dart';
import 'shot_store_http.dart';
import 'ui/findings_tab.dart';
import 'ui/not_in_comparison.dart';
import 'ui/previews_tab.dart';
import 'ui/scenarios_tab.dart';
import 'ui/state_chip.dart';
import 'ui/verdict.dart';
import '../ui/loading_state.dart';

/// The exported comparison page.
///
/// A comparison, browsable in a browser: the same tabs, the same five-mode
/// stage and the same merged tree the changes panel draws, over an
/// `index.json` fetched from wherever this was served rather than a runner in
/// this process. Nothing here compares anything — the verdict was computed on
/// the machine that exported the page, and this is what it concluded.
///
/// The same shape as `ScenarioWebViewer`, for the same reason: the viewer
/// bundle is data-free, built once, and copied beside whatever `index.json`
/// an export just wrote.
class ComparisonWebViewer extends StatefulWidget {
  const ComparisonWebViewer({
    super.key,
    required this.base,
    this.raw,
    this.history = const ViewerHistory(),
  });

  /// What every frame path is resolved against — the page's own URL, so a
  /// page moved to another host or a subdirectory still finds its own files.
  final Uri base;

  /// The already-fetched `index.json`, when the entry point read it to decide
  /// what this page is. Null makes the viewer fetch it itself.
  final String? raw;

  /// The browser's history. A test hands in its own to see what the page
  /// would push.
  final ViewerHistory history;

  @override
  State<ComparisonWebViewer> createState() => _ComparisonWebViewerState();
}

/// The page's history, as the viewer moves through it — `url_fragment.dart`
/// behind a type a test can replace.
class ViewerHistory {
  const ViewerHistory();

  /// Rewrites the entry the page is on.
  void replace(String fragment) => writeUrlFragment(fragment);

  /// A new entry, remembering the one it was pushed from.
  void push(String fragment, {required String from}) =>
      pushUrlFragment(fragment, from: from);

  /// What the current entry was pushed from, when this page pushed it.
  String? get pushedFrom => urlFragmentPushedFrom;

  void back() => urlHistoryBack();

  /// The fragment each time the browser changes it itself.
  Stream<String> get changes => urlFragmentChanges;
}

/// `previews/demo%2Fcard.dart%23card` → the tab and the decoded selection, or
/// null when [fragment] does not start with a tab this page has.
///
/// [fragment] arrives **raw** — `Uri.fragment` does not unspell escapes — and
/// the escapes are undone here, *after* the split: only the first `/`
/// structures anything, so a `%2F` in the selection never creates structure
/// and a raw `/` written by the viewer itself still reads back. That one rule
/// is what lets the PR comment escape every segment fully while the address
/// bar keeps its slashes readable, and both spellings land on the same place.
@visibleForTesting
(String tab, String? selected)? parseViewerFragment(String fragment) {
  var slash = fragment.indexOf('/');
  var tab = slash < 0 ? fragment : fragment.substring(0, slash);
  if (tab != 'previews' && tab != 'scenarios' && tab != 'findings') {
    return null;
  }
  if (slash < 0) return (tab, null);
  var rest = fragment.substring(slash + 1);
  try {
    return (tab, Uri.decodeComponent(rest));
  } on ArgumentError {
    // A hand-typed `%` that spells no escape: take the text as it stands.
    return (tab, rest);
  }
}

class _ComparisonWebViewerState extends State<ComparisonWebViewer> {
  late final _store = HttpShotStore(widget.base);

  /// Satisfies the tabs' contract; nothing on an exported page captures, so it
  /// is never asked whether the window is quiet.
  final _settle = SettleRegistry();

  ComparisonIndex? _index;
  String? _error;

  /// The two halves the tabs draw, filled once from the file. [HalfStage.done]
  /// from the start: the run this page shows already happened.
  ComparisonHalf? _previews;
  ComparisonHalf? _scenarios;

  String _tab = 'previews';

  /// What the tabs' address would name — the selected row, scenario or step.
  String? _selected;

  /// True when the tab came from the fragment — a linked-to tab must not be
  /// second-guessed by [_apply]'s empty-previews default.
  var _addressed = false;

  StreamSubscription<String>? _fragment;

  @override
  void initState() {
    super.initState();
    // The place the link named. From [ComparisonWebViewer.base] rather than a
    // live read, which is also what lets a test hand a fragment in.
    _goTo(widget.base.fragment);
    _fragment = widget.history.changes.listen(_arrive);
    if (widget.raw case var raw?) {
      _apply(raw);
    } else {
      unawaited(_load());
    }
  }

  void _goTo(String fragment) {
    if (parseViewerFragment(fragment) case (var tab, var selected)?) {
      _tab = tab;
      _selected = selected;
      _addressed = true;
    }
  }

  /// Where the page is, as its URL spells it. Decoded — the shim spells the
  /// escapes.
  String get _address => _selected == null ? _tab : '$_tab/${_selected!}';

  /// The browser moved — back, forward, or an edited address. Something that
  /// is not an address on this page is replaced by where the page still is,
  /// so the bar never shows a place the page is not drawing.
  void _arrive(String fragment) {
    var addressed = parseViewerFragment(fragment) != null;
    setState(() => _goTo(fragment));
    if (!addressed) widget.history.replace(_address);
  }

  /// Moves the page to [tab] and [selected], and decides what that costs the
  /// back button.
  ///
  /// **Deeper is an entry; sideways is not.** Another tab, a finding opened
  /// from the list, a step pushed over its flow: each is a place the reader
  /// went *into*, and back should come out of it. Another row in the same list
  /// replaces the entry the page is on, because thirty row clicks must not
  /// become thirty presses of the back button — the reason the page only ever
  /// replaced until back started leaving it altogether.
  ///
  /// **Up out of a step goes back** when this page pushed that step from the
  /// flow it is returning to. Replacing instead would leave the flow in the
  /// history twice, and the next press of back would seem to do nothing.
  void _move(String tab, String? selected) {
    if (tab == _tab && selected == _selected) return;
    var from = _address;
    var fromTab = _tab;
    var wasStep = _stepOf(_tab, _selected);
    var isStep = _stepOf(tab, selected);
    setState(() {
      _tab = tab;
      _selected = selected;
    });
    var to = _address;
    if (tab != fromTab || (isStep && !wasStep)) {
      widget.history.push(to, from: from);
    } else if (wasStep && !isStep && widget.history.pushedFrom == to) {
      widget.history.back();
    } else {
      widget.history.replace(to);
    }
  }

  /// Whether [selected] on [tab] names a step rather than a flow — split
  /// against the flows there are, the way the scenarios tab splits it.
  bool _stepOf(String tab, String? selected) {
    if (tab != 'scenarios' || selected == null) return false;
    var scenarios = _index?.scenarios ?? const [];
    var split = splitScenarioAddress(
      selected,
      scenarios.map((scenario) => scenario.scenario),
    );
    return split?.$2 != null;
  }

  Future<void> _load() async {
    String? raw;
    try {
      var response = await http.get(widget.base.resolve('index.json'));
      if (response.statusCode == 200) raw = response.body;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      if (raw == null) {
        _error =
            'This page could not read its own index.json. A comparison page '
            'has to be served over HTTP — opening index.html from the '
            'filesystem leaves the browser unable to fetch anything beside '
            'it.';
      } else {
        _apply(raw);
      }
    });
  }

  /// Parses [raw] into the fields the next build draws from. No [setState] of
  /// its own, so [initState] can call it for a body the entry point already
  /// fetched.
  void _apply(String raw) {
    try {
      var index = ComparisonIndex.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
      _index = index;
      _previews = ComparisonHalf(
        ComparisonHalfKind.previews,
        stage: HalfStage.done,
      )..rows.addAll(index.previewItems);
      _scenarios = ComparisonHalf(
        ComparisonHalfKind.scenarios,
        stage: HalfStage.done,
      )..scenarios.addAll(index.scenarios);
      // Findings first unless the link named a place. It is the answer to
      // the question a reader arrives with, and it is empty exactly when
      // there is no such question — in which case the halves are what is left
      // to look at.
      if (!_addressed) {
        _tab = index.findings.isNotEmpty
            ? 'findings'
            : index.previewItems.isNotEmpty
            ? 'previews'
            : index.scenarios.isNotEmpty
            ? 'scenarios'
            : 'findings';
        // Written, so the address bar is a link to the tab the page chose.
        // Only here: an address that named a place is left naming it, drawn
        // or not.
        widget.history.replace(_address);
      }
    } catch (error) {
      _error = 'index.json could not be read:\n$error';
    }
  }

  void _select(String tab) => _move(tab, tab == _tab ? _selected : null);

  void _selectRow(String id) => _move(_tab, id);

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    if (_error case var error?) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(FwSpacing.xl),
            child: SelectableText(error, style: context.type.bodyMuted),
          ),
        ),
      );
    }
    var index = _index;
    if (index == null) {
      return const Scaffold(
        body: LoadingState(title: 'Loading the comparison…'),
      );
    }

    var tabs = [
      'findings',
      if (index.previewItems.isNotEmpty) 'previews',
      if (index.scenarios.isNotEmpty || index.scenariosNote != null)
        'scenarios',
    ];

    return Scaffold(
      backgroundColor: colors.bg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(index: index, tabs: tabs, selected: _tab, onSelect: _select),
          const Divider(height: 1),
          Expanded(child: _body(index, tabs)),
        ],
      ),
    );
  }

  Widget _body(ComparisonIndex index, List<String> tabs) {
    if (tabs.isEmpty) {
      return const EmptyState(
        icon: Icons.compare_outlined,
        title: 'Nothing compared',
        message: 'This comparison produced no rows on either half.',
      );
    }
    // A tab this comparison does not have — `#scenarios/…` on a page that
    // compared previews only — is a miss like any other, not the first tab.
    if (!tabs.contains(_tab)) return NotInComparison(address: _address);
    var tab = _tab;
    if (tab == 'findings') {
      return FindingsTab(index: index, store: _store, onOpen: _move);
    }
    if (tab == 'scenarios' && index.scenarios.isEmpty) {
      return EmptyState(
        icon: Icons.route_outlined,
        title: 'Not compared',
        message: index.scenariosNote ?? 'No scenarios were compared.',
      );
    }
    // The same verdict the panel draws over its list, minus the controls: an
    // exported page has no session to hold a rule, so the chips are labels —
    // which is exactly what `onToggle: null` is for.
    return tab == 'previews'
        ? PreviewsTab(
            half: _previews!,
            store: _store,
            settle: _settle,
            selected: _selected,
            onSelect: _selectRow,
            header: ComparisonVerdict.ofHalf(_previews!),
            framesWithheld: index.framesWithheldFor,
          )
        : ScenariosTab(
            half: _scenarios!,
            store: _store,
            settle: _settle,
            selected: _selected,
            onSelect: _selectRow,
            header: ComparisonVerdict.ofHalf(_scenarios!),
            framesWithheld: index.framesWithheldFor,
          );
  }

  @override
  void dispose() {
    unawaited(_fragment?.cancel());
    _previews?.dispose();
    _scenarios?.dispose();
    super.dispose();
  }
}

/// A receipt, then `[ findings ][ previews ][ scenarios ]  · chips ·`.
///
/// The changes panel's strip, without the files tab — an exported page has no
/// git to read, so the file diff stays where the repository is — over a line
/// the panel does not need and this page cannot do without.
///
/// **The receipt is the page's provenance.** A reader arriving from a
/// pull-request comment is looking at a page some workflow uploaded, and their
/// first two questions are whether it still describes the branch and whether
/// it still describes today. The page could answer neither: it knew the base
/// ref and nothing else, and the only `head` in the file was the *path* of a
/// worktree on somebody else's machine.
///
/// The chips count the **selected tab's** findings, not the comparison's. They
/// used to count the comparison's while sitting over one half, so the
/// scenarios tab read `Changes 0 · All 19` under a header saying `2 failed · 7
/// changed` — numbers about the other tab.
class _Header extends StatelessWidget {
  const _Header({
    required this.index,
    required this.tabs,
    required this.selected,
    required this.onSelect,
  });

  final ComparisonIndex index;
  final List<String> tabs;
  final String selected;
  final ValueChanged<String> onSelect;

  /// What the chips over [selected] count.
  Map<ComparedState, int> get _counts {
    var states = switch (selected) {
      'previews' => index.previewItems.map((item) => item.state),
      'scenarios' => index.scenarios.map((scenario) => scenario.state),
      _ => [
        ...index.previewItems.map((item) => item.state),
        ...index.scenarios.map((scenario) => scenario.state),
      ],
    };
    var counts = <ComparedState, int>{};
    for (var state in states) {
      if (isComparedFinding(state)) {
        counts[state] = (counts[state] ?? 0) + 1;
      }
    }
    return Map.fromEntries(
      counts.entries.toList()
        ..sort((a, b) => a.key.index.compareTo(b.key.index)),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          FwSpacing.xl,
          FwSpacing.md,
          FwSpacing.xl,
          0,
        ),
        child: _Receipt(index),
      ),
      Padding(
        padding: const EdgeInsets.only(left: FwSpacing.xl, right: FwSpacing.xl),
        child: Row(
          children: [
            for (var tab in tabs)
              _TabButton(
                label: tab,
                selected: tab == selected,
                onTap: () => onSelect(tab),
              ),
            const Spacer(),
            for (var entry in _counts.entries)
              Padding(
                padding: const EdgeInsets.only(left: FwSpacing.xs),
                child: StateChip(entry.key, count: entry.value),
              ),
          ],
        ),
      ),
    ],
  );
}

/// What this page is a report of: the two commits, the reach, and the clock.
class _Receipt extends StatelessWidget {
  const _Receipt(this.index);

  final ComparisonIndex index;

  static String _sha7(String sha) => sha.length > 7 ? sha.substring(0, 7) : sha;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var packages = {
      ...index.previewsHalf.packages,
      ...?index.scenariosHalf?.packages,
    };
    var compared = index.previewItems.length + index.scenarios.length;
    var receipt = _line(context, compared, packages);
    if (index.caveats.isEmpty) return receipt;
    // Under the receipt, in the page's own voice: what the pull-request comment
    // quotes under its heading, for the reader who came straight here.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        receipt,
        for (var caveat in index.caveats)
          Padding(
            padding: const EdgeInsets.only(top: FwSpacing.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: FwIconSize.xs,
                  color: colors.warningText,
                ),
                const SizedBox(width: FwSpacing.xs),
                Expanded(
                  child: Text(
                    caveat,
                    style: context.type.micro.copyWith(
                      color: colors.warningText,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _line(BuildContext context, int compared, Set<String> packages) {
    var colors = context.colors;
    var parts = [
      '$compared compared',
      if (packages.length > 1) 'across ${packages.length} packages',
      if (index.ms > 0) 'in ${(index.ms / 1000).toStringAsFixed(1)}s',
      // Rendered from the reader's own clock against the run's, so a page
      // opened a week after the push says so rather than showing a date
      // nobody subtracts in their head.
      ?ageOf(index.at),
    ];
    return Row(
      children: [
        Expanded(
          child: RichText(
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: context.type.micro.copyWith(color: colors.mut),
              children: [
                // Head first, then base: "this, against that" is the sentence
                // the reader is holding. Two bare shas side by side made
                // whoever read it guess which was which.
                if (index.headCommit case var head?) ...[
                  TextSpan(
                    text: _sha7(head),
                    style: context.type.micro.copyWith(color: colors.ink),
                  ),
                  const TextSpan(text: ' '),
                ],
                const TextSpan(text: 'against '),
                TextSpan(
                  text: index.against,
                  style: context.type.micro.copyWith(color: colors.ink),
                ),
                TextSpan(text: ' · ${parts.join(' · ')}'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.lg,
          vertical: FwSpacing.md,
        ),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? colors.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: context.type.body.copyWith(
            color: selected ? colors.ink : colors.mut,
          ),
        ),
      ),
    );
  }
}
