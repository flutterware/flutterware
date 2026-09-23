import 'package:material_ui/material_ui.dart';
import 'package:flutterware/previews_guest.dart';

import '../inspect/elements_view.dart';
import '../inspect/inspect_dock.dart';
import '../inspect/semantics_node.dart';
import '../inspect/semantics_view.dart';
import '../inspect/transcript.dart';
import '../ui/design/design.dart';
import 'catalog_session.dart';
import '../ui/empty_state.dart';

/// The inspection panel: Chrome's shape, docked under the preview.
///
/// Collapsible and resizable, because the resting height is not the working
/// one — a widget tree is deep, and 260px is enough to see that there is a tree
/// and not enough to read it.
///
/// It reads the **live** guest through [CatalogSession], never a
/// `PluginAction`: an action renders its own headless copy, and a copy has none
/// of the state a person put this one into. That is the whole reason the panel
/// is not simply a rendering of `fw run previews inspect --tree`.
class InspectPanel extends StatefulWidget {
  const InspectPanel({
    super.key,
    required this.session,
    required this.available,
    required this.highlight,
    required this.semanticsHighlight,
    required this.picking,
    required this.controls,
  });

  final CatalogSession session;

  /// The node the pointer is over, shared with the preview's overlay — set
  /// here when you run down the tree, set there when you sweep the picker over
  /// the demo. One rectangle, pointed at from either end.
  final ValueNotifier<String?> highlight;

  /// The Semantics tab's hover, its own notifier as on the step page: the id
  /// spaces differ, and only the elements one round-trips through the picker.
  final ValueNotifier<SemanticsSnapshotNode?> semanticsHighlight;

  /// Whether the preview is in picking mode.
  final ValueNotifier<bool> picking;

  /// How tall the panel and the preview are together.
  ///
  /// Passed in rather than measured here, and that is not fussiness: a `Column`
  /// lays a non-flex child out with an **unbounded** main axis, so a
  /// `LayoutBuilder` in this position reads `maxHeight: infinity` and any clamp
  /// against it is a clamp against nothing. The panel would resize past the
  /// bottom of the window and take the canvas with it.
  final double available;

  /// The Controls tab's body, supplied rather than built here.
  ///
  /// Keeps this file free of knob widgets — which the top bar's axis controls
  /// share, so they cannot simply move — and keeps the import pointing one way.
  final WidgetBuilder controls;

  @override
  State<InspectPanel> createState() => _InspectPanelState();
}

class _InspectPanelState extends State<InspectPanel> {
  /// On the session, like the open tab and for the same reason: the shell
  /// rebuilds this panel from scratch whenever you come back to it, and a
  /// collapse kept here was forgotten on every trip to another plugin.
  bool get _collapsed => widget.session.panelCollapsed;
  set _collapsed(bool value) => widget.session.panelCollapsed = value;

  /// The last semantics read, parsed once and held by identity.
  ///
  /// Parsed in the build it would hand [SemanticsView] a *fresh* root on
  /// every rebuild — and the view keeps its selection by identity, so any
  /// session notify would silently clear what you had selected. The
  /// transcript rides the same memo: the tab's badge wants the finding count
  /// on every build, whichever tab is showing.
  Map<String, Object?>? _semanticsRaw;
  SemanticsSnapshotNode? _semanticsParsed;
  SemanticsTranscript? _transcript;

  SemanticsSnapshotNode? _parsedSemantics(Map<String, Object?>? raw) {
    if (raw == null) return null;
    if (!identical(raw, _semanticsRaw)) {
      _semanticsRaw = raw;
      _semanticsParsed = SemanticsSnapshotNode.fromJson(raw);
      _transcript = SemanticsTranscript.of(_semanticsParsed!);
    }
    return _semanticsParsed;
  }

