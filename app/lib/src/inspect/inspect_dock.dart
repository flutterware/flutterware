import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../ui/count_badge.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';

/// One tab of an [InspectDock]: a label, an optional count badge, and a body
/// built only while the tab is the open one.
class InspectDockTab {
  const InspectDockTab({
    required this.id,
    required this.label,
    this.badge = 0,
    this.enabled = true,
    this.disabledReason,
    required this.body,
  });

  final String id;
  final String label;

  /// Zero draws nothing at all — a badge that is always there is a
  /// decoration.
  final int badge;

  /// False for a tab that cannot be opened yet.
  ///
  /// Declared rather than enforced by the host swallowing the tap, which is
  /// what the run cockpit did while a build was in flight: five of its six
  /// tabs drew in the normal colour, took hover, and did nothing. A control
  /// that looks alive and is not costs the reader a hypothesis about their own
  /// machine — they click it twice and then start wondering about the window.
  ///
  /// Defaults to true, so a host that has no such state pays nothing.
  final bool enabled;

  /// Why it cannot be opened, as a tooltip on the dead tab. Null draws none.
  ///
  /// Worth having because the answer is never guessable from the label: *Screen*
  /// greyed out is either "there is no app yet" or "this build cannot do that",
  /// and those are a wait and a dead end.
  final String? disabledReason;

  final WidgetBuilder body;
}

/// The Chrome-shaped docked panel: a draggable grip, a tab strip, a
/// collapsible and resizable body. Extracted from Previews' inspect
/// panel so the scenarios step page is the *same* surface — one look, one
/// muscle memory — while each host declares its own tabs; the catalog's
/// live-guest tabs (Controls, Problems, Console) stay the catalog's.
///
/// Controlled: [current] and [collapsed] belong to the host, because hosts
/// have reasons of their own to move them — arming the catalog's picker jumps
/// the panel to Elements. The interaction grammar lives here, though:
/// clicking the open tab collapses the panel, clicking any tab while
/// collapsed restores it.
class InspectDock extends StatefulWidget {
  const InspectDock({
    super.key,
    required this.tabs,
    required this.current,
    required this.collapsed,
    required this.available,
    required this.onChanged,
    this.leading,
    this.onRefresh,
  });

  final List<InspectDockTab> tabs;

  /// The open tab's [InspectDockTab.id].
  final String current;

  final bool collapsed;

  /// How tall the panel and whatever it is docked under are together.
  ///
  /// Passed in rather than measured here, and that is not fussiness: a
  /// `Column` lays a non-flex child out with an **unbounded** main axis, so a
  /// `LayoutBuilder` in this position reads `maxHeight: infinity` and any
  /// clamp against it is a clamp against nothing. The panel would resize past
  /// the bottom of the window and take the canvas with it.
  final double available;

  /// Every state move: a tab switch, a collapse, a restore.
  final void Function(String current, bool collapsed) onChanged;

  /// Before the tabs — the catalog's picker, the step page's. Not a tab
  /// because it is not one: it changes what the surface *above* does.
  final Widget? leading;

  /// Shown while expanded, when the host has something to re-read.
  final Future<void> Function()? onRefresh;

  @override
  State<InspectDock> createState() => _InspectDockState();
}

class _InspectDockState extends State<InspectDock> {
  /// Below this the panel is a scrollbar with ambitions.
  static const _minHeight = 140.0;

  /// What the surface above keeps no matter how far the panel is dragged up.
  /// Without it the panel can eat the thing it is inspecting.
  static const _canvasFloor = 160.0;

  static const _stripHeight = 34.0;

  double _height = 260;

  InspectDockTab get _current => widget.tabs.firstWhere(
    (tab) => tab.id == widget.current,
    orElse: () => widget.tabs.first,
  );

