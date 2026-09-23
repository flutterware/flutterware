import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';

import 'design/design.dart';

/// How wide the strip that offers a folded aside back is.
const asideGutterWidth = 28.0;

/// Whether the panel's own navigation column is showing, and whether the panel
/// has one at all.
///
/// A preference about the window, like the rail's, and held the same way:
/// not per plugin, not per worktree, not written to disk. Two panels that both
/// have a list read the same answer, so folding one and stepping to the other
/// does not hand you straight back the thing you just folded away. It used to
/// be per package on the catalog alone, which is why previews could fold its
/// list and the other seven panels with a list could not.
///
/// [present] is counted rather than assigned, because the only thing that can
/// honestly answer "does this panel have an aside" is an [AsidePane] that is
/// mounted. A panel with none never registers, so the rail's peek strip keeps
/// working there — which is what keeps the shell from growing a case per
/// plugin.
class AsideVisibility extends ChangeNotifier {
  AsideVisibility({required this.railVisible, required this.setRailVisible});

  /// The rail's half of [expanded], reached through the shell rather than held
  /// here: the layout and the window minimum both read the shell's copy, and a
  /// second one would be a second truth to keep in step.
  final ValueGetter<bool> railVisible;
  final ValueSetter<bool> setRailVisible;

  /// Whether the aside is drawn. True until it is folded.
  bool get visible => _visible;
  var _visible = true;
  set visible(bool value) {
    if (value == _visible) return;
    _visible = value;
    notifyListeners();
  }

  /// True while a panel that has an aside is mounted.
  bool get present => _mounted > 0;
  var _mounted = 0;

  /// Both panes folded away — the state [expand] puts you in.
  bool get expanded => !_visible && !railVisible();

  /// Folds both panes and remembers which of them was showing, so [restore]
  /// gives back what was there rather than a rail that was already hidden.
  ///
  /// A macro over the two toggles rather than a third state. There is nothing to
  /// be stuck in and nothing to diverge: ⌘B still works on the rail alone, the
  /// gutter still works on the aside alone, and whichever of the two you use
  /// leaves the other exactly where it was.
  void expand() {
    _railWasVisible = railVisible();
    setRailVisible(false);
    visible = false;
  }

  /// Undoes [expand] — the aside back, and the rail back only if [expand] was
  /// the thing that took it.
  void restore() {
    if (_railWasVisible) setRailVisible(true);
    visible = true;
  }

  void toggleExpanded() => expanded ? restore() : expand();

  var _railWasVisible = true;

  var _disposed = false;

  void _register() {
    _mounted++;
    _notifyAfterFrame();
  }

  void _unregister() {
    _mounted--;
    _notifyAfterFrame();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Mount and unmount both land inside a build, where telling the shell
  /// straight away would rebuild it in the middle of laying itself out. The end
  /// of the frame is the earliest moment a listener can safely hear it, and
  /// nothing is waiting on the news: [present] is read by the rail's peek strip
  /// alone, to stand down while the gutter is up, and a strip that is invisible
  /// until the pointer reaches it can afford to learn that a frame late.
  void _notifyAfterFrame() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) notifyListeners();
    });
  }
}

/// Hands [AsideVisibility] to the panel below, and rebuilds it when the answer
/// changes.
class AsideScope extends InheritedNotifier<AsideVisibility> {
  const AsideScope({
    super.key,
    required AsideVisibility aside,
    required super.child,
  }) : super(notifier: aside);

  static AsideVisibility of(BuildContext context) {
    var scope = context.dependOnInheritedWidgetOfExactType<AsideScope>();
    assert(scope != null, 'No AsideScope above this panel.');
    return scope!.notifier!;
  }

  /// The same, for a widget that may also be built outside the shell — the
  /// catalog renders on the exported page as well as in the panel.
  static AsideVisibility? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AsideScope>()?.notifier;
}

/// A panel's navigation column: the list you pick from, and nothing else.
///
/// Draws [child] at [width] while the aside is showing and an [AsideGutter] in
/// its place once it is folded, so a panel that adopts this gets the way back
/// without writing one. Registers itself either way, because a folded aside is
/// still an aside and the rail's peek strip has to know it is standing on one.
class AsidePane extends StatefulWidget {
  const AsidePane({super.key, required this.width, required this.child});