  @override
  void initState() {
    super.initState();
    // After the frame: turning this on starts a read, and a read that lands
    // synchronously would notify during a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncInspecting();
      // Wider than [_syncInspecting] on purpose: the watch runs for as long as
      // the panel is here, whichever tab is showing, because a resize changes
      // what Problems should say and Problems is not the Elements tab.
      widget.session.panelOpen = true;
    });
  }

  @override
  void dispose() {
    // Safe here only because the setters deliberately do not notify.
    widget.session
      ..inspecting = false
      ..inspectingSemantics = false
      ..panelOpen = false;
    super.dispose();
  }

  /// Tells the session which projections are actually being looked at.
  ///
  /// Called after anything that could change the answer — a tab, the collapse
  /// — rather than once at mount, because the panel now opens on Controls and
  /// a mount is no longer the moment either becomes visible. The semantics
  /// flag matters more than the tree's: it is what turns the *guest's*
  /// semantics building on and off.
  void _syncInspecting() {
    widget.session
      ..inspecting =
          !_collapsed && widget.session.inspectTab == InspectTab.elements
      ..inspectingSemantics =
          !_collapsed && widget.session.inspectTab == InspectTab.semantics;
  }

  @override
  Widget build(BuildContext context) {
    var session = widget.session;
    // No `AddressScope` of its own: `inspect` is declared by [CatalogView],
    // because the picker writes a selection from the *preview* and that is on
    // the other side of the canvas. One namespace, two writers.
    return InspectDock(
      available: widget.available,
      current: session.inspectTab.name,
      collapsed: _collapsed,
      onChanged: (current, collapsed) => setState(() {
        _collapsed = collapsed;
        session.inspectTab = InspectTab.values.byName(current);
        _syncInspecting();
      }),
      // Leftmost, where Chrome puts it, and before the tabs because it is not
      // one: it changes what the *preview* does.
      leading: ValueListenableBuilder(
        valueListenable: widget.picking,
        builder: (context, on, _) => InspectStripButton(
          icon: Icons.my_location,
          tooltip: on ? 'Stop picking (esc)' : 'Pick a widget in the preview',
          active: on,
          onTap: () {
            // Arming it is also a request to see the tree: picking a widget
            // and landing on the knobs would be answering a question nobody
            // asked.
            setState(() {
              _collapsed = false;
              session.inspectTab = InspectTab.elements;
              _syncInspecting();
            });
            widget.picking.value = !widget.picking.value;
          },
        ),
      ),
      // All of it, whichever tab is open. The tree is read again, the
      // problems are *forgotten* and collected again — the record only grows
      // on its own, so a problem that has stopped needs somebody to say so —
      // and the semantics, when the guest is building any.
      onRefresh: () async {
        await session.forgetErrors();
        await session.readTree();
        if (session.inspectingSemantics) await session.readSemantics();
      },
      tabs: [
        InspectDockTab(
          id: InspectTab.controls.name,
          label: InspectTab.controls.label,
          // **What says the panel is worth opening.** It opens closed, because
          // most entries declare nothing and a permanent empty drawer is a
          // permanent reminder of a feature you are not using — so the count is
          // how a demo with three knobs says so without taking 260px from every
          // demo that has none. Zero draws nothing at all, as on Problems.
          //
          // Only after the entry has built: a knob is declared while the demo
          // builds and reported afterwards, so on a first visit this arrives a
          // beat after the picture does.
          badge: session.knobs.knobs.length,
          body: widget.controls,
        ),
        InspectDockTab(
          id: InspectTab.elements.name,
          label: InspectTab.elements.label,
          body: (context) => ElementsView(
            root: session.treeForSelection?.root,
            placeholder: session.selected == null
                ? 'No entry selected'
                : 'Reading the tree…',
            highlight: widget.highlight,
            displayRoot: session.displayRoot,
            // The guest walks its own tree, so a node with no box really has
            // none.
            readsWidgets: true,
          ),
        ),
        InspectDockTab(
          id: InspectTab.semantics.name,
          label: InspectTab.semantics.label,
          // The label audits' findings on the current read — the reason to
          // open the tab, said without opening it. Parsing here keeps the
          // badge honest whichever tab is showing; the memo makes it free.
          badge: _parsedSemantics(session.semanticsForSelection?.root) == null
              ? 0
              : _transcript?.findingCount ?? 0,
          body: (context) => SemanticsView(
            root: _parsedSemantics(session.semanticsForSelection?.root),
            transcript: _transcript,
            placeholder: session.selected == null
                ? 'No entry selected'
                : 'Reading what a screen reader gets…',
            highlight: widget.semanticsHighlight,
          ),
        ),
        InspectDockTab(
          id: InspectTab.problems.name,
          label: InspectTab.problems.label,
          // Only Problems carries one, and only when there is something to
          // carry.
          badge:
              (session.errorsForSelection?.errors.length ?? 0) +
              (session.selectedError == null ? 0 : 1),
          body: (_) => _Problems(session: session),
        ),
        InspectDockTab(
          id: InspectTab.console.name,
          label: InspectTab.console.label,
          body: (_) => _Console(session: session),
        ),
      ],
    );
  }
}