  @override
  Widget build(BuildContext context) {
    var ceiling = math.max(
      _minHeight,
      widget.available - _canvasFloor - _stripHeight,
    );
    // Its own (invisible) Material: the strip and the tree run on InkWell,
    // and a reusable dock should not gamble on the host having one.
    return Material(
      type: MaterialType.transparency,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Grip(
            enabled: !widget.collapsed,
            onDrag: (delta) => setState(() {
              // Up is negative and up is bigger.
              _height = (_height - delta).clamp(_minHeight, ceiling);
            }),
          ),
          _strip(context),
          // Clamped on the way out as well as on the drag: the window can be
          // made smaller after the panel was dragged tall, and nothing about
          // that resize goes through [_Grip].
          if (!widget.collapsed)
            SizedBox(
              height: math.min(_height, ceiling),
              child: Builder(builder: _current.body),
            ),
        ],
      ),
    );
  }

  Widget _strip(BuildContext context) {
    return InspectTabStrip(
      tabs: widget.tabs,
      // Null while collapsed: no tab is open, so none of them is lit.
      current: widget.collapsed ? null : widget.current,
      onSelect: (id) {
        // Clicking the tab you are on is how you get the panel back without
        // hunting for the chevron.
        if (id == widget.current && !widget.collapsed) {
          widget.onChanged(widget.current, true);
        } else {
          widget.onChanged(id, false);
        }
      },
      leading: widget.leading,
      trailing: [
        if (!widget.collapsed)
          if (widget.onRefresh case var refresh?)
            InspectStripButton(
              icon: Icons.refresh,
              tooltip: 'Read it all again',
              onTap: () => refresh(),
            ),
        InspectStripButton(
          icon: widget.collapsed ? Icons.expand_less : Icons.expand_more,
          tooltip: widget.collapsed ? 'Show the panel' : 'Hide the panel',
          onTap: () => widget.onChanged(widget.current, !widget.collapsed),
        ),
      ],
    );
  }
}

/// The tab strip on its own, without the dock around it.
///
/// Split out because a host can want these tabs at the *top* of a pane rather
/// than docked under a canvas — the run cockpit's run page is the first, and
/// its own hand-rolled row of `TextButton`s was the reason: three surfaces
/// showing a widget tree, two of them matching and one of them not.
///
/// [InspectDock] is now a composition of this, a drag grip and a sized body,
/// so what ui_catalog and scenarios draw is unchanged.
class InspectTabStrip extends StatelessWidget {
  const InspectTabStrip({
    super.key,
    required this.tabs,
    required this.current,
    required this.onSelect,
    this.leading,
    this.trailing = const [],
  });

  /// Only [InspectDockTab.id], [InspectDockTab.label] and
  /// [InspectDockTab.badge] are read here — a strip does not build bodies.
  final List<InspectDockTab> tabs;

  /// The open tab's id, or null for none — which is what the dock passes while
  /// it is collapsed.
  final String? current;

  final void Function(String id) onSelect;

  /// Before the tabs. Not a tab because it is not one: it changes what the
  /// surface around the strip does.
  final Widget? leading;

  /// After them, hard right — a refresh, a collapse chevron.
  final List<Widget> trailing;

  static const height = _InspectDockState._stripHeight;

  @override
  Widget build(BuildContext context) {
    // Its own (invisible) Material. The tabs no longer need one — they are
    // [Tappable]s — but [leading] and [trailing] are the host's widgets, and a
    // host handing over an `IconButton` or a `CaptureButton` is handing over
    // something that does need one. Keeping it here is what lets a host pass
    // whatever it likes; it costs nothing and it is not the thing that was
    // swallowing hover.
    return Material(
      type: MaterialType.transparency,
      child: Container(
        height: height,
        color: context.colors.panel,
        padding: const EdgeInsets.symmetric(horizontal: FwSpacing.sm),
        child: Row(
          children: [
            ?leading,
            // Scrolls rather than overflows: the panel is as narrow as its
            // window allows, and a tab strip that paints Flutter's stripes over
            // itself in an inspector is a poor advertisement.
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var tab in tabs)
                      _Tab(
                        label: tab.label,
                        selected: tab.id == current,
                        badge: tab.badge,
                        enabled: tab.enabled,
                        disabledReason: tab.disabledReason,
                        onTap: () => onSelect(tab.id),
                      ),
                  ],
                ),
              ),
            ),
            ...trailing,
          ],
        ),
      ),
    );
  }
}

/// The draggable top edge.
class _Grip extends StatelessWidget {
  const _Grip({required this.enabled, required this.onDrag});