  final double width;
  final Widget child;

  @override
  State<AsidePane> createState() => _AsidePaneState();
}

class _AsidePaneState extends State<AsidePane> {
  AsideVisibility? _aside;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    var next = AsideScope.maybeOf(context);
    if (identical(next, _aside)) return;
    _aside?._unregister();
    _aside = next?.._register();
  }

  @override
  void dispose() {
    _aside?._unregister();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var aside = _aside;
    // **Drawn here, not by the shell, and that is not a detail.** The shell
    // lays its row out before the panel inside it has built, so it cannot know
    // this frame whether the panel it is about to draw even has an aside — a
    // gutter up there is always one frame late, and the frame it is late by is
    // the first frame of a panel with nothing on it but a folded column and no
    // way out. Down here the answer is already in hand.
    if (aside != null && !aside.visible) return AsideGutter(aside: aside);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: widget.width, child: widget.child),
        const VerticalDivider(width: 1),
      ],
    );
  }
}

/// The one control that folds both panes, for an aside's own header.
///
/// On the thing it acts on, never in the window chrome. The rail's toggle
/// made that trip once already and came back — a control up in the band that
/// acts on the pane below it reads as chrome and gets scanned past.
class AsideExpandButton extends StatelessWidget {
  const AsideExpandButton({super.key});

  @override
  Widget build(BuildContext context) {
    var aside = AsideScope.maybeOf(context);
    if (aside == null) return const SizedBox.shrink();
    return _AsideIconButton(
      icon: Icons.open_in_full,
      tooltip: 'Expand the panel (⌥⌘B)',
      onPressed: aside.expand,
    );
  }
}

/// All that is left of the two panes once they are folded: the way back.
///
/// In the flow and always drawn, unlike the rail's own peek strip, which
/// appears on hover and is invisible at rest. The strip stands down while this
/// is up — see `_gutterInFlow` — so the two never stack, and that read is the
/// one thing about a folded aside the shell is allowed to learn a frame late,
/// because a control that is invisible at rest can afford it. That is the right
/// resting state for a rail folded on purpose and brought back with a known
/// shortcut; it is the wrong one for a window that has just given up both of
/// its navigation columns, where the question is how to get back. 28px of
/// 1198 is 2%, against the 39% the fold just handed back.
///
/// One button for both directions, and it reads its own label: with the rail
/// gone too there is one useful thing to do — put everything back — and with
/// the rail still there, the aside alone.
class AsideGutter extends StatelessWidget {
  const AsideGutter({super.key, required this.aside});

  final AsideVisibility aside;

  @override
  Widget build(BuildContext context) {
    var expanded = aside.expanded;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: asideGutterWidth,
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: FwSpacing.md),
              child: _AsideIconButton(
                // The fold's own glyph while both panes are away, and the
                // list's plain chevron when it is the only thing folded.
                icon: expanded ? Icons.close_fullscreen : Icons.chevron_right,
                tooltip: expanded
                    ? 'Restore the panels (⌥⌘B)'
                    : 'Show the list',
                onPressed: expanded
                    ? aside.restore
                    : () => aside.visible = true,
              ),
            ),
          ),
        ),
        // The same seam the pane it stands in for had, so the panel keeps its
        // left edge whether the column is a list or the way back to one.
        const VerticalDivider(width: 1),
      ],
    );
  }
}

/// The one icon button both halves of the fold wear.
///
/// Muted at rest, which is what this exists for. These sit in
/// a list header among controls that act on the suite — rescan, help, new — and
/// every one of those is drawn muted until the pointer is on it. An icon button
/// left to the theme takes full ink, so the one control in the row that acts on
/// the *window* came out the loudest mark in it, which is backwards.
class _AsideIconButton extends StatelessWidget {
  const _AsideIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return IconButton(
      icon: Icon(icon, size: FwIconSize.md),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 24, height: 24),
      style: ButtonStyle(
        iconColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.hovered) ? colors.ink : colors.mut,
        ),
      ),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}