/// What the entry on screen reported while building and painting.
///
/// Not what it failed to compile. That is a different question with a
/// different answer already on screen — the compiler's own words, where the
/// widget would have been — and it is answered before a frame is ever drawn.
/// This is the half that a green compile says nothing about: a demo that throws
/// in `build` paints Flutter's red `ErrorWidget` while everything about
/// compiling and reloading reports success.
class _Problems extends StatelessWidget {
  const _Problems({required this.session});

  final CatalogSession session;

  @override
  Widget build(BuildContext context) {
    // **The compile error belongs here too.** An entry that does not build
    // never renders, so waiting for a render report is waiting for something
    // that will never arrive — which is what this pane did: it sat on
    // "waiting…" forever for the one entry in the catalog that most obviously
    // has a problem. A tab called Problems should hold every reason this entry
    // is not working, and refusing to compile is the first of them.
    var compileError = session.selectedError;
    var report = session.errorsForSelection;
    var errors = report?.errors ?? const <InspectError>[];

    if (compileError == null && errors.isEmpty) {
      return Container(
        color: context.colors.panel,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(FwSpacing.lg),
        child: Text(
          report == null
              ? 'Waiting for the entry to render…'
              : 'It renders without the framework reporting anything.',
          textAlign: TextAlign.center,
          style: context.type.caption.copyWith(color: context.colors.mut),
        ),
      );
    }

    return Container(
      color: context.colors.panel,
      child: ListView.separated(
        primary: false,
        padding: const EdgeInsets.symmetric(vertical: FwSpacing.sm),
        itemCount: errors.length + (compileError == null ? 0 : 1),
        separatorBuilder: (context, _) =>
            Divider(height: 1, color: context.colors.line),
        itemBuilder: (context, index) {
          if (compileError != null && index == 0) {
            // First, because nothing below it ran. The others are what the
            // framework said while the entry was on screen; this is why it
            // never got there.
            return _Problem(
              error: InspectError(exception: compileError, library: 'compiler'),
            );
          }
          return _Problem(
            error: errors[index - (compileError == null ? 0 : 1)],
          );
        },
      ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.error});

  final InspectError error;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.lg,
        vertical: FwSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2, right: FwSpacing.sm),
                child: Icon(
                  Icons.error_outline,
                  size: FwIconSize.sm,
                  color: colors.red,
                ),
              ),
              Expanded(
                child: SelectableText(
                  error.exception,
                  style: context.type.caption.copyWith(color: colors.ink),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 22, top: FwSpacing.xxs),
            child: Text(
              [
                ?error.library,
                ?error.context,
                // Counted rather than repeated: an error thrown from `paint`
                // fires once per frame, and a panel driving frames continuously
                // would otherwise show one overflow as several hundred
                // problems.
                if (error.count > 1) '${error.count}×',
              ].join(' · '),
              style: context.type.micro.copyWith(color: colors.mut),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the demo printed, newest at the bottom.
///
/// The output existed and reached nowhere anybody could see it. The guest's
/// `print` went to the *host's* console — the terminal running the GUI — so the
/// panel could not show it, `fw` could not return it, and an agent driving a
/// demo could not read the first thing a developer reaches for when something
/// is wrong. That is finding 8 of the panel spec, and this is the half of it
/// you can look at.
///
/// Scoped to the selected entry, like every other pane here. The guest empties
/// its buffer when the entry changes, so this shows what *this* demo has said
/// rather than a running tape of the session.
class _Console extends StatefulWidget {
  const _Console({required this.session});

  final CatalogSession session;

  @override
  State<_Console> createState() => _ConsoleState();
}

class _ConsoleState extends State<_Console> {
  final _scroll = ScrollController();

  /// Whether new lines drag the view down with them.
  ///
  /// Kept **off the moment you scroll up**, which is the one thing a console
  /// has to get right: a demo printing every frame with a view that snaps back
  /// to the bottom is a console you cannot read a word of. Scrolling back to
  /// the end turns it on again, so nothing has to be pressed to resume.
  var _following = true;

  @override
  void initState() {
    super.initState();
    widget.session.guestLogs.addListener(_onLines);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.session.guestLogs.removeListener(_onLines);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // A few pixels of slack: `maxScrollExtent` moves as lines are added, and
    // demanding an exact match would drop out of following on the very frame a
    // line arrives.
    var atEnd = _scroll.offset >= _scroll.position.maxScrollExtent - 8;
    if (atEnd != _following) setState(() => _following = atEnd);
  }

  void _onLines() {
    if (!_following) return;
    // After the frame that lays the new line out — there is nothing to scroll
    // to until it has a height.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_following || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      color: colors.panel,
      child: Column(
        children: [
          Expanded(
            child: ValueListenableBuilder(
              valueListenable: widget.session.guestLogs,
              builder: (context, lines, _) {
                if (lines.isEmpty) {
                  return const EmptyState(
                    icon: Icons.terminal,
                    title: 'Nothing printed yet',
                    message: 'Anything this demo prints shows up here.',
                  );
                }
                var dropped = widget.session.logsDropped;
                return ListView.builder(
                  controller: _scroll,
                  primary: false,
                  padding: const EdgeInsets.symmetric(vertical: FwSpacing.xs),
                  itemCount: lines.length + (dropped == 0 ? 0 : 1),
                  itemBuilder: (context, index) {
                    // Said rather than silently begun in the middle: a
                    // scrollback that quietly starts partway reads as one that
                    // has everything, and the one time that matters is the one
                    // time you are looking for the first line.
                    if (dropped > 0 && index == 0) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FwSpacing.lg,
                          vertical: FwSpacing.xxs,
                        ),
                        child: Text(
                          '$dropped earlier ${dropped == 1 ? 'line' : 'lines'} '
                          'dropped',
                          style: context.type.micro.copyWith(color: colors.mut),
                        ),
                      );
                    }
                    return _LogLine(
                      line: lines[index - (dropped == 0 ? 0 : 1)],
                    );
                  },
                );
              },
            ),
          ),
          Container(height: 1, color: colors.line),
          Row(
            children: [
              InspectStripButton(
                icon: Icons.block,
                tooltip: 'Clear',
                onTap: () => widget.session.clearLogs(),
              ),
              const Spacer(),
              if (!_following)
                InspectStripButton(
                  icon: Icons.vertical_align_bottom,
                  tooltip: 'Follow new lines',
                  onTap: () {
                    setState(() => _following = true);
                    if (_scroll.hasClients) {
                      _scroll.jumpTo(_scroll.position.maxScrollExtent);
                    }
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({required this.line});

  final InspectLogLine line;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var at = DateTime.fromMillisecondsSinceEpoch(line.at);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.lg,
        vertical: 1,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Fixed width and monospace so the times form a column rather than a
          // ragged edge that the eye has to re-find on every line.
          SizedBox(
            width: 62,
            child: Text(
              '${_two(at.hour)}:${_two(at.minute)}:${_two(at.second)}'
              '.${at.millisecond.toString().padLeft(3, '0')}',
              style: context.type.micro.copyWith(
                color: colors.mut,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              line.text,
              style: context.type.caption.copyWith(color: colors.ink),
            ),
          ),
        ],
      ),
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}