  final bool enabled;
  final void Function(double delta) onDrag;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return Container(height: 1, color: context.colors.line);
    return InspectSplitGrip(axis: Axis.horizontal, onDrag: onDrag);
  }
}

/// A one-pixel rule you can drag, with a hit area wider than it is.
///
/// Shared because three panes now sit beside or above each other on this
/// surface — the dock over its canvas, the tree beside its detail, and the run
/// page's picture beside both — and a grip that behaves differently in one of
/// them has to be learned twice.
class InspectSplitGrip extends StatelessWidget {
  const InspectSplitGrip({super.key, required this.axis, required this.onDrag});

  /// The axis of the *rule*, not of the drag: [Axis.horizontal] is a
  /// left-to-right line you drag up and down.
  final Axis axis;

  final void Function(double delta) onDrag;

  @override
  Widget build(BuildContext context) {
    var line = axis == Axis.horizontal
        ? Container(height: 1, color: context.colors.line)
        : Container(width: 1, color: context.colors.line);
    return MouseRegion(
      cursor: axis == Axis.horizontal
          ? SystemMouseCursors.resizeUpDown
          : SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: axis == Axis.horizontal
            ? (event) => onDrag(event.delta.dy)
            : null,
        onHorizontalDragUpdate: axis == Axis.vertical
            ? (event) => onDrag(event.delta.dx)
            : null,
        // The line is one pixel; the thing you have to hit is not.
        child: axis == Axis.horizontal
            ? SizedBox(height: 7, child: Center(child: line))
            : SizedBox(width: 7, child: Center(child: line)),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge = 0,
    this.enabled = true,
    this.disabledReason,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Zero draws nothing at all.
  final int badge;

  /// See [InspectDockTab.enabled].
  final bool enabled;

  final String? disabledReason;

  /// [Tappable], not [InkWell], and the reason is that the [InkWell] painted
  /// nothing. A [Material]'s ink features are painted *below* its child, and
  /// the strip puts an opaque `Container(color: colors.panel)` between the two
  /// — so every hover wash these tabs asked for was drawn and then covered.
  /// Measured on the running app: hovering a tab moved no pixel, while a
  /// [Tappable] row in the same pane tinted normally. [Tappable] paints its
  /// wash inside its own subtree, where no ancestor can cover it.
  @override
  Widget build(BuildContext context) {
    var tab = Tappable(
      // Null is the disable, so the wash, the click cursor and keyboard
      // traversal all go with it — [Tappable] already knows how to be off, and
      // a second mechanism beside it would be one more thing to keep in step.
      onTap: enabled ? onTap : null,
      focusable: enabled,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected && enabled
                  ? context.colors.accent
                  : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: context.type.caption.copyWith(
                color: !enabled
                    ? context.colors.mut3
                    : selected
                    ? context.colors.ink
                    : context.colors.mut,
              ),
            ),
            if (badge > 0) ...[
              const SizedBox(width: FwSpacing.sm),
              // Quiet, not alarming. This used to be a red pill, written for a
              // Problems tab that never arrived; a count of captured events is
              // a quantity, and painting every one of them red would make the
              // strip shout about a healthy step.
              CountBadge(badge, active: selected),
            ],
          ],
        ),
      ),
    );
    if (enabled || disabledReason == null) return tab;
    return Tooltip(message: disabledReason!, child: tab);
  }
}

/// A small icon button in the dock's strip — public so hosts can build their
/// own [InspectDock.leading] in the same voice.
class InspectStripButton extends StatelessWidget {
  const InspectStripButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// Armed, for a picker — which is a mode rather than a press, and a mode
  /// that does not look like one is a mode you forget you are in.
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Tappable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: FwSpacing.xxs),
          padding: const EdgeInsets.all(FwSpacing.sm),
          decoration: active
              ? BoxDecoration(
                  color: context.colors.accentSoft,
                  borderRadius: BorderRadius.circular(
                    context.radii.radiusSmall,
                  ),
                )
              : null,
          child: Icon(
            icon,
            size: FwIconSize.md,
            color: active ? context.colors.accent : context.colors.mut,
          ),
        ),
      ),
    );
  }
}
